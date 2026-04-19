# Adopting github-automation workflows

Step-by-step guide for adding reusable workflows to any `nsalab-tmn` repository.

## Prerequisites

### 1. Repository access

The consuming repo must be in the `nsalab-tmn` organization (reusable workflows are org-scoped).

### 2. Secrets

Some workflows require secrets that must be configured in the consuming repo:

| Secret | Required by | How to create |
|--------|-------------|---------------|
| `PROJECT_TOKEN` | `reusable-auto-project` | PAT with `project` scope → repo Settings → Secrets → Actions → New repository secret |

The default `GITHUB_TOKEN` cannot modify org-level GitHub Projects. A PAT (or GitHub App token) with `project` scope is required.

## Setup

### 1. Create the caller workflow

Add a single file to your repo:

```yaml
# .github/workflows/housekeeping.yaml
name: housekeeping
run-name: "[${{github.run_number}}] Housekeeping [${{github.event_name}}]"

on:
  issues:
    types: [opened]
  pull_request:
    types: [opened, synchronize]

jobs:
  auto-assign:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-assign.yaml@main
    with:
      default-assignee: menus12

  auto-project:
    if: github.event_name == 'issues'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-project.yaml@main
    with:
      project-number: 3  # your GitHub Projects board number
    secrets:
      token: ${{ secrets.PROJECT_TOKEN }}

  auto-label:
    if: github.event_name == 'pull_request'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-label.yaml@main
    with:
      label-config: |
        {
          "configuration": ["ansible/**"],
          "infrastructure": ["terraform/**"],
          "ci-cd": [".github/**"],
          "documentation": ["docs/**", "*.md"]
        }
```

### 2. Configure secrets

For `reusable-auto-project`:

1. Create a Personal Access Token (classic) at https://github.com/settings/tokens
2. Select the `project` scope
3. Go to your repo → Settings → Secrets and variables → Actions
4. Add `PROJECT_TOKEN` with the PAT value

### 3. Verify

1. Create a test issue in your repo
2. Check that it was auto-assigned
3. Check that it appeared on the project board
4. Close the test issue

## Available workflows

| Workflow | What it does | Inputs | Secrets |
|----------|-------------|--------|---------|
| `reusable-auto-assign` | Assigns issues/PRs to creator or default assignee | `default-assignee` (optional) | — |
| `reusable-auto-project` | Adds issues to a GitHub Projects board | `project-number` (required) | `token` (required) |
| `reusable-auto-label` | Labels PRs based on changed file paths | `label-config` (required, JSON) | — |

## Customization

### Choosing which workflows to use

Each job in the caller is independent — include only what you need. The caller above shows all available workflows; remove any jobs you don't want.

### Inputs

- `default-assignee`: GitHub username to fall back to if the issue/PR creator can't be assigned (e.g., not a collaborator). Omit to skip fallback.
- `project-number`: find this in your project board URL — `https://github.com/orgs/nsalab-tmn/projects/N` → use `N`.
- `label-config`: JSON mapping of label names to arrays of glob patterns. Labels are applied additively (never removed). Example: `{"ci-cd": [".github/**"], "documentation": ["docs/**", "*.md"]}`.

## Updating

Callers pinned to `@main` automatically get the latest workflow version. No action needed when this repo is updated.

For stability, pin to a tag (e.g., `@v1`) and update manually when ready.
