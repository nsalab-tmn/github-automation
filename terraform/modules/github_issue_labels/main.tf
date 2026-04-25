locals {
  # Group by name, take last entry — repo-specific labels override defaults
  labels_grouped = { for l in var.labels : l.name => l... }
  labels_deduped = { for name, entries in local.labels_grouped : name => entries[length(entries) - 1] }
}

resource "github_issue_label" "this" {
  for_each = local.labels_deduped

  repository  = var.repository
  name        = each.value.name
  color       = each.value.color
  description = lookup(each.value, "description", "")
}
