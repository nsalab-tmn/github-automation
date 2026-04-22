#!/usr/bin/env python3
"""Decide layer: assess workability and compile context into implementation brief."""

import json
import sys

import anthropic


def load_file(path):
    with open(path) as f:
        return f.read()


def main():
    context_file = sys.argv[1] if len(sys.argv) > 1 else "issue-context.json"
    prompt_file = sys.argv[2] if len(sys.argv) > 2 else "prompts/engineering-brief.md"
    schema_file = sys.argv[3] if len(sys.argv) > 3 else "schemas/compile-brief.json"

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
        tool_choice={"type": "tool", "name": "compile_brief"},
        messages=[
            {
                "role": "user",
                "content": (
                    f"## Issue to implement\n\n"
                    f"**Repo:** {context['repo']}\n"
                    f"**Issue #{context['issue']['number']}:** "
                    f"{context['issue']['title']}\n"
                    f"**Labels:** {', '.join(context['issue'].get('labels', []))}\n\n"
                    f"### Issue body\n\n{context['issue'].get('body', '(empty)')}\n\n"
                    f"### Comments\n\n"
                    f"{format_comments(context.get('comments', []))}\n\n"
                    f"## Repository documentation\n\n"
                    f"### README.md\n\n"
                    f"{context['repo_docs'].get('readme', '(not found)')}\n\n"
                    f"### CONTRIBUTING.md\n\n"
                    f"{context['repo_docs'].get('contributing', '(not found)')}\n\n"
                    f"### docs/conventions.md\n\n"
                    f"{context['repo_docs'].get('conventions', '(not found)')}\n\n"
                    f"## Pinned issue\n\n"
                    f"{context.get('pinned_issue', '(not found)')}\n\n"
                    f"## Knowledge base conventions\n\n"
                    f"{format_kb(context.get('kb_conventions', {}))}\n\n"
                    f"## File tree\n\n"
                    f"```\n{format_file_tree(context.get('file_tree', []))}\n```\n\n"
                    f"## Recent merged PRs\n\n"
                    f"{format_prs(context.get('recent_prs', []))}\n\n"
                    f"## Recent commits\n\n"
                    f"{format_commits(context.get('recent_commits', []))}\n\n"
                    f"## Referenced issues\n\n"
                    f"{format_refs(context.get('referenced_issues', []))}"
                ),
            }
        ],
    )

    for block in response.content:
        if block.type == "tool_use" and block.name == "compile_brief":
            print(json.dumps(block.input, indent=2))
            return

    print("Error: no tool_use block in response", file=sys.stderr)
    sys.exit(1)


def format_comments(comments):
    if not comments:
        return "(no comments)"
    lines = []
    for c in comments:
        lines.append(f"**{c.get('author', 'unknown')}** ({c.get('created_at', '')}):")
        lines.append(c.get("body", ""))
        lines.append("")
    return "\n".join(lines)


def format_kb(kb):
    if not kb:
        return "(no conventions found)"
    lines = []
    for filename, content in kb.items():
        lines.append(f"### {filename}\n\n{content}\n")
    return "\n".join(lines)


def format_file_tree(tree):
    if not tree:
        return "(empty)"
    return "\n".join(tree[:200])  # Cap at 200 entries


def format_prs(prs):
    if not prs:
        return "(no recent PRs)"
    lines = []
    for pr in prs:
        labels = ", ".join(pr.get("labels", []))
        lines.append(f"- #{pr['number']} {pr['title']} [{labels}]")
    return "\n".join(lines)


def format_commits(commits):
    if not commits:
        return "(no recent commits)"
    lines = []
    for c in commits:
        lines.append(f"- {c['sha']} {c['message']}")
    return "\n".join(lines)


def format_refs(refs):
    if not refs:
        return "(no referenced issues)"
    lines = []
    for r in refs:
        labels = ", ".join(r.get("labels", []))
        lines.append(f"- #{r['number']} {r['title']} ({r['state']}) [{labels}]")
    return "\n".join(lines)


if __name__ == "__main__":
    main()
