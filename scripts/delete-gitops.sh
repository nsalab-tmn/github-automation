#!/usr/bin/env bash
set -euo pipefail

# delete-gitops.sh — Remove a gitops repo entry from Terraform config and create a PR
# Called by delete-gitops.yaml workflow
#
# Required environment variables:
#   PROJECT_NAME, ISSUE_NUMBER, ORG
# Optional:
#   JUSTIFICATION

log() { echo "::group::$1"; }
endlog() { echo "::endgroup::"; }

# --- Validation ---

log "Validating inputs"

if [[ ! "${PROJECT_NAME}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "::error::Invalid project name: ${PROJECT_NAME} (must be lowercase alphanumeric with hyphens)"
  exit 1
fi

REPO_NAME="${PROJECT_NAME}-gitops"
JUSTIFICATION="${JUSTIFICATION:-}"

endlog

# --- Check if repo exists ---

log "Checking if repo exists"

if ! gh repo view "${ORG}/${REPO_NAME}" &>/dev/null; then
  echo "::error::Repository ${ORG}/${REPO_NAME} does not exist"
  exit 1
fi

endlog

# --- Check if project is in config ---

log "Checking if project is in config"

export CONFIG_FILE="terraform/configs/gitops-projects.yaml"

if ! grep -v '^\s*#' "${CONFIG_FILE}" | grep -q "name: ${PROJECT_NAME}$"; then
  echo "::error::Project ${PROJECT_NAME} not found in ${CONFIG_FILE}"
  exit 1
fi

endlog

# --- Remove project from config ---

log "Removing project from gitops config"

python3 << 'PYEOF'
import yaml, os

config_file = os.environ["CONFIG_FILE"]
project_name = os.environ["PROJECT_NAME"]

with open(config_file) as f:
    config = yaml.safe_load(f)

config["gitops_repos"] = [
    r for r in config.get("gitops_repos", [])
    if r["name"] != project_name
]

with open(config_file, "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
PYEOF

endlog

# --- Create branch and PR ---

log "Creating branch and PR"

BRANCH="infra/${ISSUE_NUMBER}-delete-${PROJECT_NAME}-gitops"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git checkout -b "${BRANCH}"
git add "${CONFIG_FILE}"
git commit -m "Remove ${REPO_NAME} from Terraform config

Closes #${ISSUE_NUMBER}"
git push origin "${BRANCH}"

PR_URL=$(gh pr create \
  --title "Delete gitops repo: ${REPO_NAME}" \
  --body "$(cat <<EOF
## Summary

Delete \`${ORG}/${REPO_NAME}\` by removing it from Terraform config.

**WARNING**: Merging this PR will permanently delete the repository and all its contents.

## Justification

${JUSTIFICATION}

Closes #${ISSUE_NUMBER}
EOF
)")

echo "pr-url=${PR_URL}" >> "$GITHUB_OUTPUT"

endlog

echo "::notice::PR created: ${PR_URL}"
