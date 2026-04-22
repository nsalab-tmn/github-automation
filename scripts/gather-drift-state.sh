#!/usr/bin/env bash
set -euo pipefail

# gather-drift-state.sh — Collect state from all project repos + conventions
#
# Required environment variables:
#   PROJECT_CONFIG — path to project entry as JSON (from drift-projects.yaml)
#   GH_TOKEN       — token with cross-repo read access
#
# Output: JSON to stdout

PROJECT_CONFIG="${PROJECT_CONFIG:?PROJECT_CONFIG env var required}"
ADOPTION_GUIDE="${ADOPTION_GUIDE:-docs/adoption.md}"

PROJECT_NAME=$(echo "${PROJECT_CONFIG}" | jq -r '.name')
KB_REPO=$(echo "${PROJECT_CONFIG}" | jq -r '.["knowledge-base"]')
CONVENTIONS_PATH=$(echo "${PROJECT_CONFIG}" | jq -r '.["conventions-path"]')
REPOS=$(echo "${PROJECT_CONFIG}" | jq -r '.repos[]')

# --- Collect conventions from knowledge base ---

collect_conventions() {
  local kb_repo="$1"
  local conv_path="$2"

  # List convention files
  local files
  files=$(gh api "repos/${kb_repo}/contents/${conv_path}" --jq '.[].name' 2>/dev/null || echo "")

  local conventions="{}"
  for file in ${files}; do
    if [[ "${file}" == *.md ]]; then
      local content
      content=$(gh api "repos/${kb_repo}/contents/${conv_path}/${file}" --jq '.content' 2>/dev/null | base64 -d || echo "")
      if [[ -n "${content}" ]]; then
        conventions=$(echo "${conventions}" | jq --arg k "${file}" --arg v "${content}" '. + {($k): $v}')
      fi
    fi
  done

  echo "${conventions}"
}

# --- Collect adoption guide ---

collect_adoption_guide() {
  local content
  content=$(cat "${ADOPTION_GUIDE}" 2>/dev/null || echo "")
  echo "${content}"
}

# --- Collect state from a single repo ---

collect_repo_state() {
  local repo="$1"

  # File tree (top-level + key subdirectories)
  local file_tree
  file_tree=$(gh api "repos/${repo}/git/trees/main?recursive=1" --jq '[.tree[] | select(.type=="blob") | .path]' 2>/dev/null || echo "[]")

  # Workflow files content
  local workflows="{}"
  for wf in housekeeping.yaml stale-check.yaml pinned-sync.yaml; do
    local wf_content
    wf_content=$(gh api "repos/${repo}/contents/.github/workflows/${wf}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [[ -n "${wf_content}" ]]; then
      workflows=$(echo "${workflows}" | jq --arg k "${wf}" --arg v "${wf_content}" '. + {($k): $v}')
    fi
  done

  # Issue templates
  local issue_templates
  issue_templates=$(gh api "repos/${repo}/contents/.github/ISSUE_TEMPLATE" --jq '[.[].name]' 2>/dev/null || echo "[]")

  # PR template existence
  local pr_template
  pr_template=$(gh api "repos/${repo}/contents/.github/pull_request_template.md" --jq '.name' 2>/dev/null && echo "true" || echo "false")

  # Labels
  local labels
  labels=$(gh label list --repo "${repo}" --json name --jq '[.[].name]' 2>/dev/null || echo "[]")

  # Repo settings
  local settings
  settings=$(gh api "repos/${repo}" --jq '{
    description,
    private: .private,
    default_branch: .default_branch,
    delete_branch_on_merge,
    allow_squash_merge,
    allow_merge_commit,
    allow_rebase_merge
  }' 2>/dev/null || echo "{}")

  # SOPS config (existence only — don't expose key material)
  local sops_exists
  sops_exists=$(gh api "repos/${repo}/contents/.sops.yaml" --jq '.name' 2>/dev/null && echo "true" || echo "false")

  # Build repo state object
  jq -n \
    --arg repo "${repo}" \
    --argjson files "${file_tree}" \
    --argjson workflows "${workflows}" \
    --argjson issue_templates "${issue_templates}" \
    --arg pr_template "${pr_template}" \
    --argjson labels "${labels}" \
    --argjson settings "${settings}" \
    --arg sops_exists "${sops_exists}" \
    '{
      repo: $repo,
      files: $files,
      workflows: $workflows,
      issue_templates: $issue_templates,
      pr_template: ($pr_template == "true"),
      labels: $labels,
      settings: $settings,
      has_sops: ($sops_exists == "true")
    }'
}

# --- Main ---

echo "::notice::Collecting conventions from ${KB_REPO}" >&2
CONVENTIONS=$(collect_conventions "${KB_REPO}" "${CONVENTIONS_PATH}")

echo "::notice::Collecting adoption guide" >&2
ADOPTION=$(collect_adoption_guide)

REPO_STATES="[]"
REPO_COUNT=0
for repo in ${REPOS}; do
  echo "::notice::Collecting state from ${repo}" >&2
  state=$(collect_repo_state "${repo}")
  REPO_STATES=$(echo "${REPO_STATES}" | jq --argjson s "${state}" '. + [$s]')
  REPO_COUNT=$((REPO_COUNT + 1))
done

echo "::notice::Gathered state from ${REPO_COUNT} repos" >&2

# Build final output
jq -n \
  --arg project "${PROJECT_NAME}" \
  --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson conventions "${CONVENTIONS}" \
  --arg adoption_guide "${ADOPTION}" \
  --argjson repos "${REPO_STATES}" \
  '{
    project: $project,
    collected_at: $collected_at,
    conventions: $conventions,
    adoption_guide: $adoption_guide,
    repos: $repos
  }'
