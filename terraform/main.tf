# Organization-wide rulesets
module "github_organization_ruleset" {
  for_each = {
    for r in lookup(local.rulesets, "rulesets", []) :
    r.name => r
  }

  source = "./modules/github_organization_ruleset"

  name        = each.value.name
  target      = each.value.target
  enforcement = each.value.enforcement
  conditions  = each.value.conditions
  bypass_actors = lookup(each.value, "bypass_actors", [])
  rules       = each.value.rules
}
