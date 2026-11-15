data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_secretsmanager_secret" "discogs" {
  name = var.discogs_secret_name
}

data "aws_bedrock_inference_profile" "model" {
  for_each             = var.models
  inference_profile_id = each.value.id
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  app_dir    = "${path.module}/../app"
  # Image tag changes whenever app source changes, which triggers a rebuild + Lambda update.
  image_tag = substr(sha1(join("", [for f in sort(fileset(local.app_dir, "*")) : filesha1("${local.app_dir}/${f}")])), 0, 12)
  image_uri = "${aws_ecr_repository.app.repository_url}:${local.image_tag}"
}

# ------------------------------------------------------------------ secrets

# Value is set outside Terraform (see deploy.sh) so the passphrase never lands in state.
resource "aws_secretsmanager_secret" "passphrase" {
  name                    = "${var.name}/passphrase"
  description             = "Passphrase for the Books to Music web app"
  recovery_window_in_days = 7
}

# Plaintext copy of the Datadog API key for the Lambda extension (DD_API_KEY_SECRET_ARN
# must be plaintext). Value is set by deploy.sh, keeping it out of state.
resource "aws_secretsmanager_secret" "datadog_api_key" {
  name                    = "${var.name}/datadog-api-key"
  description             = "Datadog API key (plaintext) for the books-music Lambda extension"
  recovery_window_in_days = 7
}

# --------------------------------------------------------------------- data

resource "aws_s3_bucket" "data" {
  bucket_prefix = "${var.name}-data-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "history" {
  bucket       = aws_s3_bucket.data.id
  key          = "audible_listen_history.json"
  source       = var.history_file
  etag         = filemd5(var.history_file)
  content_type = "application/json"
}

resource "aws_s3_object" "notes" {
  bucket       = aws_s3_bucket.data.id
  key          = "book_notes.json"
  source       = var.notes_file
  etag         = filemd5(var.notes_file)
  content_type = "application/json"
}

resource "aws_dynamodb_table" "cache" {
  name         = "${var.name}-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }
}

# -------------------------------------------------------------------- image

resource "aws_ecr_repository" "app" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 5 most recent images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

resource "terraform_data" "image" {
  triggers_replace = [local.image_uri]

  provisioner "local-exec" {
    working_dir = local.app_dir
    command     = <<-EOT
      set -e
      aws ecr get-login-password --region ${var.region} \
        | docker login --username AWS --password-stdin ${split("/", aws_ecr_repository.app.repository_url)[0]}
      docker buildx build --platform linux/arm64 --provenance=false -t ${local.image_uri} --push .
    EOT
  }
}

# ---------------------------------------------------------------------- IAM

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid     = "InvokeModelViaProfile"
    actions = ["bedrock:InvokeModel"]
    resources = flatten([
      for p in data.aws_bedrock_inference_profile.model : concat([p.inference_profile_arn], [for m in p.models : m.model_arn])
    ])
  }

  statement {
    sid     = "ReadSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      data.aws_secretsmanager_secret.discogs.arn,
      aws_secretsmanager_secret.passphrase.arn,
      aws_secretsmanager_secret.datadog_api_key.arn,
    ]
  }

  statement {
    sid       = "ReadHistory"
    actions   = ["s3:GetObject"]
    resources = [for o in [aws_s3_object.history, aws_s3_object.notes] : "${aws_s3_bucket.data.arn}/${o.key}"]
  }

  statement {
    sid       = "Cache"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.cache.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# ------------------------------------------------------------------- Lambda

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "app" {
  function_name                  = var.name
  role                           = aws_iam_role.lambda.arn
  package_type                   = "Image"
  image_uri                      = local.image_uri
  architectures                  = ["arm64"]
  memory_size                    = 1024
  timeout                        = 60
  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      HISTORY_BUCKET             = aws_s3_bucket.data.id
      HISTORY_KEY                = aws_s3_object.history.key
      NOTES_KEY                  = aws_s3_object.notes.key
      CACHE_TABLE                = aws_dynamodb_table.cache.name
      MODELS                     = jsonencode(var.models)
      DISCOGS_SECRET_ID          = data.aws_secretsmanager_secret.discogs.arn
      PASSPHRASE_SECRET_ID       = aws_secretsmanager_secret.passphrase.arn
      COMPLETE_THRESHOLD_MINUTES = tostring(var.complete_threshold_minutes)
      DAILY_SUGGESTION_LIMIT     = tostring(var.daily_suggestion_limit)

      # Datadog: extension + datadog_lambda wrapper (see app/Dockerfile).
      DD_LAMBDA_HANDLER          = "handler.lambda_handler"
      DD_SITE                    = var.datadog_site
      DD_API_KEY_SECRET_ARN      = aws_secretsmanager_secret.datadog_api_key.arn
      DD_SERVICE                 = var.name
      DD_ENV                     = var.env
      DD_VERSION                 = local.image_tag
      DD_TRACE_ENABLED           = "true"
      DD_LOGS_INJECTION          = "true"
      DD_SERVERLESS_LOGS_ENABLED = "true"
      DD_ENHANCED_METRICS        = "true"
      DD_CAPTURE_LAMBDA_PAYLOAD  = "false" # requests carry the passphrase header
      DD_LLMOBS_ENABLED          = "1"
      DD_LLMOBS_ML_APP           = var.name
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  tags = {
    service = var.name
    env     = var.env
  }

  depends_on = [terraform_data.image, aws_iam_role_policy.lambda]
}

# Public URL; access is gated by the passphrase check in the handler.
resource "aws_lambda_function_url" "app" {
  function_name      = aws_lambda_function.app.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.app.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke" {
  statement_id             = "AllowInvokeViaFunctionUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.app.function_name
  principal                = "*"
  invoked_via_function_url = true
}
