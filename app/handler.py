"""Books -> Music: suggest albums based on completed Audible audiobooks.

Single Lambda behind a Function URL:
  GET  /              web page
  GET  /api/books     completed books from the listen history in S3
  POST /api/suggest   {"book_id": int, "model": "A", "refresh": bool} -> album suggestions
"""

import base64
import datetime
import difflib
import hashlib
import hmac
import json
import logging
import os
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import boto3
from botocore.config import Config
from datadog_lambda.metric import lambda_metric
from ddtrace import tracer
from ddtrace.llmobs import LLMObs

# The Datadog wrapper (datadog_lambda.handler.handler) instruments boto3 calls (Bedrock,
# DynamoDB, S3, Secrets Manager) automatically; Bedrock Converse calls become LLM spans.
log = logging.getLogger("books_music")
log.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "us-east-2")
BUCKET = os.environ["HISTORY_BUCKET"]
HISTORY_KEY = os.environ.get("HISTORY_KEY", "audible_listen_history.json")
NOTES_KEY = os.environ.get("NOTES_KEY", "book_notes.json")
TABLE = os.environ["CACHE_TABLE"]
# Demo models, e.g. {"A": {"id": "us.amazon.nova-2-lite-v1:0", "label": "Nova 2 Lite"}, "B": {...}}.
MODELS = json.loads(os.environ["MODELS"])
DEFAULT_MODEL = sorted(MODELS)[0]
DISCOGS_SECRET = os.environ["DISCOGS_SECRET_ID"]
PASSPHRASE_SECRET = os.environ["PASSPHRASE_SECRET_ID"]
THRESHOLD_MIN = int(os.environ.get("COMPLETE_THRESHOLD_MINUTES", "60"))
DAILY_LIMIT = int(os.environ.get("DAILY_SUGGESTION_LIMIT", "50"))
USER_AGENT = "BooksToMusic/1.0 +https://www.discogs.com/user/TheBestScott"
# Bump when the prompt or matching logic changes so cached suggestions regenerate.
PROMPT_VERSION = "3"
MATCH_VERSION = "2"  # bump when Discogs matching changes so cached lookups are redone
BOOKS_CACHE_SECONDS = 300
DISCOGS_CACHE_DAYS = 30

s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")
table = boto3.resource("dynamodb").Table(TABLE)
bedrock = boto3.client(
    "bedrock-runtime",
    config=Config(read_timeout=50, retries={"max_attempts": 3, "mode": "adaptive"}),
)

INDEX_HTML = (Path(__file__).parent / "index.html").read_text()

# Cached across warm invocations; refreshed every 10 minutes so rotations apply.
_secret_cache: dict[str, tuple[float, str]] = {}


def _secret(secret_id: str) -> str:
    hit = _secret_cache.get(secret_id)
    if hit and time.time() - hit[0] < 600:
        return hit[1]
    value = secrets.get_secret_value(SecretId=secret_id)["SecretString"]
    _secret_cache[secret_id] = (time.time(), value)
    return value


def _discogs_token() -> str:
    return json.loads(_secret(DISCOGS_SECRET))["token"]


def _metric(name: str, value: float = 1, **tags):
    lambda_metric(f"books_music.{name}", value, tags=[f"{k}:{v}" for k, v in tags.items()])


# ---------------------------------------------------------------- HTTP helpers


def _resp(status: int, body, content_type="application/json"):
    if content_type == "application/json":
        body = json.dumps(body)
    return {
        "statusCode": status,
        "headers": {
            "content-type": content_type,
            "cache-control": "no-store",
            "x-content-type-options": "nosniff",
        },
        "body": body,
    }


def _authorized(event) -> bool:
    supplied = (event.get("headers") or {}).get("x-passphrase", "")
    expected = _secret(PASSPHRASE_SECRET).strip()
    return bool(supplied) and hmac.compare_digest(supplied.encode(), expected.encode())


def _json_body(event) -> dict:
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode()
    return json.loads(raw)


# ---------------------------------------------------------------------- books


_books_cache: tuple[float, list[dict]] | None = None


def _s3_json(key: str, default=None):
    try:
        return json.loads(s3.get_object(Bucket=BUCKET, Key=key)["Body"].read())
    except s3.exceptions.NoSuchKey:
        return default


def _load_completed_books() -> list[dict]:
    global _books_cache
    if _books_cache and time.time() - _books_cache[0] < BOOKS_CACHE_SECONDS:
        return _books_cache[1]

    doc = _s3_json(HISTORY_KEY)
    notes = _s3_json(NOTES_KEY, {})
    books, seen = [], set()
    for item in doc["items"]:
        left = item.get("time_left_minutes")
        done = item["status"] == "Finished" or (left is not None and left <= THRESHOLD_MIN)
        dedupe_key = item["title"].strip().lower()
        if not done or dedupe_key in seen:
            continue
        seen.add(dedupe_key)
        books.append(
            {
                "id": item["id"],
                "title": item["title"],
                "authors": item["authors"],
                "status": item["status"],
                "time_left_minutes": left,
                "last_listened": item.get("last_listened"),
                "note": notes.get(item["title"]),
            }
        )
    _books_cache = (time.time(), books)
    return books


def _hash(*parts: str) -> str:
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:32]


def _cache_key(book: dict, model_id: str) -> str:
    # Includes model, prompt version and note so any of those changing yields fresh suggestions.
    authors = ",".join(sorted(a.lower() for a in book["authors"]))
    return "suggest#" + _hash(book["title"].lower(), authors, book.get("note") or "", model_id, PROMPT_VERSION)


def _model_tag(model: dict) -> str:
    return model["label"].lower().replace(" ", "-")


# ------------------------------------------------------------------- limiting


def _consume_daily_quota() -> bool:
    today = datetime.date.today().isoformat()
    try:
        table.update_item(
            Key={"pk": f"quota#{today}"},
            UpdateExpression="ADD n :one SET expires_at = :exp",
            ConditionExpression="attribute_not_exists(n) OR n < :limit",
            ExpressionAttributeValues={
                ":one": 1,
                ":limit": DAILY_LIMIT,
                ":exp": int(time.time()) + 3 * 86400,
            },
        )
        return True
    except table.meta.client.exceptions.ConditionalCheckFailedException:
        _metric("quota.exhausted")
        return False


# ---------------------------------------------------------------------- model

SUGGEST_TOOL = {
    "toolSpec": {
        "name": "submit_suggestions",
        "description": "Return music album suggestions for the given audiobook.",
        "inputSchema": {
            "json": {
                "type": "object",
                "properties": {
                    "book_vibe": {
                        "type": "string",
                        "description": "One sentence on the book's mood, themes, era or setting as it relates to music.",
                    },
                    "albums": {
                        "type": "array",
                        "minItems": 4,
                        "maxItems": 8,
                        "items": {
                            "type": "object",
                            "properties": {
                                "artist": {"type": "string"},
                                "album": {"type": "string", "description": "Exact album title as released"},
                                "year": {"type": "integer"},
                                "connection": {
                                    "type": "string",
                                    "enum": ["featured in book", "author's band", "same scene/era", "thematic match", "mood match"],
                                },
                                "reason": {"type": "string", "description": "One or two sentences tying the album to this specific book."},
                            },
                            "required": ["artist", "album", "connection", "reason"],
                        },
                    },
                },
                "required": ["book_vibe", "albums"],
            }
        },
    }
}

SYSTEM_PROMPT = (
    "You are a music curator with deep knowledge of books and record collecting. "
    "Given an audiobook someone has finished, suggest real, released albums they would enjoy next. "
    "If the book is a music memoir or about a music scene, lead with the essential records from that "
    "artist and scene, then branch out to related artists. For fiction and non-fiction, match the "
    "book's themes, setting, era and emotional tone. Mix well-known and lesser-known picks, avoid "
    "duplicating an artist, and only name albums that actually exist so they can be found on Discogs. "
    "Use the exact official album title and the primary artist name. "
    "If a description of the book is provided, trust it over your own memory: other books may share the title."
)


def _ask_model(book: dict, model_id: str) -> dict:
    prompt = f"Audiobook: \"{book['title']}\" by {', '.join(book['authors'])}.\n"
    if book.get("note"):
        prompt += f"About this book: {book['note']}\n"
    prompt += "Suggest 6 albums. Call submit_suggestions with your answer."
    out = bedrock.converse(
        modelId=model_id,
        system=[{"text": SYSTEM_PROMPT}],
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        toolConfig={"tools": [SUGGEST_TOOL], "toolChoice": {"tool": {"name": "submit_suggestions"}}},
        inferenceConfig={"maxTokens": 2000, "temperature": 0.7},
    )
    for block in out["output"]["message"]["content"]:
        if "toolUse" in block:
            ideas = block["toolUse"]["input"]
            for a in ideas["albums"]:
                a["artist"], a["album"] = a["artist"].strip(), a["album"].strip()
            return ideas
    raise RuntimeError("Model did not return suggestions")


# -------------------------------------------------------------------- Discogs


def _discogs_search(params: dict) -> list:
    url = "https://api.discogs.com/database/search?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Discogs token={_discogs_token()}", "User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read())["results"]


MIN_MATCH_SCORE = 0.75


def _norm(s: str) -> str:
    """Normalize for comparison: Discogs writes 'Eno*', 'Artist (2)', and drops leading 'The'."""
    s = s.lower().replace("&", "and")
    s = "".join(c if c.isalnum() or c.isspace() else " " for c in s)
    words = [w for w in s.split() if not w.isdigit() or len(w) > 1]
    if words and words[0] == "the":
        words = words[1:]
    return " ".join(words)


def _similarity(a: str, b: str) -> float:
    a, b = _norm(a), _norm(b)
    ratio = difflib.SequenceMatcher(None, a, b).ratio()
    # Whole-word containment ("Eno" in "Brian Eno") is a strong match, but exact still wins
    # ("Dookie" over "Dookie Demo"). Word-level so "All" doesn't match "allSTARS".
    wa, wb = set(a.split()), set(b.split())
    if wa and wb and (wa <= wb or wb <= wa):
        return 0.85 + 0.15 * ratio
    return ratio


def _match_score(album: dict, hit: dict) -> float:
    # Discogs titles look like "Artist - Album".
    artist, _, title = (hit.get("title") or "").partition(" - ")
    return 0.6 * _similarity(album["album"], title) + 0.4 * _similarity(album["artist"], artist)


def _best_discogs_hit(album: dict):
    artist = album["artist"][4:] if album["artist"].lower().startswith("the ") else album["artist"]
    attempts = [
        {"type": "master", "artist": artist, "release_title": album["album"]},
        {"type": "master", "q": f"{artist} {album['album']}"},
        {"type": "release", "artist": artist, "release_title": album["album"]},
    ]
    best, best_score = None, 0.0
    for params in attempts:
        for hit in _discogs_search({**params, "per_page": 5}):
            score = _match_score(album, hit)
            if score > best_score:
                best, best_score = hit, score
        if best_score >= 0.99:  # exact match; skip remaining searches
            break
    return (best, best_score) if best_score >= MIN_MATCH_SCORE else (None, best_score)


def _discogs_lookup(album: dict) -> dict:
    # Shows up as a tool step under the suggest_albums workflow in LLM Observability.
    with LLMObs.tool(name="discogs_lookup") as span:
        result = _discogs_lookup_inner(album)
        LLMObs.annotate(
            span=span,
            input_data={"artist": album["artist"], "album": album["album"]},
            output_data=result["discogs"],
            tags={"matched": str(bool(result["discogs"])).lower()},
        )
        return result


def _discogs_lookup_inner(album: dict) -> dict:
    search_url = "https://www.discogs.com/search/?" + urllib.parse.urlencode(
        {"q": f"{album['artist']} {album['album']}", "type": "all"}
    )
    key = "discogs#" + _hash(_norm(album["artist"]), _norm(album["album"]), MATCH_VERSION)
    cached = table.get_item(Key={"pk": key}).get("Item")
    if cached:
        match = json.loads(cached["data"])
        _metric("discogs.lookup", source="cache", matched=str(bool(match)).lower())
    else:
        try:
            with tracer.trace("discogs.search", service="discogs", resource=f"{album['artist']} - {album['album']}") as span:
                hit, score = _best_discogs_hit(album)
                span.set_tag("discogs.match_score", round(score, 2))
        except Exception as e:  # Discogs outage or rate limit shouldn't fail the whole request
            log.warning("discogs lookup failed for %s - %s: %s", album["artist"], album["album"], e)
            _metric("discogs.error")
            return {**album, "discogs": None, "discogs_search_url": search_url}
        _metric("discogs.lookup", source="api", matched=str(bool(hit)).lower())
        match = hit and {
            "title": hit.get("title"),
            "year": hit.get("year"),
            "genres": hit.get("genre", []),
            "styles": hit.get("style", []),
            "cover": hit.get("cover_image") or hit.get("thumb"),
            "url": "https://www.discogs.com" + hit["uri"] if hit.get("uri") else search_url,
            "score": round(score, 2),
        }
        table.put_item(
            Item={"pk": key, "data": json.dumps(match), "expires_at": int(time.time()) + DISCOGS_CACHE_DAYS * 86400}
        )
    return {**album, "discogs": match, "discogs_search_url": search_url}


# ---------------------------------------------------------------- evaluations

VERIFIED_PASS_RATIO = 0.67


def _submit_evaluations(span: dict | None, albums: list[dict], tags: dict[str, str]):
    """Code-based LLM Observability evaluations: does Discogs confirm the model's picks are real?"""
    if not span or not albums:
        return
    unverified = [f"{a['artist']} - {a['album']}" for a in albums if not a["discogs"]]
    ratio = 1 - len(unverified) / len(albums)
    artists = [_norm(a["artist"]) for a in albums]
    distinct = len(set(artists)) == len(artists)
    try:
        LLMObs.submit_evaluation(
            span=span,
            label="discogs_verified_ratio",
            metric_type="score",
            value=round(ratio, 3),
            assessment="pass" if ratio >= VERIFIED_PASS_RATIO else "fail",
            reasoning=("Not found on Discogs: " + "; ".join(unverified)) if unverified else "All albums found on Discogs",
            tags=tags,
        )
        LLMObs.submit_evaluation(span=span, label="unverified_albums", metric_type="score", value=len(unverified), tags=tags)
        LLMObs.submit_evaluation(
            span=span,
            label="distinct_artists",
            metric_type="boolean",
            value=distinct,
            assessment="pass" if distinct else "fail",
            tags=tags,
        )
    except Exception:  # evaluations are best-effort; never fail the user's request over them
        log.exception("failed to submit LLM Observability evaluations")


# -------------------------------------------------------------------- routes


def _suggest(event):
    body = _json_body(event)
    books = {b["id"]: b for b in _load_completed_books()}
    book = books.get(body.get("book_id"))
    if not book:
        return _resp(404, {"error": "Book not found in completed list"})
    model_key = body.get("model") or DEFAULT_MODEL
    if model_key not in MODELS:
        return _resp(400, {"error": f"Unknown model {model_key!r}"})
    model = MODELS[model_key]
    tag = _model_tag(model)

    key = _cache_key(book, model["id"])
    if not body.get("refresh"):
        cached = table.get_item(Key={"pk": key}).get("Item")
        if cached:
            _metric("suggest.request", cache="hit", model=tag)
            return _resp(200, {**json.loads(cached["data"]), "model_key": model_key, "model_label": model["label"], "cached": True})
    _metric("suggest.request", cache="refresh" if body.get("refresh") else "miss", model=tag)

    if not _consume_daily_quota():
        return _resp(429, {"error": f"Daily limit of {DAILY_LIMIT} new suggestions reached. Try again tomorrow."})

    # Workflow span groups the model call (auto-instrumented LLM span) and the Discogs tool calls.
    with LLMObs.workflow(name="suggest_albums") as wf:
        ideas = _ask_model(book, model["id"])
        with ThreadPoolExecutor(max_workers=3) as pool:
            albums = list(pool.map(_discogs_lookup, ideas["albums"]))
        matched = sum(1 for a in albums if a["discogs"])
        LLMObs.annotate(
            span=wf,
            input_data={"title": book["title"], "authors": book["authors"], "note": book.get("note")},
            output_data=[f"{a['artist']} - {a['album']}" for a in albums],
            metadata={"model": model["id"], "prompt_version": PROMPT_VERSION},
            metrics={"albums": len(albums), "discogs_matched": matched},
            tags={"book": book["title"], "model": tag, "model_slot": model_key},
        )
        _submit_evaluations(LLMObs.export_span(span=wf), albums, {"model": tag})
    _metric("suggest.generated", book=book["title"].lower().replace(" ", "_")[:60], model=tag)
    _metric("suggest.discogs_match_ratio", matched / max(len(albums), 1), model=tag)

    result = {
        "book": book,
        "book_vibe": ideas["book_vibe"],
        "albums": albums,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "model": model["id"],
        "model_key": model_key,
        "model_label": model["label"],
    }
    table.put_item(Item={"pk": key, "data": json.dumps(result)})
    return _resp(200, {**result, "cached": False})


def lambda_handler(event, context):
    method = event["requestContext"]["http"]["method"]
    path = event.get("rawPath", "/")

    if method == "GET" and path == "/":
        return _resp(200, INDEX_HTML, "text/html; charset=utf-8")
    if not path.startswith("/api/"):
        return _resp(404, {"error": "Not found"})
    if not _authorized(event):
        log.warning("rejected %s %s: bad or missing passphrase", method, path)
        _metric("auth.failed")
        return _resp(401, {"error": "Wrong or missing passphrase"})

    try:
        if method == "GET" and path == "/api/books":
            models = [{"key": k, "label": MODELS[k]["label"]} for k in sorted(MODELS)]
            return _resp(200, {"threshold_minutes": THRESHOLD_MIN, "models": models, "books": _load_completed_books()})
        if method == "POST" and path == "/api/suggest":
            return _suggest(event)
    except Exception as e:
        # Handled so the user gets JSON, but still marked as an error in APM and logs.
        log.exception("error handling %s %s", method, path)
        _metric("error", route=path)
        root = tracer.current_root_span()
        if root:
            root.set_exc_info(type(e), e, e.__traceback__)
        return _resp(500, {"error": "Something went wrong generating suggestions"})
    finally:
        LLMObs.flush()
    return _resp(404, {"error": "Not found"})
