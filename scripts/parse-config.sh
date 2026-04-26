#!/usr/bin/env bash
set -euo pipefail

# parse-config.sh — Parse a YAML agent config and output key=value pairs
#
# Required environment variables:
#   CONFIG_FILE — path to the YAML config file
#
# Output: key=value pairs to stdout (for $GITHUB_OUTPUT)

CONFIG_FILE="${CONFIG_FILE:?CONFIG_FILE env var required}"

python3 -c "
import yaml, json

with open('${CONFIG_FILE}') as f:
    config = yaml.safe_load(f)

agent = config['agent']
print(f\"project_number={agent['project-number']}\")

# Collect all unique project board numbers (per-project overrides + top-level default)
board_nums = set([agent['project-number']])
for proj in config.get('projects', []):
    if 'project-number' in proj:
        board_nums.add(proj['project-number'])
print(f\"project_numbers={' '.join(str(n) for n in sorted(board_nums))}\")

# Optional fields with defaults
print(f\"max_attempts={agent.get('max-attempts', 3)}\")
print(f\"max_review_attempts={agent.get('max-review-attempts', 3)}\")
print(f\"max_file_count={agent.get('max-file-count', 10)}\")
print(f\"max_diff_lines={agent.get('max-diff-lines', 499)}\")
print(f\"timeout_minutes={agent.get('timeout-minutes', 30)}\")
print(f\"auto_merge={agent.get('auto-merge', False)}\")

# Label arrays
for key in ['excluded-labels', 'require-labels', 'require-pr-labels', 'excluded-pr-labels', 'eligible-statuses']:
    val = agent.get(key, [])
    safe_key = key.replace('-', '_')
    print(f'{safe_key}={json.dumps(val)}')

# Status column names
status = agent.get('status', {})
for key in ['backlog', 'blocked', 'in-progress', 'in-review', 'done']:
    val = status.get(key, key.replace('-', ' ').title())
    safe_key = 'status_' + key.replace('-', '_')
    print(f'{safe_key}={val}')

# Projects
projects = json.dumps(config.get('projects', []))
print(f'projects={projects}')

# Allowed repos — flattened from all projects
all_repos = []
for proj in config.get('projects', []):
    all_repos.extend(proj.get('repos', []))
print(f\"allowed_repos={json.dumps(sorted(set(all_repos)))}\")
"
