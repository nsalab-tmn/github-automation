#!/usr/bin/env bash
set -euo pipefail

# scaffold-gitops.sh — Add a gitops repo entry to Terraform config and create a PR
# Called by scaffold-gitops.yaml workflow
#
# Required environment variables:
#   PROJECT_NAME, ISSUE_NUMBER, ORG
# Optional:
#   DESCRIPTION, JUSTIFICATION

log() { echo "::group::$1"; }
endlog() { echo "::endgroup::"; }

# --- Validation ---

log "Validating inputs"

if [[ ! "${PROJECT_NAME}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "::error::Invalid project name: ${PROJECT_NAME} (must be lowercase alphanumeric with hyphens)"
  exit 1
fi

REPO_NAME="${PROJECT_NAME}-gitops"
DESCRIPTION="${DESCRIPTION:-}"
JUSTIFICATION="${JUSTIFICATION:-}"

endlog

# --- Check if repo already exists ---

log "Checking if repo already exists"

if gh repo view "${ORG}/${REPO_NAME}" &>/dev/null; then
  echo "::error::Repository ${ORG}/${REPO_NAME} already exists"
  exit 1
fi

endlog

# --- Add project to config ---

log "Adding project to gitops config"

CONFIG_FILE="terraform/configs/gitops-projects.yaml"

if grep -q "name: ${PROJECT_NAME}$" "${CONFIG_FILE}"; then
  echo "::error::Project ${PROJECT_NAME} already exists in ${CONFIG_FILE}"
  exit 1
fi

python3 << 'PYEOF'
import yaml, os

config_file = os.environ["CONFIG_FILE"]
project_name = os.environ["PROJECT_NAME"]
description = os.environ["DESCRIPTION"]

with open(config_file) as f:
    config = yaml.safe_load(f)

if config.get("gitops_repos") is None:
    config["gitops_repos"] = []

config["gitops_repos"].append({
    "name": project_name,
    "description": description
})

with open(config_file, "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
PYEOF

endlog

# --- Create branch and PR ---

log "Creating branch and PR"

BRANCH="infra/${ISSUE_NUMBER}-add-${PROJECT_NAME}-gitops"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git checkout -b "${BRANCH}"
git add "${CONFIG_FILE}"
git commit -m "Add ${REPO_NAME} to Terraform config

Closes #${ISSUE_NUMBER}"
git push origin "${BRANCH}"

PR_URL=$(gh pr create \
  --title "Add gitops repo: ${REPO_NAME}" \
  --body "$(cat <<EOF
## Summary

Create \`${ORG}/${REPO_NAME}\` from \`template-gitops\` template.

## Justification

${JUSTIFICATION}

Closes #${ISSUE_NUMBER}
EOF
)")

echo "pr-url=${PR_URL}" >> "$GITHUB_OUTPUT"

endlog

echo "::notice::PR created: ${PR_URL}"
