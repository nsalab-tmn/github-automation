#!/usr/bin/env bash
set -euo pipefail

# check-blocked.sh — Check all Blocked-status items across boards and unblock resolved ones
#
# Required environment variables:
#   GH_TOKEN        — token with project and issue access
#   PROJECT_NUMBERS — space-separated list of GitHub Projects V2 numbers
#   ORG             — GitHub organization name
#
# Optional:
#   PROJECT_NUMBER  — single board number (fallback if PROJECT_NUMBERS not set)
#
# Output: summary to stderr, total unblocked count to stdout

ORG="${ORG:?ORG env var required}"
PROJECT_NUMBERS="${PROJECT_NUMBERS:-${PROJECT_NUMBER:-}}"
if [[ -z "$PROJECT_NUMBERS" ]]; then
  echo "::error::Either PROJECT_NUMBERS or PROJECT_NUMBER must be set" >&2
  exit 1
fi
STATUS_BLOCKED="${STATUS_BLOCKED:-Blocked}"
STATUS_BACKLOG="${STATUS_BACKLOG:-Backlog}"

TOTAL_UNBLOCKED=0

for PROJECT_NUMBER in $PROJECT_NUMBERS; do
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
    echo "::notice::No 'Blocked' status option found on project #${PROJECT_NUMBER}" >&2
    continue
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
  ' -f projectId="$PROJECT_ID" | jq --arg s "$STATUS_BLOCKED" '[.data.node.items.nodes[] | select(type == "object") | select(.fieldValueByName.name == $s) | select((.content | type) == "object" and .content.number != null)]')

  BLOCKED_COUNT=$(echo "$BLOCKED_ITEMS" | jq 'length')
  echo "::notice::Found ${BLOCKED_COUNT} blocked item(s) on project #${PROJECT_NUMBER}" >&2

  if [[ "$BLOCKED_COUNT" -eq 0 ]]; then
    continue
  fi

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
      gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
        -f body="All blockers and sub-issues resolved — returning to Backlog. This issue is eligible for agent selection again." \
        >/dev/null

      TOTAL_UNBLOCKED=$((TOTAL_UNBLOCKED + 1))
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
done

echo "::notice::Unblocked ${TOTAL_UNBLOCKED} item(s) total" >&2
echo "$TOTAL_UNBLOCKED"
