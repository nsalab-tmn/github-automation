# Technical Reference

## What this repo manages

__DESCRIPTION__

## Documentation map

| Document | Read when... |
|----------|-------------|
| [README.md](../README.md) | First time here |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | About to make changes |
| [Knowledge base](https://github.com/nsalab-tmn/cheburnet-knowledge-base) | Cross-repo conventions |
| This file | Need technical details |

## Technology stack

| Layer | Implementation |
|-------|---------------|
| Configuration management | Ansible |
| Secrets | SOPS with age encryption |
| CI/CD | GitHub Actions |

## SOPS encryption

Per-repo age keypair (following cheburnet convention). Private key in GitHub environment secrets (`SOPS_AGE_KEY`).

## Known gotchas

<!-- Add repo-specific gotchas here -->
