#!/usr/bin/env bash
set -euo pipefail

# post-review.sh — Post a PR review and handle REQUEST_CHANGES board transition
#
# Required environment variables:
#   GH_TOKEN           — token with PR and project access
#   PR_REPO            — full repo name (owner/name)
#   PR_NUMBER          — PR number
#   ISSUE_NUMBER       — linked issue number
#   PROJECT_NUMBER     — GitHub Projects V2 project number
#   STATUS_IN_PROGRESS — board column name for In Progress
#   REVIEW_FILE        — path to review.json (Decide phase output)
#   RUN_URL            — link to this workflow run
#   RUN_NUMBER         — workflow run number
#
# Output: notices to stderr

PR_REPO="${PR_REPO:?PR_REPO env var required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER env var required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER env var required}"
PROJECT_NUMBER="${PROJECT_NUMBER:?PROJECT_NUMBER env var required}"
STATUS_IN_PROGRESS="${STATUS_IN_PROGRESS:?STATUS_IN_PROGRESS env var required}"
REVIEW_FILE="${REVIEW_FILE:-review.json}"
RUN_URL="${RUN_URL:?RUN_URL env var required}"
RUN_NUMBER="${RUN_NUMBER:?RUN_NUMBER env var required}"

DECISION=$(jq -r '.decision' "$REVIEW_FILE")
CONFIDENCE=$(jq -r '.confidence' "$REVIEW_FILE")
SUMMARY=$(jq -r '.summary' "$REVIEW_FILE")
ADDRESSES=$(jq -r 'if .addresses_issue then "x" else " " end' "$REVIEW_FILE")
FOLLOWS=$(jq -r 'if .follows_conventions then "x" else " " end' "$REVIEW_FILE")
MINIMAL=$(jq -r 'if .minimal_change then "x" else " " end' "$REVIEW_FILE")
ISSUES=$(jq -r '.issues_found | if length > 0 then map("- **\(.severity)** `\(.file)`:\(.line) — \(.description)") | join("\n") else "" end' "$REVIEW_FILE")

REVIEW_EVENT=$(echo "$DECISION" | sed 's/approve/APPROVE/;s/request_changes/REQUEST_CHANGES/;s/comment/COMMENT/')

# --- Post PR review ---

ISSUES_SECTION=""
if [[ -n "$ISSUES" ]]; then
  ISSUES_SECTION="### Issues Found

${ISSUES}"
fi

BODY="<!-- review-agent -->
## Review Agent Assessment

**Decision:** ${REVIEW_EVENT} | **Confidence:** ${CONFIDENCE}

### Summary
${SUMMARY}

### Checks
- [${ADDRESSES}] Addresses linked issue
- [${FOLLOWS}] Follows conventions
- [${MINIMAL}] Minimal and focused change

${ISSUES_SECTION}

---
*Reviewed by [review agent](${RUN_URL})*
<!-- /review-agent -->"

gh api "repos/${PR_REPO}/pulls/${PR_NUMBER}/reviews" \
  -f event="$REVIEW_EVENT" \
  -f body="$BODY"

echo "::notice::Posted ${REVIEW_EVENT} review on PR #${PR_NUMBER}" >&2

# --- Handle REQUEST_CHANGES ---

if [[ "$DECISION" != "request_changes" ]]; then
  exit 0
fi

echo "::notice::Handling REQUEST_CHANGES — posting issue feedback and updating board" >&2

# Post feedback on linked issue for engineering agent
ATTEMPT=$(gh api "repos/${PR_REPO}/issues/${ISSUE_NUMBER}/comments" \
  --jq '[.[] | select(.body | test("<!-- review:attempt:"))] | length' 2>/dev/null || echo "0")
ATTEMPT=$((ATTEMPT + 1))

COMMENT="<!-- review:attempt:${ATTEMPT} -->
**Review agent attempt #${ATTEMPT}** — [run #${RUN_NUMBER}](${RUN_URL})
**Decision:** REQUEST_CHANGES

**Issues to fix:**
${ISSUES}

**Summary:** ${SUMMARY}
<!-- /review:attempt:${ATTEMPT} -->"

gh api "repos/${PR_REPO}/issues/${ISSUE_NUMBER}/comments" \
  -f body="$COMMENT" >/dev/null

# Move linked issue from In review → In progress
# (bot review events don't trigger project-sync, so we do it directly)
ISSUE_ID=$(gh api "repos/${PR_REPO}/issues/${ISSUE_NUMBER}" --jq '.node_id' 2>/dev/null || echo "")

if [[ -z "$ISSUE_ID" || "$ISSUE_ID" == "null" ]]; then
  echo "::warning::Could not get issue node ID — skipping board update" >&2
  exit 0
fi

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
IN_PROGRESS_ID=$(echo "$PROJECT_DATA" | jq -r --arg s "$STATUS_IN_PROGRESS" \
  '.data.organization.projectV2.field.options[] | select(.name == $s) | .id')

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

if [[ -n "$ITEM_ID" && "$ITEM_ID" != "null" ]]; then
  gh api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
        value: { singleSelectOptionId: $optionId }
      }) { projectV2Item { id } }
    }
  ' -f projectId="$PROJECT_ID" -f itemId="$ITEM_ID" \
    -f fieldId="$STATUS_FIELD_ID" -f optionId="$IN_PROGRESS_ID" >/dev/null
  echo "::notice::Moved issue #${ISSUE_NUMBER} to In progress" >&2
fi
