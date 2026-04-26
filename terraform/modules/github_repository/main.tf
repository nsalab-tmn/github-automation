resource "github_repository" "this" {
  name        = var.name
  description = var.description
  visibility  = var.visibility

  # Merge settings — org standard: squash only
  allow_squash_merge          = var.allow_squash_merge
  allow_merge_commit          = var.allow_merge_commit
  allow_rebase_merge          = var.allow_rebase_merge
  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "BLANK"

  # Branch settings
  delete_branch_on_merge = var.delete_branch_on_merge

  # Feature toggles
  has_issues      = var.has_issues
  has_projects    = var.has_projects
  has_wiki        = var.has_wiki
  has_discussions = var.has_discussions
  is_template     = var.is_template

  dynamic "template" {
    for_each = var.template != null ? [var.template] : []
    content {
      owner                = template.value.owner
      repository           = template.value.repository
      include_all_branches = false
    }
  }

  lifecycle {
    ignore_changes = [template]
  }
}
