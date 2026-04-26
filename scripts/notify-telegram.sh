#!/usr/bin/env bash
set -euo pipefail

# notify-telegram.sh — Send a Telegram notification via Bot API
#
# Required environment variables:
#   TELEGRAM_BOT_TOKEN — Telegram bot token (from BotFather)
#   TELEGRAM_CHAT_ID   — Telegram chat/channel ID to send to
#
# Org secrets: TRANSPORTER_BOT_TOKEN, TRANSPORTER_CHAT_ID
# (namespaced to avoid conflicts with per-repo Telegram bots)
#
# Message source (use one):
#   TELEGRAM_MESSAGE   — pre-built HTML message string
#   OR: REVIEW_FILE + PR_REPO + PR_NUMBER + ISSUE_NUMBER + RUN_URL
#       (script builds the message from review.json fields)
#
# Exits 0 on missing credentials or API failure (fail-safe).

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "::warning::TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set — skipping Telegram notification" >&2
  exit 0
fi

if [[ -z "${TELEGRAM_MESSAGE:-}" ]]; then
  REVIEW_FILE="${REVIEW_FILE:-review.json}"
  SUMMARY=$(jq -r '.summary' "$REVIEW_FILE")
  CONFIDENCE=$(jq -r '.confidence' "$REVIEW_FILE")
  PR_URL="https://github.com/${PR_REPO}/pull/${PR_NUMBER}"
  ISSUE_URL="https://github.com/${PR_REPO}/issues/${ISSUE_NUMBER}"

  TELEGRAM_MESSAGE="<b>PR approved — ready to merge</b>

<b>PR:</b> <a href=\"${PR_URL}\">${PR_REPO}#${PR_NUMBER}</a>
<b>Issue:</b> <a href=\"${ISSUE_URL}\">#${ISSUE_NUMBER}</a>
<b>Confidence:</b> ${CONFIDENCE}

${SUMMARY}

<a href=\"${RUN_URL:-}\">View review run</a>"
fi

# Convert markdown backticks to HTML <code> tags for Telegram
TELEGRAM_MESSAGE=$(echo "$TELEGRAM_MESSAGE" | sed 's/`\([^`]*\)`/<code>\1<\/code>/g')

PAYLOAD=$(jq -n \
  --arg chat_id "$TELEGRAM_CHAT_ID" \
  --arg text "$TELEGRAM_MESSAGE" \
  '{chat_id: $chat_id, text: $text, parse_mode: "HTML", disable_web_page_preview: true}')

TMPFILE=$(mktemp)
HTTP_STATUS=$(curl --silent --show-error \
  --request POST \
  --url "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --header "Content-Type: application/json" \
  --data "$PAYLOAD" \
  --output "$TMPFILE" \
  --write-out "%{http_code}") || {
  echo "::warning::Telegram notification failed (curl error)" >&2
  rm -f "$TMPFILE"
  exit 0
}

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "::warning::Telegram API returned HTTP ${HTTP_STATUS}: $(cat "$TMPFILE")" >&2
  rm -f "$TMPFILE"
  exit 0
fi

rm -f "$TMPFILE"
echo "::notice::Telegram notification sent to chat ${TELEGRAM_CHAT_ID}" >&2
