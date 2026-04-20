#!/usr/bin/env bash
set -euo pipefail

# gather-repo-state.sh — Collect repo state for AI review
# Output: JSON to stdout
#
# Required environment variables:
#   REPO — owner/name format (e.g., nsalab-tmn/github-automation)

REPO="${REPO:?REPO env var required (owner/name)}"

NOW=$(date -u +%s)

# Open issues (excluding PRs)
OPEN_ISSUES=$(gh issue list --repo "${REPO}" --state open --json number,title,labels,assignees,createdAt,updatedAt --limit 100)

# Open PRs
OPEN_PRS=$(gh pr list --repo "${REPO}" --state open --json number,title,labels,author,createdAt,updatedAt,reviewDecision --limit 50)

# Recently closed issues (last 14 days)
CLOSED_ISSUES=$(gh issue list --repo "${REPO}" --state closed --json number,title,closedAt,labels --limit 30)

# Recently merged PRs (last 14 days)
MERGED_PRS=$(gh pr list --repo "${REPO}" --state merged --json number,title,mergedAt,labels --limit 30)

# Build output
cat <<EOF
{
  "repo": "${REPO}",
  "collected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "open_issues": ${OPEN_ISSUES},
  "open_prs": ${OPEN_PRS},
  "recently_closed_issues": ${CLOSED_ISSUES},
  "recently_merged_prs": ${MERGED_PRS}
}
EOF
