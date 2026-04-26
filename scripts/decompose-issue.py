#!/usr/bin/env python3
"""Decide layer: decompose a complex issue into mechanic-sized sub-issues.

Uses Claude Opus with extended thinking for deep reasoning about
dependency graphs, scope boundaries, and phasing.
"""

import json
import sys

import anthropic


def load_file(path):
    with open(path) as f:
        return f.read()


def main():
    context_file = sys.argv[1] if len(sys.argv) > 1 else "issue-context.json"
    prompt_file = sys.argv[2] if len(sys.argv) > 2 else "prompts/planning-brief.md"
    schema_file = sys.argv[3] if len(sys.argv) > 3 else "schemas/decompose-issue.json"

    context = json.loads(load_file(context_file))
    system_prompt = load_file(prompt_file)
    schema = json.loads(load_file(schema_file))

    client = anthropic.Anthropic()

    response = client.messages.create(
        model="claude-opus-4-6",
        max_tokens=32768,
        thinking={
            "type": "adaptive",
        },
        system=system_prompt,
        tools=[schema],
        tool_choice={"type": "auto"},
        messages=[
            {
                "role": "user",
                "content": format_context(context),
            }
        ],
    )

    # Log response shape for debugging
    block_types = [f"{b.type}({b.name})" if hasattr(b, "name") else b.type for b in response.content]
    print(f"Response blocks: {block_types}", file=sys.stderr)
    print(f"Stop reason: {response.stop_reason}", file=sys.stderr)

    for block in response.content:
        if block.type == "tool_use" and block.name == "decompose_issue":
            print(json.dumps(block.input, indent=2))
            return

    # Fallback: print any text blocks for debugging
    for block in response.content:
        if block.type == "text":
            print(f"Text block: {block.text[:500]}", file=sys.stderr)

    print("Error: no tool_use block in response", file=sys.stderr)
    sys.exit(1)


def format_context(ctx):
    issue = ctx.get("issue", {})
    labels = ", ".join(issue.get("labels", []))

    sections = [
        f"## Issue to decompose\n\n"
        f"**Repo:** {ctx.get('repo', 'unknown')}\n"
        f"**Issue #{issue.get('number', '?')}:** {issue.get('title', 'untitled')}\n"
        f"**Labels:** {labels}\n"
        f"**State:** {issue.get('state', 'unknown')}\n\n"
        f"{issue.get('body', '(empty body)')}",
        f"## Issue comments\n\n{format_comments(ctx.get('comments', []))}",
        f"## Repository documentation\n\n"
        f"### README.md\n\n{ctx.get('repo_docs', {}).get('readme', '(not found)')}\n\n"
        f"### CONTRIBUTING.md\n\n{ctx.get('repo_docs', {}).get('contributing', '(not found)')}\n\n"
        f"### docs/conventions.md\n\n{ctx.get('repo_docs', {}).get('conventions', '(not found)')}",
        f"## Pinned issue\n\n{ctx.get('pinned_issue', '(none)')}",
        f"## File tree\n\n```\n{format_file_tree(ctx.get('file_tree', []))}\n```",
        f"## Knowledge base conventions\n\n{format_kb(ctx.get('kb_conventions', {}))}",
        f"## Recent merged PRs\n\n{format_prs(ctx.get('recent_prs', []))}",
        f"## Recent commits\n\n{format_commits(ctx.get('recent_commits', []))}",
        f"## Referenced issues\n\n{format_referenced(ctx.get('referenced_issues', []))}",
    ]

    return "\n\n---\n\n".join(sections)


def format_comments(comments):
    if not comments:
        return "(no comments)"
    lines = []
    for c in comments:
        lines.append(
            f"**{c.get('author', 'unknown')}** ({c.get('created_at', '')}):"
        )
        lines.append(c.get("body", ""))
        lines.append("")
    return "\n".join(lines)


def format_file_tree(tree):
    if not tree:
        return "(empty)"
    return "\n".join(tree[:200])


def format_kb(kb):
    if not kb:
        return "(no conventions found)"
    lines = []
    for filename, content in kb.items():
        lines.append(f"### {filename}\n\n{content}\n")
    return "\n".join(lines)


def format_prs(prs):
    if not prs:
        return "(no recent PRs)"
    lines = []
    for pr in prs:
        labels = ", ".join(pr.get("labels", []))
        lines.append(
            f"- PR #{pr.get('number', '?')}: {pr.get('title', 'untitled')} "
            f"[{labels}] (merged {pr.get('merged_at', 'unknown')})"
        )
    return "\n".join(lines)


def format_commits(commits):
    if not commits:
        return "(no recent commits)"
    lines = []
    for c in commits:
        lines.append(f"- `{c.get('sha', '?')}` {c.get('message', '')}")
    return "\n".join(lines)


def format_referenced(issues):
    if not issues:
        return "(no referenced issues)"
    lines = []
    for i in issues:
        labels = ", ".join(i.get("labels", []))
        lines.append(
            f"- #{i.get('number', '?')}: {i.get('title', 'untitled')} "
            f"[{i.get('state', '?')}] [{labels}]"
        )
    return "\n".join(lines)


if __name__ == "__main__":
    main()
