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
| `reusable-auto-project` | `issues` | `project-number`, `default-status`, `type-mapping` (JSON) | Adds issue to a GitHub Projects board, sets Status and Type |
| `reusable-project-sync` | `issues`, `pull_request`, `pull_request_review` | `project-number`, `status-backlog`, `status-in-progress`, `status-in-review`, `status-done` | Syncs issue Status on project board based on PR/issue lifecycle events |
| `reusable-auto-label` | `pull_request` | `label-config` (JSON) | Labels PRs based on changed file paths |
| `reusable-pr-size` | `pull_request` | `size-xs`, `size-s`, `size-m`, `size-l`, `exclude-patterns` (JSON) | Labels PRs by lines changed (XS/S/M/L/XL) |
| `reusable-pr-validate` | `pull_request` | `require-issue`, `require-labels`, `require-description` | Validates PR has linked issue, description, labels |
| `reusable-stale-check` | `schedule` | `days-before-stale`, `days-before-close`, `stale-label`, `exempt-labels`, `exempt-assignees` | Labels inactive issues as stale, optionally closes them |
| `reusable-pinned-sync` | `issues: [closed]`, `pull_request: [closed]`, `schedule` | `pinned-label` | Auto-updates pinned context issue sections marked with HTML comment markers |
| `scaffold-repo` | `issues` (with `repository-request` label) | Issue form fields | Creates a new repo with org standards via issue form |

### Caller workflow pattern

Each consuming repo creates a thin caller:

```yaml
# .github/workflows/housekeeping.yaml
name: Housekeeping

on:
  issues:
    types: [opened]
  pull_request:
    types: [opened, synchronize, edited, labeled, unlabeled, reopened, ready_for_review, review_requested, closed]
  pull_request_review:
    types: [submitted]

jobs:
  auto-assign:
    if: github.event_name == 'issues' || github.event_name == 'pull_request'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-assign.yaml@main
    with:
      default-assignee: menus12

  auto-project:
    if: github.event_name == 'issues' && github.event.action == 'opened'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-project.yaml@main
    with:
      project-number: 3
    secrets:
      token: ${{ secrets.PROJECT_TOKEN }}

  project-sync:
    if: >-
      github.event_name == 'pull_request_review'
      || (github.event_name == 'pull_request'
          && contains(fromJSON('["opened","reopened","ready_for_review","review_requested","closed"]'),
                      github.event.action))
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-project-sync.yaml@main
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
- **Workflow call depth**: GitHub allows max 10 levels of reusable workflow nesting (increased from 4). Keep it flat — callers call this repo directly, no chaining.
- **Reusable workflow bootstrap**: When introducing a new reusable workflow, don't add the caller job in the same PR. The `@main` reference will fail because the workflow doesn't exist on main yet, which breaks the entire workflow file (all jobs fail, not just the new one). Merge the workflow first, then add the caller in a follow-up commit.
- **project-sync + Layer 1 hybrid**: `project-sync` is designed to work alongside Layer 1 built-in project workflows. Layer 1 handles common transitions (PR linked → In Review, item closed → Done, item reopened → Backlog) with clean single-event timelines. `project-sync` handles only transitions Layer 1 cannot: draft PRs, ready_for_review, review re-requests after changes, and PR closed without merge. Both must be active for full lifecycle coverage.
- **`pull_request_review` event**: Only fires on `submitted`, not on dismissal. The `changes_requested` state moves the linked issue back to In Progress. The `approved` state is a no-op (stays In Review until merged).
