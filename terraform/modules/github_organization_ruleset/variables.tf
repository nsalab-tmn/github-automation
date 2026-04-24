variable "org" {
  type        = string
  description = "GitHub organization name"
}

variable "github_token" {
  type        = string
  sensitive   = true
  description = "GitHub token for gh CLI"
}

variable "name" {
  type        = string
  description = "Ruleset name"
}

variable "target" {
  type        = string
  default     = "branch"
  description = "Ruleset target: branch"

  validation {
    condition     = var.target == "branch"
    error_message = "Only branch target is supported."
  }
}

variable "enforcement" {
  type        = string
  default     = "active"
  description = "Enforcement mode: active, disabled, or evaluate"

  validation {
    condition     = contains(["disabled", "active", "evaluate"], var.enforcement)
    error_message = "Enforcement must be one of: disabled, active, evaluate."
  }
}

variable "conditions" {
  type = object({
    ref_name = object({
      include = list(string)
      exclude = optional(list(string), [])
    })
    repository_name = object({
      include   = list(string)
      exclude   = optional(list(string), [])
      protected = optional(bool, true)
    })
  })
  description = "Conditions for ref_name and repository_name matching"
}

variable "bypass_actors" {
  type = list(object({
    actor_id    = optional(number)
    actor_type  = string
    bypass_mode = string
  }))
  default     = []
  description = "Actors that can bypass this ruleset"
}

variable "rules" {
  type = object({
    non_fast_forward = optional(bool)
    pull_request = optional(object({
      required_approving_review_count   = optional(number, 0)
      require_code_owner_review         = optional(bool, false)
      require_last_push_approval        = optional(bool, false)
      required_review_thread_resolution = optional(bool, false)
      dismiss_stale_reviews_on_push     = optional(bool, false)
    }))
    required_status_checks = optional(object({
      strict = optional(bool, false)
      checks = optional(list(object({
        context        = string
        integration_id = optional(number)
      })), [])
    }))
  })
  description = "Rules to enforce"
}
