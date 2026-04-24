#!/usr/bin/env python3
"""Decide layer: review an AI-generated PR against its linked issue."""

import json
import sys

import anthropic


def load_file(path):
    with open(path) as f:
        return f.read()


def main():
    context_file = sys.argv[1] if len(sys.argv) > 1 else "pr-context.json"
    prompt_file = sys.argv[2] if len(sys.argv) > 2 else "prompts/review-brief.md"
    schema_file = sys.argv[3] if len(sys.argv) > 3 else "schemas/review-pr.json"

    context = json.loads(load_file(context_file))
    system_prompt = load_file(prompt_file)
    schema = json.loads(load_file(schema_file))

    client = anthropic.Anthropic()

    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=4096,
        temperature=0,
        system=system_prompt,
        tools=[schema],
        tool_choice={"type": "tool", "name": "review_pr"},
        messages=[
            {
                "role": "user",
                "content": (
                    f"## Pull Request to review\n\n"
                    f"**Repo:** {context['repo']}\n"
                    f"**PR #{context['pr']['number']}:** "
                    f"{context['pr']['title']}\n"
                    f"**Labels:** {', '.join(context['pr'].get('labels', []))}\n"
                    f"**Branch:** {context['pr'].get('head_ref', 'unknown')}\n\n"
                    f"### PR body\n\n{context['pr'].get('body', '(empty)')}\n\n"
                    f"### CI status\n\n"
                    f"Combined: {context.get('ci_status', 'unknown')}\n"
                    f"{format_checks(context.get('ci_checks', []))}\n\n"
                    f"### Diff\n\n```diff\n{context.get('diff', '(empty)')}\n```\n\n"
                    f"## Linked issue\n\n"
                    f"{format_issue(context.get('linked_issue', {}))}\n\n"
                    f"### Issue comments\n\n"
                    f"{format_comments(context.get('issue_comments', []))}\n\n"
                    f"### Previous reviews\n\n"
                    f"{format_reviews(context.get('pr_reviews', []))}\n\n"
                    f"## Repository documentation\n\n"
                    f"### README.md\n\n"
                    f"{context['repo_docs'].get('readme', '(not found)')}\n\n"
                    f"### CONTRIBUTING.md\n\n"
                    f"{context['repo_docs'].get('contributing', '(not found)')}\n\n"
                    f"### docs/conventions.md\n\n"
                    f"{context['repo_docs'].get('conventions', '(not found)')}\n\n"
                    f"## Knowledge base conventions\n\n"
                    f"{format_kb(context.get('kb_conventions', {}))}"
                ),
            }
        ],
    )

    for block in response.content:
        if block.type == "tool_use" and block.name == "review_pr":
            print(json.dumps(block.input, indent=2))
            return

    print("Error: no tool_use block in response", file=sys.stderr)
    sys.exit(1)


def format_checks(checks):
    if not checks:
        return "(no checks)"
    lines = []
    for c in checks:
        icon = "✅" if c.get("conclusion") == "success" else "❌" if c.get("conclusion") == "failure" else "⏳"
        lines.append(f"- {icon} {c.get('name', 'unknown')}: {c.get('conclusion', c.get('status', 'pending'))}")
    return "\n".join(lines)


def format_issue(issue):
    if not issue or not issue.get("number"):
        return "(no linked issue found)"
    labels = ", ".join(issue.get("labels", []))
    return (
        f"**Issue #{issue['number']}:** {issue.get('title', 'untitled')}\n"
        f"**Labels:** {labels}\n\n"
        f"{issue.get('body', '(empty body)')}"
    )


def format_comments(comments):
    if not comments:
        return "(no comments)"
    lines = []
    for c in comments:
        lines.append(f"**{c.get('author', 'unknown')}** ({c.get('created_at', '')}):")
        lines.append(c.get("body", ""))
        lines.append("")
    return "\n".join(lines)


def format_reviews(reviews):
    if not reviews:
        return "(no previous reviews)"
    lines = []
    for r in reviews:
        lines.append(f"**{r.get('author', 'unknown')}** — {r.get('state', '')} ({r.get('submitted_at', '')}):")
        body = r.get("body", "")
        if body:
            lines.append(body[:500])
        lines.append("")
    return "\n".join(lines)


def format_kb(kb):
    if not kb:
        return "(no conventions found)"
    lines = []
    for filename, content in kb.items():
        lines.append(f"### {filename}\n\n{content}\n")
    return "\n".join(lines)


if __name__ == "__main__":
    main()
