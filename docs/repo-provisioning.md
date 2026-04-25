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
  - name: cheburnet
    description: "GitOps configuration for the cheburnet project"
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

## Known gotchas

- **Org rulesets block initial commits**: Template repos work because `do_not_enforce_on_create=true` on `require-pr-validation` and `nsalab-doorman` is a bypass actor on both rulesets.
- **`do_not_enforce_on_create` resets**: The Terraform GitHub provider (v6.11.1) doesn't properly track this field. After TF apply, verify via `gh api orgs/nsalab-tmn/rulesets/<id>` and fix via API if needed.
- **Doorman needs `contents:read`**: Template generation requires cloning the template repo's content. The doorman App must have this permission.
- **GITHUB_TOKEN won't trigger workflows**: Scaffold/delete workflows use `nsalab-automation` App token so the created PR triggers housekeeping and PR Validation.
- **Pinned label must exist**: Bootstrap script creates issues with `pinned` label. The label is provisioned by Terraform from `labels.yaml` — runs in the same apply as repo creation.
