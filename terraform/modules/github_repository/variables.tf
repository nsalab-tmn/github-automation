variable "name" {
  type        = string
  description = "Repository name"
}

variable "description" {
  type        = string
  default     = ""
  description = "Repository description"
}

variable "visibility" {
  type        = string
  default     = "private"
  description = "Repository visibility: private, public, or internal"
}

# Merge settings — org standard defaults
variable "allow_squash_merge" {
  type    = bool
  default = true
}

variable "allow_merge_commit" {
  type    = bool
  default = false
}

variable "allow_rebase_merge" {
  type    = bool
  default = false
}

variable "delete_branch_on_merge" {
  type    = bool
  default = true
}

# Feature toggles
variable "has_issues" {
  type    = bool
  default = true
}

variable "has_projects" {
  type    = bool
  default = false
}

variable "has_wiki" {
  type    = bool
  default = false
}

variable "has_discussions" {
  type    = bool
  default = false
}

variable "is_template" {
  type        = bool
  default     = false
  description = "Whether this repository is itself a template repository"
}

variable "template" {
  type = object({
    owner      = string
    repository = string
  })
  default     = null
  description = "Template repo to create from (only used at creation time)"
}
