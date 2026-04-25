# Repository Provisioning

Self-service repository lifecycle management via Terraform and issue forms. All repo creation and deletion is declarative — no scripts, no PATs, no manual steps.

## How it works

```
Issue form → workflow creates PR → human reviews → merge → Terraform apply
```

Two levels of provisioning:

| Level | Where | What it creates | Template |
|-------|-------|----------------|----------|
| **GitOps repos** | github-automation | `[project]-gitops` repos | `template-gitops` |
| **Project repos** | `[project]-gitops` | Project service/infra repos | `template-generic` |

## Template repos

### template-gitops

Template for project GitOps repos. Contains:

- Terraform configs (`repos.yaml`, `labels.yaml`) and modules
- TF plan/apply caller workflows with dynamic backend key (derived from repo name)
- Full housekeeping suite (10 caller workflows)
- Self-service issue forms for repo create/delete
- Scaffold and delete workflows that create PRs modifying YAML configs
- Post-apply bootstrap script (creates pinned context issues)
- Engineering documentation (CONTRIBUTING.md, docs/conventions.md)

### template-generic

Generic template for project repos. Contains:

- Skeleton documentation with hidden agent prompts (HTML comments):
  - `README.md` — repo description, quick start, structure, related repos
  - `CONTRIBUTING.md` — issue-first workflow, branching conventions
  - `docs/conventions.md` — tech stack, config formats, known gotchas
- Full housekeeping suite (10 caller workflows)
- Issue templates (bug, enhancement), PR template
- `.gitignore`

Agent prompts guide the librarian/mechanic to fill content by inspecting the repo, reading the pinned context issue, and cross-referencing the project knowledge base. Prompts are removed after the section is populated.

## Creating a GitOps repo

1. Open **Create GitOps repository** issue form in `github-automation`
2. Fill in: project name (required), description (required), justification (required)
3. `scaffold-gitops` workflow creates a PR adding the project to `terraform/configs/gitops-projects.yaml`
4. Terraform plan runs on the PR — review the new repo that will be created
5. Merge the PR
6. Terraform apply creates the repo from `template-gitops`

The new gitops repo is immediately functional — TF workflows, housekeeping, and self-service forms are all inherited from the template.

## Creating a project repo

1. Open **Create repository** issue form in the project's `[project]-gitops` repo
2. Fill in: repo name (required), description (required), visibility (required), justification (required), upstream issue (optional)
3. `scaffold-repo` workflow creates a PR adding the repo to `terraform/configs/repos.yaml` with `template: template-generic`
4. Terraform plan runs — review the new repo
5. Merge the PR
6. Terraform apply creates the repo from `template-generic`
7. Post-apply bootstrap job creates a pinned context issue in the new repo

## Deleting a repo

Same flow in reverse:

1. Open **Delete GitOps repository** (in github-automation) or **Delete repository** (in project-gitops) issue form
2. Workflow creates a PR removing the entry from the YAML config
3. Terraform plan shows the repo will be destroyed — **review carefully**
4. Merge the PR
5. Terraform apply deletes the repo permanently

## Agent bootstrap pipeline

After a project repo is created from `template-generic`, agents autonomously populate the documentation:

```
template-generic provides skeleton docs with hidden agent prompts
  → bootstrap job creates pinned context issue (description + gitops link)
  → librarian detects content gaps ("conventions.md: Technology stack is empty")
  → mechanic reads agent prompts + knowledge base + upstream issue
  → mechanic fills sections, removes prompts
  → beekeeper reviews content against knowledge base
```

### Signal chain

Agents reconstruct the repo's purpose from these signals:

| Signal | Source | What it tells the agent |
|--------|--------|------------------------|
| Repo description | `repos.yaml` → Terraform | What this repo is for (one-line) |
| Pinned context issue | Bootstrap script | Description + link to gitops repo for full context |
| Upstream issue | Create-repo form (optional) | The issue that triggered repo creation — detailed requirements |
| Knowledge base | Project-specific KB repo | Cross-repo conventions (ansible patterns, SOPS, CI/CD, etc.) |
| Hidden agent prompts | `template-generic` docs | Specific instructions for each section to fill |
| Template markers | `<!-- TEMPLATE: -->` in docs | Uncustomized sections — gather script reports `has_template_markers` flag |
| Doc compliance signals | Gather script (deterministic) | `has_template_markers`, `links_to_kb`, `has_project_name` — targeted boolean checks |

### Drift-detect integration

The gather script checks documentation files for specific signals rather than sending full content to Claude:

| Signal | What it checks | How detected |
|--------|---------------|--------------|
| `has_template_markers` | `<!-- TEMPLATE: -->` or `<!-- AGENT: -->` present in docs | grep in README.md, CONTRIBUTING.md, docs/conventions.md |
| `links_to_kb` | Docs reference the project's knowledge base URL | grep for KB repo name |
| `has_project_name` | README heading is project-specific, not generic "Project GitOps" | First `#` heading check |

These boolean signals give Claude clear compliance criteria without requiring full file content in the API call.

## Identity and auth

| Operation | Identity | Why |
|-----------|----------|-----|
| Scaffold/delete workflow (push + PR) | `nsalab-automation[bot]` | Must trigger downstream workflows (GITHUB_TOKEN doesn't) |
| Terraform plan/apply | `nsalab-doorman[bot]` | Repo admin operations + ruleset bypass for template bootstrapping |
| Bootstrap pinned issues | `nsalab-automation[bot]` | Creates issues in newly provisioned repos |

## Terraform modules

Both template repos reference modules from this repo:

| Module | What it manages |
|--------|----------------|
| `github_repository` | Repo settings: merge strategy, branch deletion, feature toggles, template |
| `github_issue_labels` | Labels: standard set + per-repo overrides |
| `github_organization_ruleset` | Org-wide branch protection rulesets |

Modules are referenced via `source = "github.com/nsalab-tmn/github-automation//terraform/modules/<name>?ref=main"`.

## Config formats

### gitops-projects.yaml (in github-automation)

```yaml
gitops_repos:
  - name: myproject
    description: "GitOps configuration for the myproject project"
```

### repos.yaml (in project-gitops repos)

```yaml
repos:
  - name: project-service
    description: "Service description"
    visibility: private
    template: template-generic    # optional, defaults to no template
```

### labels.yaml (in project-gitops repos)

```yaml
default_labels:
  - { name: bug, color: "d73a4a", description: "Something isn't working" }

repo_specific_labels:
  project-service:
    - { name: api, color: "5319e7", description: "API changes" }
```

## Why two-tier architecture

The provisioning system uses two tiers: org-wide (`github-automation`) and per-project (`[project]-gitops`). A simpler single-tier approach (all repos in one config) would work for small orgs but doesn't scale. The deciding factors:

**Privacy.** `github-automation` is a public repo — project-specific configs (repo names, descriptions, labels) would be visible to anyone. Project gitops repos are private, keeping project boundaries private.

**TF state isolation.** Each gitops repo has its own Terraform state in Azure Blob Storage. A provider crash or failed apply in project A doesn't block project B. A single state file managing all repos across projects is a single point of failure.

**Agent blast radius.** When the mechanic agent working on a project repo needs a new repo, it creates an issue in that project's gitops repo — scoped to that project. If it went to `github-automation` instead, the agent would need cross-project write access and could accidentally affect other projects' configs.

### Template propagation limitation

Template repos are applied at creation time only. Changes to `template-gitops` do NOT propagate to existing gitops repos. This means:
- Bug fixes in template workflows require manual sync to each existing gitops repo
- New features (like self-labeling) need to be added to each repo individually

**Mitigation strategy** (planned, see nsalab-tmn/template-gitops#14): move complex logic (scaffold/delete scripts, bootstrap) to reusable workflows in `github-automation`, consumed via `@main` references. The template becomes thinner — only thin caller workflows and TF configs. Fixes propagate automatically to all consumers.

## Known gotchas

- **Org rulesets block initial commits**: Template repos work because `do_not_enforce_on_create=true` on `require-pr-validation` and `nsalab-doorman` is a bypass actor on both rulesets.
- **`do_not_enforce_on_create` resets**: The Terraform GitHub provider (v6.11.1) doesn't properly track this field. After TF apply, verify via `gh api orgs/nsalab-tmn/rulesets/<id>` and fix via API if needed.
- **Doorman needs `contents:read`**: Template generation requires cloning the template repo's content. The doorman App must have this permission.
- **GITHUB_TOKEN won't trigger workflows**: Scaffold/delete workflows use `nsalab-automation` App token so the created PR triggers housekeeping and PR Validation.
- **Pinned label must exist**: Bootstrap script creates issues with `pinned` label. The label is provisioned by Terraform from `labels.yaml` — runs in the same apply as repo creation.
- **Complex inline YAML breaks workflow registration**: GitHub's Actions YAML parser can fail to register workflows with complex inline scripts (Python heredocs, multi-line shell with special characters). Always extract logic to external shell scripts in `scripts/` — the workflow should only contain issue form parsing (github-script) and comments.
- **Template propagation**: Changes to `template-gitops` or `template-generic` only affect NEW repos created after the change. Existing repos need manual sync. See nsalab-tmn/template-gitops#14 for the planned mitigation.
- **Self-labeling requires first TF apply**: Newly created gitops repos don't have `repo-request`/`repo-delete` labels until their first `terraform apply` runs. The bootstrap job (from github-automation) creates the `pinned` label as a workaround, but scaffold/delete labels come from self-labeling.
