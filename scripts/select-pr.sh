#!/usr/bin/env bash
set -euo pipefail

# select-pr.sh — Select an AI-generated PR to review from the project board
#
# Finds issues in "In review" status that have open PRs with ai-generated label.
# Validates each candidate and returns the first one that passes all checks.
#
# Required environment variables:
#   GH_TOKEN             — token with project and issue access
#   PROJECT_NUMBER       — GitHub Projects V2 project number
#   ORG                  — GitHub organization name
#   ELIGIBLE_STATUSES    — JSON array of eligible board statuses
#   REQUIRE_PR_LABELS    — JSON array of labels the PR must have
#   EXCLUDED_PR_LABELS   — JSON array of labels that disqualify the PR
#   MAX_REVIEW_ATTEMPTS  — max review-agent attempts before skipping
#
# Output: JSON with selected PR details to stdout, empty if none eligible

ORG="${ORG:?ORG env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
ELIGIBLE_STATUSES="${ELIGIBLE_STATUSES:-'["In review"]'}"
REQUIRE_PR_LABELS="${REQUIRE_PR_LABELS:-'["ai-generated"]'}"
EXCLUDED_PR_LABELS="${EXCLUDED_PR_LABELS:-'["needs-triage","stale"]'}"
MAX_REVIEW_ATTEMPTS="${MAX_REVIEW_ATTEMPTS:-3}"

echo "::notice::Selecting PR to review from project #${PROJECT_NUMBER}" >&2

# Paginate through all board items (file-based to avoid arg-list-too-long)
ITEMS_FILE=$(mktemp)
CANDIDATES_FILE=$(mktemp)
trap 'rm -f "$ITEMS_FILE" "$CANDIDATES_FILE"' EXIT
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
  " -f org="$ORG" -F number="$PROJECT_NUMBER" > "$PAGE_FILE"

  jq '.data.organization.projectV2.items.nodes' "$PAGE_FILE" > "${ITEMS_FILE}.nodes"
  jq --slurpfile n "${ITEMS_FILE}.nodes" '. + $n[0]' "$ITEMS_FILE" > "${ITEMS_FILE}.tmp" && mv "${ITEMS_FILE}.tmp" "$ITEMS_FILE"
  HAS_NEXT=$(jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage' "$PAGE_FILE")
  CURSOR=$(jq -r '.data.organization.projectV2.items.pageInfo.endCursor' "$PAGE_FILE")
  rm -f "$PAGE_FILE" "${ITEMS_FILE}.nodes"

  COUNT=$(jq 'length' "$ITEMS_FILE")
  echo "::notice::  Fetched ${COUNT} items so far (hasNextPage: ${HAS_NEXT})" >&2
done

TOTAL=$(jq 'length' "$ITEMS_FILE")
echo "::notice::Total board items: ${TOTAL}" >&2

# Filter to issues in eligible statuses (these are the issues linked to PRs)
jq --argjson eligible "$ELIGIBLE_STATUSES" '
  map(select(
    .content != null
    and .content.number != null
    and .content.state == "OPEN"
    and ((.status // {}).name // "" as $s | $eligible | index($s) != null)
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
      issue_labels: [.content.labels.nodes[].name],
      priority: ((.priority // {}).name // ""),
      created_at: .content.createdAt
    }]
' "$ITEMS_FILE" > "$CANDIDATES_FILE"

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
    HAS_REQUIRED=$(echo "$PR_LABELS" | jq --argjson req "$REQUIRE_PR_LABELS" \
      '$req | all(. as $r | $ARGS.positional[0] | index($r) != null)' --args -- "$PR_LABELS" 2>/dev/null || echo "false")

    # Simpler check
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
  REVIEW_ATTEMPTS=$(gh api "repos/${ISSUE_REPO}/pulls/${PR_NUM}/comments" \
    --jq 'length' 2>/dev/null || echo "0")
  # Actually check for review-agent markers in PR reviews
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
    # Check combined status
    STATUS=$(gh api "repos/${ISSUE_REPO}/commits/${HEAD_SHA}/status" --jq '.state' 2>/dev/null || echo "pending")
    if [[ "$STATUS" == "failure" || "$STATUS" == "error" ]]; then
      CI_FAILING="true"
    fi

    # Also check check-runs
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
