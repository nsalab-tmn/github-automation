#!/usr/bin/env bash
set -euo pipefail

# resolve-kb.sh — Resolve the knowledge base repo, conventions path, and
#                  optional per-project board number for a given repo
#
# Required environment variables:
#   PROJECTS_JSON — JSON array of project definitions
#   TARGET_REPO   — full repo name (owner/name) to look up
#
# Output: "KB_REPO KB_CONV_PATH [PROJECT_NUMBER]" to stdout (space-separated)
#   Falls back to defaults if repo not found in any project
#   PROJECT_NUMBER is omitted if not set per-project (use global default)

PROJECTS_JSON="${PROJECTS_JSON:?PROJECTS_JSON env var required}"
TARGET_REPO="${TARGET_REPO:?TARGET_REPO env var required}"

KB_INFO=$(echo "$PROJECTS_JSON" | jq -r --arg repo "$TARGET_REPO" '
  .[] | select(.repos | index($repo)) |
  "\(.["knowledge-base"]) \(.["conventions-path"]) \(.["project-number"] // "")"
')

if [[ -z "$KB_INFO" || "$KB_INFO" == "null null " ]]; then
  echo "nsalab-tmn/cheburnet-knowledge-base conventions"
else
  echo "$KB_INFO"
fi
