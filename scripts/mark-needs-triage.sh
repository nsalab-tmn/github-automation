#!/usr/bin/env bash
set -euo pipefail

# mark-needs-triage.sh — Add needs-triage label and move issue to Blocked
#
# Required environment variables:
#   GH_TOKEN        — token with issue and project access
#   ISSUE_REPO      — full repo name (owner/name)
#   ISSUE_NUMBER    — issue number
#   ISSUE_ID        — issue node ID (GraphQL ID)
#   PROJECT_NUMBER  — project board number
#   TARGET_STATUS   — board status to set (e.g. "Blocked")

ISSUE_REPO="${ISSUE_REPO:?ISSUE_REPO env var required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER env var required}"
ISSUE_ID="${ISSUE_ID:?ISSUE_ID env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
TARGET_STATUS="${TARGET_STATUS:?TARGET_STATUS env var required}"

# Add needs-triage label
gh label create needs-triage --repo "$ISSUE_REPO" \
  --color "FBCA04" --description "Needs human attention" \
  2>/dev/null || true
gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/labels" \
  -f "labels[]=needs-triage" >/dev/null 2>&1 || true

# Move to target status on board
export ISSUE_ID PROJECT_NUMBER TARGET_STATUS
./scripts/set-board-status.sh
