#!/usr/bin/env bash
set -euo pipefail

# bootstrap-gitops.sh — Create pinned context issues for newly provisioned gitops repos
# Called by terraform-apply.yaml after successful apply
#
# Required environment variables:
#   ORG, GH_TOKEN

log() { echo "::group::$1"; }
endlog() { echo "::endgroup::"; }

CONFIG_FILE="terraform/configs/gitops-projects.yaml"

# Parse project names from config
PROJECTS=$(python3 -c "
import yaml
with open('${CONFIG_FILE}') as f:
    config = yaml.safe_load(f)
for r in config.get('gitops_repos', []):
    print(r['name'])
")

if [[ -z "${PROJECTS}" ]]; then
  echo "::notice::No gitops projects in config — nothing to bootstrap"
  exit 0
fi

BOOTSTRAPPED=0

for PROJECT_NAME in ${PROJECTS}; do
  REPO_NAME="${PROJECT_NAME}-gitops"
  log "Checking ${ORG}/${REPO_NAME}"

  # Skip if repo doesn't exist yet
  if ! gh repo view "${ORG}/${REPO_NAME}" &>/dev/null; then
    echo "::warning::Repo ${ORG}/${REPO_NAME} does not exist — skipping"
    endlog
    continue
  fi

  # Skip if pinned issue already exists
  EXISTING=$(gh issue list --repo "${ORG}/${REPO_NAME}" --label "pinned" --json number --jq '.[0].number' 2>/dev/null || echo "")
  if [[ -n "${EXISTING}" ]]; then
    echo "Pinned issue #${EXISTING} already exists — skipping"
    endlog
    continue
  fi

  # Get repo description
  DESCRIPTION=$(gh repo view "${ORG}/${REPO_NAME}" --json description --jq '.description // "No description"')

  # Bootstrap pinned label (may not exist yet if gitops repo's TF hasn't run)
  gh label create pinned --repo "${ORG}/${REPO_NAME}" --color "006b75" --description "Pinned context issue" --force 2>/dev/null || true

  # Create pinned context issue
  ISSUE_URL=$(gh issue create \
    --repo "${ORG}/${REPO_NAME}" \
    --title "Context: ${REPO_NAME}" \
    --body "$(cat <<EOF
## What this repo manages

${DESCRIPTION}

## Context

Provisioned via [github-automation](https://github.com/${ORG}/github-automation). See the PR that added this project to \`terraform/configs/gitops-projects.yaml\` for justification.

## Key docs

- [CONTRIBUTING.md](../blob/main/CONTRIBUTING.md) — how to make changes
- [docs/conventions.md](../blob/main/docs/conventions.md) — technical reference
- [repo-provisioning](https://github.com/${ORG}/github-automation/blob/main/docs/repo-provisioning.md) — self-service repo lifecycle

## Quick start

1. Add repos to \`terraform/configs/repos.yaml\` via issue form or PR
2. Configure labels in \`terraform/configs/labels.yaml\` via PR
3. Terraform plan runs on PR, apply on merge

## Current state

- [x] GitOps repo provisioned via Terraform
- [ ] Project repos imported/configured
- [ ] Labels configured
EOF
    )" \
    --label "pinned")

  # Pin the issue
  ISSUE_NUMBER=$(echo "${ISSUE_URL}" | grep -oE '[0-9]+$')
  gh issue pin "${ISSUE_NUMBER}" --repo "${ORG}/${REPO_NAME}" 2>/dev/null || true

  echo "::notice::Created and pinned context issue: ${ISSUE_URL}"
  BOOTSTRAPPED=$((BOOTSTRAPPED + 1))

  endlog
done

echo "::notice::Bootstrapped ${BOOTSTRAPPED} gitops repo(s)"
