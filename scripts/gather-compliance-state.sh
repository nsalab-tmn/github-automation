#!/usr/bin/env bash
set -euo pipefail

# gather-compliance-state.sh — Collect compliance issue/PR/board state for a repo
#
# Used by drift-detect Execute phase to make suppression decisions.
# Collects open compliance issues, recently closed ones, open PRs, and board status.
#
# Required environment variables:
#   GH_TOKEN        — token with cross-repo access
#   REPO            — full repo name (owner/name)
#   PROJECT_NUMBER  — GitHub Projects V2 project number
#   ORG             — GitHub organization name
#
# Output: JSON to stdout

REPO="${REPO:?REPO env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
ORG="${ORG:?ORG env var required}"
SUPPRESSION_DAYS="${SUPPRESSION_DAYS:-30}"

echo "::notice::  Gathering compliance state for ${REPO}" >&2

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

# Helper: safe API call with fallback (reused pattern from gather-drift-state.sh)
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

# --- Open compliance issues ---

OPEN_ISSUES=$(safe_api "[]" "repos/${REPO}/issues?labels=compliance&state=open&per_page=100" \
  --jq '[.[] | {
    number,
    title,
    body,
    labels: [.labels[].name],
    assignees: [.assignees[].login],
    node_id: .node_id
  }]')

# Extract markers, check PRs, count agent attempts for each open issue
OPEN_WITH_STATE="[]"
for i in $(echo "$OPEN_ISSUES" | jq -r 'range(length)'); do
  ISSUE=$(echo "$OPEN_ISSUES" | jq ".[$i]")
  NUM=$(echo "$ISSUE" | jq -r '.number')
  BODY=$(echo "$ISSUE" | jq -r '.body // ""')
  NODE_ID=$(echo "$ISSUE" | jq -r '.node_id')

  # Extract drift marker
  MARKER=$(echo "$BODY" | grep -oP '<!-- drift:\K[^>]+(?= -->)' | head -1 || echo "")

  # Check for open PRs referencing this issue
  HAS_OPEN_PR="false"
  OPEN_PR_COUNT=$(gh pr list --repo "$REPO" --state open --search "closes #${NUM}" --json number --jq 'length' 2>/dev/null || echo "0")
  if [[ "$OPEN_PR_COUNT" -gt 0 ]]; then
    HAS_OPEN_PR="true"
  fi

  # Count agent attempts (failed/blocked/not-workable only)
  AGENT_ATTEMPTS=$(safe_api "[]" "repos/${REPO}/issues/${NUM}/comments" \
    --jq '[.[] | select(.body | test("<!-- agent:attempt:")) | select(.body | test("\\*\\*Status:\\*\\* (failed|blocked|not-workable)"))] | length')

  # Get board status via GraphQL
  BOARD_STATUS=""
  if [[ -n "$NODE_ID" && "$NODE_ID" != "null" ]]; then
    BOARD_STATUS=$(gh api graphql -f query='
      query($issueId: ID!) {
        node(id: $issueId) {
          ... on Issue {
            projectItems(first: 10) {
              nodes {
                project { number }
                fieldValueByName(name: "Status") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
              }
            }
          }
        }
      }
    ' -f issueId="$NODE_ID" 2>/dev/null \
      | jq -r --argjson pn "$PROJECT_NUMBER" \
        '.data.node.projectItems.nodes[] | select(.project.number == $pn) | .fieldValueByName.name // ""' 2>/dev/null || echo "")
  fi

  ENRICHED=$(echo "$ISSUE" | jq \
    --arg marker "$MARKER" \
    --arg has_open_pr "$HAS_OPEN_PR" \
    --argjson agent_attempts "$AGENT_ATTEMPTS" \
    --arg board_status "$BOARD_STATUS" \
    '{
      number,
      marker: $marker,
      labels,
      has_open_pr: ($has_open_pr == "true"),
      agent_attempts: $agent_attempts,
      board_status: $board_status
    }')

  OPEN_WITH_STATE=$(echo "$OPEN_WITH_STATE" | jq --argjson e "$ENRICHED" '. + [$e]')
done

# --- Recently closed compliance issues ---

SINCE_DATE=$(date -u -d "-${SUPPRESSION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-${SUPPRESSION_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || echo "2026-03-01T00:00:00Z")

CLOSED_ISSUES=$(safe_api "[]" "repos/${REPO}/issues?labels=compliance&state=closed&since=${SINCE_DATE}&per_page=100" \
  --jq '[.[] | {
    number,
    body,
    closed_at,
    state_reason
  }]')

# Extract markers from closed issues
RECENTLY_CLOSED="[]"
for i in $(echo "$CLOSED_ISSUES" | jq -r 'range(length)'); do
  ISSUE=$(echo "$CLOSED_ISSUES" | jq ".[$i]")
  BODY=$(echo "$ISSUE" | jq -r '.body // ""')
  MARKER=$(echo "$BODY" | grep -oP '<!-- drift:\K[^>]+(?= -->)' | head -1 || echo "")

  if [[ -n "$MARKER" ]]; then
    ENTRY=$(echo "$ISSUE" | jq --arg marker "$MARKER" '{
      number,
      marker: $marker,
      closed_at,
      state_reason
    }')
    RECENTLY_CLOSED=$(echo "$RECENTLY_CLOSED" | jq --argjson e "$ENTRY" '. + [$e]')
  fi
done

OPEN_COUNT=$(echo "$OPEN_WITH_STATE" | jq 'length')
CLOSED_COUNT=$(echo "$RECENTLY_CLOSED" | jq 'length')
echo "::notice::    ${OPEN_COUNT} open, ${CLOSED_COUNT} recently closed compliance issues" >&2

# Build output
jq -n \
  --arg repo "$REPO" \
  --argjson open "$OPEN_WITH_STATE" \
  --argjson closed "$RECENTLY_CLOSED" \
  '{
    repo: $repo,
    open_compliance_issues: $open,
    recently_closed_compliance: $closed
  }'
