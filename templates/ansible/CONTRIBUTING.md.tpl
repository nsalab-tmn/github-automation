# Contributing to __REPO_NAME__

> **Before starting work**, check the [pinned context issue](../../issues?q=label%3Apinned+is%3Aopen) for current project state.

## Getting started

1. Read this file
2. Read [docs/conventions.md](docs/conventions.md)
3. Check the pinned context issue for current state
4. Read [cheburnet-knowledge-base](https://github.com/nsalab-tmn/cheburnet-knowledge-base) for cross-repo conventions

## Quick reference

| Task | Command |
|------|---------|
| Plan (dry-run) | `ansible-playbook -i inventory/test.yml playbooks/site.yml --check --diff` |
| Deploy (local) | `ansible-playbook -i inventory/test.yml playbooks/site.yml` |

## Issue-first workflow

All changes start with an issue. No PRs without a tracking issue.

1. Create issue using the appropriate template
2. Branch from `main`: `<type>/<issue-number>-<short-description>`
3. Open PR referencing issue (`Closes #N`)
4. Merge

## Branching

| Prefix | Use for |
|--------|---------|
| `feature/<N>-<desc>` | New capabilities |
| `fix/<N>-<desc>` | Bug fixes |
| `infra/<N>-<desc>` | Infrastructure, roles, CI/CD |
| `docs/<N>-<desc>` | Documentation only |
