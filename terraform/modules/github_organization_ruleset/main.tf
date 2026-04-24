resource "github_organization_ruleset" "this" {
  name        = var.name
  target      = var.target
  enforcement = var.enforcement

  conditions {
    ref_name {
      include = var.conditions.ref_name.include
      exclude = lookup(var.conditions.ref_name, "exclude", [])
    }

    repository_name {
      include   = var.conditions.repository_name.include
      exclude   = lookup(var.conditions.repository_name, "exclude", [])
      protected = lookup(var.conditions.repository_name, "protected", true)
    }
  }

  dynamic "bypass_actors" {
    for_each = var.bypass_actors

    content {
      actor_id    = bypass_actors.value.actor_id
      actor_type  = bypass_actors.value.actor_type
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

  rules {
    non_fast_forward = lookup(var.rules, "non_fast_forward", true)

    dynamic "pull_request" {
      for_each = var.rules.pull_request != null ? [var.rules.pull_request] : []

      content {
        required_approving_review_count   = lookup(pull_request.value, "required_approving_review_count", 0)
        require_code_owner_review         = lookup(pull_request.value, "require_code_owner_review", false)
        require_last_push_approval        = lookup(pull_request.value, "require_last_push_approval", false)
        required_review_thread_resolution = lookup(pull_request.value, "required_review_thread_resolution", false)
        dismiss_stale_reviews_on_push     = lookup(pull_request.value, "dismiss_stale_reviews_on_push", false)
      }
    }

    dynamic "required_status_checks" {
      for_each = var.rules.required_status_checks != null ? [var.rules.required_status_checks] : []

      content {
        strict_required_status_checks_policy = lookup(required_status_checks.value, "strict", false)

        dynamic "required_check" {
          for_each = lookup(required_status_checks.value, "checks", [])

          content {
            context        = required_check.value.context
            integration_id = lookup(required_check.value, "integration_id", null)
          }
        }
      }
    }
  }
}
