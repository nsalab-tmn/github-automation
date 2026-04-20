#!/usr/bin/env python3
"""Decide layer: analyze repo state and produce structured review via Claude API."""

import json
import os
import sys

import anthropic

REVIEW_SCHEMA = {
    "name": "repo_review",
    "description": "Structured repo health review with findings and recommendations",
    "input_schema": {
        "type": "object",
        "properties": {
            "health_score": {
                "type": "integer",
                "minimum": 1,
                "maximum": 10,
                "description": "Overall repo health from 1 (critical) to 10 (excellent)",
            },
            "findings": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "type": {
                            "type": "string",
                            "enum": [
                                "stale",
                                "unlabeled",
                                "unassigned",
                                "blocked",
                                "needs_review",
                                "hygiene",
                            ],
                        },
                        "number": {
                            "type": "integer",
                            "description": "Issue or PR number",
                        },
                        "title": {"type": "string"},
                        "recommendation": {"type": "string"},
                    },
                    "required": ["type", "number", "title", "recommendation"],
                },
            },
            "summary": {
                "type": "string",
                "description": "One paragraph overview of repo health",
            },
        },
        "required": ["health_score", "findings", "summary"],
    },
}

SYSTEM_PROMPT = """\
You are a repo health reviewer. You analyze GitHub repository state and produce \
structured findings.

Rules:
- Respond ONLY by calling the repo_review tool. Never respond with plain text.
- health_score: 10 = no issues found, subtract points for findings.
- Finding types and when to use them:
  - stale: issue/PR with no activity for >14 days
  - unlabeled: issue/PR with zero labels
  - unassigned: issue with no assignees
  - blocked: issue/PR that appears stuck
  - needs_review: PR with no review decision
  - hygiene: other housekeeping concerns
- Only report genuine problems. An issue that's open and being worked on is fine.
- Issues labeled "pinned" are exempt from stale/unassigned checks.
- Recommendations should be specific and actionable (e.g., "Close as completed" not "Consider reviewing").
- Keep the summary to 2-3 sentences max.
"""


def main():
    state_file = sys.argv[1] if len(sys.argv) > 1 else "/dev/stdin"

    with open(state_file) as f:
        repo_state = json.load(f)

    client = anthropic.Anthropic()

    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=1024,
        temperature=0,
        system=SYSTEM_PROMPT,
        tools=[REVIEW_SCHEMA],
        tool_choice={"type": "tool", "name": "repo_review"},
        messages=[
            {
                "role": "user",
                "content": f"Review this repository state and produce findings:\n\n```json\n{json.dumps(repo_state, indent=2)}\n```",
            }
        ],
    )

    # Extract tool use response
    for block in response.content:
        if block.type == "tool_use" and block.name == "repo_review":
            review = block.input
            print(json.dumps(review, indent=2))
            return

    print("Error: no tool_use block in response", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
