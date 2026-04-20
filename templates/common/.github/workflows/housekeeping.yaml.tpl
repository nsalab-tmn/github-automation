name: housekeeping
run-name: "[${{github.run_number}}] Housekeeping [${{github.event_name}}]"

on:
  issues:
    types: [opened]
  pull_request:
    types: [opened, synchronize, edited, labeled, unlabeled]

jobs:
  auto-assign:
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-assign.yaml@main
    with:
      default-assignee: __DEFAULT_ASSIGNEE__
__AUTO_PROJECT_BLOCK__
  auto-label:
    if: github.event_name == 'pull_request'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-auto-label.yaml@main
    with:
      label-config: |
        __LABEL_CONFIG__

  pr-validate:
    needs: auto-label
    if: github.event_name == 'pull_request'
    uses: nsalab-tmn/github-automation/.github/workflows/reusable-pr-validate.yaml@main
    with:
      require-issue: true
      require-labels: true
      require-description: true
