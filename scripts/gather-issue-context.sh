#!/usr/bin/env bash
set -euo pipefail

# gather-issue-context.sh — Collect Tier 1+2 context for a selected issue
#
# Required environment variables:
#   GH_TOKEN        — token with cross-repo read access
#   ISSUE_REPO      — full repo name (owner/name)
#   ISSUE_NUMBER    — issue number
#   KB_REPO         — knowledge base repo (owner/name)
#   KB_CONV_PATH    — conventions path in KB repo
#
# Output: JSON context envelope to stdout

ISSUE_REPO="${ISSUE_REPO:?ISSUE_REPO env var required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER env var required}"
KB_REPO="${KB_REPO:?KB_REPO env var required}"
KB_CONV_PATH="${KB_CONV_PATH:?KB_CONV_PATH env var required}"

# Helper: run gh api with error fallback (reused from gather-drift-state.sh)
safe_api() {
  local fallback="$1"; shift
  local result
  if ! result=$(gh api "$@" 2>/dev/null); then
    echo "${fallback}"; return
  fi
  if echo "${result}" | jq -e 'type == "object" and has("message")' >/dev/null 2>&1; then
    echo "${fallback}"; return
  fi
  echo "${result}"
}

echo "::notice::Gathering context for #${ISSUE_NUMBER} in ${ISSUE_REPO}" >&2

# --- Tier 1: Always load ---

# Issue details + comments
echo "::notice::  Fetching issue details" >&2
ISSUE=$(safe_api "{}" "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}" --jq '{
  number, title, body, state, created_at: .created_at,
  labels: [.labels[].name],
  assignees: [.assignees[].login]
}')

echo "::notice::  Fetching issue comments" >&2
COMMENTS=$(safe_api "[]" "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
  --jq '[.[] | {author: .user.login, body, created_at: .created_at}]')

# Pinned issue
echo "::notice::  Fetching pinned issue" >&2
PINNED_BODY=$(safe_api "" "repos/${ISSUE_REPO}/issues?labels=pinned&state=open&per_page=1" \
  --jq '.[0].body // ""')

# Repo docs — README, CONTRIBUTING, docs/conventions.md
echo "::notice::  Fetching repo docs (README, CONTRIBUTING, conventions)" >&2

fetch_file() {
  local repo="$1" path="$2"
  local content
  content=$(safe_api "" "repos/${repo}/contents/${path}" --jq '.content')
  if [[ -n "$content" ]]; then
    echo "$content" | base64 -d 2>/dev/null || true
  fi
}

README=$(fetch_file "$ISSUE_REPO" "README.md")
CONTRIBUTING=$(fetch_file "$ISSUE_REPO" "CONTRIBUTING.md")
CONVENTIONS=$(fetch_file "$ISSUE_REPO" "docs/conventions.md")

# File tree (paths only)
echo "::notice::  Fetching file tree" >&2
FILE_TREE=$(safe_api "[]" "repos/${ISSUE_REPO}/git/trees/main?recursive=1" \
  --jq '[.tree[] | select(.type=="blob") | .path]')

# --- Tier 2: Issue-specific context ---

# Knowledge base conventions (load all — small enough, Decide phase filters)
echo "::notice::  Fetching KB conventions from ${KB_REPO}" >&2
KB_FILES=$(gh api "repos/${KB_REPO}/contents/${KB_CONV_PATH}" --jq '.[].name' 2>/dev/null || echo "")

KB_CONVENTIONS="{}"
for file in ${KB_FILES}; do
  if [[ "${file}" == *.md ]]; then
    content=$(fetch_file "$KB_REPO" "${KB_CONV_PATH}/${file}")
    if [[ -n "$content" ]]; then
      KB_CONVENTIONS=$(echo "$KB_CONVENTIONS" | jq --arg k "$file" --arg v "$content" '. + {($k): $v}')
    fi
  fi
done

# Recent merged PRs (titles + labels, for pattern reference)
echo "::notice::  Fetching recent merged PRs" >&2
RECENT_PRS=$(gh pr list --repo "$ISSUE_REPO" --state merged --limit 5 \
  --json number,title,labels,mergedAt \
  --jq '[.[] | {number, title, labels: [.labels[].name], merged_at: .mergedAt}]' 2>/dev/null || echo "[]")

# Recent commits (for commit message style)
echo "::notice::  Fetching recent commits" >&2
RECENT_COMMITS=$(safe_api "[]" "repos/${ISSUE_REPO}/commits?per_page=10" \
  --jq '[.[] | {sha: .sha[0:7], message: .commit.message | split("\n")[0]}]')

# Referenced issues (parse #N from issue body)
echo "::notice::  Checking referenced issues" >&2
REFERENCED_ISSUES="[]"
REFS=$(echo "$ISSUE" | jq -r '.body // ""' | grep -oP '#\d+' | sort -u | head -5 || true)
for ref in $REFS; do
  ref_num="${ref#\#}"
  # Skip self-reference
  if [[ "$ref_num" == "$ISSUE_NUMBER" ]]; then continue; fi
  ref_data=$(safe_api "" "repos/${ISSUE_REPO}/issues/${ref_num}" \
    --jq '{number, title, state, labels: [.labels[].name]}')
  if [[ -n "$ref_data" ]]; then
    REFERENCED_ISSUES=$(echo "$REFERENCED_ISSUES" | jq --argjson r "$ref_data" '. + [$r]')
  fi
done

echo "::notice::Context gathered" >&2

# Build final output
jq -n \
  --arg repo "$ISSUE_REPO" \
  --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson issue "$ISSUE" \
  --argjson comments "$COMMENTS" \
  --arg pinned_issue "$PINNED_BODY" \
  --arg readme "$README" \
  --arg contributing "$CONTRIBUTING" \
  --arg conventions "$CONVENTIONS" \
  --argjson file_tree "$FILE_TREE" \
  --argjson kb_conventions "$KB_CONVENTIONS" \
  --argjson recent_prs "$RECENT_PRS" \
  --argjson recent_commits "$RECENT_COMMITS" \
  --argjson referenced_issues "$REFERENCED_ISSUES" \
  '{
    repo: $repo,
    collected_at: $collected_at,
    issue: $issue,
    comments: $comments,
    pinned_issue: $pinned_issue,
    repo_docs: {
      readme: $readme,
      contributing: $contributing,
      conventions: $conventions
    },
    file_tree: $file_tree,
    kb_conventions: $kb_conventions,
    recent_prs: $recent_prs,
    recent_commits: $recent_commits,
    referenced_issues: $referenced_issues
  }'
