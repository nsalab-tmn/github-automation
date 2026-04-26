#!/usr/bin/env bash
set -euo pipefail

# wait-and-merge.sh — Poll for PR Validation CI then squash-merge.
# Writes merged=true|false to GITHUB_OUTPUT.
#
# Required env: GH_TOKEN, PR_REPO, PR_NUMBER

PR_REPO="${PR_REPO:?PR_REPO env var required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER env var required}"

MAX_WAIT=120
INTERVAL=10
ELAPSED=0
CI_PASSED=false

echo "::notice::Polling 'PR Validation' check on ${PR_REPO}#${PR_NUMBER} (up to ${MAX_WAIT}s)..."

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  CONCLUSION=$(gh pr checks "$PR_NUMBER" --repo "$PR_REPO" --required --json name,conclusion \
    2>/dev/null \
    | jq -r '.[] | select(.name == "PR Validation") | .conclusion' \
    2>/dev/null || true)

  case "${CONCLUSION}" in
    success)
      echo "::notice::PR Validation passed after ${ELAPSED}s — proceeding to merge"
      CI_PASSED=true
      break
      ;;
    failure|cancelled|timed_out|action_required)
      echo "::warning::PR Validation check concluded: ${CONCLUSION} — skipping merge"
      echo "merged=false" >> "$GITHUB_OUTPUT"
      exit 0
      ;;
    *)
      echo "PR Validation: ${CONCLUSION:-pending} — retrying in ${INTERVAL}s (${ELAPSED}s elapsed)"
      sleep $INTERVAL
      ELAPSED=$((ELAPSED + INTERVAL))
      ;;
  esac
done

if [[ "$CI_PASSED" == "false" ]]; then
  echo "::warning::Timed out waiting for PR Validation after ${MAX_WAIT}s — skipping merge"
  echo "merged=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "::notice::Attempting squash-merge of ${PR_REPO}#${PR_NUMBER}..."
if gh pr merge "$PR_NUMBER" --repo "$PR_REPO" --squash; then
  ACTUAL=$(gh pr view "$PR_NUMBER" --repo "$PR_REPO" --json merged --jq '.merged' 2>/dev/null || echo "false")
  if [[ "$ACTUAL" == "true" ]]; then
    echo "::notice::PR #${PR_NUMBER} successfully squash-merged"
    echo "merged=true" >> "$GITHUB_OUTPUT"
  else
    echo "::warning::gh pr merge exited 0 but PR is not marked as merged — reporting failure"
    echo "merged=false" >> "$GITHUB_OUTPUT"
  fi
else
  echo "::warning::gh pr merge failed for ${PR_REPO}#${PR_NUMBER}"
  echo "merged=false" >> "$GITHUB_OUTPUT"
fi
