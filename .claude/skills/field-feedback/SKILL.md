---
name: field-feedback
description: Report bugs, enhancements, or configuration issues from consumer repos back to the claude-tastic framework repo
permissions:
  max_tier: T1
  scripts:
    - name: submit-feedback.sh
      tier: T1
---

# Field Feedback Skill

This skill allows consumer repositories using the claude-tastic framework to report bugs, enhancement requests, and configuration issues back to the source claude-tastic repository.

## When to Use

Claude will use this skill when the user wants to:
- Report a bug in the framework
- Suggest an enhancement to the framework
- Report configuration issues or compatibility problems
- Provide feedback about framework behavior

## Instructions

When this skill is invoked:

1. Parse the feedback type from command line flags (--bug, --enhancement, --config)
2. Collect the feedback message from the user
3. Gather context information:
   - Consumer repository identifier
   - Framework version being used
   - Error context (if applicable)
   - Environment details
4. Create a structured GitHub issue in the claude-tastic source repository
5. Confirm issue creation with the user and provide the issue URL

## Usage

```bash
/field-feedback --bug "Container launch fails on M1 Mac"
/field-feedback --enhancement "Add support for custom Docker images"
/field-feedback --config "Keychain not found on Linux"
```

## Permissions

This skill has T1 (safe write) permissions:
- **submit-feedback.sh (T1)** - Creates GitHub issues in the source repository

## Implementation Notes

- The skill determines the source repository from the framework installation
- Issues are created with appropriate labels (bug, enhancement, config)
- Context is automatically captured to help with triage and debugging
- Duplicate detection helps avoid spam
