#!/usr/bin/env bash
set -euo pipefail

# session-summary.sh — Write a session summary to $GITHUB_STEP_SUMMARY
#
# Required environment variables:
#   AGENT_NAME    — "Engineering Agent" or "Review Agent"
#   DRY_RUN       — "true" or "false"
#   SELECTED      — "true" or "false"
#
# Optional (when SELECTED=true):
#   SUMMARY_ITEM  — e.g. "nsalab-tmn/cheburnet-vpn#42" or "PR: repo#N"
#   SUMMARY_EXTRA — additional lines (e.g. issue number)
#   RESULT_FILE   — path to JSON result file (brief.json or review.json)
#   RESULT_FIELDS — jq expression to extract summary fields from RESULT_FILE

AGENT_NAME="${AGENT_NAME:?AGENT_NAME env var required}"
DRY_RUN="${DRY_RUN:-false}"
SELECTED="${SELECTED:-false}"
RESULT_FILE="${RESULT_FILE:-}"
RESULT_FIELDS="${RESULT_FIELDS:-}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "## ${AGENT_NAME} — DRY RUN" >> "$GITHUB_STEP_SUMMARY"
else
  echo "## ${AGENT_NAME} Session" >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$SELECTED" != "true" ]]; then
  echo "No eligible items found." >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

if [[ -n "${SUMMARY_ITEM:-}" ]]; then
  echo "**Item:** ${SUMMARY_ITEM}" >> "$GITHUB_STEP_SUMMARY"
fi

if [[ -n "${SUMMARY_EXTRA:-}" ]]; then
  echo "${SUMMARY_EXTRA}" >> "$GITHUB_STEP_SUMMARY"
fi

if [[ -n "$RESULT_FILE" && -f "$RESULT_FILE" ]]; then
  echo "" >> "$GITHUB_STEP_SUMMARY"

  if [[ -n "$RESULT_FIELDS" ]]; then
    jq -r "$RESULT_FIELDS" "$RESULT_FILE" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi
fi
