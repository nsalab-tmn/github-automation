# Security

## Reporting a vulnerability

If you discover a security issue in this repo's workflows, please report it privately via [GitHub Security Advisories](https://github.com/nsalab-tmn/github-automation/security/advisories/new) rather than opening a public issue.

For issues affecting the nsalab-tmn organization or its private repositories, contact the maintainers directly.

## Scope

This repo contains reusable GitHub Actions workflows. Security reports are welcome for:

- Workflow injection vulnerabilities (untrusted input in unsafe contexts)
- Secret exfiltration risks in workflow logic
- Permission escalation through workflow design
- Supply chain concerns in action dependencies

Out of scope: the organization's private repositories, infrastructure, and cloud resources.

## Supply chain context

These workflows are called by other repositories via `@main`. A merged change takes effect immediately across all consumers. Workflow modifications are reviewed with this in mind — changes to reusable workflows carry elevated risk.

## Credential handling

No secrets, tokens, or credentials are stored in this repository. All sensitive values are passed at runtime via GitHub Secrets and are automatically masked in workflow logs.
