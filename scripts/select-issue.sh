#!/usr/bin/env bash
set -euo pipefail

# select-issue.sh — Select the highest-priority issue across all project boards
#
# Paginates through all items on each board, merges candidates, then ranks by:
# Priority > Size > Type > Age (oldest first)
#
# Required environment variables:
#   GH_TOKEN          — token with project and issue access
#   PROJECT_NUMBERS   — space-separated list of GitHub Projects V2 numbers
#   ORG               — GitHub organization name
#   EXCLUDED_LABELS   — JSON array of labels to exclude
#   ELIGIBLE_STATUSES — JSON array of eligible board statuses
#   MAX_ATTEMPTS      — max failed attempts before skipping
#
# Optional:
#   PROJECT_NUMBER    — single board number (fallback if PROJECT_NUMBERS not set)
#   REQUIRE_LABELS    — JSON array of labels ALL candidates must have
#   ALLOWED_REPOS     — JSON array of repo names (org/repo) to consider; empty = all

ORG="${ORG:?ORG env var required}"
PROJECT_NUMBERS="${PROJECT_NUMBERS:-${PROJECT_NUMBER:-}}"
if [[ -z "$PROJECT_NUMBERS" ]]; then
  echo "::error::Either PROJECT_NUMBERS or PROJECT_NUMBER must be set" >&2
  exit 1
fi
EXCLUDED_LABELS="${EXCLUDED_LABELS:-'["pinned","needs-triage","stale"]'}"
ELIGIBLE_STATUSES="${ELIGIBLE_STATUSES:-'["Backlog","In progress"]'}"
REQUIRE_LABELS="${REQUIRE_LABELS:-'[]'}"
ALLOWED_REPOS="${ALLOWED_REPOS:-'[]'}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

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
                size: fieldValueByName(name: \"Size\") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
                content {
                  __typename
                  ... on Issue {
                    id
                    number
                    title
                    body
                    createdAt
                    state
                    issueType { name }
                    assignees(first: 10) { nodes { login } }
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

TOTAL=$(jq 'length' "$ALL_ITEMS_FILE")
echo "::notice::Total board items across all projects: ${TOTAL}" >&2

NON_ISSUE_COUNT=$(jq '[.[] | select(.content == null or (.content.__typename // "") != "Issue")] | length' "$ALL_ITEMS_FILE")
if [[ "$NON_ISSUE_COUNT" -gt 0 ]]; then
  echo "::notice::Skipping ${NON_ISSUE_COUNT} non-Issue item(s) (draft PRs, pull requests, or archived items)" >&2
fi

# Filter and rank all candidates (output sorted array to file)
jq \
  --argjson excluded "$EXCLUDED_LABELS" \
  --argjson eligible "$ELIGIBLE_STATUSES" \
  --argjson required "$REQUIRE_LABELS" \
  --argjson allowed "$ALLOWED_REPOS" '

  def priority_rank:
    if . == "P1" then 0 elif . == "P2" then 1 elif . == "P3" then 2 else 99 end;
  def size_rank:
    if . == "S" then 0 elif . == "M" then 1 elif . == "L" then 2 elif . == "XL" then 3 else 99 end;
  def type_rank:
    if . == "Bug" then 0 elif . == "Task" then 1 elif . == "Feature" then 2 else 99 end;

  map(select(
      .content != null
      and (.content.__typename // "") == "Issue"
      and .content.number != null
      and .content.state == "OPEN"
      and ((.status // {}).name // "" as $s | $eligible | index($s) != null)
      and ($allowed | length == 0 or (.content.repository.nameWithOwner as $r | $allowed | index($r) != null))
      and ([.content.labels.nodes[].name] as $labels |
        ($excluded | all(. as $e | $labels | index($e) == null))
        and ($required | all(. as $r | $labels | index($r) != null))
      )
    ))
  | map(. + {
      _priority_rank: ((.priority // {}).name // "" | priority_rank),
      _size_rank: ((.size // {}).name // "" | size_rank),
      _type_rank: (.content.issueType.name // "" | type_rank),
      _created: .content.createdAt
    })
  | sort_by([._priority_rank, ._size_rank, ._type_rank, ._created])
  | [.[] | {
      item_id: .id,
      issue_id: .content.id,
      issue_number: .content.number,
      title: .content.title,
      body: (.content.body // ""),
      created_at: .content.createdAt,
      repo: .content.repository.nameWithOwner,
      status: ((.status // {}).name // ""),
      priority: ((.priority // {}).name // ""),
      size: ((.size // {}).name // ""),
      issue_type: (.content.issueType.name // ""),
      labels: [.content.labels.nodes[].name],
      assignees: [.content.assignees.nodes[].login],
      project_number: ._project_number
    }]
' "$ALL_ITEMS_FILE" > "$CANDIDATES_FILE"

CANDIDATE_COUNT=$(jq 'length' "$CANDIDATES_FILE")
echo "::notice::${CANDIDATE_COUNT} candidate(s) after filtering" >&2

if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then
  echo "::notice::No eligible issues found on any board" >&2
  echo ""
  exit 0
fi

# Validate candidates in rank order — pick the first one that passes all checks
for i in $(seq 0 $((CANDIDATE_COUNT - 1))); do
  CANDIDATE=$(jq ".[$i]" "$CANDIDATES_FILE")
  ISSUE_NUM=$(echo "$CANDIDATE" | jq -r '.issue_number')
  ISSUE_REPO=$(echo "$CANDIDATE" | jq -r '.repo')
  ISSUE_ID=$(echo "$CANDIDATE" | jq -r '.issue_id')

  echo "::notice::Checking #${ISSUE_NUM} in ${ISSUE_REPO}: $(echo "$CANDIDATE" | jq -r '.title')" >&2

  # Check failed attempt count (only count failed/blocked, not completed)
  FAILED_ATTEMPTS=$(gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUM}/comments" \
    --jq '[.[] | select(.body | test("<!-- agent:attempt:")) | select(.body | test("\\*\\*Status:\\*\\* (failed|blocked|not-workable)"))] | length' 2>/dev/null || echo "0")

  if [[ "$FAILED_ATTEMPTS" -ge "$MAX_ATTEMPTS" ]]; then
    echo "::notice::  Skipping: ${FAILED_ATTEMPTS} failed attempts (max: ${MAX_ATTEMPTS})" >&2
    continue
  fi

  # Check for existing open PRs linked to this issue
  OPEN_PRS=$(gh pr list --repo "$ISSUE_REPO" --state open --search "closes #${ISSUE_NUM}" --json number --jq 'length' 2>/dev/null || echo "0")

  if [[ "$OPEN_PRS" -gt 0 ]]; then
    echo "::notice::  Skipping: already has an open PR" >&2
    continue
  fi

  # Check blockedBy dependencies
  if [[ -n "$ISSUE_ID" && "$ISSUE_ID" != "" ]]; then
    BLOCKER_COUNT=$(gh api graphql -f query='
      query($issueId: ID!) {
        node(id: $issueId) {
          ... on Issue {
            blockedBy(first: 50) {
              nodes { state }
            }
          }
        }
      }
    ' -f issueId="$ISSUE_ID" 2>/dev/null \
      | jq '[.data.node.blockedBy.nodes[] | select(.state == "OPEN")] | length' 2>/dev/null || echo "0")

    if [[ "$BLOCKER_COUNT" -gt 0 ]]; then
      echo "::notice::  Skipping: ${BLOCKER_COUNT} open blocker(s)" >&2
      continue
    fi
  fi

  # Check for open sub-issues (parent should wait for children)
  SUB_COUNT=$(gh api graphql -f query='
    query($issueId: ID!) {
      node(id: $issueId) {
        ... on Issue {
          subIssues(first: 1, filter: {states: [OPEN]}) {
            totalCount
          }
        }
      }
    }
  ' -f issueId="$ISSUE_ID" 2>/dev/null \
    | jq '.data.node.subIssues.totalCount // 0' 2>/dev/null || echo "0")

  if [[ "$SUB_COUNT" -gt 0 ]]; then
    echo "::notice::  Skipping: ${SUB_COUNT} open sub-issue(s)" >&2
    continue
  fi

  # This candidate passed all checks
  echo "::notice::Selected #${ISSUE_NUM} in ${ISSUE_REPO}: $(echo "$CANDIDATE" | jq -r '.title')" >&2
  echo "$CANDIDATE"
  exit 0
done

echo "::notice::All candidates were filtered out by validation checks" >&2
echo ""
