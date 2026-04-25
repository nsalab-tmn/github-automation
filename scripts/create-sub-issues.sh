#!/usr/bin/env bash
set -euo pipefail

# create-sub-issues.sh — Create sub-issues from decomposition and link to parent
#
# Required environment variables:
#   GH_TOKEN        — token with issue and project access
#   ISSUE_REPO      — full repo name (owner/name)
#   ISSUE_NUMBER    — parent issue number
#   DECOMPOSITION   — path to decomposition JSON file
#   PROJECT_NUMBER  — project board number
#   RUN_URL         — link to this workflow run
#
# The decomposition JSON must have a "sub_issues" array with objects containing:
#   phase, title, body, labels, depends_on_phases

ISSUE_REPO="${ISSUE_REPO:?ISSUE_REPO env var required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER env var required}"
DECOMPOSITION="${DECOMPOSITION:?DECOMPOSITION env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
RUN_URL="${RUN_URL:?RUN_URL env var required}"

# Get parent issue node ID
echo "::notice::Fetching parent issue node ID" >&2
PARENT_ID=$(gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}" --jq '.node_id')

SUB_COUNT=$(jq '.sub_issues | length' "$DECOMPOSITION")
echo "::notice::Creating ${SUB_COUNT} sub-issues for #${ISSUE_NUMBER}" >&2

# Track created issues for summary comment
CREATED_ISSUES="[]"

# Phase number → issue number mapping for dependency tracking
declare -A PHASE_TO_ISSUE

for i in $(seq 0 $((SUB_COUNT - 1))); do
  PHASE=$(jq -r ".sub_issues[$i].phase" "$DECOMPOSITION")
  TITLE=$(jq -r ".sub_issues[$i].title" "$DECOMPOSITION")
  BODY=$(jq -r ".sub_issues[$i].body" "$DECOMPOSITION")
  LABELS_JSON=$(jq -r ".sub_issues[$i].labels" "$DECOMPOSITION")
  DEPS=$(jq -r ".sub_issues[$i].depends_on_phases | join(\",\")" "$DECOMPOSITION")

  echo "::notice::  Creating phase ${PHASE}: ${TITLE}" >&2

  # Build label args
  LABEL_ARGS=""
  for label in $(echo "$LABELS_JSON" | jq -r '.[]'); do
    LABEL_ARGS="${LABEL_ARGS} --label ${label}"
  done

  # Add dependency references to body if any
  if [[ -n "$DEPS" ]]; then
    DEP_REFS=""
    IFS=',' read -ra DEP_PHASES <<< "$DEPS"
    for dep_phase in "${DEP_PHASES[@]}"; do
      dep_issue="${PHASE_TO_ISSUE[$dep_phase]:-}"
      if [[ -n "$dep_issue" ]]; then
        DEP_REFS="${DEP_REFS}\n- Depends on #${dep_issue} (Phase ${dep_phase})"
      fi
    done
    if [[ -n "$DEP_REFS" ]]; then
      BODY="${BODY}

## Phase dependencies
$(echo -e "$DEP_REFS")"
    fi
  fi

  # Create the issue
  ISSUE_URL=$(gh issue create \
    --repo "$ISSUE_REPO" \
    --title "$TITLE" \
    --body "$BODY" \
    $LABEL_ARGS 2>&1)

  # Extract issue number from URL
  SUB_NUMBER=$(echo "$ISSUE_URL" | grep -oP '\d+$')
  echo "::notice::    Created #${SUB_NUMBER}" >&2

  # Store phase → issue mapping
  PHASE_TO_ISSUE[$PHASE]=$SUB_NUMBER

  # Get sub-issue node ID and link to parent
  SUB_ID=$(gh api "repos/${ISSUE_REPO}/issues/${SUB_NUMBER}" --jq '.node_id')

  echo "::notice::    Linking #${SUB_NUMBER} as sub-issue of #${ISSUE_NUMBER}" >&2
  gh api graphql -f query="
    mutation {
      addSubIssue(input: {issueId: \"${PARENT_ID}\", subIssueId: \"${SUB_ID}\"}) {
        issue { number }
        subIssue { number }
      }
    }
  " >/dev/null 2>&1 || echo "::warning::    Failed to link #${SUB_NUMBER} as sub-issue" >&2

  # Track for summary
  CREATED_ISSUES=$(echo "$CREATED_ISSUES" | jq \
    --argjson phase "$PHASE" \
    --arg title "$TITLE" \
    --argjson number "$SUB_NUMBER" \
    --arg deps "$DEPS" \
    '. + [{"phase": $phase, "title": $title, "number": $number, "deps": $deps}]')
done

# Post summary comment on parent issue
echo "::notice::Posting decomposition summary on #${ISSUE_NUMBER}" >&2

SUMMARY_LINES=""
for i in $(seq 0 $((SUB_COUNT - 1))); do
  NUMBER=$(echo "$CREATED_ISSUES" | jq -r ".[$i].number")
  PHASE=$(echo "$CREATED_ISSUES" | jq -r ".[$i].phase")
  TITLE=$(echo "$CREATED_ISSUES" | jq -r ".[$i].title")
  DEPS=$(echo "$CREATED_ISSUES" | jq -r ".[$i].deps")

  DEP_TEXT=""
  if [[ -n "$DEPS" ]]; then
    DEP_REFS=""
    IFS=',' read -ra DEP_PHASES <<< "$DEPS"
    for dp in "${DEP_PHASES[@]}"; do
      dep_num="${PHASE_TO_ISSUE[$dp]:-?}"
      DEP_REFS="${DEP_REFS}#${dep_num} "
    done
    DEP_TEXT=" (depends on ${DEP_REFS% })"
  fi

  SUMMARY_LINES="${SUMMARY_LINES}
- [ ] #${NUMBER} — Phase ${PHASE}: ${TITLE}${DEP_TEXT}"
done

COMMENT_BODY="<!-- agent:decomposition -->
### Decomposed into ${SUB_COUNT} sub-issues

${SUMMARY_LINES}

---
*Decomposed by [planning agent](${RUN_URL})*
<!-- /agent:decomposition -->"

gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
  -f body="$COMMENT_BODY" >/dev/null

echo "::notice::Done — created ${SUB_COUNT} sub-issues" >&2
echo "sub_issue_count=${SUB_COUNT}" >> "$GITHUB_OUTPUT"
