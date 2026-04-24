locals {
  rulesets = yamldecode(file("${path.module}/configs/rulesets.yaml"))
}
