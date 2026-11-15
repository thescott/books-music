variable "region" {
  type    = string
  default = "us-east-2"
}

variable "name" {
  description = "Prefix for all resource names."
  type        = string
  default     = "books-music"
}

variable "models" {
  description = "Models offered by the A/B switch in the web page (Bedrock inference profile IDs). The first key is the default."
  type = map(object({
    id    = string
    label = string
  }))
  default = {
    A = { id = "us.amazon.nova-2-lite-v1:0", label = "Nova 2 Lite" }
    B = { id = "us.amazon.nova-pro-v1:0", label = "Nova Pro" }
  }
}

variable "discogs_secret_name" {
  description = "Existing Secrets Manager secret holding {\"token\": \"<Discogs PAT>\"}."
  type        = string
  default     = "discogs-pat"
}

variable "history_file" {
  description = "Audible listen history JSON uploaded to S3."
  type        = string
  default     = "../audible_listen_history.json"
}

variable "notes_file" {
  description = "Optional per-book descriptions given to the model as ground truth."
  type        = string
  default     = "../book_notes.json"
}

variable "complete_threshold_minutes" {
  description = "In-progress books with this many minutes or fewer left count as completed."
  type        = number
  default     = 60
}

variable "daily_suggestion_limit" {
  description = "Max uncached (Bedrock-calling) suggestion requests per day."
  type        = number
  default     = 50
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"
}

variable "datadog_api_key_secret_name" {
  description = "Existing secret {\"api_key\", \"site\"}; used by Terraform and copied into the plaintext secret the Lambda extension reads."
  type        = string
  default     = "coh/datadog-api-key"
}

variable "datadog_app_key_secret_name" {
  description = "Existing secret {\"app_key\"}; used only by Terraform to manage the dashboard and monitors."
  type        = string
  default     = "coh/datadog-app-key"
}

variable "env" {
  description = "Datadog env tag."
  type        = string
  default     = "prod"
}

variable "reserved_concurrency" {
  description = "Caps simultaneous Lambda executions to bound cost."
  type        = number
  default     = 2
}
