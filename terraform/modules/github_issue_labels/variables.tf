variable "repository" {
  type        = string
  description = "Repository name to create labels in"
}

variable "labels" {
  type = list(object({
    name        = string
    color       = string
    description = optional(string, "")
  }))
  description = "List of labels to create"

  default = [
    { name = "bug", color = "d73a4a", description = "Something isn't working" },
    { name = "enhancement", color = "a2eeef", description = "New feature or request" },
    { name = "documentation", color = "0075ca", description = "Documentation changes" },
    { name = "ci-cd", color = "e4e669", description = "CI/CD pipeline changes" },
    { name = "tech-debt", color = "d4c5f9", description = "Technical debt" },
    { name = "pinned", color = "006b75", description = "Pinned context issue" },
    { name = "stale", color = "ededed", description = "No activity for 30+ days" },
    { name = "in-progress", color = "0e8a16", description = "Work in progress" },
    { name = "compliance", color = "B60205", description = "Convention compliance finding" },
    { name = "merge-conflict", color = "ee0701", description = "PR has merge conflicts" },
    { name = "ai-generated", color = "BFD4F2", description = "Created by engineering agent" },
    { name = "needs-triage", color = "FBCA04", description = "Needs human attention" },
  ]
}
