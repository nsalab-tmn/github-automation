# Contributing to __REPO_NAME__

> This is a knowledge base, not a code repo. Articles are the primary deliverable.

## When to add an article

- A convention or pattern is used in 2+ repos
- A design decision affects the project as a whole
- A procedure spans multiple repos

## When NOT to add an article

- The knowledge is specific to one repo — use that repo's `docs/conventions.md`
- It's derivable from the code or git history

## Article structure

1. **What** — one paragraph explaining the concept
2. **Why** — the motivation or constraint
3. **How** — the actual pattern or procedure
4. **Cross-references** — links to repos/issues where this applies

## File organization

```
conventions/    — shared standards across repos
architecture/   — how the system fits together
decisions/      — why things are the way they are
runbooks/       — step-by-step procedures
```

## Workflow

1. Branch from `main`: `docs/<issue-number>-<short-description>`
2. Add or update article(s)
3. Update the README table if adding a new article
4. PR with a brief description
