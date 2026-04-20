# __REPO_NAME__

__DESCRIPTION__

> **Contributors**: see [CONTRIBUTING.md](CONTRIBUTING.md) for workflow and [docs/conventions.md](docs/conventions.md) for full technical context.

## Quick Start

```bash
cd ansible/
ansible-playbook -i inventory/test.yml playbooks/site.yml --check --diff   # plan
ansible-playbook -i inventory/test.yml playbooks/site.yml                 # deploy
```

## Repository Structure

```
ansible/
  ansible.cfg             Ansible configuration
  requirements.yml        Galaxy dependencies
  roles/                  Ansible roles
  inventory/              Targets
    group_vars/           Shared config + SOPS-encrypted credentials
  playbooks/
    site.yml              Full deployment
docs/
  conventions.md          Technical reference
```

## Related repos

| Repo | Relationship |
|------|-------------|
| [cheburnet-knowledge-base](https://github.com/nsalab-tmn/cheburnet-knowledge-base) | Cross-repo conventions |
