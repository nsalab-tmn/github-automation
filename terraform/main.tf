# Organization-wide rulesets
module "github_organization_ruleset" {
  for_each = {
    for r in lookup(local.rulesets, "rulesets", []) :
    r.name => r
  }

  source = "./modules/github_organization_ruleset"

  name          = each.value.name
  target        = each.value.target
  enforcement   = each.value.enforcement
  conditions    = each.value.conditions
  bypass_actors = lookup(each.value, "bypass_actors", [])
  rules         = each.value.rules
}

# Labels for this repo (github-automation)
module "github_automation_labels" {
  source     = "./modules/github_issue_labels"
  repository = "github-automation"
  labels     = local.labels.labels
}

# Labels for template-gitops
module "template_gitops_labels" {
  source     = "./modules/github_issue_labels"
  repository = "template-gitops"
  labels     = local.labels.template_labels
}

# Labels for template-generic
module "template_generic_labels" {
  source     = "./modules/github_issue_labels"
  repository = "template-generic"
  labels     = local.labels.template_labels
}

# Repository settings for template-gitops
module "template_gitops_repo" {
  source = "./modules/github_repository"

  name        = "template-gitops"
  visibility  = "public"
  is_template = true

  allow_squash_merge     = true
  allow_merge_commit     = false
  allow_rebase_merge     = false
  delete_branch_on_merge = true
  has_wiki               = false
}

# Repository settings for template-generic
module "template_generic_repo" {
  source = "./modules/github_repository"

  name        = "template-generic"
  visibility  = "public"
  is_template = true

  allow_squash_merge     = true
  allow_merge_commit     = false
  allow_rebase_merge     = false
  delete_branch_on_merge = true
  has_wiki               = false
}

# GitOps repositories (created from template-gitops)
module "gitops_repo" {
  for_each = {
    for r in lookup(local.gitops_projects, "gitops_repos", []) :
    r.name => r
  }

  source = "./modules/github_repository"

  name        = "${each.key}-gitops"
  description = each.value.description
  template = {
    owner      = "nsalab-tmn"
    repository = "template-gitops"
  }
}
