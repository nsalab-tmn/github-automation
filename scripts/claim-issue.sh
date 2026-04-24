#!/usr/bin/env bash
set -euo pipefail

# claim-issue.sh — Claim an issue: assign bot, move to In Progress, post comment
#
# Required environment variables:
#   GH_TOKEN        — token with issue and project access
#   ISSUE_REPO      — full repo name (owner/name)
#   ISSUE_NUMBER    — issue number
#   ISSUE_ID        — issue node ID (GraphQL ID)
#   PROJECT_NUMBER  — project board number
#   TARGET_STATUS   — board status to set (e.g. "In progress")
#   RUN_URL         — link to this workflow run
#   RUN_NUMBER      — workflow run number

ISSUE_REPO="${ISSUE_REPO:?ISSUE_REPO env var required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER env var required}"
ISSUE_ID="${ISSUE_ID:?ISSUE_ID env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
TARGET_STATUS="${TARGET_STATUS:?TARGET_STATUS env var required}"
RUN_URL="${RUN_URL:?RUN_URL env var required}"
RUN_NUMBER="${RUN_NUMBER:?RUN_NUMBER env var required}"

# Assign the bot
RESULT=$(gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/assignees" \
  --method POST -f "assignees[]=nsalab-mechanic[bot]" \
  --jq '[.assignees[].login]' 2>&1) && \
  echo "::notice::Assigned: ${RESULT}" >&2 || \
  echo "::warning::Assignment failed: ${RESULT}" >&2

# Move to target status on board
export ISSUE_ID PROJECT_NUMBER TARGET_STATUS
./scripts/set-board-status.sh

# Post session comment
gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
  -f body="Agent session started — [run #${RUN_NUMBER}](${RUN_URL})" \
  >/dev/null
