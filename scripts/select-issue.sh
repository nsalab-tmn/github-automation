#!/usr/bin/env bash
set -euo pipefail

# select-issue.sh — Select the highest-priority issue from the project board
#
# Required environment variables:
#   GH_TOKEN        — token with project and issue access
#   PROJECT_NUMBER  — GitHub Projects V2 project number
#   ORG             — GitHub organization name
#   AGENT_CONFIG    — path to engineering-agent.yaml (parsed externally)
#   EXCLUDED_LABELS — JSON array of labels to exclude
#   MAX_ATTEMPTS    — max failed attempts before skipping
#
# Output: JSON with selected issue to stdout, empty string if none eligible

ORG="${ORG:?ORG env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
EXCLUDED_LABELS="${EXCLUDED_LABELS:-'["pinned","needs-triage","stale"]'}"
ELIGIBLE_STATUSES="${ELIGIBLE_STATUSES:-'["Backlog","In progress"]'}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

echo "::notice::Selecting issue from project #${PROJECT_NUMBER}" >&2

# Fetch all project items with fields
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

# Filter and rank using jq
# Eligible: Backlog or In Progress, open, no excluded labels
# Sort: Priority (P1>P2>P3>none) > Size (S>M>L>XL>none) > Type (Bug>Task>Feature>none) > Age (oldest first)
SELECTED=$(echo "$ITEMS" | jq -r --argjson excluded "$EXCLUDED_LABELS" --argjson eligible "$ELIGIBLE_STATUSES" '
  # Priority/Size/Type rank maps (lower = better)
  def priority_rank:
    if . == "P1" then 0
    elif . == "P2" then 1
    elif . == "P3" then 2
    else 99 end;

  def size_rank:
    if . == "S" then 0
    elif . == "M" then 1
    elif . == "L" then 2
    elif . == "XL" then 3
    else 99 end;

  def type_rank:
    if . == "Bug" then 0
    elif . == "Task" then 1
    elif . == "Feature" then 2
    else 99 end;

  .data.organization.projectV2.items.nodes
  | map(select(
      .content != null
      and .content.number != null
      and .content.state == "OPEN"
      and ((.status // {}).name // "" as $s | $eligible | index($s) != null)
      and ([.content.labels.nodes[].name] | any(. as $l | $excluded | index($l)) | not)
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
      assignees: [.content.assignees.nodes[].login]
    }
')

if [[ -z "$SELECTED" ]]; then
  echo "::notice::No eligible issues found" >&2
  echo ""
  exit 0
fi

ISSUE_NUM=$(echo "$SELECTED" | jq -r '.issue_number')
ISSUE_REPO=$(echo "$SELECTED" | jq -r '.repo')
ISSUE_PRIORITY=$(echo "$SELECTED" | jq -r '.priority')
ISSUE_SIZE=$(echo "$SELECTED" | jq -r '.size')
echo "::notice::Selected #${ISSUE_NUM} in ${ISSUE_REPO} (${ISSUE_PRIORITY}/${ISSUE_SIZE}): $(echo "$SELECTED" | jq -r '.title')" >&2

# Check attempt count from issue comments
ATTEMPTS=$(gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUM}/comments" \
  --jq '[.[] | select(.body | test("<!-- agent:attempt:"))] | length' 2>/dev/null || echo "0")

if [[ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]]; then
  echo "::notice::Issue #${ISSUE_NUM} has ${ATTEMPTS} attempts (max: ${MAX_ATTEMPTS}), skipping" >&2
  # TODO: in a full implementation, re-run selection excluding this issue
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

# Check blockedBy dependencies
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
' -f issueId="$(echo "$SELECTED" | jq -r '.issue_id')" 2>/dev/null \
  | jq '[.data.node.blockedBy.nodes[] | select(.state == "OPEN")] | length' 2>/dev/null || echo "0")

if [[ "$BLOCKER_COUNT" -gt 0 ]]; then
  echo "::notice::Issue #${ISSUE_NUM} has ${BLOCKER_COUNT} open blocker(s), skipping" >&2
  echo ""
  exit 0
fi

echo "$SELECTED"
