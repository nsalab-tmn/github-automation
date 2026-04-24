resource "github_issue_label" "this" {
  for_each = {
    for l in var.labels :
    l.name => l
  }

  repository  = var.repository
  name        = each.value.name
  color       = each.value.color
  description = lookup(each.value, "description", "")
}
