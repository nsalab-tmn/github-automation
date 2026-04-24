#!/usr/bin/env bash
set -euo pipefail

# set-board-status.sh — Update an issue's status on the project board
#
# Required environment variables:
#   GH_TOKEN        — token with project access
#   ISSUE_ID        — issue node ID (GraphQL ID)
#   PROJECT_NUMBER  — GitHub Projects V2 project number
#   TARGET_STATUS   — target status name (e.g. "In progress", "Blocked", "Backlog")
#
# Output: notice to stderr on success

ISSUE_ID="${ISSUE_ID:?ISSUE_ID env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
TARGET_STATUS="${TARGET_STATUS:?TARGET_STATUS env var required}"

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
' -f org=nsalab-tmn -F number="$PROJECT_NUMBER")

PROJECT_ID=$(echo "$PROJECT_DATA" | jq -r '.data.organization.projectV2.id')
STATUS_FIELD_ID=$(echo "$PROJECT_DATA" | jq -r '.data.organization.projectV2.field.id')
OPTION_ID=$(echo "$PROJECT_DATA" | jq -r --arg s "$TARGET_STATUS" \
  '.data.organization.projectV2.field.options[] | select(.name == $s) | .id')

if [[ -z "$OPTION_ID" || "$OPTION_ID" == "null" ]]; then
  echo "::warning::Status option '${TARGET_STATUS}' not found on project board" >&2
  exit 0
fi

ITEM_ID=$(gh api graphql -f query='
  query($issueId: ID!) {
    node(id: $issueId) {
      ... on Issue {
        projectItems(first: 10) {
          nodes { id project { number } }
        }
      }
    }
  }
' -f issueId="$ISSUE_ID" | jq -r --argjson pn "$PROJECT_NUMBER" \
  '.data.node.projectItems.nodes[] | select(.project.number == $pn) | .id')

if [[ -z "$ITEM_ID" || "$ITEM_ID" == "null" ]]; then
  echo "::warning::Issue not found on project board #${PROJECT_NUMBER}" >&2
  exit 0
fi

gh api graphql -f query='
  mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
      value: { singleSelectOptionId: $optionId }
    }) { projectV2Item { id } }
  }
' -f projectId="$PROJECT_ID" -f itemId="$ITEM_ID" \
  -f fieldId="$STATUS_FIELD_ID" -f optionId="$OPTION_ID" >/dev/null

echo "::notice::Board status → ${TARGET_STATUS}" >&2
