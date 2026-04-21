#!/usr/bin/env python3
"""Decide layer: analyze gathered state against conventions via Claude API."""

import json
import sys

import anthropic


def load_file(path):
    with open(path) as f:
        return f.read()


def main():
    state_file = sys.argv[1] if len(sys.argv) > 1 else "drift-state.json"
    prompt_file = sys.argv[2] if len(sys.argv) > 2 else "prompts/drift-review.md"
    schema_file = sys.argv[3] if len(sys.argv) > 3 else "schemas/drift-findings.json"

    state = json.loads(load_file(state_file))
    system_prompt = load_file(prompt_file)
    schema = json.loads(load_file(schema_file))

    client = anthropic.Anthropic()

    response = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=4096,
        temperature=0,
        system=system_prompt,
        tools=[schema],
        tool_choice={"type": "tool", "name": "drift_review"},
        messages=[
            {
                "role": "user",
                "content": (
                    f"Review the following project for convention drift.\n\n"
                    f"## Project: {state['project']}\n\n"
                    f"## Conventions (from knowledge base)\n\n"
                    f"```json\n{json.dumps(state['conventions'], indent=2)}\n```\n\n"
                    f"## Adoption guide\n\n{state['adoption_guide']}\n\n"
                    f"## Repository states\n\n"
                    f"```json\n{json.dumps(state['repos'], indent=2)}\n```"
                ),
            }
        ],
    )

    for block in response.content:
        if block.type == "tool_use" and block.name == "drift_review":
            print(json.dumps(block.input, indent=2))
            return

    print("Error: no tool_use block in response", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
