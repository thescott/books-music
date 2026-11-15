#!/usr/bin/env bash
# Build + deploy Books to Music, then make sure the app passphrase is set.
set -euo pipefail
cd "$(dirname "$0")/terraform"

docker info >/dev/null 2>&1 || { echo "Docker isn't running — start Docker Desktop first." >&2; exit 1; }

terraform init -input=false -upgrade=false >/dev/null
terraform apply "$@"

secret_id=$(terraform output -raw passphrase_secret_id)
if ! aws secretsmanager get-secret-value --secret-id "$secret_id" >/dev/null 2>&1; then
  pass=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
  aws secretsmanager put-secret-value --secret-id "$secret_id" --secret-string "$pass" >/dev/null
  echo
  echo "Generated app passphrase (stored in Secrets Manager as $secret_id):"
  echo "  $pass"
  echo "Retrieve it later with:"
  echo "  aws secretsmanager get-secret-value --secret-id $secret_id --query SecretString --output text"
fi

# Copy the Datadog API key into the plaintext secret the Lambda extension reads (first run only).
dd_secret_id=$(terraform output -raw datadog_api_key_secret_id)
if ! aws secretsmanager get-secret-value --secret-id "$dd_secret_id" >/dev/null 2>&1; then
  src=$(terraform output -raw datadog_source_secret_name)
  aws secretsmanager get-secret-value --secret-id "$src" --query SecretString --output text \
    | python3 -c 'import sys, json; sys.stdout.write(json.load(sys.stdin)["api_key"])' \
    | aws secretsmanager put-secret-value --secret-id "$dd_secret_id" --secret-string file:///dev/stdin >/dev/null
  echo "Copied Datadog API key from $src into $dd_secret_id"
fi

echo
echo "App URL: $(terraform output -raw app_url)"
echo "Datadog dashboard: $(terraform output -raw datadog_dashboard_url)"
