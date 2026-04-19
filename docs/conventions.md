# Conventions

Technical reference for github-automation workflows.

## Documentation map

| Document | Read when |
|----------|-----------|
| [README.md](../README.md) | First time here, need quick orientation |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | About to make changes |
| [docs/adoption.md](adoption.md) | Adding workflows to your repo |
| This file | Need technical details on workflows |

## Workflow naming

All reusable workflows follow the pattern:

```
reusable-<action>.yaml
```

Examples: `reusable-auto-assign.yaml`, `reusable-auto-project.yaml`, `reusable-stale-check.yaml`.

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
| `reusable-auto-project` | `issues` | `project-number`, `type-mapping` (JSON) | Adds issue to a GitHub Projects board, optionally sets Type field from labels |
| `reusable-auto-label` | `pull_request` | `label-config` (JSON) | Labels PRs based on changed file paths |
| `reusable-pr-validate` | `pull_request` | `require-issue`, `require-labels`, `require-description` | Validates PR has linked issue, description, labels |
| `reusable-stale-check` | `schedule` | `days-before-stale`, `days-before-close`, `stale-label`, `exempt-labels`, `exempt-assignees` | Labels inactive issues as stale, optionally closes them |

### Caller workflow pattern

Each consuming repo creates a thin caller:

```yaml
# .github/workflows/housekeeping.yaml
name: Housekeeping

on:
  issues:
    types: [opened, edited, assigned]
  pull_request:
    types: [opened, edited, labeled, unlabeled]

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

### Inputs convention

- Use descriptive names with hyphens: `default-assignee`, `project-number`
- Boolean inputs default to `true` for opt-out rather than opt-in
- Complex config (like label mappings) passed as JSON strings
- Secrets passed via `secrets:` block, never via `inputs:`

### Run name convention

Caller workflows must set `run-name` for readable Actions UI history:

```yaml
name: housekeeping
run-name: "[${{github.run_number}}] Housekeeping [${{github.event_name}}]"
```

Format: `[${{github.run_number}}] Description [${{context}}]` — consistent with other org repos.

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
