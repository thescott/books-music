locals {
  dd_fn   = "functionname:${var.name}"
  dd_tags = ["service:${var.name}", "env:${var.env}", "managed-by:terraform"]

  timeseries = {
    for k, w in {
      invocations = { title = "Invocations & errors", q = [["sum:aws.lambda.enhanced.invocations{${local.dd_fn}}.as_count()", "bars"], ["sum:aws.lambda.enhanced.errors{${local.dd_fn}}.as_count()", "bars"]] }
      duration    = { title = "Duration p50 / p95 (ms)", q = [["p50:aws.lambda.enhanced.duration{${local.dd_fn}}", "line"], ["p95:aws.lambda.enhanced.duration{${local.dd_fn}}", "line"]] }
      cache       = { title = "Suggestion requests by model / cache result", q = [["sum:books_music.suggest.request{*} by {model,cache}.as_count()", "bars"]] }
      discogs     = { title = "Discogs lookups by source / matched", q = [["sum:books_music.discogs.lookup{*} by {source,matched}.as_count()", "bars"]] }
      match_ratio = { title = "Discogs match ratio by model", q = [["avg:books_music.suggest.discogs_match_ratio{*} by {model}", "line"]] }
      guards      = { title = "Auth failures / daily limit hits / errors", q = [["sum:books_music.auth.failed{*}.as_count()", "bars"], ["sum:books_music.quota.exhausted{*}.as_count()", "bars"], ["sum:books_music.error{*}.as_count()", "bars"], ["sum:books_music.discogs.error{*}.as_count()", "bars"]] }
      } : k => {
      definition = {
        type  = "timeseries"
        title = w.title
        requests = [for q in w.q : {
          queries         = [{ data_source = "metrics", name = "q", query = q[0] }]
          formulas        = [{ formula = "q" }]
          response_format = "timeseries"
          display_type    = q[1]
        }]
      }
    }
  }
}

resource "datadog_dashboard_json" "app" {
  dashboard = jsonencode({
    title       = "Books to Music"
    description = "Lambda health, cache efficiency, Discogs matching and guardrails for ${var.name}. LLM traces: LLM Observability → ml_app:${var.name}. Managed by Terraform."
    layout_type = "ordered"
    tags        = []
    widgets = concat(
      [{
        definition = {
          type             = "note"
          content          = "**Books to Music** — Lambda `${var.name}` (${var.region}).\n\n- APM: service `${var.name}`\n- Logs: `service:${var.name}`\n- LLM Observability: ml_app `${var.name}` (workflow `suggest_albums` → Bedrock LLM span → `discogs_lookup` tools)"
          background_color = "gray"
          font_size        = "14"
          show_tick        = false
        }
      }],
      [for k in ["invocations", "duration", "cache", "discogs", "match_ratio", "guards"] : local.timeseries[k]],
      [{
        definition = {
          type    = "log_stream"
          title   = "Warnings & errors"
          query   = "service:${var.name} status:(warn OR error)"
          columns = ["host", "service"]
          indexes = []
          sort    = { column = "time", order = "desc" }
        }
      }]
    )
  })
}

resource "datadog_monitor" "errors" {
  name    = "[${var.name}] Lambda errors"
  type    = "query alert"
  query   = "sum(last_15m):sum:aws.lambda.enhanced.errors{${local.dd_fn}}.as_count() + sum:books_music.error{*}.as_count() > 3"
  message = "Books to Music is failing requests. Check logs: service:${var.name} status:error"
  tags    = local.dd_tags

  monitor_thresholds {
    critical = 3
    warning  = 1
  }
  notify_no_data = false
}

resource "datadog_monitor" "auth_failures" {
  name    = "[${var.name}] Passphrase guessing"
  type    = "query alert"
  query   = "sum(last_15m):sum:books_music.auth.failed{*}.as_count() > 20"
  message = "More than 20 failed passphrase attempts in 15 minutes on the public Function URL. Consider rotating secret ${var.name}/passphrase."
  tags    = local.dd_tags

  monitor_thresholds {
    critical = 20
  }
}

resource "datadog_monitor" "quota" {
  name    = "[${var.name}] Daily suggestion limit reached"
  type    = "query alert"
  query   = "sum(last_1h):sum:books_music.quota.exhausted{*}.as_count() > 0"
  message = "The daily cap of ${var.daily_suggestion_limit} model calls was hit. Raise daily_suggestion_limit if this is legitimate use."
  tags    = local.dd_tags

  monitor_thresholds {
    critical = 0
  }
}

resource "datadog_monitor" "discogs" {
  name    = "[${var.name}] Discogs lookups failing"
  type    = "query alert"
  query   = "sum(last_30m):sum:books_music.discogs.error{*}.as_count() > 5"
  message = "Discogs API lookups are failing (rate limit, outage, or an invalid discogs-pat token)."
  tags    = local.dd_tags

  monitor_thresholds {
    critical = 5
  }
}

output "datadog_dashboard_url" {
  value = "https://app.${var.datadog_site}${datadog_dashboard_json.app.url}"
}
