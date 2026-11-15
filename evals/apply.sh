#!/usr/bin/env bash
# Create or update the LLM Observability custom evaluators in evals/*.json.
# (No Terraform resource exists for these yet; this uses Datadog's preview API.)
set -euo pipefail
cd "$(dirname "$0")"

secret_field() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['$2'])"; }
DD_API_KEY=$(secret_field coh/datadog-api-key api_key)
DD_APP_KEY=$(secret_field coh/datadog-app-key app_key)
DD_SITE=${DD_SITE:-datadoghq.com}

for f in *.json; do
  name=$(python3 -c "import sys, json; print(json.load(open(sys.argv[1]))['data']['id'])" "$f")
  status=$(curl -s -o /tmp/dd-eval-resp.$$ -w '%{http_code}' -X PUT \
    "https://api.${DD_SITE}/api/unstable/llm-obs/config/evaluators/custom/${name}" \
    -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
    -H "Content-Type: application/json" --data @"$f")
  echo "${name}: HTTP ${status}"
  [[ "$status" == 2* ]] || { head -c 600 /tmp/dd-eval-resp.$$; echo; }
  rm -f /tmp/dd-eval-resp.$$
done
