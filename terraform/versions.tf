terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.0"
    }
  }
}

# Keys are read ephemerally so they never land in Terraform state.
ephemeral "aws_secretsmanager_secret_version" "datadog_api" {
  secret_id = var.datadog_api_key_secret_name
}

ephemeral "aws_secretsmanager_secret_version" "datadog_app" {
  secret_id = var.datadog_app_key_secret_name
}

provider "datadog" {
  api_key = jsondecode(ephemeral.aws_secretsmanager_secret_version.datadog_api.secret_string)["api_key"]
  app_key = jsondecode(ephemeral.aws_secretsmanager_secret_version.datadog_app.secret_string)["app_key"]
  api_url = "https://api.${var.datadog_site}/"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.name
      ManagedBy = "terraform"
    }
  }
}
