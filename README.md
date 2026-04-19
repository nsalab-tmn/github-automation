# GitHub Automation

Org-wide reusable GitHub Actions workflows for project management automation. Provides deterministic housekeeping rules that any `nsalab-tmn` repository can call.

## What this repo manages

Reusable workflows that enforce project hygiene across all organization repositories:
- Issue and PR assignment
- Project board synchronization
- Automatic labeling
- PR validation
- Stale issue management

These workflows are **project-agnostic** — they accept configuration via inputs and work with any repo in the organization.

## Quick start

### Using a workflow from another repo

Create a thin caller workflow in your repo:

```yaml
# .github/workflows/housekeeping.yaml
name: Housekeeping

on:
  issues:
    types: [opened]
  pull_request:
    types: [opened]

jobs:
  auto-assign:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-assign.yaml@main
    with:
      default-assignee: menus12

  auto-project:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-project.yaml@main
    with:
      project-number: 3
    secrets:
      token: ${{ secrets.PROJECT_TOKEN }}
```

### CI/CD path

This repo has no deployments. Changes to reusable workflows take effect immediately when called from other repos (pinned to `@main` or a specific tag).

## Repository structure

```
github-automation/
├── .github/
│   ├── ISSUE_TEMPLATE/          Issue templates
│   ├── pull_request_template.md PR template
│   └── workflows/               Reusable workflows (the primary deliverable)
├── docs/
│   └── conventions.md           Technical reference, workflow catalog
├── README.md                    This file
└── CONTRIBUTING.md              How to work in this repo
```

## Available workflows

| Workflow | Purpose | Status |
|----------|---------|--------|
| `reusable-auto-assign` | Auto-assign issues and PRs to creator or default assignee | Active |
| `reusable-auto-project` | Add issues to GitHub Projects board | Active |
| `reusable-auto-label` | Label PRs by changed file paths | Planned |
| `reusable-pr-validate` | Validate PR structure and linked issue | Planned |
| `reusable-stale-check` | Label and manage inactive issues | Planned |

See [docs/conventions.md](docs/conventions.md) for the full catalog with inputs/outputs documentation.
