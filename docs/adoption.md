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
    types: [opened, reopened, closed]
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
      project-number: 3  # your GitHub Projects board number
      default-status: Backlog  # set initial Status so items appear in filtered views
      type-mapping: |
        {
          "bug": "Bug",
          "enhancement": "Feature"
        }
    secrets:
      token: ${{ secrets.PROJECT_TOKEN }}

  project-sync:
    if: >-
      github.event_name == 'pull_request_review'
      || (github.event_name == 'issues' && github.event.action != 'opened')
      || (github.event_name == 'pull_request'
          && contains(fromJSON('["opened","reopened","ready_for_review","review_requested","closed"]'),
                      github.event.action))
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-project-sync.yaml@main
    with:
      project-number: 3  # same project as auto-project
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

  pr-validate:
    needs: auto-label  # must run after auto-label so labels are present for validation
    if: github.event_name == 'pull_request'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-pr-validate.yaml@main
    with:
      require-issue: true
      require-labels: true
      require-description: true
```

> **Important:** If using both `auto-label` and `pr-validate`, add `needs: auto-label` to `pr-validate`. Without this, the jobs race and validation may fail because labels haven't been applied yet.

> **Note on `project-sync` and `auto-project`:** These workflows are complementary — `auto-project` adds new issues to the board on `issues.opened`, while `project-sync` handles status transitions on subsequent events. They don't overlap: `project-sync` explicitly skips `issues.opened`. However, `project-sync` requires the issue to already be on the board (it won't add it). This is naturally ordered by the issue-first workflow — the issue exists on the board before any PR referencing it is opened. If `project-sync` can't find an item on the board, it logs a warning and skips.

### Stale check (separate caller)

Stale check runs on a schedule, so it needs its own workflow file:

```yaml
# .github/workflows/stale-check.yaml
name: stale-check
run-name: "[${{github.run_number}}] Stale check [${{github.event_name}}]"

on:
  schedule:
    - cron: '0 9 * * 1'  # Monday 9am UTC
  workflow_dispatch:

jobs:
  stale-check:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-stale-check.yaml@main
    with:
      days-before-stale: 30
      days-before-close: 14
      exempt-labels: pinned,in-progress
```

### Pinned issue sync (separate caller)

Keeps the pinned context issue in sync with repo state. Triggered on issue close, PR merge, and weekly schedule:

```yaml
# .github/workflows/pinned-sync.yaml
name: pinned-sync
run-name: "[${{github.run_number}}] Pinned sync [${{github.event_name}}]"

on:
  issues:
    types: [closed]
  pull_request:
    types: [closed]
  schedule:
    - cron: '0 9 * * 1'
  workflow_dispatch:

jobs:
  pinned-sync:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-pinned-sync.yaml@main
```

The pinned issue must use HTML comment markers to define auto-updated sections:

```markdown
<!-- auto:checklist -->
- [ ] Task one (#5)
- [ ] Task two (#6)
<!-- /auto:checklist -->

<!-- auto:remaining -->
<!-- /auto:remaining -->

<!-- auto:completed -->
<!-- /auto:completed -->
```

Content outside markers is never modified.

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
| `reusable-auto-project` | Adds issues to a GitHub Projects board, sets Type field | `project-number` (required), `type-mapping` (optional, JSON) | `token` (required) |
| `reusable-project-sync` | Syncs project board Status based on issue/PR lifecycle | `project-number` (required), `status-backlog`, `status-in-progress`, `status-in-review`, `status-done` (all optional) | `token` (required) |
| `reusable-auto-label` | Labels PRs based on changed file paths | `label-config` (required, JSON) | — |
| `reusable-pr-validate` | Validates PR has linked issue, description, labels | `require-issue`, `require-labels`, `require-description` (all optional, default `true`) | — |
| `reusable-stale-check` | Labels inactive issues as stale, optionally closes them | `days-before-stale`, `days-before-close`, `stale-label`, `exempt-labels`, `exempt-assignees` (all optional) | — |
| `reusable-pinned-sync` | Auto-updates pinned issue checklist, remaining, and completed sections | `pinned-label` (optional, default `pinned`) | — |

## Customization

### Choosing which workflows to use

Each job in the caller is independent — include only what you need. The caller above shows all available workflows; remove any jobs you don't want.

### Inputs

- `default-assignee`: GitHub username to fall back to if the issue/PR creator can't be assigned (e.g., not a collaborator). Omit to skip fallback.
- `project-number`: find this in your project board URL — `https://github.com/orgs/nsalab-tmn/projects/N` → use `N`.
- `default-status`: initial Status value for newly added items (e.g., `Backlog`). **Recommended** — without this, items won't appear in board views that filter by Status.
- `status-backlog`: Status column name for backlog/reopened items. Default `Backlog`. Must match the option name on your project board exactly.
- `status-in-progress`: Status column name for items under active development. Default `In Progress`.
- `status-in-review`: Status column name for items under review. Default `In Review`.
- `status-done`: Status column name for completed items. Default `Done`.
- `type-mapping`: JSON mapping of issue label names to project Type field option names. First matching label wins. Example: `{"bug": "Bug", "enhancement": "Feature"}`. Omit to skip type assignment.
- `label-config`: JSON mapping of label names to arrays of glob patterns. Labels are applied additively (never removed). **Important:** if using `require-labels: true` in pr-validate, every PR must match at least one pattern — ensure your config covers all directories in the repo. Common patterns:
  - `"ci-cd": [".github/**"]`
  - `"documentation": ["docs/**", "*.md"]`
  - `"configuration": ["ansible/**"]`
  - `"infrastructure": ["terraform/**"]`
  - `"dashboards": ["dashboards/**"]`
- `require-issue`: require `Closes #N` / `Fixes #N` in the PR body. Default `true`.
- `require-labels`: require at least one label. Default `true`.
- `require-description`: require non-empty PR body. Default `true`.
- `days-before-stale`: days of inactivity before labeling stale. Default `30`.
- `days-before-close`: days after stale label before closing (0 = never close). Default `0`.
- `stale-label`: label name to apply. Default `stale`.
- `exempt-labels`: comma-separated labels that exempt issues. Default `pinned`.
- `exempt-assignees`: comma-separated assignees whose issues are exempt. Default empty.

## Updating

Callers pinned to `@main` automatically get the latest workflow version. No action needed when this repo is updated.

For stability, pin to a specific commit SHA or tag (e.g., `@v1`) and update manually when ready.
