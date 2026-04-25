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

  # Helper: run gh api, validate output is valid JSON array/object, fallback otherwise
  # Usage: safe_api <fallback> <gh api args...>
  safe_api() {
    local fallback="$1"; shift
    local result
    if ! result=$(gh api "$@" 2>/dev/null); then
      echo "${fallback}"; return
    fi
    # Reject GitHub error responses (contain "message" key)
    if echo "${result}" | jq -e 'type == "object" and has("message")' >/dev/null 2>&1; then
      echo "${fallback}"; return
    fi
    echo "${result}"
  }

  # File tree
  local file_tree
  file_tree=$(safe_api "[]" "repos/${repo}/git/trees/main?recursive=1" --jq '[.tree[] | select(.type=="blob") | .path]')

  # Workflow files content
  local workflows="{}"
  for wf in housekeeping.yaml stale-check.yaml pinned-sync.yaml; do
    local wf_raw wf_content
    wf_raw=$(safe_api "" "repos/${repo}/contents/.github/workflows/${wf}" --jq '.content')
    if [[ -n "${wf_raw}" ]]; then
      wf_content=$(echo "${wf_raw}" | base64 -d 2>/dev/null || true)
      if [[ -n "${wf_content}" ]]; then
        workflows=$(echo "${workflows}" | jq --arg k "${wf}" --arg v "${wf_content}" '. + {($k): $v}')
      fi
    fi
  done

  # Documentation files content
  local docs="{}"
  for doc in README.md CONTRIBUTING.md docs/conventions.md; do
    local doc_raw doc_content
    doc_raw=$(safe_api "" "repos/${repo}/contents/${doc}" --jq '.content')
    if [[ -n "${doc_raw}" ]]; then
      doc_content=$(echo "${doc_raw}" | base64 -d 2>/dev/null || true)
      if [[ -n "${doc_content}" ]]; then
        docs=$(echo "${docs}" | jq --arg k "${doc}" --arg v "${doc_content}" '. + {($k): $v}')
      fi
    fi
  done

  # Issue templates
  local issue_templates
  issue_templates=$(safe_api "[]" "repos/${repo}/contents/.github/ISSUE_TEMPLATE" --jq '[.[].name]')

  # PR template existence
  local pr_template="false"
  local pr_check
  pr_check=$(safe_api "" "repos/${repo}/contents/.github/pull_request_template.md" --jq '.name')
  if [[ -n "${pr_check}" ]]; then
    pr_template="true"
  fi

  # Labels
  local labels
  labels=$(gh label list --repo "${repo}" --json name --jq '[.[].name]' 2>/dev/null || echo "[]")

  # Repo settings
  local settings
  settings=$(safe_api "{}" "repos/${repo}" --jq '{
    description,
    private: .private,
    default_branch: .default_branch,
    delete_branch_on_merge,
    allow_squash_merge,
    allow_merge_commit,
    allow_rebase_merge
  }')

  # SOPS config (existence only)
  local sops_exists="false"
  local sops_check
  sops_check=$(safe_api "" "repos/${repo}/contents/.sops.yaml" --jq '.name')
  if [[ -n "${sops_check}" ]]; then
    sops_exists="true"
  fi

  # Top-level directories (for label-config coverage analysis)
  local top_dirs
  top_dirs=$(echo "${file_tree}" | jq '[.[] | split("/")[0]] | unique | map(select(contains(".") | not))' 2>/dev/null || echo "[]")

  # Pinned issue
  local pinned_issue='{"exists": false, "has_auto_markers": false}'
  local pinned_body
  pinned_body=$(safe_api "" "repos/${repo}/issues?labels=pinned&state=open&per_page=1" --jq '.[0].body // ""')
  if [[ -n "${pinned_body}" && "${pinned_body}" != '""' ]]; then
    local has_markers="false"
    if echo "${pinned_body}" | grep -q "auto:checklist" && \
       echo "${pinned_body}" | grep -q "auto:remaining" && \
       echo "${pinned_body}" | grep -q "auto:completed"; then
      has_markers="true"
    fi
    pinned_issue="{\"exists\": true, \"has_auto_markers\": ${has_markers}}"
  fi

  # Branch protection (public repos only — private repos return 403)
  local branch_protection='{"enabled": false}'
  local bp_data
  bp_data=$(safe_api "" "repos/${repo}/branches/main/protection" --jq '{
    enabled: true,
    required_status_checks: (.required_status_checks.contexts // []),
    enforce_admins: .enforce_admins.enabled,
    allow_force_pushes: .allow_force_pushes.enabled
  }')
  if [[ -n "${bp_data}" ]]; then
    branch_protection="${bp_data}"
  fi

  # Build repo state object
  jq -n \
    --arg repo "${repo}" \
    --argjson files "${file_tree}" \
    --argjson top_dirs "${top_dirs}" \
    --argjson workflows "${workflows}" \
    --argjson docs "${docs}" \
    --argjson issue_templates "${issue_templates}" \
    --arg pr_template "${pr_template}" \
    --argjson labels "${labels}" \
    --argjson settings "${settings}" \
    --arg sops_exists "${sops_exists}" \
    --argjson pinned_issue "${pinned_issue}" \
    --argjson branch_protection "${branch_protection}" \
    '{
      repo: $repo,
      files: $files,
      top_level_dirs: $top_dirs,
      workflows: $workflows,
      docs: $docs,
      issue_templates: $issue_templates,
      pr_template: ($pr_template == "true"),
      labels: $labels,
      settings: $settings,
      has_sops: ($sops_exists == "true"),
      pinned_issue: $pinned_issue,
      branch_protection: $branch_protection
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
