# Books to Music

Suggests albums based on audiobooks you've completed on Audible. A Bedrock model
picks albums that fit each book's themes, era or music scene; Discogs confirms each one and
supplies cover art, original year and a link. Albums Discogs can't confirm are shown as
"not matched" rather than linked to a wrong record.

```
Browser ─► Lambda Function URL ─► Lambda (arm64 container image from ECR, Datadog extension)
                                    ├─ GET  /            web page
                                    ├─ GET  /api/books   completed books (history + notes JSON in S3)
                                    └─ POST /api/suggest Nova 2 Lite → Discogs search
                                                          └─ cached in DynamoDB
```

A book counts as **completed** if Audible marks it Finished, or it has 60 minutes or less left
(`complete_threshold_minutes`).

## Model A/B switch

The page has a model switch so the same book can be compared across models, which is the point
of the demo: a lite model versus a stronger one. Models are set in the `models` Terraform variable:

| Key | Model | Inference profile |
|---|---|---|
| A (default) | Nova 2 Lite | `us.amazon.nova-2-lite-v1:0` |
| B | Nova Pro | `us.amazon.nova-pro-v1:0` |

Each model's suggestions are cached separately. Metrics, LLM Observability spans and evaluations
are tagged `model:nova-2-lite` / `model:nova-pro`, so they can be compared side by side in Datadog.
Claude models need the Bedrock Marketplace agreement accepted first.

## Book notes

`book_notes.json` holds a one-line description per title, passed to the model as ground truth.
Small models confuse same-titled books (e.g. Roddy Bottum's memoir *The Royal We* vs. the
royal-romance novel). Edit a note and redeploy; that book's cached suggestions regenerate.

## Caching

| Layer | What | Lifetime |
|---|---|---|
| DynamoDB `suggest#…` | Suggestions per book and model (keyed by book, note, model ID, `PROMPT_VERSION`) | until regenerated ("New suggestions") |
| DynamoDB `discogs#…` | Each artist/album lookup, incl. misses (keyed with `MATCH_VERSION`) | 30 days (TTL) |
| Lambda memory | Book list + notes from S3; secrets | 5 / 10 minutes |
| Browser memory | Suggestions already viewed this page load, per model | until reload |

## Datadog

- **APM:** service `books-music`; boto3 calls (Bedrock, DynamoDB, S3, Secrets Manager) auto-traced, Discogs searches as `discogs.search` spans.
- **Logs:** shipped by the extension, correlated to traces (`dd.trace_id`).
- **Metrics:** Lambda enhanced metrics plus `books_music.*` (cache hit/miss, Discogs match rate, auth failures, quota, errors).
- **LLM Observability:** ml_app `books-music` — workflow `suggest_albums` → Bedrock LLM span → `discogs_lookup` tool spans, with tokens.
- **Dashboard + 4 monitors:** `terraform/datadog.tf` (Terraform output `datadog_dashboard_url`).

### Evaluations (are the suggestions legit?)

| Evaluation | Kind | Passes when |
|---|---|---|
| `discogs_verified_ratio` | code, submitted by the handler | ≥ 67% of albums found on Discogs (reasoning lists the misses) |
| `unverified_albums` | code | — (count of albums Discogs couldn't find) |
| `distinct_artists` | code | no artist repeated |
| `music-fit` | LLM judge (Datadog-managed Claude Haiku 5.5), `evals/music-fit.json` | "Excellent fit" or "Good fit": albums are real and fit the book |

The Datadog templates `goal-completeness`, `prompt-injection` and `sentiment` are also enabled on
this ml_app (created in the UI). Apply changes to `evals/*.json` with `./evals/apply.sh`, since
Terraform has no resource for LLM Observability evaluators yet.

Terraform reads `coh/datadog-api-key` and `coh/datadog-app-key` ephemerally (never stored in
state). The Lambda extension reads `books-music/datadog-api-key`, a plaintext copy that
`deploy.sh` creates on first run.

## Deploy

Requirements: Terraform ≥ 1.10, Docker running, AWS CLI signed in (`aws login`).

```bash
./deploy.sh          # terraform apply, then generates the passphrase on first run
```

`deploy.sh` prints the app URL and, the first time, the passphrase. Retrieve the passphrase later:

```bash
aws secretsmanager get-secret-value --secret-id books-music/passphrase --query SecretString --output text
```

## Secrets

| Secret | Format | Managed by |
|---|---|---|
| `discogs-pat` | `{"token": "<Discogs personal access token>"}` | you (pre-existing) |
| `books-music/passphrase` | plain string | Terraform creates it; `deploy.sh` sets the value so it stays out of state |
| `books-music/datadog-api-key` | plain string | Terraform creates it; `deploy.sh` copies the key from `coh/datadog-api-key` |

## Updating the listen history

Replace `audible_listen_history.json` and run `./deploy.sh`. Terraform uploads the new file to S3.

## Cost controls

- Passphrase required for every `/api/*` call.
- Reserved concurrency of 2 (`reserved_concurrency`).
- At most 50 new model calls per day (`daily_suggestion_limit`); cached books don't count.

## Tear down

```bash
cd terraform && terraform destroy
```
