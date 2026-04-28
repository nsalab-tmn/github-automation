#!/usr/bin/env bash
set -euo pipefail

# dispatch-mechanic.sh — Dispatch engineering-agent to retry an issue
#
# Required environment variables:
#   GH_TOKEN      — token with actions:write on nsalab-tmn/github-automation
#   ISSUE_REPO    — full repo name (owner/name)
#   ISSUE_NUMBER  — issue number

ISSUE_REPO="${ISSUE_REPO:?ISSUE_REPO env var required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER env var required}"

gh workflow run engineering-agent \
  --repo nsalab-tmn/github-automation \
  -f issue-url="https://github.com/${ISSUE_REPO}/issues/${ISSUE_NUMBER}"
echo "::notice::Dispatched engineering-agent for ${ISSUE_REPO}#${ISSUE_NUMBER}"
