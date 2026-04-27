#!/usr/bin/env bash
set -euo pipefail

# select-pr.sh — Select an AI-generated PR to review across all project boards
#
# If MANUAL_PR_URL is set, fetches that PR directly (skips board selection).
# Otherwise finds issues in "In review" status with qualifying open PRs.
#
# Required environment variables:
#   GH_TOKEN             — token with project and issue access
#   PROJECT_NUMBERS      — space-separated list of GitHub Projects V2 numbers
#   ORG                  — GitHub organization name
#   ELIGIBLE_STATUSES    — JSON array of eligible board statuses
#   REQUIRE_PR_LABELS    — JSON array of labels the PR must have
#   EXCLUDED_PR_LABELS   — JSON array of labels that disqualify the PR
#   MAX_REVIEW_ATTEMPTS  — max review-agent attempts before skipping
#
# Optional:
#   PROJECT_NUMBER       — single board number (fallback if PROJECT_NUMBERS not set)
#   MANUAL_PR_URL        — specific PR URL to review (bypasses selection)
#   ALLOWED_REPOS        — JSON array of repo names (org/repo) to consider; empty = all
#
# Output: JSON with selected PR details to stdout, empty if none eligible

ORG="${ORG:?ORG env var required}"

# --- Manual PR URL override ---
if [[ -n "${MANUAL_PR_URL:-}" ]]; then
  REPO=$(echo "$MANUAL_PR_URL" | grep -oP 'github\.com/\K[^/]+/[^/]+')
  NUM=$(echo "$MANUAL_PR_URL" | grep -oP '/pull/\K\d+')
  echo "::notice::Manual PR: ${REPO}#${NUM}" >&2

  gh api "repos/${REPO}/pulls/${NUM}" --jq '{
    pr_number: .number, pr_title: .title, pr_branch: .head.ref,
    pr_sha: .head.sha, issue_repo: .base.repo.full_name,
    issue_number: (.body | capture("(?i)closes\\s+#(?<n>\\d+)") | .n | tonumber)
  }' 2>/dev/null || { echo "::error::Could not fetch PR from URL: ${MANUAL_PR_URL}" >&2; exit 1; }
  exit 0
fi

PROJECT_NUMBERS="${PROJECT_NUMBERS:-${PROJECT_NUMBER:-}}"
if [[ -z "$PROJECT_NUMBERS" ]]; then
  echo "::error::Either PROJECT_NUMBERS or PROJECT_NUMBER must be set" >&2
  exit 1
fi
ELIGIBLE_STATUSES="${ELIGIBLE_STATUSES:-'["In review"]'}"
REQUIRE_PR_LABELS="${REQUIRE_PR_LABELS:-'["ai-generated"]'}"
EXCLUDED_PR_LABELS="${EXCLUDED_PR_LABELS:-'["needs-triage","stale"]'}"
ALLOWED_REPOS="${ALLOWED_REPOS:-'[]'}"
MAX_REVIEW_ATTEMPTS="${MAX_REVIEW_ATTEMPTS:-3}"

ALL_ITEMS_FILE=$(mktemp)
echo "[]" > "$ALL_ITEMS_FILE"
CANDIDATES_FILE=$(mktemp)
trap 'rm -f "$ALL_ITEMS_FILE" "$CANDIDATES_FILE"' EXIT

for PROJ_NUM in $PROJECT_NUMBERS; do
  echo "::notice::Fetching items from project #${PROJ_NUM}" >&2

  ITEMS_FILE=$(mktemp)
  echo "[]" > "$ITEMS_FILE"
  HAS_NEXT="true"
  CURSOR=""

  while [[ "$HAS_NEXT" == "true" ]]; do
    if [[ -z "$CURSOR" ]]; then
      CURSOR_ARG=""
    else
      CURSOR_ARG=", after: \"${CURSOR}\""
    fi

    PAGE_FILE=$(mktemp)
    gh api graphql -f query="
      query(\$org: String!, \$number: Int!) {
        organization(login: \$org) {
          projectV2(number: \$number) {
            items(first: 100${CURSOR_ARG}) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                status: fieldValueByName(name: \"Status\") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
                priority: fieldValueByName(name: \"Priority\") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
                content {
                  ... on Issue {
                    id
                    number
                    title
                    state
                    createdAt
                    labels(first: 20) { nodes { name } }
                    repository { nameWithOwner }
                  }
                }
              }
            }
          }
        }
      }
    " -f org="$ORG" -F number="$PROJ_NUM" > "$PAGE_FILE"

    jq '.data.organization.projectV2.items.nodes' "$PAGE_FILE" > "${ITEMS_FILE}.nodes"
    jq --slurpfile n "${ITEMS_FILE}.nodes" '. + $n[0]' "$ITEMS_FILE" > "${ITEMS_FILE}.tmp" && mv "${ITEMS_FILE}.tmp" "$ITEMS_FILE"
    HAS_NEXT=$(jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage' "$PAGE_FILE")
    CURSOR=$(jq -r '.data.organization.projectV2.items.pageInfo.endCursor' "$PAGE_FILE")
    rm -f "$PAGE_FILE" "${ITEMS_FILE}.nodes"

    COUNT=$(jq 'length' "$ITEMS_FILE")
    echo "::notice::  Fetched ${COUNT} items so far from #${PROJ_NUM} (hasNextPage: ${HAS_NEXT})" >&2
  done

  # Tag items with source project number and merge into ALL_ITEMS_FILE
  TAGGED_FILE=$(mktemp)
  jq --argjson pn "$PROJ_NUM" 'map(. + {_project_number: $pn})' "$ITEMS_FILE" > "$TAGGED_FILE"
  jq --slurpfile tagged "$TAGGED_FILE" '. + $tagged[0]' "$ALL_ITEMS_FILE" > "${ALL_ITEMS_FILE}.tmp" && mv "${ALL_ITEMS_FILE}.tmp" "$ALL_ITEMS_FILE"
  rm -f "$ITEMS_FILE" "$TAGGED_FILE"
done

# Flatten and filter to only objects (guard against nested arrays and non-issue items)
jq '[flatten[] | select(type == "object")]' "$ALL_ITEMS_FILE" > "${ALL_ITEMS_FILE}.tmp" && mv "${ALL_ITEMS_FILE}.tmp" "$ALL_ITEMS_FILE"
TOTAL=$(jq 'length' "$ALL_ITEMS_FILE")
echo "::notice::Total board items across all projects: ${TOTAL}" >&2

# Filter to issues in eligible statuses (these are the issues linked to PRs)
jq --argjson eligible "$ELIGIBLE_STATUSES" \
   --argjson allowed "$ALLOWED_REPOS" '
  map(select(
    (.content | type) == "object"
    and .content.number != null
    and .content.state == "OPEN"
    and ((.status // {}).name // "" as $s | $eligible | index($s) != null)
    and ($allowed | length == 0 or (.content.repository.nameWithOwner as $r | $allowed | index($r) != null))
  ))
  | sort_by([
    (if (.priority // {}).name == "P1" then 0
     elif (.priority // {}).name == "P2" then 1
     elif (.priority // {}).name == "P3" then 2
     else 99 end),
    .content.createdAt
  ])
  | [.[] | {
      issue_id: .content.id,
      issue_number: .content.number,
      issue_title: .content.title,
      issue_repo: .content.repository.nameWithOwner,
      issue_labels: [(.content.labels.nodes // [])[].name],
      priority: ((.priority // {}).name // ""),
      created_at: .content.createdAt,
      project_number: ._project_number
    }]
' "$ALL_ITEMS_FILE" > "$CANDIDATES_FILE"

CANDIDATE_COUNT=$(jq 'length' "$CANDIDATES_FILE")
echo "::notice::${CANDIDATE_COUNT} issue(s) in review status" >&2

if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then
  echo "::notice::No issues in review status" >&2
  echo ""
  exit 0
fi

# For each candidate issue, find the linked PR and validate
for i in $(seq 0 $((CANDIDATE_COUNT - 1))); do
  CANDIDATE=$(jq ".[$i]" "$CANDIDATES_FILE")
  ISSUE_NUM=$(echo "$CANDIDATE" | jq -r '.issue_number')
  ISSUE_REPO=$(echo "$CANDIDATE" | jq -r '.issue_repo')

  echo "::notice::Checking issue #${ISSUE_NUM} in ${ISSUE_REPO}" >&2

  # Find open PRs that close this issue
  PR_DATA=$(gh pr list --repo "$ISSUE_REPO" --state open \
    --search "closes #${ISSUE_NUM}" \
    --json number,title,labels,headRefName,headRefOid,createdAt \
    --jq '.' 2>/dev/null || echo "[]")

  PR_COUNT=$(echo "$PR_DATA" | jq 'length')
  if [[ "$PR_COUNT" -eq 0 ]]; then
    echo "::notice::  Skipping: no open PR found" >&2
    continue
  fi

  # Check each PR for required/excluded labels
  FOUND_PR=""
  for j in $(seq 0 $((PR_COUNT - 1))); do
    PR=$(echo "$PR_DATA" | jq ".[$j]")
    PR_NUM=$(echo "$PR" | jq -r '.number')
    PR_LABELS=$(echo "$PR" | jq '[.labels[].name]')

    # Check required labels
    HAS_REQUIRED="true"
    for label in $(echo "$REQUIRE_PR_LABELS" | jq -r '.[]'); do
      if ! echo "$PR_LABELS" | jq -e "index(\"$label\")" >/dev/null 2>&1; then
        HAS_REQUIRED="false"
        break
      fi
    done

    if [[ "$HAS_REQUIRED" != "true" ]]; then
      echo "::notice::  PR #${PR_NUM}: missing required labels" >&2
      continue
    fi

    # Check excluded labels
    HAS_EXCLUDED="false"
    for label in $(echo "$EXCLUDED_PR_LABELS" | jq -r '.[]'); do
      if echo "$PR_LABELS" | jq -e "index(\"$label\")" >/dev/null 2>&1; then
        HAS_EXCLUDED="true"
        break
      fi
    done

    if [[ "$HAS_EXCLUDED" == "true" ]]; then
      echo "::notice::  PR #${PR_NUM}: has excluded label" >&2
      continue
    fi

    FOUND_PR="$PR"
    break
  done

  if [[ -z "$FOUND_PR" ]]; then
    echo "::notice::  Skipping: no qualifying PR" >&2
    continue
  fi

  PR_NUM=$(echo "$FOUND_PR" | jq -r '.number')

  # Check review attempt count
  REVIEW_ATTEMPTS=$(gh api "repos/${ISSUE_REPO}/pulls/${PR_NUM}/reviews" \
    --jq '[.[] | select(.body | test("<!-- review-agent -->"))] | length' 2>/dev/null || echo "0")

  if [[ "$REVIEW_ATTEMPTS" -ge "$MAX_REVIEW_ATTEMPTS" ]]; then
    echo "::notice::  Skipping: ${REVIEW_ATTEMPTS} review attempts (max: ${MAX_REVIEW_ATTEMPTS})" >&2
    continue
  fi

  # Check CI status
  HEAD_SHA=$(echo "$FOUND_PR" | jq -r '.headRefOid')
  CI_FAILING="false"
  if [[ -n "$HEAD_SHA" && "$HEAD_SHA" != "null" ]]; then
    STATUS=$(gh api "repos/${ISSUE_REPO}/commits/${HEAD_SHA}/status" --jq '.state' 2>/dev/null || echo "pending")
    if [[ "$STATUS" == "failure" || "$STATUS" == "error" ]]; then
      CI_FAILING="true"
    fi

    CHECK_CONCLUSION=$(gh api "repos/${ISSUE_REPO}/commits/${HEAD_SHA}/check-runs" \
      --jq '[.check_runs[] | select(.conclusion == "failure")] | length' 2>/dev/null || echo "0")
    if [[ "$CHECK_CONCLUSION" -gt 0 ]]; then
      CI_FAILING="true"
    fi
  fi

  if [[ "$CI_FAILING" == "true" ]]; then
    echo "::notice::  Skipping: CI checks failing" >&2
    continue
  fi

  # All checks passed — select this PR
  echo "::notice::Selected PR #${PR_NUM} in ${ISSUE_REPO} (issue #${ISSUE_NUM})" >&2

  echo "$CANDIDATE" | jq \
    --argjson pr_number "$PR_NUM" \
    --arg pr_title "$(echo "$FOUND_PR" | jq -r '.title')" \
    --arg pr_branch "$(echo "$FOUND_PR" | jq -r '.headRefName')" \
    --arg pr_sha "$(echo "$FOUND_PR" | jq -r '.headRefOid')" \
    '. + {
      pr_number: $pr_number,
      pr_title: $pr_title,
      pr_branch: $pr_branch,
      pr_sha: $pr_sha
    }'
  exit 0
done

echo "::notice::All candidates filtered out" >&2
echo ""
