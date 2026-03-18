---
description: Example slash command - customize or delete this
---

# Example Command

This is an example slash command. You can invoke it with `/example`.

## Usage

Type `/example` in Claude Code to see this message.

## Customization

Edit this file to change the command behavior, or delete it and create your own commands.

## Creating New Commands

1. Create a new `.md` file in the `commands/` directory
2. Add frontmatter with a description
3. Write the command instructions
4. Sync changes with `sync.sh push`

## Token Optimization

This is a template skill demonstrating best practices for token efficiency:

**Current implementation:**
- Minimal instructional content (template only)
- No data gathering operations
- No external script calls needed

**Best practices for new commands:**
- ✅ Delegate data gathering to shell scripts (e.g., `./scripts/command-name-data.sh`)
- ✅ Use `jq` for JSON parsing instead of Claude analysis
- ✅ Batch API calls (GitHub, etc.) in scripts rather than sequential calls
- ✅ Return structured JSON from scripts for direct presentation
- ✅ Include a "Token Optimization" section documenting efficiency measures

**Token usage:**
- Current: ~200 tokens (minimal template)
- Target for real commands: 400-800 tokens with data script optimization
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Example optimization pattern:**
```bash
# Instead of multiple sequential gh calls:
gh issue list --state open
gh issue view 123
gh pr list --state merged

# Use a single data script:
./scripts/my-command-data.sh --issue 123
# Returns all needed data in one JSON response
```

**Related:**
- `/audit-skills` - Analyze skills for optimization opportunities
- `/skill-sync` - Sync skill changes across environments
