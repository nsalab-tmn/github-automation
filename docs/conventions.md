# Conventions

Technical reference for github-automation workflows.

## Documentation map

| Document | Read when |
|----------|-----------|
| [README.md](../README.md) | First time here, need quick orientation |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | About to make changes |
| This file | Need technical details on workflows |

## Workflow naming

All reusable workflows follow the pattern:

```
reusable-<action>.yml
```

Examples: `reusable-auto-assign.yml`, `reusable-auto-project.yml`, `reusable-stale-check.yml`.

## Workflow design principles

1. **Project-agnostic**: No workflow should reference a specific project, repo, or domain. All context comes via inputs.
2. **Minimal permissions**: Each workflow declares only the permissions it needs.
3. **Idempotent**: Running the same workflow twice on the same event should not produce duplicate side effects.
4. **Observable**: Every action taken should be logged via workflow output or step summary.
5. **Fail-safe**: If a workflow fails, the worst outcome is "automation didn't run" — never "automation broke something."

## Workflow catalog

### Active workflows

| Workflow | Trigger | Inputs | What it does |
|----------|---------|--------|-------------|
| `reusable-auto-assign` | `issues`, `pull_request` | `default-assignee` | Assigns creator or default assignee if none set |

### Planned workflows

| Workflow | Trigger | Inputs | What it does |
|----------|---------|--------|-------------|
| `reusable-auto-project` | `issues`, `pull_request` | `project-number` | Adds item to a GitHub Projects board |
| `reusable-auto-label` | `pull_request` | `label-config` (JSON) | Labels PRs based on changed file paths |
| `reusable-pr-validate` | `pull_request` | `require-issue`, `require-labels` | Validates PR has linked issue, description, labels |
| `reusable-stale-check` | `schedule` | `days-before-stale`, `exempt-labels` | Labels inactive issues as stale |

### Caller workflow pattern

Each consuming repo creates a thin caller:

```yaml
# .github/workflows/housekeeping.yml
name: Housekeeping

on:
  issues:
    types: [opened, edited, assigned]
  pull_request:
    types: [opened, edited, labeled, unlabeled]

jobs:
  auto-assign:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-assign.yml@main
    with:
      default-assignee: menus12

  auto-project:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-project.yml@main
    with:
      project-number: 3
    secrets:
      token: ${{ secrets.PROJECT_TOKEN }}
```

### Inputs convention

- Use descriptive names with hyphens: `default-assignee`, `project-number`
- Boolean inputs default to `true` for opt-out rather than opt-in
- Complex config (like label mappings) passed as JSON strings
- Secrets passed via `secrets:` block, never via `inputs:`

### Permissions convention

Each reusable workflow declares minimum required permissions:

```yaml
on:
  workflow_call:
    inputs: ...

permissions:
  issues: write        # only if modifying issues
  pull-requests: write # only if modifying PRs
  contents: read       # default for most workflows
```

## Actions versions

Pinned to major versions for stability:

| Action | Version |
|--------|---------|
| `actions/checkout` | `v5` |
| `actions/github-script` | `v8` |
| `actions/labeler` | `v5` |

## Known gotchas

- **Reusable workflow secrets**: Callers must explicitly pass secrets — they are not inherited. Use `secrets: inherit` only if the caller trusts this repo with all its secrets.
- **GITHUB_TOKEN scope**: The default `GITHUB_TOKEN` cannot add items to GitHub Projects (org-level). A PAT or GitHub App token with `project` scope is required for `reusable-auto-project`.
- **Workflow call depth**: GitHub allows max 4 levels of reusable workflow nesting. Keep it flat — callers call this repo directly, no chaining.
