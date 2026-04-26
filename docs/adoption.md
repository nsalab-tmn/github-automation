# Adopting github-automation workflows

Step-by-step guide for adding reusable workflows to any `nsalab-tmn` repository.

## Prerequisites

### 1. Repository access

The consuming repo must be in the `nsalab-tmn` organization (reusable workflows are org-scoped).

### 2. Secrets

Some workflows require secrets that must be configured in the consuming repo:

| Secret | Required by | How to create |
|--------|-------------|---------------|
| `APP_ID` | `reusable-auto-project`, `reusable-project-sync` | GitHub App ID from org Settings → Developer settings → GitHub Apps → nsalab-automation |
| `APP_PRIVATE_KEY` | `reusable-auto-project`, `reusable-project-sync` | Generate private key from the same app settings page |

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
    types: [opened, typed]
  pull_request:
    types: [opened, synchronize, edited, labeled, unlabeled, ready_for_review, review_requested, closed]
  pull_request_review:
    types: [submitted]

jobs:
  auto-assign:
    if: >-
      (github.event_name == 'issues' && github.event.action == 'opened')
      || (github.event_name == 'pull_request' && github.event.action == 'opened')
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-assign.yaml@main
    with:
      default-assignee: menus12

  auto-project:
    if: github.event_name == 'issues' && github.event.action == 'opened'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-project.yaml@main
    with:
      project-number: 3  # your GitHub Projects board number
      type-mapping: |
        {
          "bug": "Bug",
          "enhancement": "Feature"
        }
    secrets:
      app-id: ${{ secrets.APP_ID }}
      app-private-key: ${{ secrets.APP_PRIVATE_KEY }}

  issue-defaults:
    if: github.event_name == 'issues'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-issue-defaults.yaml@main
    with:
      project-number: 3
    secrets:
      app-id: ${{ secrets.APP_ID }}
      app-private-key: ${{ secrets.APP_PRIVATE_KEY }}

  project-sync:
    if: >-
      github.event_name == 'pull_request_review'
      || (github.event_name == 'pull_request'
          && contains(fromJSON('["ready_for_review","review_requested","closed"]'),
                      github.event.action))
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-project-sync.yaml@main
    with:
      project-number: 3  # same project as auto-project
    secrets:
      app-id: ${{ secrets.APP_ID }}
      app-private-key: ${{ secrets.APP_PRIVATE_KEY }}

  auto-label:
    if: >-
      github.event_name == 'pull_request'
      && contains(fromJSON('["opened","synchronize"]'), github.event.action)
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-label.yaml@main
    with:
      label-config: |
        {
          "configuration": ["ansible/**"],
          "infrastructure": ["terraform/**"],
          "ci-cd": [".github/**"],
          "documentation": ["docs/**", "*.md"]
        }

  pr-size:
    if: >-
      github.event_name == 'pull_request'
      && contains(fromJSON('["opened","synchronize"]'), github.event.action)
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-pr-size.yaml@main
    with:
      exclude-patterns: '["*.lock"]'

  branch-validate:
    if: github.event_name == 'pull_request' && github.event.action == 'opened'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-branch-validate.yaml@main

  pr-validate:
    needs: [auto-label, pr-size]
    if: github.event_name == 'pull_request' && always()
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-pr-validate.yaml@main
    with:
      require-issue: true
      require-labels: true
      require-description: true
```

> **Important:** If using both `auto-label` and `pr-validate`, add `needs: auto-label` to `pr-validate`. Without this, the jobs race and validation may fail because labels haven't been applied yet.

> **Note on `project-sync`, `auto-project`, and Layer 1:** `project-sync` works alongside Layer 1 built-in project workflows. Layer 1 handles the common transitions cleanly (PR linked to issue → In Review, item closed → Done, item reopened → Backlog). `project-sync` handles only what Layer 1 cannot: draft PRs → In Progress, ready_for_review → In Review, review re-requested → In Review, changes requested → In Progress, and PR closed without merge → Backlog. Layer 1 workflows must be enabled on the project board — see the adoption issue for setup instructions.

> **Note:** The caller template above contains the 8 standard housekeeping jobs (`auto-assign`, `auto-project`, `issue-defaults`, `project-sync`, `auto-label`, `pr-size`, `branch-validate`, `pr-validate`). The `github-automation` repo's own `housekeeping.yaml` intentionally includes two additional platform-specific jobs not present in this template: `mechanic-dispatch` (dispatches `engineering-agent` on every new issue) and `bulk-assign` (a `workflow_dispatch` utility for bulk-assigning open issues). These are specific to this platform repo and should not be copied into consuming repos.

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

### Stale PR check (separate caller)

Labels inactive PRs as stale. Optionally closes stale draft PRs. Can share the same schedule as stale-check or run independently:

```yaml
# .github/workflows/stale-pr.yaml
name: stale-pr
run-name: "[${{github.run_number}}] Stale PR check [${{github.event_name}}]"

on:
  schedule:
    - cron: '0 9 * * 1'  # Monday 9am UTC
  workflow_dispatch:

jobs:
  stale-pr:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-stale-pr.yaml@main
    with:
      days-before-stale: 14
      days-before-close: 7
      exempt-labels: pinned,in-progress
```

> **Note:** `days-before-close` only applies to draft PRs. Non-draft stale PRs are never auto-closed — the label serves as a signal.

### Compliance check (separate caller)

Detects policy violations: direct pushes to main (bypassing PRs) and PRs merged without passing validation. Creates alert issues labeled `compliance`. Compensates for branch protection rules unavailable on the free GitHub tier:

```yaml
# .github/workflows/compliance-check.yaml
name: compliance-check
run-name: "[${{github.run_number}}] Compliance check [${{github.event_name}}]"

on:
  push:
    branches: [main]
  pull_request:
    types: [closed]

jobs:
  compliance-check:
    if: >-
      (github.event_name == 'push')
      || (github.event_name == 'pull_request' && github.event.pull_request.merged)
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-compliance-check.yaml@main
```

### Structural check (separate caller)

Validates the repo has required files, workflow callers, and labels. Posts results to the pinned issue (if `<!-- structural-check -->` markers exist) and creates a compliance issue on failures:

```yaml
# .github/workflows/structural-check.yaml
name: structural-check
run-name: "[${{github.run_number}}] Structural check [${{github.event_name}}]"

on:
  schedule:
    - cron: '0 9 * * 1'
  workflow_dispatch:

jobs:
  structural-check:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-structural-check.yaml@main
```

To display results in the pinned issue, add markers to its body:

```markdown
<!-- structural-check -->
<!-- /structural-check -->
```

### Conflict check (separate caller)

Checks open PRs for merge conflicts after pushes to main. Also runs weekly as a fallback:

```yaml
# .github/workflows/conflict-check.yaml
name: conflict-check
run-name: "[${{github.run_number}}] Conflict check [${{github.event_name}}]"

on:
  push:
    branches: [main]
  schedule:
    - cron: '0 9 * * 1'
  workflow_dispatch:

jobs:
  conflict-check:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-conflict-check.yaml@main
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

The `nsalab-automation` GitHub App provides identity for project board operations. Secrets are set at the **org level** (shared across all repos):

1. Go to org Settings → Developer settings → GitHub Apps → nsalab-automation
2. Note the **App ID** → set as org secret `APP_ID`
3. Generate a **private key** → set as org secret `APP_PRIVATE_KEY`

If org-level secrets are already configured, no per-repo setup is needed.

### 3. Verify

1. Create a test issue in your repo
2. Check that it was auto-assigned
3. Check that it appeared on the project board
4. Close the test issue

## Available workflows

| Workflow | What it does | Inputs | Secrets |
|----------|-------------|--------|---------|
| `reusable-auto-assign` | Assigns issues/PRs to creator or default assignee | `default-assignee` (optional) | — |
| `reusable-auto-project` | Adds issues to a GitHub Projects board, sets Type field | `project-number` (required), `type-mapping` (optional, JSON) | `app-id`, `app-private-key` (required) |
| `reusable-project-sync` | Syncs project board Status based on issue/PR lifecycle | `project-number` (required), `status-backlog`, `status-in-progress`, `status-in-review`, `status-done` (all optional) | `app-id`, `app-private-key` (required) |
| `reusable-auto-label` | Labels PRs based on changed file paths | `label-config` (required, JSON) | — |
| `reusable-issue-defaults` | Sets Priority/Size defaults from issue type | `project-number` (required), `defaults-mapping` (optional, JSON) | `app-id`, `app-private-key` (required) |
| `reusable-branch-validate` | Validates branch name convention and linked issue | `branch-pattern` (optional, regex), `exempt-authors` (optional) | — |
| `reusable-pr-size` | Labels PRs by lines changed (XS/S/M/L/XL) | `size-xs`, `size-s`, `size-m`, `size-l` (all optional), `exclude-patterns` (optional, JSON) | — |
| `reusable-pr-validate` | Validates PR has linked issue, description, labels | `require-issue`, `require-labels`, `require-description` (all optional, default `true`) | — |
| `reusable-compliance-check` | Detects direct pushes and merges without validation | `require-pr`, `require-checks`, `exempt-authors`, `compliance-label` (all optional) | — |
| `reusable-conflict-check` | Detects merge conflicts on open PRs and labels them | `conflict-label` (optional, default `merge-conflict`) | — |
| `reusable-stale-check` | Labels inactive issues as stale, optionally closes them | `days-before-stale`, `days-before-close`, `stale-label`, `exempt-labels`, `exempt-assignees` (all optional) | — |
| `reusable-structural-check` | Validates required files, workflows, and labels exist | `required-files`, `required-workflows`, `required-labels` (all optional with defaults) | — |
| `reusable-stale-pr` | Labels inactive PRs as stale, optionally closes drafts | `days-before-stale`, `days-before-close`, `stale-label`, `exempt-labels`, `exempt-authors` (all optional) | — |
| `reusable-pinned-sync` | Auto-updates pinned issue checklist, remaining, and completed sections | `pinned-label` (optional, default `pinned`) | — |

## Customization

### Choosing which workflows to use

Each job in the caller is independent — include only what you need. The caller above shows all available workflows; remove any jobs you don't want.

### Inputs

- `default-assignee`: GitHub username to fall back to if the issue/PR creator can't be assigned (e.g., not a collaborator). Omit to skip fallback.
- `project-number`: find this in your project board URL — `https://github.com/orgs/nsalab-tmn/projects/N` → use `N`.
- `default-status`: initial Status value for newly added items (e.g., `Backlog`). **Not needed** if Layer 1 #12 (Item added to project → Backlog) is enabled on the board — Layer 1 handles it with cleaner identity.
- `status-backlog`: Status column name for backlog/reopened items. Default `Backlog`. Must match the option name on your project board exactly.
- `status-in-progress`: Status column name for items under active development. Default `In Progress`.
- `status-in-review`: Status column name for items under review. Default `In Review`.
- `status-done`: Status column name for completed items. Default `Done`.
- `type-mapping`: JSON mapping of issue label names to project Type field option names. First matching label wins. Example: `{"bug": "Bug", "enhancement": "Feature"}`. Omit to skip type assignment.
- `size-xs`, `size-s`, `size-m`, `size-l`: upper bounds for each size bucket (inclusive). Defaults: 9, 49, 199, 499. Anything above `size-l` is XL.
- `exclude-patterns`: JSON array of glob patterns for files to exclude from the line count (e.g., `["*.lock", "generated/**"]`). Omit to count all files.
- `branch-pattern`: regex for valid branch names. Default: `^(feature|fix|docs|infra|cleanup)/[0-9]+-[a-z0-9-]+$`. Customize if your repo uses different prefixes.
- `exempt-authors`: comma-separated authors exempt from branch name check. Default: `github-actions[bot],dependabot[bot],nsalab-automation[bot]`.
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
