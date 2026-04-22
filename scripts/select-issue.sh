#!/usr/bin/env bash
set -euo pipefail

# select-issue.sh — Select the highest-priority issue for the engineering agent
#
# Selection strategy:
# 1. Query the project board for eligible items (with priority/size fields)
# 2. If REQUIRE_LABELS is set and no board matches, search repos directly
#    for issues with those labels (handles bot-created issues not on the board)
# 3. Rank by: Priority > Size > Type > Age
#
# Required environment variables:
#   GH_TOKEN          — token with project and issue access
#   PROJECT_NUMBER    — GitHub Projects V2 project number
#   ORG               — GitHub organization name
#   EXCLUDED_LABELS   — JSON array of labels to exclude
#   ELIGIBLE_STATUSES — JSON array of eligible board statuses
#   MAX_ATTEMPTS      — max failed attempts before skipping
#
# Optional:
#   REQUIRE_LABELS    — JSON array of labels ALL candidates must have
#   PROJECT_REPOS     — JSON array of repos to search (for off-board issues)

ORG="${ORG:?ORG env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
EXCLUDED_LABELS="${EXCLUDED_LABELS:-'["pinned","needs-triage","stale"]'}"
ELIGIBLE_STATUSES="${ELIGIBLE_STATUSES:-'["Backlog","In progress"]'}"
REQUIRE_LABELS="${REQUIRE_LABELS:-'[]'}"
PROJECT_REPOS="${PROJECT_REPOS:-'[]'}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

echo "::notice::Selecting issue from project #${PROJECT_NUMBER}" >&2
echo "::notice::Required labels: ${REQUIRE_LABELS}" >&2

# --- Strategy 1: Search project board ---

ITEMS=$(gh api graphql -f query='
  query($org: String!, $number: Int!) {
    organization(login: $org) {
      projectV2(number: $number) {
        items(first: 100) {
          nodes {
            id
            status: fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
            priority: fieldValueByName(name: "Priority") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
            size: fieldValueByName(name: "Size") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
            content {
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
' -f org="$ORG" -F number="$PROJECT_NUMBER")

SELECTED=$(echo "$ITEMS" | jq -r \
  --argjson excluded "$EXCLUDED_LABELS" \
  --argjson eligible "$ELIGIBLE_STATUSES" \
  --argjson required "$REQUIRE_LABELS" '

  def priority_rank:
    if . == "P1" then 0 elif . == "P2" then 1 elif . == "P3" then 2 else 99 end;
  def size_rank:
    if . == "S" then 0 elif . == "M" then 1 elif . == "L" then 2 elif . == "XL" then 3 else 99 end;
  def type_rank:
    if . == "Bug" then 0 elif . == "Task" then 1 elif . == "Feature" then 2 else 99 end;

  .data.organization.projectV2.items.nodes
  | map(select(
      .content != null
      and .content.number != null
      and .content.state == "OPEN"
      and ((.status // {}).name // "" as $s | $eligible | index($s) != null)
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
  | first // empty
  | {
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
      on_board: true
    }
')

# --- Strategy 2: Search repos directly for off-board issues ---

if [[ -z "$SELECTED" ]] && [[ "$REQUIRE_LABELS" != "[]" ]] && [[ "$PROJECT_REPOS" != "[]" ]]; then
  echo "::notice::No eligible issues on board — searching repos for labeled issues" >&2

  LABEL_CSV=$(echo "$REQUIRE_LABELS" | jq -r 'join(",")')
  BEST=""

  for repo in $(echo "$PROJECT_REPOS" | jq -r '.[]'); do
    ISSUES=$(gh issue list --repo "$repo" --label "$LABEL_CSV" --state open \
      --json number,title,body,createdAt,labels,assignees \
      --jq '.' 2>/dev/null || echo "[]")

    COUNT=$(echo "$ISSUES" | jq 'length')
    if [[ "$COUNT" -eq 0 ]]; then continue; fi

    echo "::notice::  Found ${COUNT} candidate(s) in ${repo}" >&2

    # Pick oldest (FIFO — no priority/size on off-board issues)
    CANDIDATE=$(echo "$ISSUES" | jq --arg repo "$repo" '
      sort_by(.createdAt) | first |
      {
        item_id: "",
        issue_id: "",
        issue_number: .number,
        title: .title,
        body: (.body // ""),
        created_at: .createdAt,
        repo: $repo,
        status: "",
        priority: "",
        size: "",
        issue_type: "",
        labels: [.labels[].name],
        assignees: [.assignees[].login],
        on_board: false
      }
    ')

    if [[ -z "$BEST" ]]; then
      BEST="$CANDIDATE"
    else
      # Compare by createdAt (oldest first)
      BEST_DATE=$(echo "$BEST" | jq -r '.created_at')
      CAND_DATE=$(echo "$CANDIDATE" | jq -r '.created_at')
      if [[ "$CAND_DATE" < "$BEST_DATE" ]]; then
        BEST="$CANDIDATE"
      fi
    fi
  done

  SELECTED="$BEST"
fi

# --- Validate selected issue ---

if [[ -z "$SELECTED" ]]; then
  echo "::notice::No eligible issues found" >&2
  echo ""
  exit 0
fi

ISSUE_NUM=$(echo "$SELECTED" | jq -r '.issue_number')
ISSUE_REPO=$(echo "$SELECTED" | jq -r '.repo')
echo "::notice::Selected #${ISSUE_NUM} in ${ISSUE_REPO}: $(echo "$SELECTED" | jq -r '.title')" >&2

# Check attempt count from issue comments
ATTEMPTS=$(gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUM}/comments" \
  --jq '[.[] | select(.body | test("<!-- agent:attempt:"))] | length' 2>/dev/null || echo "0")

if [[ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]]; then
  echo "::notice::Issue #${ISSUE_NUM} has ${ATTEMPTS} attempts (max: ${MAX_ATTEMPTS}), skipping" >&2
  echo ""
  exit 0
fi

# Check for existing open PRs linked to this issue
OPEN_PRS=$(gh pr list --repo "$ISSUE_REPO" --state open --search "closes #${ISSUE_NUM}" --json number --jq 'length' 2>/dev/null || echo "0")

if [[ "$OPEN_PRS" -gt 0 ]]; then
  echo "::notice::Issue #${ISSUE_NUM} already has an open PR, skipping" >&2
  echo ""
  exit 0
fi

# Get issue node ID if not from board (needed for project operations)
if [[ "$(echo "$SELECTED" | jq -r '.issue_id')" == "" ]]; then
  OWNER="${ISSUE_REPO%%/*}"
  REPO="${ISSUE_REPO##*/}"
  ISSUE_ID=$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $number) { id }
      }
    }
  ' -f owner="$OWNER" -f repo="$REPO" -F number="$ISSUE_NUM" --jq '.data.repository.issue.id' 2>/dev/null || echo "")
  SELECTED=$(echo "$SELECTED" | jq --arg id "$ISSUE_ID" '.issue_id = $id')
fi

# Check blockedBy dependencies
ISSUE_ID=$(echo "$SELECTED" | jq -r '.issue_id')
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
    echo "::notice::Issue #${ISSUE_NUM} has ${BLOCKER_COUNT} open blocker(s), skipping" >&2
    echo ""
    exit 0
  fi
fi

echo "$SELECTED"
