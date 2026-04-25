locals {
  rulesets        = yamldecode(file("${path.module}/configs/rulesets.yaml"))
  gitops_projects = yamldecode(file("${path.module}/configs/gitops-projects.yaml"))
}
