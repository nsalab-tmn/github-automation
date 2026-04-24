variable "github_token" {
  type        = string
  sensitive   = true
  description = "GitHub token with admin:org and repo scope"
}

variable "github_owner" {
  type        = string
  description = "GitHub organization name"
}
