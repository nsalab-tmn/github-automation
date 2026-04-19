# Contributing to github-automation

> Check the [pinned context issue](https://github.com/nsalab-tmn/github-automation/issues) for current state and active work.

## Quick reference

| Task | How |
|------|-----|
| Add a new workflow | Create `reusable-<name>.yml` in `.github/workflows/`, document in `docs/conventions.md` |
| Test a workflow | Call it from a test repo with `@<branch>` ref |
| Update docs | Edit relevant file, update README table if adding a workflow |

## Getting started

1. Read this file
2. Read [docs/conventions.md](docs/conventions.md) for workflow conventions
3. Check the pinned issue for current state and planned work

## Workflow

### Issue-first

Every change starts with an issue. Check existing issues before creating a new one.

### Branching

Branch from `main` using the pattern:

```
feature/<N>-<short-description>
fix/<N>-<short-description>
docs/<N>-<short-description>
```

Where `<N>` is the issue number.

### PR process

1. Branch from `main`
2. Implement the workflow or change
3. Update `docs/conventions.md` with inputs/outputs documentation
4. Update the README workflows table if adding a new workflow
5. PR with summary, test plan (which repo you tested from), and link to issue

### Testing

Reusable workflows cannot be tested in isolation. To test:

1. Push your branch
2. In a test repo, create a caller workflow pointing to `@<your-branch>`
3. Trigger the event (create issue, open PR, etc.)
4. Verify the automation ran correctly
5. Clean up the test caller before merging

### Versioning

Workflows are called with `@main` for latest or `@v1` for stable. When making breaking changes to inputs/outputs:

1. Create a new major version tag
2. Keep the old workflow functional until all callers migrate
3. Document migration steps in the PR
