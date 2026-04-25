variable "github_token" {
  type        = string
  sensitive   = true
  description = "GitHub token with admin:org and repo scope"
}

variable "github_owner" {
  type        = string
  description = "GitHub organization name"
}

variable "self_repo_name" {
  type        = string
  description = "Name of this repository (set automatically by CI)"
}
