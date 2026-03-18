---
description: Scaffold a new skill using framework templates
argument-hint: "<skill-name> [--domain DOMAIN]"
global: true
---

# Create Skill

Scaffold a new skill for your consumer repository using framework templates and best practices.

## Usage

```
/local:create-skill <skill-name>              # Interactive mode
/local:create-skill deploy --domain release   # Create with domain prefix
/local:create-skill my-tool --domain tool     # Create tool:my-tool
```

## Steps

### 1. Validate Skill Name

- Check naming conventions (lowercase, hyphens only)
- Verify domain namespace if provided
- Ensure skill doesn't already exist

### 2. Gather Skill Details

Prompt for:
- **Description**: One-line summary (required)
- **Domain**: Namespace (issue, pr, milestone, audit, ops, repo, local, release, sprint, tool)
- **Argument hint**: Usage pattern (e.g., "ISSUE_NUMBER [--flag]")
- **Permission tier**: 1 (read-only), 2 (write), or 3 (destructive)

### 3. Create Skill File

Generate `.claude/commands/{domain}-{name}.md` with:

```markdown
---
description: {description}
argument-hint: "{argument-hint}"
---

# {Title}

{description}

## Usage

```
/{domain}-{name} {argument-hint}
```

## Steps

### 1. [Step Name]

Describe what this step does.

## Notes

- Document any important considerations
- List related skills
- Note permission tier if applicable
```

### 4. Register in Manifest

Add entry to `.claude/.manifest.json`:

```json
{
  "core/commands/{domain}-{name}.md": {
    "target": "commands/{domain}-{name}.md",
    "category": "commands",
    "hash": "<computed-sha256>",
    "size": <file-size>
  }
}
```

### 5. Display Next Steps

Show:
- File created at: `.claude/commands/{domain}-{name}.md`
- Invoke with: `/{domain}-{name}`
- Edit the file to implement logic
- Run `/tool:skill-sync` to sync with framework if needed

## Notes

- New skills are automatically detected by Claude
- Follow SKILL_FORMAT.md conventions
- Use existing skills as reference templates
- Consider token optimization from the start
