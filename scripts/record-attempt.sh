#!/usr/bin/env bash
set -euo pipefail

# record-attempt.sh — Post an attempt tracking comment on an issue
#
# Required environment variables:
#   GH_TOKEN      — token with issue access
#   ISSUE_REPO    — full repo name (owner/name)
#   ISSUE_NUMBER  — issue number
#   STATUS        — attempt status (completed, failed, not-workable, blocked)
#   BRIEF         — 1-2 sentence summary of what was attempted
#   RESULT        — 1-2 sentence outcome
#   RUN_URL       — link to this workflow run
#   RUN_NUMBER    — workflow run number
#
# Optional:
#   FILES_TOUCHED — comma-separated list of files (default: "none")
#   BLOCKERS      — markdown list of blockers (for not-workable status)

ISSUE_REPO="${ISSUE_REPO:?ISSUE_REPO env var required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER env var required}"
STATUS="${STATUS:?STATUS env var required}"
BRIEF="${BRIEF:-N/A}"
RESULT="${RESULT:-N/A}"
RUN_URL="${RUN_URL:?RUN_URL env var required}"
RUN_NUMBER="${RUN_NUMBER:?RUN_NUMBER env var required}"
FILES_TOUCHED="${FILES_TOUCHED:-none}"
BLOCKERS="${BLOCKERS:-}"

ATTEMPT=$(gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
  --jq '[.[] | select(.body | test("<!-- agent:attempt:"))] | length' 2>/dev/null || echo "0")
ATTEMPT=$((ATTEMPT + 1))

BLOCKERS_SECTION=""
if [[ -n "$BLOCKERS" ]]; then
  BLOCKERS_SECTION="**Blockers:**
${BLOCKERS}
"
fi

BODY="<!-- agent:attempt:${ATTEMPT} -->
**Agent attempt #${ATTEMPT}** — [run #${RUN_NUMBER}](${RUN_URL})
**Status:** ${STATUS}
**Brief:** ${BRIEF}
${BLOCKERS_SECTION}**Result:** ${RESULT}
**Files touched:** ${FILES_TOUCHED}
<!-- /agent:attempt:${ATTEMPT} -->"

gh api "repos/${ISSUE_REPO}/issues/${ISSUE_NUMBER}/comments" \
  -f body="$BODY" >/dev/null
