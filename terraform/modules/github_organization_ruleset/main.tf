# Uses gh API directly to work around provider crash with App tokens
# (terraform-provider-github #2597: nil pointer in response parsing)

resource "terraform_data" "ruleset" {
  input = {
    name          = var.name
    target        = var.target
    enforcement   = var.enforcement
    conditions    = var.conditions
    bypass_actors = var.bypass_actors
    rules         = var.rules
  }

  provisioner "local-exec" {
    command = <<-EOT
      EXISTING=$(gh api "orgs/${var.org}/rulesets" --jq "[.[] | select(.name == \"${var.name}\")] | length" 2>/dev/null || echo "0")

      BODY=$(cat <<'JSONEOF'
      ${jsonencode({
    name        = var.name
    target      = var.target
    enforcement = var.enforcement
    conditions = {
      ref_name = {
        include = var.conditions.ref_name.include
        exclude = lookup(var.conditions.ref_name, "exclude", [])
      }
      repository_name = {
        include   = var.conditions.repository_name.include
        exclude   = lookup(var.conditions.repository_name, "exclude", [])
        protected = lookup(var.conditions.repository_name, "protected", true)
      }
    }
    bypass_actors = [for a in var.bypass_actors : {
      actor_id    = a.actor_id
      actor_type  = a.actor_type
      bypass_mode = a.bypass_mode
    }]
    rules = merge(
      var.rules.non_fast_forward != null ? { non_fast_forward = var.rules.non_fast_forward } : {},
      var.rules.pull_request != null ? {
        pull_request = {
          required_approving_review_count   = lookup(var.rules.pull_request, "required_approving_review_count", 0)
          dismiss_stale_reviews_on_push     = lookup(var.rules.pull_request, "dismiss_stale_reviews_on_push", false)
          require_code_owner_review         = lookup(var.rules.pull_request, "require_code_owner_review", false)
          require_last_push_approval        = lookup(var.rules.pull_request, "require_last_push_approval", false)
          required_review_thread_resolution = lookup(var.rules.pull_request, "required_review_thread_resolution", false)
        }
      } : {},
      var.rules.required_status_checks != null ? {
        required_status_checks = {
          strict_required_status_checks_policy = lookup(var.rules.required_status_checks, "strict", false)
          required_status_checks = [for c in lookup(var.rules.required_status_checks, "checks", []) : {
            context        = c.context
            integration_id = lookup(c, "integration_id", null)
          }]
        }
      } : {}
    )
})}
      JSONEOF
      )

      if [ "$EXISTING" = "0" ]; then
        echo "$BODY" | gh api "orgs/${var.org}/rulesets" --input - --method POST > /dev/null
        echo "Created ruleset: ${var.name}"
      else
        RULESET_ID=$(gh api "orgs/${var.org}/rulesets" --jq ".[] | select(.name == \"${var.name}\") | .id")
        echo "$BODY" | gh api "orgs/${var.org}/rulesets/$RULESET_ID" --input - --method PUT > /dev/null
        echo "Updated ruleset: ${var.name}"
      fi
    EOT

environment = {
  GH_TOKEN = var.github_token
}
}
}
