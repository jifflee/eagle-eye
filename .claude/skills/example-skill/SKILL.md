---
name: example-skill
description: Example skill that demonstrates the skill format - customize or delete this
permissions:
  max_tier: T1
  scripts:
    - name: example-data.sh
      tier: T0
    - name: example-update.sh
      tier: T1
---

# Example Skill

This is an example skill that Claude can automatically invoke when relevant.

## When to Use

Claude will use this skill when the user asks about example topics.

## Instructions

When this skill is invoked:

1. Greet the user
2. Explain that this is an example skill
3. Suggest they customize or replace it

## Permissions

This skill demonstrates the permissions block feature (Issue #203):

- **max_tier: T1** - Scripts up to T1 are auto-approved
- **example-data.sh (T0)** - Read-only script, auto-approved
- **example-update.sh (T1)** - Safe write script, auto-approved

When invoked, declared scripts run without permission prompts.

## Notes

- Skills are automatically invoked by Claude based on the description
- Create specific, focused skills for better results
- Use the description field to help Claude know when to invoke the skill
- Use the permissions block to declare scripts for auto-approval
