output "app_url" {
  value = aws_lambda_function_url.app.function_url
}

output "passphrase_secret_id" {
  value = aws_secretsmanager_secret.passphrase.id
}

output "datadog_api_key_secret_id" {
  value = aws_secretsmanager_secret.datadog_api_key.id
}

output "datadog_source_secret_name" {
  value = var.datadog_api_key_secret_name
}

output "image_uri" {
  value = local.image_uri
}
