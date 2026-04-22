# Enforcement Architecture

How convention enforcement works across the `nsalab-tmn` organization. Four layers, each handling what it's best at.

## Layers overview

```
Layer 0: GitHub Settings          ← configure once, automatic, no drift possible
Layer 1: GitHub Built-ins         ← templates, default labels, issue forms
Layer 2: Deterministic Workflows  ← IF event THEN action, no judgment
Layer 3: AI-Assisted Heuristics   ← reads context, exercises judgment
```

Each layer catches what the one below it can't. The goal is to push enforcement as low as possible — Layer 0 is cheapest, Layer 3 is most expensive.

## Layer 0: GitHub Settings

Settings configured once at the org or repo level. Zero maintenance, no drift possible once set.

### Free tier

Available for all repos regardless of plan.

| Setting | What it enforces | How set |
|---|---|---|
| Squash merge only | Linear commit history | API: `allow_merge_commit=false, allow_rebase_merge=false` |
| Auto-delete head branches | No stale branches after merge | API: `delete_branch_on_merge=true` |
| Default branch = `main` | Naming consistency | Set by scaffold or manually |
| Wiki disabled | Docs live in repo, not wiki | Set by scaffold |
| Branch protection (public repos) | Require PR, status checks, block force push | Repo settings |

### GitHub Teams tier

Requires GitHub Teams plan ($4/user/month). Currently active.

| Setting | What it enforces | Status |
|---|---|---|
| Org-wide ruleset: require PR | No direct pushes to main across all repos | ✅ Active |
| Org-wide ruleset: require PR Validation | PRs must pass validation before merge | ✅ Active |
| Org-wide ruleset: block force push | History cannot be rewritten | ✅ Active |
| Org-level secrets | Single source for `APP_ID`, `APP_PRIVATE_KEY`, `ANTHROPIC_API_KEY` | ✅ Active |

### GitHub Projects automation

GitHub Projects V2 has built-in automation rules that operate independently of GitHub Actions:

| Workflow | What it does | Status |
|---|---|---|
| Item closed → Done | Set Status when issue/PR closes | ✅ Enabled |
| PR linked to issue → In Review | Set Status when PR links to issue | ✅ Enabled |
| Item added → Backlog | Set Status when item is added to board | ✅ Enabled |
| Item reopened → Backlog | Set Status when issue reopens | ✅ Enabled |
| Auto-add sub-issues | Add sub-issues when parent is on board | ✅ Enabled |
| Auto-archive | Archive items matching criteria | ✅ Enabled |

These fire regardless of who created the event (including bots), produce clean single-event timelines, and cannot be configured via API (manual UI setup per project board).

## Layer 1: GitHub Built-ins

Features that work through GitHub's native mechanisms without custom workflows.

| Feature | What it does | How configured |
|---|---|---|
| Issue templates | Apply labels at creation (`labels:` frontmatter) | `.github/ISSUE_TEMPLATE/*.md` |
| Issue forms | Structured input with validation | `.github/ISSUE_TEMPLATE/*.yaml` |
| PR template | Guide PR structure | `.github/pull_request_template.md` |
| Native Issue Types | Bug, Feature, Task classification | Org-level configuration |

## Layer 2: Deterministic Workflows

Reusable GitHub Actions workflows in this repo. Rule-based: IF event THEN action. No AI, no judgment.

### Housekeeping workflows (event-driven)

| Workflow | Trigger | What it does |
|---|---|---|
| `reusable-auto-assign` | Issue/PR opened | Assigns creator or default assignee |
| `reusable-auto-project` | Issue opened | Adds to project board, sets Status and Issue Type |
| `reusable-auto-label` | PR opened/synchronized | Labels PRs by changed file paths |
| `reusable-pr-size` | PR opened/synchronized | Labels PRs by lines changed (XS/S/M/L/XL) |
| `reusable-pr-validate` | PR opened/edited/labeled | Validates linked issue, description, labels |
| `reusable-branch-validate` | PR opened | Enforces branch naming convention |
| `reusable-issue-defaults` | Issue opened/typed | Sets project field defaults (Priority, Size) based on Issue Type |
| `reusable-project-sync` | PR review/state change | Syncs project board Status with PR lifecycle |

### Compliance workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `reusable-compliance-check` | Push to main, PR merged | Detects direct pushes and PRs merged without validation |
| `reusable-structural-check` | Weekly schedule | Validates required files, workflow callers, and labels exist |
| `reusable-conflict-check` | Push to main, weekly | Detects and labels PRs with merge conflicts |

### Maintenance workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `reusable-stale-check` | Weekly | Labels inactive issues as stale, optionally closes |
| `reusable-stale-pr` | Weekly | Labels inactive PRs as stale, optionally closes drafts |
| `reusable-pinned-sync` | On close + weekly | Auto-updates pinned context issue from repo state |

### Other workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `scaffold-repo` | Issue form with `repository-request` label | Creates new repos with all org standards |

### Design principles

1. **Project-agnostic**: All context comes via inputs, nothing is hardcoded
2. **Minimal permissions**: Each workflow declares only what it needs
3. **Idempotent**: Safe to run multiple times on the same event
4. **Observable**: Every action logged via step summary
5. **Fail-safe**: Worst case is "automation didn't run", never "automation broke something"

### Adoption

Consuming repos create thin caller workflows that reference reusable workflows via `@main`. See [docs/adoption.md](adoption.md) for setup.

## Layer 3: AI-Assisted Heuristics

Tasks that require reading context, understanding intent, and exercising judgment. Uses the Claude API with schema-constrained tool use for near-deterministic output.

### Architecture: Gather → Decide → Execute

```
Gather (deterministic)          Decide (Claude API)              Execute (deterministic)
  Shell scripts collect    →    Schema-constrained tool use  →   Create issues, post
  repo state via gh CLI         temperature=0, forced output     summaries via gh API
```

- **Gather**: deterministic shell scripts that collect JSON state from GitHub API
- **Decide**: Claude API call with gathered state + conventions. Output constrained to a strict JSON schema via tool use. `temperature=0` for near-deterministic results
- **Execute**: parse Claude's structured output into `gh` CLI / API commands. No free-form text drives actions

### Determinism approach

Claude's output is constrained at multiple levels:

| Constraint | How | Effect |
|---|---|---|
| `temperature: 0` | API parameter | Greedy decoding, most deterministic |
| Forced tool use | `tool_choice: {type: "tool", name: "..."}` | No free-form text, must use schema |
| JSON schema | `input_schema` on the tool | Output structure is fixed |
| Enum fields | `type`, `severity` are enums | Limited vocabulary |
| Filename constraint | `convention_file` must match input filenames | Stable dedup keys |
| Prompt rules | "ONE finding per type+file per repo" | Consolidation prevents splitting |

Result: ~100% structural determinism (same JSON shape every run), ~95% content determinism (same findings for same input, minor wording variation in free-text fields).

### Active Layer 3 workflows

| Workflow | Schedule | What it does |
|---|---|---|
| `drift-detect` | Weekly + manual | Compares project repos against knowledge base conventions, creates issues for drift |

### Convention drift detection

Centralized in this repo. Reads project config from `config/drift-projects.yaml`:

```yaml
projects:
  - name: <project>
    knowledge-base: nsalab-tmn/<project>-knowledge-base
    conventions-path: conventions
    repos:
      - nsalab-tmn/<project>-knowledge-base
      - nsalab-tmn/<project>-vpn
      - nsalab-tmn/<project>-infra
      - ...
```

Finding types:
- `drift` — repo previously followed convention but diverged
- `gap` — repo never adopted a convention
- `stale_docs` — convention doc is outdated vs actual practice
- `inconsistency` — repos handle the same thing differently without documented reason

Issues are created as `nsalab-automation[bot]` (GitHub App) with `compliance` label. Dedup via HTML markers prevents duplicates across runs.

### Maturation principle

Layer 3 is an R&D lab for Layer 2. When Claude makes the same recommendation repeatedly, formalize it as a deterministic workflow and push it down to Layer 2. Over time, Layer 2 grows and Layer 3 shrinks — that's the system maturing.

## Knowledge hierarchy

```
github-automation (org-wide)
  ├── Reusable workflows (Layer 2)
  ├── Drift detection (Layer 3)
  ├── Scaffold templates
  └── This architecture doc
        ↓ consumed by
[project]-knowledge-base (project-wide)
  ├── conventions/     ← project-specific standards
  ├── architecture/    ← system design
  └── decisions/       ← rationale
        ↓ compared against
[project]-* repos (individual repos)
  └── .github/workflows/housekeeping.yaml  ← thin callers
```

Vertical distribution: project repos follow project knowledge base, which follows org-wide standards.

## Identity and authentication

| Operation | Token | Identity shown |
|---|---|---|
| Single-repo Layer 2 (assign, label, validate) | `GITHUB_TOKEN` | `github-actions[bot]` |
| Project board Layer 0 (built-in automations) | Internal | `github-project-automation[bot]` |
| Project board Layer 2 (auto-project, project-sync) | GitHub App token | `nsalab-automation[bot]` |
| Cross-repo Layer 3 (drift detection, issue creation) | GitHub App token | `nsalab-automation[bot]` |
| Claude API calls | `ANTHROPIC_API_KEY` | N/A |

Secrets are org-level (shared across all repos): `APP_ID`, `APP_PRIVATE_KEY`, `ANTHROPIC_API_KEY`. Repo-specific secrets remain per-repo (e.g., `SCAFFOLD_TOKEN` in github-automation).

### Bot event behavior

GitHub Actions workflows are NOT triggered by events created via App tokens (safety feature to prevent loops). The `issues.opened` event is suppressed for bot-created issues. Workaround: GitHub Projects automation fires `issues.typed` which some workflows catch.

## Cross-references

- [docs/adoption.md](adoption.md) — how to adopt workflows in your repo
- [docs/conventions.md](conventions.md) — workflow catalog and technical reference
- [Issue #7](https://github.com/nsalab-tmn/github-automation/issues/7) — Layer 3 architecture discussion
- [Issue #51](https://github.com/nsalab-tmn/github-automation/issues/51) — drift detection implementation and testing
