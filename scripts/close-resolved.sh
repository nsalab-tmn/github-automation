#!/usr/bin/env bash
set -euo pipefail

# close-resolved.sh — Close an issue as already resolved with evidence comment
#
# Required environment variables:
#   GH_TOKEN        — token with issue access
#   ISSUE_REPO      — full repo name (owner/name)
#   ISSUE_NUMBER    — issue number
#   RESOLUTION      — explanation of why the issue is resolved
#   RUN_URL         — link to this workflow run
#   RUN_NUMBER      — workflow run number

ISSUE_REPO="${ISSUE_REPO:?ISSUE_REPO env var required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER env var required}"
RESOLUTION="${RESOLUTION:?RESOLUTION env var required}"
RUN_URL="${RUN_URL:?RUN_URL env var required}"
RUN_NUMBER="${RUN_NUMBER:?RUN_NUMBER env var required}"

gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
  -f body="**Issue already resolved** — verified by [engineering agent run #${RUN_NUMBER}](${RUN_URL})

${RESOLUTION}

Closing as the problem no longer exists." >/dev/null

gh issue close "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --reason completed
echo "::notice::Issue closed as already resolved" >&2
