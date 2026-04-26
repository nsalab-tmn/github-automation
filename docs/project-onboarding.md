# Project Onboarding

End-to-end guide for bringing a project from zero to fully autonomous pipeline. This document sequences the phases — it tells you **what to do in what order** and links to other docs for how each piece works internally.

> Throughout this guide, `<org>` refers to your GitHub organization name. Replace it with your actual org name in all commands and configuration.

## Prerequisites

These org-level resources must exist before onboarding a project. They are shared across all projects and only need to be set up once.

| Prerequisite | How to verify |
|---|---|
| GitHub org membership | `gh api user/memberships/orgs/<org>` |
| GitHub Apps installed org-wide | Org Settings > GitHub Apps > Installed GitHub Apps — verify all 5 apps listed below |
| Org-level secrets configured | Org Settings > Secrets and variables > Actions — verify all secrets listed below |
| Terraform remote backend | CI handles this via backend-specific secrets (e.g., `ARM_*` for Azure, `AWS_*` for S3) |

### GitHub Apps

Five GitHub Apps provide identity separation for different automation layers. Each org creates its own apps — the names below describe the role, not a required naming convention.

| Role | Purpose |
|---|---|
| **automation** | Layer 2 project board operations (auto-project, project-sync, issue-defaults, scaffold/delete) |
| **librarian** | Layer 3 drift detection — creates compliance issues |
| **mechanic** | Layer 3 engineering agent — checkout, push, PR creation. Requires `workflows: write` permission |
| **beekeeper** | Layer 3 review agent — posts PR reviews (APPROVE/REQUEST_CHANGES) |
| **doorman** | Terraform operations — repo admin, ruleset management. Permanent bypass actor on org rulesets |

Separate identities ensure clean audit trails and allow cross-bot interactions (e.g., the beekeeper can APPROVE PRs created by the mechanic since they are different App identities).

### Org secrets

| Secret | Used by |
|---|---|
| `APP_ID`, `APP_PRIVATE_KEY` | Layer 2 workflows (automation app) |
| `LIBRARIAN_CLIENT_ID`, `LIBRARIAN_PRIVATE_KEY` | `drift-detect` (librarian app) |
| `MECHANIC_CLIENT_ID`, `MECHANIC_PRIVATE_KEY` | `engineering-agent` (mechanic app) |
| `BEEKEEPER_CLIENT_ID`, `BEEKEEPER_PRIVATE_KEY` | `review-agent` (beekeeper app) |
| `DOORMAN_CLIENT_ID`, `DOORMAN_PRIVATE_KEY` | `terraform-plan/apply` (doorman app) |
| `ANTHROPIC_API_KEY` | All Layer 3 Decide phases (Claude API) |
| Backend-specific secrets | Terraform remote state (e.g., `ARM_*` for Azure Blob, `AWS_*` for S3) |

No per-repo secret configuration is needed — org secrets are available to all repos by default. If secret visibility is restricted to specific repos, add new project repos to the allowed list in each secret's repository access settings.

## Phases overview

```
Phase 1: Create GitHub Project Board
   │
Phase 2: Provision [project]-gitops repo
   │
Phase 3: Register repos in gitops
   ├── Import existing repos (terraform import)
   └── Create new repos (including knowledge-base)
   │
Phase 4: Per-repo Layer 2 adoption
   │
Phase 5: Layer 3 agent enablement
   │
Phase 6: Verification
```

Each phase depends on the previous one. Phases 3a (import) and 3b (create) can run in parallel.

---

## Phase 1: Create GitHub Project Board

**Goal**: A Kanban board that serves as the single source of truth for work status across all project repos.

### Create the project

1. Go to `https://github.com/orgs/<org>/projects` > **New project**
2. Select the **Board** (Kanban) template
3. The template includes: columns **Backlog**, **Blocked**, **In progress**, **In review**, **Done** + **Priority** and **Size** fields

Note the **project-number** from the URL: `https://github.com/orgs/<org>/projects/N` — use `N` in all subsequent configuration.

### Enable Layer 1 automations

Go to the project > **Settings** > **Workflows** and enable all 6 automations:

| Automation | Trigger | Action |
|---|---|---|
| Item closed | Issue/PR closed | Set Status = Done |
| PR linked to issue | PR linked to project item | Set Status = In Review |
| Item added to project | Item added to board | Set Status = Backlog |
| Item reopened | Issue/PR reopened | Set Status = Backlog |
| Auto-add sub-issues | Sub-issue created | Add to project |
| Auto-archive | Configurable criteria | Archive item |

> **Why manual?** These built-in automations cannot be configured via API or Terraform. They must be enabled per project board through the UI. They fire regardless of who created the event (including bots), produce clean single-event timelines, and handle the common lifecycle transitions. See [docs/architecture.md](architecture.md) for how they interact with Layer 2 `project-sync`.

### Verify

Create a test issue in any org repo, add it to the board manually, confirm it lands in Backlog. Close it, confirm it moves to Done. Delete the test issue.

---

## Phase 2: Provision [project]-gitops repo

**Goal**: A Terraform-managed gitops repo that serves as the control plane for all project repos — settings, labels, and self-service repo creation/deletion.

### Create the gitops repo

1. Open the **Create GitOps repository** issue form in the github-automation repo
2. Fill in: **project name** (lowercase, alphanumeric + hyphens), **description**, **justification**
3. Submit — the `scaffold-gitops` workflow creates a PR modifying `terraform/configs/gitops-projects.yaml`
4. Wait for `terraform-plan` to post a plan comment on the PR — review that it shows exactly one new `github_repository` resource: `module.gitops_repo["<project>"]`
5. Merge the PR
6. `terraform-apply` creates `<org>/<project>-gitops` from `template-gitops`
7. Bootstrap job creates a pinned context issue in the new repo

The new gitops repo is immediately functional: TF plan/apply workflows, full housekeeping suite, self-service issue forms for repo create/delete, and engineering documentation — all inherited from `template-gitops`.

See [docs/repo-provisioning.md](repo-provisioning.md) for full scaffold/delete mechanics and template contents.

### Org rulesets and new repos

Two org-wide rulesets apply to all repos including newly created ones. Understanding their interaction with repo provisioning is critical.

**`require-pull-request` ruleset** — requires all changes to the default branch go through PRs with squash merge. Blocks direct pushes and force pushes.

**`require-pr-validation` ruleset** — requires the "PR Validation" status check to pass before merge. Has a special setting:

```yaml
rules:
  required_status_checks:
    do_not_enforce_on_create: true
```

This allows new repos to receive their initial template commits without failing on missing status checks. Without it, repos created from templates would immediately be in a broken state — no PR could merge because the PR Validation workflow doesn't exist yet in the repo's first commit.

**Doorman bypass** — the doorman app is configured as a permanent bypass actor on both rulesets. This allows the Terraform provider (authenticated as doorman) to push the template content as the initial commit without going through a PR.

> **`do_not_enforce_on_create` tracking bug**: The GitHub Terraform provider (v6.11.1) does not properly track the `do_not_enforce_on_create` field. After Terraform apply, it may silently reset to `false`. Verify after each apply:
>
> ```bash
> gh api orgs/<org>/rulesets --jq \
>   '.[] | select(.name=="require-pr-validation") | .rules[] | select(.type=="required_status_checks") | .parameters'
> ```
>
> If `do_not_enforce_on_create` is `false`, fix via API:
>
> ```bash
> RULESET_ID=$(gh api orgs/<org>/rulesets --jq '.[] | select(.name=="require-pr-validation") | .id')
> gh api --method PUT "orgs/<org>/rulesets/$RULESET_ID" \
>   --input <(jq -n '{rules: [{type: "required_status_checks", parameters: {do_not_enforce_on_create: true, strict_required_status_checks_policy: false, required_status_checks: [{context: "PR Validation"}]}}]}')
> ```

### Verify

- Repo exists: `gh repo view <org>/<project>-gitops`
- Pinned issue exists: `gh issue list --repo <org>/<project>-gitops --label pinned`
- Settings correct: squash merge only, auto-delete branches, wiki disabled
- Template content present: TF configs, housekeeping workflows, issue forms

---

## Phase 3: Register repos in gitops

**Goal**: All project repos — existing and new — are managed declaratively through the gitops repo.

### Import existing repos

If the project has repos that predate the gitops repo, import them into Terraform management.

**Step 1**: Add entries to `terraform/configs/repos.yaml` in the gitops repo via PR:

```yaml
repos:
  - name: existing-repo
    description: "Description of the repo"
    visibility: private
```

Do **not** set `template:` for existing repos — templates are only applied at creation time.

**Step 2**: Import existing resources into Terraform state. This must happen before Terraform apply, otherwise TF will attempt to create repos that already exist. Run the imports via CI or locally with proper credentials:

```bash
# Import repo settings
terraform import 'module.repo["existing-repo"].github_repository.this' existing-repo

# Import labels — repeat for each label that already exists on the repo
terraform import 'module.repo_labels["existing-repo"].github_issue_labels.this["bug"]' existing-repo/bug
terraform import 'module.repo_labels["existing-repo"].github_issue_labels.this["enhancement"]' existing-repo/enhancement
# ... for each default label (bug, enhancement, documentation, ci-cd, tech-debt,
#     pinned, stale, in-progress, compliance, merge-conflict, ai-generated, needs-triage)
```

> **Tip**: Only import labels that already exist on the repo. Terraform will create missing labels on the next apply. If the repo has no labels yet, skip the label imports entirely.

**Step 3**: Create the PR with `repos.yaml` changes. Terraform plan should show in-place updates to align settings (e.g., enabling squash-only merge), not resource creation.

**Step 4**: Merge — Terraform apply aligns settings with org standards.

### Create new repos

New repos (including the knowledge base) are created through the gitops self-service flow:

1. Open the **Create repository** issue form in `<org>/<project>-gitops`
2. Fill in: repo name, description, visibility, justification
3. The scaffold workflow creates a PR adding the repo to `repos.yaml` with `template: template-generic`
4. Review terraform plan, merge, terraform apply creates the repo
5. Bootstrap job creates a pinned context issue in the new repo

### Knowledge base

The knowledge base should be one of the first repos created. It serves as the source of truth for project-specific conventions that drift-detect compares repos against.

After creation, seed the `conventions/` directory with project-specific standards:

```
<project>-knowledge-base/
└── conventions/
    ├── workflows.md      # CI/CD patterns, required workflows
    ├── documentation.md  # Doc structure, required sections
    ├── naming.md         # Branch, label, repo naming conventions
    └── ...               # Project-specific convention files
```

> **Special case — self-referencing projects**: The github-automation repo itself can use its own `docs/` directory as its knowledge base. In the agent configs, set `knowledge-base: <org>/github-automation` and `conventions-path: docs`. No separate KB repo needed.

### Verify

- New repos exist with correct settings: `gh repo view <org>/<project>-<repo>`
- Imported repos aligned: `terraform plan` shows no changes
- Knowledge base has `conventions/` directory
- Pinned context issues created in each new repo

---

## Phase 4: Per-repo Layer 2 adoption

**Goal**: Each project repo calls the reusable workflows for automated housekeeping and compliance.

See [docs/adoption.md](adoption.md) for the full caller workflow examples, available workflows table, and input documentation.

### Repos created from template-generic

These already have 10 caller workflows inherited from the template. Update the `project-number` input in all callers that reference it:
- `auto-project` — use the project-number from Phase 1
- `project-sync` — same project-number
- `issue-defaults` — same project-number

### Imported repos

Add caller workflows manually per [docs/adoption.md](adoption.md). The key workflow files:

| File | Purpose | Trigger |
|---|---|---|
| `housekeeping.yaml` | Assign, project, label, size, validate | Issues + PRs |
| `stale-check.yaml` | Label inactive issues | Weekly schedule |
| `stale-pr.yaml` | Label inactive PRs | Weekly schedule |
| `compliance-check.yaml` | Detect direct pushes, unchecked merges | Push to main + PR merge |
| `structural-check.yaml` | Validate repo structure | Weekly schedule |
| `conflict-check.yaml` | Detect merge conflicts | Push to main + weekly |
| `pinned-sync.yaml` | Update pinned issue | Issue/PR close + weekly |

The `housekeeping.yaml` caller must handle these events for full lifecycle coverage:

```yaml
on:
  issues:
    types: [opened, typed]
  pull_request:
    types: [opened, synchronize, edited, labeled, unlabeled,
            ready_for_review, review_requested, closed]
  pull_request_review:
    types: [submitted]
```

### Pinned issue

Each repo needs a pinned context issue with HTML markers for auto-updated sections:

```markdown
<!-- auto:checklist -->
<!-- /auto:checklist -->

<!-- auto:remaining -->
<!-- /auto:remaining -->

<!-- auto:completed -->
<!-- /auto:completed -->

<!-- structural-check -->
<!-- /structural-check -->
```

Content outside markers is never modified by automation. Repos created from `template-generic` get a pinned issue from the bootstrap job, but imported repos need one created manually.

### Verify per repo

- Create a test issue — check auto-assign and project board placement
- Open a test PR from a properly named branch — check labels, size label, validation passes
- Run `structural-check` manually via `workflow_dispatch` — check results in pinned issue

---

## Phase 5: Layer 3 agent enablement

**Goal**: Enable AI-assisted drift detection, automated fixes, and automated PR reviews for the project.

See [docs/architecture.md](architecture.md) for the full Layer 3 architecture, Gather-Decide-Execute pattern, and the feedback loop between agents.

### Add project to agent configs

Three config files in `config/` need a project entry. Create a PR in github-automation adding the project to all three:

**`config/drift-projects.yaml`**:

```yaml
project-number: <N>  # top-level, shared across all projects on the same board

projects:
  # existing projects...
  - name: <project>
    knowledge-base: <org>/<project>-knowledge-base
    conventions-path: conventions
    repos:
      - <org>/<project>-knowledge-base
      - <org>/<project>-repo1
      - <org>/<project>-repo2
```

**`config/engineering-agent.yaml`** — add the same `projects` entry. The `agent` section at the top contains global settings (schedule, limits, board column names) shared across all projects.

**`config/review-agent.yaml`** — add the same `projects` entry.

> **Column names are case-sensitive.** The `status` block must match the project board column names exactly: `Backlog`, `Blocked`, `In progress`, `In review`, `Done`.

> **Multiple boards.** `project-number` is a top-level field shared across all projects. If the new project uses a different board than existing projects, the config structure would need refactoring to support per-project board numbers.

### Verify app installations

All 5 GitHub Apps must have access to the target repos. Check each App's installation in Org Settings > GitHub Apps > Installed GitHub Apps:
- If set to "All repositories" — no action needed
- If set to "Only select repositories" — add the new project repos to each App's list

### Dry-run drift-detect

Go to **Actions** > `drift-detect` > **Run workflow** > check **Dry run**. Review the step summary:

- Verify it discovers the project and all repos
- Verify findings are reasonable (expect `gap` findings for new repos, `has_template_markers` for repos from template-generic)
- No issues are created in dry-run mode

### Dry-run engineering-agent

Go to **Actions** > `engineering-agent` > **Run workflow** > check **Dry run**. Optionally provide a specific issue URL. Review:

- Issue selection works (finds issues on the board with `compliance` label in eligible statuses)
- Brief compilation produces a coherent implementation brief from gathered context
- No PR is created in dry-run mode

### Schedules

Workflow schedules are defined in the workflow files themselves and are always active:

| Workflow | Schedule |
|---|---|
| `drift-detect` | Monday 10am UTC |
| `engineering-agent` | Weekdays 8am UTC (or manual only during crawl phase) |
| `review-agent` | Weekdays 9am UTC |

Once the project entries exist in config files, the workflows will include the project's repos on their next scheduled run. No separate "enable" step is needed.

### Verify

- Drift-detect dry-run completes without errors
- Engineering-agent dry-run produces a valid brief
- After first real drift-detect run: compliance issues appear on the project board in Backlog
- After first real engineering-agent run: PRs appear for workable compliance issues

---

## Phase 6: Verification checklist

| Phase | Check | How to verify |
|---|---|---|
| 1 | Board exists with 5 columns | Visit project URL, verify Backlog/Blocked/In progress/In review/Done |
| 1 | Layer 1 automations enabled | Project Settings > Workflows — all 6 active |
| 2 | GitOps repo exists | `gh repo view <org>/<project>-gitops` |
| 2 | GitOps pinned issue | `gh issue list --repo <org>/<project>-gitops --label pinned` |
| 2 | `do_not_enforce_on_create` intact | API check (see Phase 2) |
| 3 | Imported repos in TF state | `terraform plan` shows no changes |
| 3 | KB repo has conventions/ | `gh api repos/<org>/<project>-knowledge-base/contents/conventions` |
| 4 | Caller workflows present | `gh api repos/<org>/<repo>/contents/.github/workflows` |
| 4 | Pinned issue has markers | Read pinned issue body, verify HTML comment markers |
| 4 | Test issue lands on board | Create issue, check board placement |
| 5 | Project in all 3 agent configs | `grep -l '<project>' config/*.yaml` |
| 5 | Apps have repo access | Org Settings > GitHub Apps — verify each app |
| 5 | Drift-detect dry-run passes | Actions > drift-detect > Run workflow (dry-run) |
| 5 | Engineering-agent dry-run passes | Actions > engineering-agent > Run workflow (dry-run) |

---

## Special cases

### Self-referencing projects

The github-automation repo can use its own `docs/` directory as its knowledge base. In the agent configs:

```yaml
- name: platform
  knowledge-base: <org>/github-automation
  conventions-path: docs
  repos:
    - <org>/github-automation
    - <org>/template-generic
    - <org>/template-gitops
```

No separate knowledge-base repo needed — the conventions are the docs in this repo.

### Template repos

`template-generic` and `template-gitops` are org-wide resources managed in github-automation, not in any project's gitops repo. They can be included in a project's agent config for drift detection and automated fixes, but changes to templates only affect **new** repos created after the change — existing repos need manual sync.

### Private repo secret visibility

Org-level secrets are available to all repos by default. If secret visibility is restricted to specific repos, add new project repos to the allowed list: Org Settings > Secrets and variables > Actions > each secret > Repository access.

---

## Cross-references

| Document | Read when |
|---|---|
| [docs/adoption.md](adoption.md) | Setting up Layer 2 caller workflows (Phase 4 details) |
| [docs/repo-provisioning.md](repo-provisioning.md) | Scaffold/delete mechanics, template contents, bootstrap pipeline |
| [docs/architecture.md](architecture.md) | Understanding the 4-layer architecture and Layer 3 feedback loop |
| [docs/conventions.md](conventions.md) | Workflow catalog, naming conventions, known gotchas |
