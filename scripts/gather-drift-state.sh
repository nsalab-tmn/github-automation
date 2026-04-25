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

  # Documentation compliance signals (targeted checks, not full content)
  local has_template_markers="false"
  local links_to_kb="false"
  local has_project_name="false"
  local doc_files_with_markers="[]"

  # Derive expected KB repo from project config
  local expected_kb
  expected_kb=$(echo "${PROJECT_CONFIG}" | jq -r '.["knowledge-base"] // ""')

  for doc in README.md CONTRIBUTING.md docs/conventions.md; do
    local doc_raw doc_content
    doc_raw=$(safe_api "" "repos/${repo}/contents/${doc}" --jq '.content')
    if [[ -n "${doc_raw}" ]]; then
      doc_content=$(echo "${doc_raw}" | base64 -d 2>/dev/null || true)
      if [[ -n "${doc_content}" ]]; then
        # Check for template/agent markers
        if echo "${doc_content}" | grep -qE '<!-- (TEMPLATE|AGENT):'; then
          has_template_markers="true"
          doc_files_with_markers=$(echo "${doc_files_with_markers}" | jq --arg f "${doc}" '. + [$f]')
        fi
        # Check for knowledge base link
        if [[ -n "${expected_kb}" ]] && echo "${doc_content}" | grep -q "${expected_kb}"; then
          links_to_kb="true"
        fi
        # Check if README has a project-specific name (not just generic "Project")
        if [[ "${doc}" == "README.md" ]]; then
          local first_heading
          first_heading=$(echo "${doc_content}" | head -5 | grep -oP '^#\s+\K.*' || echo "")
          if [[ -n "${first_heading}" ]] && ! echo "${first_heading}" | grep -qiE '^project (gitops|repository|repo)$'; then
            has_project_name="true"
          fi
        fi
      fi
    fi
  done

  local docs
  docs=$(jq -n \
    --arg has_template_markers "${has_template_markers}" \
    --arg links_to_kb "${links_to_kb}" \
    --arg has_project_name "${has_project_name}" \
    --argjson files_with_markers "${doc_files_with_markers}" \
    '{
      has_template_markers: ($has_template_markers == "true"),
      links_to_kb: ($links_to_kb == "true"),
      has_project_name: ($has_project_name == "true"),
      files_with_markers: $files_with_markers
    }')

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

  # Build repo state object using temp files to avoid arg-too-long
  local repo_tmp
  repo_tmp=$(mktemp -d)

  echo "${file_tree}" > "${repo_tmp}/files.json"
  echo "${top_dirs}" > "${repo_tmp}/top_dirs.json"
  echo "${workflows}" > "${repo_tmp}/workflows.json"
  echo "${docs}" > "${repo_tmp}/docs.json"
  echo "${issue_templates}" > "${repo_tmp}/issue_templates.json"
  echo "${labels}" > "${repo_tmp}/labels.json"
  echo "${settings}" > "${repo_tmp}/settings.json"
  echo "${pinned_issue}" > "${repo_tmp}/pinned_issue.json"
  echo "${branch_protection}" > "${repo_tmp}/branch_protection.json"

  jq -n \
    --arg repo "${repo}" \
    --slurpfile files "${repo_tmp}/files.json" \
    --slurpfile top_dirs "${repo_tmp}/top_dirs.json" \
    --slurpfile workflows "${repo_tmp}/workflows.json" \
    --slurpfile docs "${repo_tmp}/docs.json" \
    --slurpfile issue_templates "${repo_tmp}/issue_templates.json" \
    --arg pr_template "${pr_template}" \
    --slurpfile labels "${repo_tmp}/labels.json" \
    --slurpfile settings "${repo_tmp}/settings.json" \
    --arg sops_exists "${sops_exists}" \
    --slurpfile pinned_issue "${repo_tmp}/pinned_issue.json" \
    --slurpfile branch_protection "${repo_tmp}/branch_protection.json" \
    '{
      repo: $repo,
      files: $files[0],
      top_level_dirs: $top_dirs[0],
      workflows: $workflows[0],
      docs: $docs[0],
      issue_templates: $issue_templates[0],
      pr_template: ($pr_template == "true"),
      labels: $labels[0],
      settings: $settings[0],
      has_sops: ($sops_exists == "true"),
      pinned_issue: $pinned_issue[0],
      branch_protection: $branch_protection[0]
    }'

  rm -rf "${repo_tmp}"
}

# --- Main ---

echo "::notice::Collecting conventions from ${KB_REPO}" >&2
CONVENTIONS=$(collect_conventions "${KB_REPO}" "${CONVENTIONS_PATH}")

echo "::notice::Collecting adoption guide" >&2
ADOPTION=$(collect_adoption_guide)

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

echo "[]" > "${TMPDIR}/repos.json"
REPO_COUNT=0
for repo in ${REPOS}; do
  echo "::notice::Collecting state from ${repo}" >&2
  collect_repo_state "${repo}" > "${TMPDIR}/repo-state.json"
  jq --slurpfile s "${TMPDIR}/repo-state.json" '. + $s' "${TMPDIR}/repos.json" > "${TMPDIR}/repos.tmp" && mv "${TMPDIR}/repos.tmp" "${TMPDIR}/repos.json"
  REPO_COUNT=$((REPO_COUNT + 1))
done

echo "::notice::Gathered state from ${REPO_COUNT} repos" >&2

# Write conventions and adoption guide to temp files
echo "${CONVENTIONS}" > "${TMPDIR}/conventions.json"
echo "${ADOPTION}" > "${TMPDIR}/adoption.txt"

# Build final output using files instead of shell arguments
jq -n \
  --arg project "${PROJECT_NAME}" \
  --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile conventions "${TMPDIR}/conventions.json" \
  --rawfile adoption_guide "${TMPDIR}/adoption.txt" \
  --slurpfile repos "${TMPDIR}/repos.json" \
  '{
    project: $project,
    collected_at: $collected_at,
    conventions: $conventions[0],
    adoption_guide: $adoption_guide,
    repos: $repos[0]
  }'
