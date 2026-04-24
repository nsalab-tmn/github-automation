# Enforcement Architecture

A practical architecture for maintaining engineering standards across a multi-repo GitHub organization using a combination of platform settings, deterministic workflows, and AI-assisted automation. The system is designed so that convention enforcement is as cheap and automatic as possible — human judgment is reserved for decisions that genuinely need it.

The architecture scales from a single project to an organization with dozens of repositories, and from a solo maintainer to a team. Every component is open source, uses standard GitHub features, and can be adopted incrementally — start with Layer 0 settings, add Layer 2 workflows when manual processes become repetitive, and introduce Layer 3 agents when the volume of routine work justifies AI-assisted automation.

---

How convention enforcement works across the organization. Four layers, each handling what it's best at.

## Layers overview

```
Layer 0: GitHub Settings + Terraform ← configure once, version-controlled, no drift
Layer 1: GitHub Built-ins            ← templates, default labels, issue forms
Layer 2: Deterministic Workflows     ← IF event THEN action, no judgment
Layer 3: AI-Assisted Heuristics      ← reads context, exercises judgment
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
| Org-level secrets | Single source for App credentials and API keys | ✅ Active |

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

### Terraform-managed settings

Organization settings that require version control and audit trails are managed via Terraform (`nsalab-doorman[bot]`):

| Resource | Terraform module | Config |
|---|---|---|
| Org rulesets | `github_organization_ruleset` | `terraform/configs/rulesets.yaml` |
| Repo settings | `github_repository` (reusable module) | Per-project `configs/repos.yaml` |
| Labels | `github_issue_label` (reusable module) | Per-project `configs/labels.yaml` |

**Two-tier architecture:**
- **Org-wide** (`github-automation/terraform/`): rulesets, reusable modules. Public, project-agnostic.
- **Per-project** (`[project]-gitops/terraform/`): repos, labels, descriptions. Private, project-specific.

New project repos are created from the `template-gitops` template repository. State is stored in Azure Blob Storage.

CI: `terraform plan` on PR (posts plan as comment) → `terraform apply` on merge.

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

All Layer 3 workflows follow the same three-phase pipeline:

```
Gather (deterministic)          Decide (Claude API)              Execute (deterministic)
  Shell scripts collect    →    Schema-constrained tool use  →   Deterministic actions
  state via gh CLI/GraphQL      temperature=0, forced output     via gh CLI / GraphQL
```

- **Gather**: deterministic shell scripts that collect JSON state from GitHub API. No AI cost.
- **Decide**: Claude API call with gathered state. Output constrained to a strict JSON schema via tool use. `temperature=0` for near-deterministic results.
- **Execute**: parse Claude's structured output into deterministic actions. No free-form text drives actions.

Each workflow extends this pattern differently — drift-detect uses Claude API for both Decide and Execute, while the engineering agent uses Claude API for Decide and Claude Code CLI for Execute.

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
| `drift-detect` | Weekly + manual | Compares project repos against conventions, creates compliance issues |
| `engineering-agent` | Manual (crawl phase) | Picks compliance issues from board, implements fixes, creates PRs |
| `review-agent` | Weekdays + manual | Reviews AI-generated PRs, posts structured reviews |

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

Issues are created as `nsalab-librarian[bot]` (GitHub App) with `compliance` label. Dedup via HTML markers prevents duplicates across runs.

**Awareness filtering** — before creating an issue, drift-detect checks the compliance state of each repo:

| Check | Action |
|---|---|
| Open issue with same marker exists | Skip (duplicate) |
| Existing issue has `needs-triage` label | Suppress (agent triaged as not-workable) |
| Existing issue has an open PR | Suppress (fix in progress) |
| Closed issue with same marker, completed within 30 days | Suppress (recently fixed) |
| None of the above | Create issue + add to project board |

New issues are automatically added to the project board with Backlog status (compensates for GitHub's suppression of `issues.opened` events from App tokens).

### Engineering agent

Picks issues from the project board backlog and implements them autonomously. Three-stage pipeline:

```
 GATHER (free)              DECIDE (cheap)              EXECUTE (capable)
 Deterministic scripts      Claude API, Sonnet          Claude Code CLI
 harvest Layer 2 signals    temperature=0, schema       full tool access
                            constrained
 ┌──────────────────┐      ┌──────────────────┐       ┌──────────────────┐
 │ Project board     │      │ Verify problem    │       │ Starts with a    │
 │ Issue + comments  │─────>│ still exists      │──────>│ focused brief    │
 │ Pinned issue      │      │ Assess workability│       │ instead of raw   │
 │ Repo docs + tree  │      │ Compile ~3K brief │       │ docs — goes      │
 │ KB conventions    │      │ from ~20K raw     │       │ straight to      │
 │ Recent PRs        │      │ context           │       │ coding           │
 └──────────────────┘      └──────────────────┘       └──────────────────┘
```

**Issue selection**: Priority > Size > Type > Age (deterministic, no AI). Only issues on the project board with `compliance` label (crawl phase). Paginates through all board items.

**State machine** — board columns: Backlog → Blocked → In progress → In review → Done

| Event | Transition | Signal |
|---|---|---|
| Agent picks issue | Backlog → In progress | Assigns `nsalab-mechanic[bot]` |
| Agent creates PR | In progress → In review | Layer 1 (PR linked to issue) |
| Agent finds non-PR issue | In progress → Blocked | `needs-triage` label |
| Agent verifies already fixed | — | Closes issue with evidence |
| Agent fails 3 times | In progress → Backlog | `needs-triage` label |
| Reviewer merges PR | In review → Done | Layer 1 (item closed) |

**Safety invariants**: agent never merges PRs (human review required), never pushes to main (feature branches only), concurrency group prevents parallel runs. See [version-control-only principle](#version-control-only-principle) below.

### Review agent

Reviews AI-generated PRs against their linked issues. Posts structured GitHub PR reviews.

```
 GATHER (free)              DECIDE (cheap)              EXECUTE (deterministic)
 PR diff + linked issue     Claude API, Sonnet          Post PR review via API
 CI status + conventions    temperature=0, schema       Update board if needed
                            constrained
 ┌──────────────────┐      ┌──────────────────┐       ┌──────────────────┐
 │ PR metadata+diff  │      │ Does diff solve   │       │ APPROVE          │
 │ Linked issue body │─────>│ the stated issue? │──────>│ REQUEST_CHANGES  │
 │ CI check results  │      │ Convention check  │       │ COMMENT          │
 │ KB conventions    │      │ Side effect check │       │ (escalate)       │
 └──────────────────┘      └──────────────────┘       └──────────────────┘
```

**PR selection**: board-driven, finds issues in "In review" status with open `ai-generated` PRs. Skips PRs with failing CI or max review attempts reached. Sorts by linked issue Priority > Age.

**Review decisions**:
- `approve` — changes address the issue, conventions followed, minimal and focused
- `request_changes` — blocking issues found (wrong fix, errors, convention violations)
- `comment` — low confidence, escalate to human judgment

**On REQUEST_CHANGES**: posts review feedback on the linked issue (for engineering agent context), directly updates board status to "In progress" (bot events don't trigger project-sync). Engineering agent picks it up on next run.

**Separate identities**: the review agent (`nsalab-beekeeper[bot]`) can properly APPROVE PRs created by the engineering agent (`nsalab-mechanic[bot]`) since they are different GitHub App identities.

**Max 3 review attempts** before escalating to human with `needs-triage` label.

### Feedback loop

All three Layer 3 workflows form a closed loop:

```
drift-detect              engineering-agent           review-agent
  finds drift ── creates ──> issue (Backlog)
                                  │
                             picks issue
                             implements fix
                                  │
                             PR created ──────────> reviews PR
                             (In review)                │
                                  │               ┌─ approve ──> human merges ──> Done
  recognizes fix                  │               │
  (suppresses)  <─────────────────┤               └─ request_changes
                                  │                       │
                                  └── picks up again <────┘
                                      (In progress)
```

**The full cycle**: drift-detect finds problems → engineering agent fixes them → review agent validates the fix → human merges. Drift-detect suppresses findings that already have open PRs or were recently fixed.

Issues that can't be fixed via PR (API operations, manual settings) are triaged to Blocked with `needs-triage` for human attention.

### Version-control-only principle

**Autonomous agents MUST NEVER make changes that cannot be version controlled.** Every agent action must produce an auditable, reviewable, revertable artifact — a commit, a PR, or an issue comment.

This means agents are explicitly forbidden from:
- Editing GitHub issue or PR bodies directly (not version controlled)
- Creating or modifying labels, milestones, or project board settings
- Changing repository settings (description, merge rules, branch protection)
- Calling `gh repo edit`, `gh label create`, or similar administrative commands
- Any GitHub API mutation that modifies state outside of git-tracked files

When an agent encounters an issue that requires these operations, it must flag the issue as `workable: false` with blocker type `needs_human_decision` and move it to Blocked with `needs-triage`. Humans perform non-version-controlled operations.

**Why this matters:**
- Version-controlled changes can be reviewed in PRs before taking effect
- If an agent makes a mistake, `git revert` fixes it
- The full history of what changed, when, and why is preserved in git
- Non-version-controlled changes (labels, settings, issue bodies) have no review gate, no revert mechanism, and limited audit trail

The only exceptions are operational side effects of the agent's workflow:
- Posting issue comments (append-only, used for attempt tracking)
- Updating project board status (state machine transitions)
- Assigning issues (concurrency signals)

These are operational metadata, not content changes, and are logged in the workflow run.

### Shared scripts

All Layer 3 workflows share a common library of scripts:

| Script | Purpose |
|---|---|
| `parse-config.sh` | Parse YAML agent config into key=value outputs |
| `resolve-kb.sh` | Look up knowledge base repo for a target repo |
| `set-board-status.sh` | Update issue status on the project board |
| `claim-issue.sh` | Assign bot + move to In Progress + post comment |
| `mark-needs-triage.sh` | Add needs-triage label + move to Blocked |
| `record-attempt.sh` | Post structured attempt tracking comment |
| `close-resolved.sh` | Close issue with evidence comment |
| `session-summary.sh` | Write step summary to workflow output |

Workflow-specific scripts follow the Gather → Decide → Execute pattern:

| Workflow | Gather | Decide | Execute |
|---|---|---|---|
| drift-detect | `gather-drift-state.sh`, `gather-compliance-state.sh` | `drift-detect.py` | inline (actions/github-script) |
| engineering-agent | `select-issue.sh`, `check-blocked.sh`, `gather-issue-context.sh` | `compile-brief.py` | Claude Code CLI |
| review-agent | `select-pr.sh`, `gather-pr-context.sh` | `review-pr.py` | `post-review.sh` |

### Maturation principle

Layer 3 is an R&D lab for Layer 2. When Claude makes the same recommendation repeatedly, formalize it as a deterministic workflow and push it down to Layer 2. Over time, Layer 2 grows and Layer 3 shrinks — that's the system maturing.

## Knowledge hierarchy

```
github-automation (org-wide)
  ├── Reusable workflows (Layer 2)
  ├── Drift detection (Layer 3)    ← finds problems
  ├── Engineering agent (Layer 3)  ← fixes problems
  ├── Review agent (Layer 3)       ← validates fixes
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
| Layer 3 drift detection (issue creation, board-add) | GitHub App token | `nsalab-librarian[bot]` |
| Layer 3 engineering agent (checkout, push, PR creation) | GitHub App token | `nsalab-mechanic[bot]` |
| Layer 3 review agent (post reviews, board updates) | GitHub App token | `nsalab-beekeeper[bot]` |
| Claude API calls (all Layer 3 Decide phases) | `ANTHROPIC_API_KEY` | N/A |
| Claude Code CLI (engineering-agent Execute) | `ANTHROPIC_API_KEY` | N/A |

Each Layer 3 workflow has its own GitHub App identity for clean audit trails and proper permission separation. The review agent (`nsalab-beekeeper`) can approve PRs created by the engineering agent (`nsalab-mechanic`) since they are different identities.

Secrets are org-level (shared across all repos):
- `LIBRARIAN_CLIENT_ID`, `LIBRARIAN_PRIVATE_KEY` — drift-detect (`nsalab-librarian`)
- `MECHANIC_CLIENT_ID`, `MECHANIC_PRIVATE_KEY` — engineering-agent (`nsalab-mechanic`)
- `BEEKEEPER_CLIENT_ID`, `BEEKEEPER_PRIVATE_KEY` — review-agent (`nsalab-beekeeper`)
- `APP_CLIENT_ID`, `APP_PRIVATE_KEY` — Layer 2 workflows (`nsalab-automation`)
- `ANTHROPIC_API_KEY` — Claude API (all Layer 3 workflows)

Repo-specific secrets remain per-repo (e.g., `SCAFFOLD_TOKEN` in github-automation).

### Bot event behavior

GitHub Actions workflows are NOT triggered by events created via App tokens (safety feature to prevent loops). The `issues.opened` event is suppressed for bot-created issues. Workaround: GitHub Projects automation fires `issues.typed` which some workflows catch.

## Cross-references

- [docs/adoption.md](adoption.md) — how to adopt workflows in your repo
- [docs/conventions.md](conventions.md) — workflow catalog and technical reference
- [Issue #7](https://github.com/nsalab-tmn/github-automation/issues/7) — Layer 3 architecture discussion
- [Issue #51](https://github.com/nsalab-tmn/github-automation/issues/51) — drift detection implementation and testing
- [Issue #112](https://github.com/nsalab-tmn/github-automation/issues/112) — engineering agent implementation and testing
- [Issue #130](https://github.com/nsalab-tmn/github-automation/issues/130) — drift-detect awareness improvements
- [Issue #135](https://github.com/nsalab-tmn/github-automation/issues/135) — review agent implementation
- [Issue #138](https://github.com/nsalab-tmn/github-automation/issues/138) — separate bot identities
