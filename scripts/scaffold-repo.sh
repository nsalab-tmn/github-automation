#!/usr/bin/env bash
set -euo pipefail

# scaffold-repo.sh — Create a new repo with org standards
# Called by scaffold-repo.yaml workflow
#
# Required environment variables:
#   REPO_NAME, REPO_TYPE, ORG
# Optional:
#   DESCRIPTION, PROJECT_NUMBER, DEFAULT_ASSIGNEE, PROJECT_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "${WORK_DIR}"' EXIT

log() { echo "::group::$1"; }
endlog() { echo "::endgroup::"; }

# --- Validation ---

log "Validating inputs"

if [[ ! "${REPO_NAME}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "::error::Invalid repo name: ${REPO_NAME} (must be lowercase alphanumeric with hyphens)"
  exit 1
fi

if [[ ! -d "${TEMPLATE_DIR}/${REPO_TYPE}" ]]; then
  echo "::error::Unknown repo type: ${REPO_TYPE} (available: $(ls -1 "${TEMPLATE_DIR}" | grep -v common | tr '\n' ', '))"
  exit 1
fi

endlog

# --- Create repo ---

log "Creating repo nsalab-tmn/${REPO_NAME}"

DESCRIPTION="${DESCRIPTION:-}"

gh repo create "${ORG}/${REPO_NAME}" \
  --private \
  --description "${DESCRIPTION}" \
  --clone \
  --disable-wiki

cd "${REPO_NAME}"
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${ORG}/${REPO_NAME}.git"

endlog

# --- Copy templates ---

log "Copying templates"

# Common templates first
cp -r "${TEMPLATE_DIR}/common/." .

# Type-specific overlay (overrides common files if present)
cp -r "${TEMPLATE_DIR}/${REPO_TYPE}/." .

endlog

# --- Substitute variables ---

log "Substituting template variables"

DEFAULT_ASSIGNEE="${DEFAULT_ASSIGNEE:-menus12}"
PROJECT_NUMBER="${PROJECT_NUMBER:-}"

# Build auto-project block for housekeeping
if [[ -n "${PROJECT_NUMBER}" ]]; then
  AUTO_PROJECT_BLOCK="
  auto-project:
    if: github.event_name == 'issues'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-project.yaml@main
    with:
      project-number: ${PROJECT_NUMBER}
      type-mapping: |
        {
          \"bug\": \"Bug\",
          \"enhancement\": \"Feature\"
        }
    secrets:
      token: \${{ secrets.PROJECT_TOKEN }}
"
else
  AUTO_PROJECT_BLOCK=""
fi

# Build label-config based on repo type
case "${REPO_TYPE}" in
  ansible)
    LABEL_CONFIG='{
          "configuration": ["ansible/**"],
          "ci-cd": [".github/**"],
          "documentation": ["docs/**", "*.md"]
        }'
    ;;
  docs)
    LABEL_CONFIG='{
          "documentation": ["**/*.md"]
        }'
    ;;
esac

# Process .tpl files
find . -name '*.tpl' -type f | while read -r tpl; do
  target="${tpl%.tpl}"
  sed \
    -e "s|__REPO_NAME__|${REPO_NAME}|g" \
    -e "s|__DESCRIPTION__|${DESCRIPTION:-No description provided}|g" \
    -e "s|__DEFAULT_ASSIGNEE__|${DEFAULT_ASSIGNEE}|g" \
    -e "s|__PROJECT_NUMBER__|${PROJECT_NUMBER}|g" \
    -e "s|__SOPS_AGE_PUBLIC_KEY__|REPLACE_WITH_AGE_PUBLIC_KEY|g" \
    "${tpl}" > "${target}"
  rm "${tpl}"
done

# Housekeeping needs special handling for multi-line blocks
if [[ -f ".github/workflows/housekeeping.yaml" ]]; then
  # Replace the auto-project placeholder
  if [[ -n "${AUTO_PROJECT_BLOCK}" ]]; then
    python3 -c "
import sys
content = open('.github/workflows/housekeeping.yaml').read()
content = content.replace('__AUTO_PROJECT_BLOCK__', '''${AUTO_PROJECT_BLOCK}''')
open('.github/workflows/housekeeping.yaml', 'w').write(content)
"
  else
    sed -i '/__AUTO_PROJECT_BLOCK__/d' .github/workflows/housekeeping.yaml
  fi

  # Replace label config
  python3 -c "
content = open('.github/workflows/housekeeping.yaml').read()
content = content.replace('__LABEL_CONFIG__', '''${LABEL_CONFIG}''')
open('.github/workflows/housekeeping.yaml', 'w').write(content)
"
fi

endlog

# --- Commit and push ---

log "Committing and pushing"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -A
git commit -m "Initial scaffolding: documentation, templates, conventions

Created via github-automation scaffold workflow."
git branch -M main
git push -u origin main

endlog

# --- Create labels ---

log "Creating labels"

COMMON_LABELS=(
  "bug:1D76DB:Workflow not behaving as expected"
  "enhancement:a2eeef:New feature or request"
  "documentation:0075ca:Documentation changes"
  "ci-cd:e4e669:CI/CD and workflow changes"
  "pinned:D93F0B:Pinned context issue"
  "stale:cccccc:Inactive issue"
  "in-progress:0E8A16:Work in progress"
  "tech-debt:FBCA04:Technical debt"
)

ANSIBLE_LABELS=(
  "configuration:5319e7:Ansible configuration changes"
  "infrastructure:d4c5f9:Infrastructure changes"
)

DOCS_LABELS=(
  "convention:bfd4f2:Convention documentation"
)

for entry in "${COMMON_LABELS[@]}"; do
  IFS=: read -r name color desc <<< "${entry}"
  gh label create "${name}" --repo "${ORG}/${REPO_NAME}" --color "${color}" --description "${desc}" --force
done

case "${REPO_TYPE}" in
  ansible)
    for entry in "${ANSIBLE_LABELS[@]}"; do
      IFS=: read -r name color desc <<< "${entry}"
      gh label create "${name}" --repo "${ORG}/${REPO_NAME}" --color "${color}" --description "${desc}" --force
    done
    ;;
  docs)
    for entry in "${DOCS_LABELS[@]}"; do
      IFS=: read -r name color desc <<< "${entry}"
      gh label create "${name}" --repo "${ORG}/${REPO_NAME}" --color "${color}" --description "${desc}" --force
    done
    ;;
esac

endlog

# --- Set secrets ---

if [[ -n "${PROJECT_NUMBER}" && -n "${PROJECT_TOKEN:-}" ]]; then
  log "Setting PROJECT_TOKEN secret"
  gh secret set PROJECT_TOKEN --repo "${ORG}/${REPO_NAME}" --body "${PROJECT_TOKEN}"
  endlog
fi

# --- Create and pin context issue ---

log "Creating pinned context issue"

CONTEXT_BODY="## What this repo manages

${DESCRIPTION:-No description provided}

## Key docs

- [docs/conventions.md](../blob/main/docs/conventions.md) — technical reference
- [CONTRIBUTING.md](../blob/main/CONTRIBUTING.md) — how to make changes
- [README.md](../blob/main/README.md) — quick start

## Current state

- [x] Repo scaffolded with org standards
- [ ] Initial implementation

## Recently completed

(none yet)"

gh issue create \
  --repo "${ORG}/${REPO_NAME}" \
  --title "Context: ${REPO_NAME}" \
  --body "${CONTEXT_BODY}" \
  --label "pinned"

# Pin the issue
gh issue pin 1 --repo "${ORG}/${REPO_NAME}"

endlog

echo "::notice::Repository created: https://github.com/${ORG}/${REPO_NAME}"
