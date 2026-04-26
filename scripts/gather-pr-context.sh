#!/usr/bin/env bash
set -euo pipefail

# gather-pr-context.sh — Collect context for reviewing a PR
#
# Gathers PR diff, linked issue, CI status, conventions, and repo docs.
#
# Required environment variables:
#   GH_TOKEN        — token with cross-repo access
#   PR_REPO         — full repo name (owner/name)
#   PR_NUMBER       — PR number
#   KB_REPO         — knowledge base repo (owner/name)
#   KB_CONV_PATH    — conventions path in KB repo
#
# Output: JSON context envelope to stdout

PR_REPO="${PR_REPO:?PR_REPO env var required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER env var required}"
KB_REPO="${KB_REPO:?KB_REPO env var required}"
KB_CONV_PATH="${KB_CONV_PATH:?KB_CONV_PATH env var required}"

OWNER="${PR_REPO%%/*}"
REPO_NAME="${PR_REPO##*/}"

echo "::notice::Gathering context for PR #${PR_NUMBER} in ${PR_REPO}" >&2

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

fetch_file() {
  local repo="$1" path="$2"
  local content
  content=$(safe_api "" "repos/${repo}/contents/${path}" --jq '.content')
  if [[ -n "$content" ]]; then
    echo "$content" | base64 -d 2>/dev/null || true
  fi
}

# --- PR metadata ---
echo "::notice::  Fetching PR metadata" >&2
PR_META=$(safe_api "{}" "repos/${PR_REPO}/pulls/${PR_NUMBER}" --jq '{
  number, title, body, state,
  head_sha: .head.sha,
  head_ref: .head.ref,
  base_ref: .base.ref,
  user: .user.login,
  labels: [.labels[].name],
  created_at: .created_at,
  updated_at: .updated_at
}')

# --- PR diff ---
echo "::notice::  Fetching PR diff" >&2
PR_DIFF_FILE=$(mktemp)
gh api "repos/${PR_REPO}/pulls/${PR_NUMBER}" \
  -H "Accept: application/vnd.github.diff" \
  > "$PR_DIFF_FILE" 2>/dev/null || echo "" > "$PR_DIFF_FILE"
PR_DIFF=$(cat "$PR_DIFF_FILE")
rm -f "$PR_DIFF_FILE"

# Extract HEAD SHA early for CI readiness polling
HEAD_SHA=$(echo "$PR_META" | jq -r '.head_sha // empty')

# --- CI readiness poll: Phase 1 — wait for checks to appear (max 30s) ---
if [[ -n "${HEAD_SHA}" && "${HEAD_SHA}" != "null" ]]; then
  echo "::notice::  Waiting for CI checks to appear for SHA ${HEAD_SHA:0:7}..." >&2
  _elapsed=0
  _check_count=0
  for _i in 1 2 3 4 5 6; do
    _check_count=$(safe_api "0" "repos/${PR_REPO}/commits/${HEAD_SHA}/check-runs" \
      --jq '.check_runs | length')
    echo "::notice::    [CI poll 1/2] elapsed=${_elapsed}s checks_found=${_check_count}" >&2
    if [[ "${_check_count}" -gt 0 ]]; then
      echo "::notice::  CI checks appeared (${_check_count} check(s) found)" >&2
      break
    fi
    if [[ "${_i}" -lt 6 ]]; then
      sleep 5
      _elapsed=$(( _elapsed + 5 ))
    fi
  done
  if [[ "${_check_count}" -eq 0 ]]; then
    echo "::warning::  No CI checks appeared within 30s — proceeding with unknown CI status" >&2
  else
    # --- CI readiness poll: Phase 2 — wait for all checks to complete (max 150s) ---
    echo "::notice::  Waiting for all CI checks to complete..." >&2
    _elapsed=0
    _pending="${_check_count}"
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      _total=$(safe_api "0" "repos/${PR_REPO}/commits/${HEAD_SHA}/check-runs" \
        --jq '.check_runs | length')
      _pending=$(safe_api "1" "repos/${PR_REPO}/commits/${HEAD_SHA}/check-runs" \
        --jq '[.check_runs[] | select(.status != "completed")] | length')
      echo "::notice::    [CI poll 2/2] elapsed=${_elapsed}s pending=${_pending}/${_total}" >&2
      if [[ "${_pending}" -eq 0 ]]; then
        echo "::notice::  All ${_total} CI check(s) completed" >&2
        break
      fi
      if [[ "${_i}" -lt 10 ]]; then
        sleep 15
        _elapsed=$(( _elapsed + 15 ))
      fi
    done
    if [[ "${_pending}" -gt 0 ]]; then
      echo "::warning::  CI checks did not all complete within 150s — proceeding with partial CI status" >&2
    fi
  fi
fi

# --- CI check status ---
echo "::notice::  Fetching CI status" >&2
HEAD_SHA=$(echo "$PR_META" | jq -r '.head_sha')
CI_STATUS="unknown"
CI_CHECKS="[]"
if [[ -n "$HEAD_SHA" && "$HEAD_SHA" != "null" ]]; then
  CI_STATUS=$(safe_api "unknown" "repos/${PR_REPO}/commits/${HEAD_SHA}/status" --jq '.state')
  CI_CHECKS=$(safe_api "[]" "repos/${PR_REPO}/commits/${HEAD_SHA}/check-runs" \
    --jq '[.check_runs[] | {name, status, conclusion}]')
fi

# --- Linked issue ---
echo "::notice::  Fetching linked issue" >&2
PR_BODY=$(echo "$PR_META" | jq -r '.body // ""')
ISSUE_NUM=$(echo "$PR_BODY" | grep -oP '(?i)closes\s+#\K\d+|fixes\s+#\K\d+|resolves\s+#\K\d+' | head -1 || echo "")

LINKED_ISSUE="{}"
ISSUE_COMMENTS="[]"
if [[ -n "$ISSUE_NUM" ]]; then
  LINKED_ISSUE=$(safe_api "{}" "repos/${PR_REPO}/issues/${ISSUE_NUM}" --jq '{
    number, title, body, state,
    labels: [.labels[].name],
    created_at: .created_at
  }')
  ISSUE_COMMENTS=$(safe_api "[]" "repos/${PR_REPO}/issues/${ISSUE_NUM}/comments" \
    --jq '[.[] | {author: .user.login, body, created_at: .created_at}]')
fi

# --- PR reviews (previous review-agent reviews) ---
echo "::notice::  Fetching PR reviews" >&2
PR_REVIEWS=$(safe_api "[]" "repos/${PR_REPO}/pulls/${PR_NUMBER}/reviews" \
  --jq '[.[] | {author: .user.login, state, body, submitted_at: .submitted_at}]')

# --- Repo docs ---
echo "::notice::  Fetching repo docs" >&2
README=$(fetch_file "$PR_REPO" "README.md")
CONTRIBUTING=$(fetch_file "$PR_REPO" "CONTRIBUTING.md")
CONVENTIONS=$(fetch_file "$PR_REPO" "docs/conventions.md")

# --- KB conventions ---
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

echo "::notice::Context gathered" >&2

# Build output
jq -n \
  --arg repo "$PR_REPO" \
  --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson pr "$PR_META" \
  --arg diff "$PR_DIFF" \
  --arg ci_status "$CI_STATUS" \
  --argjson ci_checks "$CI_CHECKS" \
  --argjson linked_issue "$LINKED_ISSUE" \
  --argjson issue_comments "$ISSUE_COMMENTS" \
  --argjson pr_reviews "$PR_REVIEWS" \
  --arg readme "$README" \
  --arg contributing "$CONTRIBUTING" \
  --arg conventions "$CONVENTIONS" \
  --argjson kb_conventions "$KB_CONVENTIONS" \
  '{
    repo: $repo,
    collected_at: $collected_at,
    pr: $pr,
    diff: $diff,
    ci_status: $ci_status,
    ci_checks: $ci_checks,
    linked_issue: $linked_issue,
    issue_comments: $issue_comments,
    pr_reviews: $pr_reviews,
    repo_docs: {
      readme: $readme,
      contributing: $contributing,
      conventions: $conventions
    },
    kb_conventions: $kb_conventions
  }'
