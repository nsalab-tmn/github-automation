#!/usr/bin/env bash
set -euo pipefail

# dispatch-planner.sh — Dispatch planning-agent if blocker is too_complex and no decomposition exists
#
# Required environment variables:
#   GH_TOKEN      — token with actions:write on nsalab-tmn/github-automation
#   ISSUE_REPO    — full repo name (owner/name)
#   ISSUE_NUMBER  — issue number
#
# Reads brief.json from the current directory to determine the blocker type.

ISSUE_REPO="${ISSUE_REPO:?ISSUE_REPO env var required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER env var required}"

BLOCKER_TYPE=$(jq -r '.blockers[0].type // ""' brief.json)

HAS_DECOMPOSITION=$(gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
  --jq '[.[] | select(.body | test("agent:decomposition"))] | length')

if [[ "$BLOCKER_TYPE" == "too_complex" && "$HAS_DECOMPOSITION" == "0" ]]; then
  gh workflow run planning-agent \
    --repo nsalab-tmn/github-automation \
    -f issue-url="https://github.com/${ISSUE_REPO}/issues/${ISSUE_NUMBER}"
  echo "::notice::Dispatched planning-agent for ${ISSUE_REPO}#${ISSUE_NUMBER} (too_complex)"
fi
