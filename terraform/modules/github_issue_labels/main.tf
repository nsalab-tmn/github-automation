locals {
  # Group by name, take last entry — repo-specific labels override defaults
  labels_grouped = { for l in var.labels : l.name => l... }
  labels_deduped = { for name, entries in local.labels_grouped : name => entries[length(entries) - 1] }
}

# Use github_issue_labels (plural) to manage the full label set idempotently.
# Unlike the singular github_issue_label, this resource adopts pre-existing
# labels (e.g. GitHub's defaults created at repo init) instead of failing
# with 422 already_exists.
resource "github_issue_labels" "this" {
  repository = var.repository

  dynamic "label" {
    for_each = local.labels_deduped
    content {
      name        = label.value.name
      color       = label.value.color
      description = label.value.description
    }
  }
}
