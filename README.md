# GitHub Automation

Org-wide reusable GitHub Actions workflows for project management automation. Provides deterministic housekeeping rules that any `nsalab-tmn` repository can call.

## What this repo manages

Reusable workflows that enforce project hygiene across all organization repositories:
- Issue and PR assignment
- Project board synchronization
- Automatic labeling
- PR validation
- Stale issue management
- Issue-driven repo scaffolding

These workflows are **project-agnostic** — they accept configuration via inputs and work with any repo in the organization.

## Quick start

### Using workflows from another repo

See [docs/adoption.md](docs/adoption.md) for the full setup guide with prerequisites, secrets configuration, and caller examples.

### CI/CD path

This repo has no deployments. Changes to reusable workflows take effect immediately when called from other repos (pinned to `@main` or a specific tag).

## Repository structure

```
github-automation/
├── .github/
│   ├── ISSUE_TEMPLATE/          Issue templates
│   ├── pull_request_template.md PR template
│   └── workflows/               Reusable + Layer 3 agent workflows
├── config/                      Agent configurations (YAML)
├── docs/
│   ├── adoption.md              How to adopt workflows in your repo
│   ├── architecture.md          4-layer enforcement architecture
│   └── conventions.md           Technical reference, workflow catalog
├── prompts/                     Claude API system prompts
├── schemas/                     Claude API tool schemas
├── scripts/                     Shared scripts for agent + scaffold workflows
├── terraform/
│   ├── configs/                 Org-wide Terraform configs (rulesets, labels, gitops projects)
│   └── modules/                 Reusable Terraform modules (repo, labels, rulesets)
├── README.md                    This file
└── CONTRIBUTING.md              How to work in this repo
```

## Available workflows

| Workflow | Purpose | Status |
|----------|---------|--------|
| `reusable-auto-assign` | Auto-assign issues and PRs to creator or default assignee | Active |
| `reusable-auto-project` | Add issues to GitHub Projects board | Active |
| `reusable-project-sync` | Sync project board Status from issue/PR lifecycle | Active |
| `reusable-auto-label` | Label PRs by changed file paths | Active |
| `reusable-issue-defaults` | Set Priority and Size defaults from issue type | Active |
| `reusable-branch-validate` | Validate branch naming convention and linked issue | Active |
| `reusable-pr-size` | Label PRs by lines changed (XS/S/M/L/XL) | Active |
| `reusable-pr-validate` | Validate PR structure and linked issue | Active |
| `reusable-compliance-check` | Detect direct pushes and unchecked merges | Active |
| `reusable-conflict-check` | Detect and label PRs with merge conflicts | Active |
| `reusable-stale-check` | Label and manage inactive issues | Active |
| `reusable-structural-check` | Validate required files, labels, and workflows | Active |
| `reusable-stale-pr` | Label and manage inactive pull requests | Active |
| `reusable-pinned-sync` | Auto-update pinned context issue from repo state | Active |
| `reusable-terraform-plan` | Terraform fmt, validate, plan with PR comment | Active |
| `reusable-terraform-apply` | Terraform apply on merge | Active |
| `scaffold-gitops` | Create gitops repos via issue form + Terraform | Active |
| `delete-gitops` | Delete gitops repos via issue form + Terraform | Active |
| `drift-detect` | Convention drift detection (Layer 3, AI-assisted) | Active |
| `engineering-agent` | AI engineering agent — picks issues, creates PRs (Layer 3) | Active |
| `review-agent` | AI review agent — reviews PRs, posts structured reviews (Layer 3) | Active |

See [docs/conventions.md](docs/conventions.md) for the full catalog with inputs/outputs documentation.

## Terraform

Organization settings managed as code in `terraform/`:
- Org-wide rulesets (require PR, squash merge only, branch naming)
- GitOps project repos (created from `template-gitops` via issue form)
- Labels for this repo
- Reusable modules for repos, labels, and rulesets

Project-specific config lives in `[project]-gitops` repos (created from `template-gitops`). Project repos are created from `template-generic`.

See [docs/repo-provisioning.md](docs/repo-provisioning.md) for the full self-service lifecycle.
