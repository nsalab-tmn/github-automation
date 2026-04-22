#!/usr/bin/env bash
set -euo pipefail

# check-blocked.sh — Check all Blocked-status items and unblock resolved ones
#
# Required environment variables:
#   GH_TOKEN        — token with project and issue access
#   PROJECT_NUMBER  — GitHub Projects V2 project number
#   ORG             — GitHub organization name
#
# Output: summary to stderr, unblocked count to stdout

ORG="${ORG:?ORG env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
STATUS_BLOCKED="${STATUS_BLOCKED:-Blocked}"
STATUS_BACKLOG="${STATUS_BACKLOG:-Backlog}"

echo "::notice::Checking blocked items on project #${PROJECT_NUMBER}" >&2

# Get project ID and Blocked status option ID
PROJECT_DATA=$(gh api graphql -f query='
  query($org: String!, $number: Int!) {
    organization(login: $org) {
      projectV2(number: $number) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options { id name }
          }
        }
      }
    }
  }
' -f org="$ORG" -F number="$PROJECT_NUMBER")

PROJECT_ID=$(echo "$PROJECT_DATA" | jq -r '.data.organization.projectV2.id')
STATUS_FIELD_ID=$(echo "$PROJECT_DATA" | jq -r '.data.organization.projectV2.field.id')
BLOCKED_OPTION_ID=$(echo "$PROJECT_DATA" | jq -r --arg s "$STATUS_BLOCKED" '.data.organization.projectV2.field.options[] | select(.name == $s) | .id')
BACKLOG_OPTION_ID=$(echo "$PROJECT_DATA" | jq -r --arg s "$STATUS_BACKLOG" '.data.organization.projectV2.field.options[] | select(.name == $s) | .id')

if [[ -z "$BLOCKED_OPTION_ID" || "$BLOCKED_OPTION_ID" == "null" ]]; then
  echo "::notice::No 'Blocked' status option found on project board" >&2
  echo "0"
  exit 0
fi

# Get all items with Blocked status
BLOCKED_ITEMS=$(gh api graphql -f query='
  query($projectId: ID!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        items(first: 100) {
          nodes {
            id
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
              }
            }
            content {
              ... on Issue {
                id
                number
                title
                state
                repository { nameWithOwner }
              }
            }
          }
        }
      }
    }
  }
' -f projectId="$PROJECT_ID" | jq --arg s "$STATUS_BLOCKED" '[.data.node.items.nodes[] | select(.fieldValueByName.name == $s) | select(.content != null)]')

BLOCKED_COUNT=$(echo "$BLOCKED_ITEMS" | jq 'length')
echo "::notice::Found ${BLOCKED_COUNT} blocked item(s)" >&2

if [[ "$BLOCKED_COUNT" -eq 0 ]]; then
  echo "0"
  exit 0
fi

UNBLOCKED=0

for i in $(seq 0 $((BLOCKED_COUNT - 1))); do
  ITEM=$(echo "$BLOCKED_ITEMS" | jq ".[$i]")
  ITEM_ID=$(echo "$ITEM" | jq -r '.id')
  ISSUE_ID=$(echo "$ITEM" | jq -r '.content.id')
  ISSUE_NUMBER=$(echo "$ITEM" | jq -r '.content.number')
  ISSUE_REPO=$(echo "$ITEM" | jq -r '.content.repository.nameWithOwner')
  ISSUE_TITLE=$(echo "$ITEM" | jq -r '.content.title')

  echo "::group::Checking #${ISSUE_NUMBER} in ${ISSUE_REPO}: ${ISSUE_TITLE}" >&2

  # Check blockedBy dependencies
  BLOCKERS=$(gh api graphql -f query='
    query($issueId: ID!) {
      node(id: $issueId) {
        ... on Issue {
          blockedBy(first: 50) {
            nodes {
              number
              title
              state
              repository { nameWithOwner }
            }
          }
        }
      }
    }
  ' -f issueId="$ISSUE_ID" 2>/dev/null | jq '.data.node.blockedBy.nodes // []')

  OPEN_BLOCKERS=$(echo "$BLOCKERS" | jq '[.[] | select(.state == "OPEN")] | length')

  # Check sub-issues
  SUB_SUMMARY=$(gh api graphql -f query='
    query($issueId: ID!) {
      node(id: $issueId) {
        ... on Issue {
          subIssuesSummary {
            total
            completed
          }
        }
      }
    }
  ' -f issueId="$ISSUE_ID" 2>/dev/null | jq '.data.node.subIssuesSummary // {"total": 0, "completed": 0}')

  SUB_TOTAL=$(echo "$SUB_SUMMARY" | jq '.total')
  SUB_COMPLETED=$(echo "$SUB_SUMMARY" | jq '.completed')
  SUB_REMAINING=$((SUB_TOTAL - SUB_COMPLETED))

  echo "::notice::  Blockers: ${OPEN_BLOCKERS} open, Sub-issues: ${SUB_REMAINING} remaining" >&2

  if [[ "$OPEN_BLOCKERS" -eq 0 && "$SUB_REMAINING" -eq 0 ]]; then
    echo "::notice::  All resolved — moving to Backlog" >&2

    # Move to Backlog
    gh api graphql -f query='
      mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
        updateProjectV2ItemFieldValue(input: {
          projectId: $projectId
          itemId: $itemId
          fieldId: $fieldId
          value: { singleSelectOptionId: $optionId }
        }) {
          projectV2Item { id }
        }
      }
    ' -f projectId="$PROJECT_ID" \
      -f itemId="$ITEM_ID" \
      -f fieldId="$STATUS_FIELD_ID" \
      -f optionId="$BACKLOG_OPTION_ID" >/dev/null

    # Comment on issue
    OWNER="${ISSUE_REPO%%/*}"
    REPO="${ISSUE_REPO##*/}"
    gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
      -f body="All blockers and sub-issues resolved — returning to Backlog. This issue is eligible for agent selection again." \
      >/dev/null

    UNBLOCKED=$((UNBLOCKED + 1))
  else
    if [[ "$OPEN_BLOCKERS" -gt 0 ]]; then
      echo "::notice::  Still blocked by ${OPEN_BLOCKERS} open issue(s)" >&2
    fi
    if [[ "$SUB_REMAINING" -gt 0 ]]; then
      echo "::notice::  ${SUB_REMAINING} sub-issue(s) still open" >&2
    fi
  fi

  echo "::endgroup::" >&2
done

echo "::notice::Unblocked ${UNBLOCKED} of ${BLOCKED_COUNT} item(s)" >&2
echo "$UNBLOCKED"
