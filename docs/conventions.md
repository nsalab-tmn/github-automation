# Conventions

Technical reference for github-automation workflows.

## Documentation map

| Document | Read when |
|----------|-----------|
| [README.md](../README.md) | First time here, need quick orientation |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | About to make changes |
| [docs/adoption.md](adoption.md) | Adding workflows to your repo |
| [docs/architecture.md](architecture.md) | Understanding the 4-layer enforcement architecture |
| [docs/repo-provisioning.md](repo-provisioning.md) | Self-service repo creation/deletion via Terraform |
| [docs/project-onboarding.md](project-onboarding.md) | Bringing a project from zero to autonomous pipeline |
| This file | Need technical details on workflows |

## Workflow naming

### File names

All reusable workflows follow the pattern:

```
reusable-<action>.yaml
```

Callers use the action name without the `reusable-` prefix: `housekeeping.yaml`, `stale-check.yaml`, `conflict-check.yaml`.

### Display names (`name:` field)

- **Callers**: `lowercase-slug` matching the filename — e.g., `housekeeping`, `stale-check`
- **Reusable workflows**: `reusable - <slug>` — e.g., `reusable - auto-assign`, `reusable - project-sync`

This groups reusable workflows visually in the Actions sidebar, separate from callers.

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
| `reusable-issue-defaults` | `issues` | `project-number`, `defaults-mapping` (JSON) | Sets Priority and Size defaults based on issue type |
| `reusable-branch-validate` | `pull_request` | `branch-pattern` (regex), `exempt-authors` | Validates branch name convention and linked issue |
| `reusable-pr-size` | `pull_request` | `size-xs`, `size-s`, `size-m`, `size-l`, `exclude-patterns` (JSON) | Labels PRs by lines changed (XS/S/M/L/XL) |
| `reusable-pr-validate` | `pull_request` | `require-issue`, `require-labels`, `require-description` | Validates PR has linked issue, description, labels |
| `reusable-compliance-check` | `push`, `pull_request` | `require-pr`, `require-checks`, `exempt-authors`, `compliance-label` | Detects direct pushes and PRs merged without passing validation |
| `reusable-conflict-check` | `push`, `schedule` | `conflict-label` | Detects merge conflicts on open PRs and labels them |
| `reusable-stale-check` | `schedule` | `days-before-stale`, `days-before-close`, `stale-label`, `exempt-labels`, `exempt-assignees` | Labels inactive issues as stale, optionally closes them |
| `reusable-structural-check` | `schedule` | `required-files`, `required-workflows`, `required-labels`, `pinned-label`, `compliance-label` | Validates repo has required files, workflow callers, and labels |
| `reusable-stale-pr` | `schedule` | `days-before-stale`, `days-before-close`, `stale-label`, `exempt-labels`, `exempt-authors` | Labels inactive PRs as stale, optionally closes drafts |
| `reusable-pinned-sync` | `issues: [closed]`, `pull_request: [closed]`, `schedule` | `pinned-label` | Auto-updates pinned context issue sections marked with HTML comment markers |
| `reusable-terraform-plan` | `workflow_call` | `working-directory`, `terraform-version` | Terraform fmt, init, validate, plan, post plan as PR comment |
| `reusable-terraform-apply` | `workflow_call` | `working-directory`, `terraform-version` | Terraform init, apply |
| `scaffold-gitops` | `issues` (with `gitops-request` label) | Issue form fields | Creates PR adding gitops repo to Terraform config |
| `delete-gitops` | `issues` (with `gitops-delete` label) | Issue form fields | Creates PR removing gitops repo from Terraform config |
| `drift-detect` | `schedule`, `workflow_dispatch` | `dry-run` | Compares repos against conventions, creates compliance issues |
| `planning-agent` | `workflow_dispatch` | `issue-url`, `dry-run` | Decomposes complex issues into mechanic-sized sub-issues |
| `engineering-agent` | `workflow_dispatch` | `issue-url`, `dry-run` | Picks issues from board, implements fixes, creates PRs |
| `review-agent` | `schedule`, `workflow_dispatch` | `pr-url`, `dry-run` | Reviews AI-generated PRs, posts structured reviews |

### Caller workflow pattern

Each consuming repo creates a thin caller:

```yaml
# .github/workflows/housekeeping.yaml
name: Housekeeping

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
      project-number: 3
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
      project-number: 3
    secrets:
      app-id: ${{ secrets.APP_ID }}
      app-private-key: ${{ secrets.APP_PRIVATE_KEY }}
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

Format: `[run_number] Description [context]` — consistent across org repos.

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

## Bot identities

Each Layer 3 workflow has its own GitHub App identity:

| Bot | Workflow | Role |
|-----|----------|------|
| `nsalab-librarian[bot]` | `drift-detect` | Finds convention drift, creates compliance issues |
| `nsalab-mechanic[bot]` | `engineering-agent` | Implements fixes, creates PRs |
| `nsalab-beekeeper[bot]` | `review-agent` | Reviews PRs, posts APPROVE/REQUEST_CHANGES |
| `nsalab-doorman[bot]` | `terraform-plan/apply` | Manages org rulesets and repo settings via Terraform. Bypass actor on org rulesets for template bootstrapping |
| `nsalab-automation[bot]` | Layer 2 workflows, scaffold/delete | Housekeeping, scaffold/delete workflows (triggers downstream workflows, project board access) |
| `nsalab-transporter` | `review-agent` (notify step) | Sends Telegram notifications on beekeeper APPROVE |

## Terraform

Organization settings are managed via Terraform in the `terraform/` directory:

- `configs/rulesets.yaml` — org-wide branch protection rulesets
- `configs/gitops-projects.yaml` — gitops repos created from `template-gitops`
- `configs/labels.yaml` — labels for this repo
- `modules/github_repository/` — reusable module for repo settings (supports template creation)
- `modules/github_issue_labels/` — reusable module for standard label sets
- `modules/github_organization_ruleset/` — reusable module for org rulesets

CI workflows: `terraform-plan.yaml` (on PR) and `terraform-apply.yaml` (on merge).
Both are thin callers to `reusable-terraform-plan.yaml` and `reusable-terraform-apply.yaml`.
The reusable workflows accept an optional `backend-key` input for dynamic state key derivation.

### Template repos

| Template | Purpose | Used by |
|----------|---------|---------|
| `template-gitops` | GitOps repos with TF configs, housekeeping, scaffold/delete forms | github-automation creates `[project]-gitops` repos |
| `template-generic` | Project repos with skeleton docs (agent prompts), housekeeping | `[project]-gitops` repos create project repos |

See [docs/repo-provisioning.md](repo-provisioning.md) for the full self-service lifecycle.

## Actions versions

Pinned to major versions for stability:

| Action | Version |
|--------|---------|
| `actions/checkout` | `v5` |
| `actions/create-github-app-token` | `v3` |
| `actions/github-script` | `v8` |

## Known gotchas

- **Reusable workflow secrets**: Callers must explicitly pass secrets — they are not inherited. Use `secrets: inherit` only if the caller trusts this repo with all its secrets.
- **GITHUB_TOKEN scope**: The default `GITHUB_TOKEN` cannot add items to GitHub Projects (org-level). The `nsalab-automation` GitHub App with `organization_projects: write` permission is used for `reusable-auto-project` and `reusable-project-sync`. Callers pass `APP_ID` and `APP_PRIVATE_KEY` secrets; the reusable workflow generates a short-lived installation token internally.
- **Workflow call depth**: GitHub allows max 10 levels of reusable workflow nesting (increased from 4). Keep it flat — callers call this repo directly, no chaining.
- **Reusable workflow bootstrap**: When introducing a new reusable workflow, don't add the caller job in the same PR. The `@main` reference will fail because the workflow doesn't exist on main yet, which breaks the entire workflow file (all jobs fail, not just the new one). Merge the workflow first, then add the caller in a follow-up commit.
- **project-sync + Layer 1 hybrid**: `project-sync` is designed to work alongside Layer 1 built-in project workflows. Layer 1 handles common transitions (PR linked → In Review, item closed → Done, item reopened → Backlog) with clean single-event timelines. `project-sync` handles only transitions Layer 1 cannot: draft PRs, ready_for_review, review re-requests after changes, and PR closed without merge. Both must be active for full lifecycle coverage.
- **`pull_request_review` event**: Only fires on `submitted`, not on dismissal. The `changes_requested` state moves the linked issue back to In Progress. The `approved` state is a no-op (stays In Review until merged).
- **Bot events don't trigger workflows**: GitHub suppresses events from App tokens. The review agent must directly update board status on REQUEST_CHANGES (project-sync won't fire). Drift-detect must manually add new issues to the project board (auto-project won't fire).
- **Org rulesets block initial commits**: New repos can't receive direct pushes to main. Use template repos (`template-gitops`, `template-generic`) for bootstrapping. `nsalab-doorman` is a permanent bypass actor on both rulesets, and `do_not_enforce_on_create=true` on `require-pr-validation` allows status checks to be skipped for the initial push.
- **GitHub Terraform provider v6.12.0**: Has nil pointer crash in `github_organization_ruleset` with App tokens. Pin to v6.11.1. Modules must declare `required_providers` with `source = "integrations/github"` to avoid legacy `hashicorp/github` namespace resolution.
- **Complex inline YAML breaks workflow registration**: GitHub's Actions YAML parser can fail silently on workflows with complex inline scripts (Python heredocs, multi-line shell with nested quotes/special characters). Symptom: workflow shows path instead of `name:` field in Actions API, never triggers on events. Fix: always extract logic to external shell scripts in `scripts/` — workflows should only contain form parsing (github-script) and issue comments.
- **Template propagation**: Changes to `template-gitops` or `template-generic` only affect NEW repos. Existing repos need manual sync. Planned mitigation: thin templates with reusable logic consumed via `@main` (nsalab-tmn/template-gitops#14).
- **Mechanic needs `workflows` permission**: The `nsalab-mechanic` App requires `workflows: write` to push changes to `.github/workflows/` files. Without it, pushes are rejected with "refusing to allow a GitHub App to create or update workflow without `workflows` permission."
- **Chicken-egg: modifying housekeeping.yaml**: If the mechanic modifies `housekeeping.yaml` (which contains pr-validate), any syntax error breaks PR Validation for the PR itself — making it permanently unmergeable. Secret parameter names must match exactly (e.g., `app-id` not `APP_ID`).
- **Drift-detect max_tokens**: The Claude API `max_tokens` must be large enough to output all findings. With 7+ repos, 4096 tokens truncates the response — Claude writes the summary but drops the `findings` array. Set to 16384.
- **TF state lock prevention**: Reusable TF plan/apply workflows use `concurrency: { group: terraform-${{ github.repository }}, cancel-in-progress: false }` so runs queue instead of cancelling. Prevents stale state locks from cancelled runs.
- **Template markers**: Template repos use `<!-- TEMPLATE: ... -->` and `<!-- AGENT: ... -->` markers in documentation files. The drift-detect gather script detects these as compliance signals (`has_template_markers`, `links_to_kb`, `has_project_name`). Markers indicate uncustomized content that needs project-specific replacement.
- **Mechanic struggles with nested formats**: The mechanic (Claude Code CLI) can struggle with complex nested structures like JSON embedded inside YAML `label-config` blocks. It may assess the issue as workable but fail to produce changes after multiple attempts.
- **Mechanic creates orphaned PRs**: When re-triggered on an issue with an existing open PR (e.g., after beekeeper REQUEST_CHANGES), the mechanic creates a new branch instead of pushing to the existing PR branch. Planned fix: nsalab-tmn/github-automation#223.
- **Beekeeper phantom rejections**: The beekeeper can sometimes post REQUEST_CHANGES while its own analysis concludes the PR is correct. This is a non-determinism issue at the decision boundary. Planned fix: have the mechanic critically evaluate beekeeper feedback (nsalab-tmn/github-automation#223).
- **Agent chaining (mechanic-dispatch → review-agent)**: `housekeeping.yaml` dispatches `engineering-agent` on every new issue via `gh workflow run` (workflow_dispatch), bypassing bot-event suppression. `engineering-agent` dispatches `review-agent` after creating or updating a PR. The mechanic App (`MECHANIC_CLIENT_ID`/`MECHANIC_PRIVATE_KEY`) must have `actions: write` on github-automation to dispatch workflows — verify App installation permissions if dispatch silently fails.
- **github-automation's housekeeping.yaml is a superset of the standard template**: The platform repo's own `.github/workflows/housekeeping.yaml` intentionally includes two jobs not present in the standard caller template for consuming repos: `mechanic-dispatch` (see *Agent chaining* above) and `bulk-assign` (a `workflow_dispatch` utility for bulk-assigning open issues). This is a documented, intentional deviation — not drift to be fixed. The standard template for consuming repos is in [docs/adoption.md](adoption.md).
