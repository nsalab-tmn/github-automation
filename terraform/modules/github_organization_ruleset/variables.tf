variable "name" {
  type        = string
  description = "Ruleset name"
}

variable "target" {
  type        = string
  default     = "branch"
  description = "Ruleset target: branch"
}

variable "enforcement" {
  type        = string
  default     = "active"
  description = "Enforcement mode: active, disabled, or evaluate"
}

variable "conditions" {
  type        = any
  description = "Conditions for ref_name and repository_name matching"
}

variable "bypass_actors" {
  type = list(object({
    actor_id    = number
    actor_type  = string
    bypass_mode = string
  }))
  default     = []
  description = "Actors that can bypass this ruleset"
}

variable "rules" {
  type        = any
  description = "Rules to enforce (non_fast_forward, pull_request, required_status_checks)"
}
