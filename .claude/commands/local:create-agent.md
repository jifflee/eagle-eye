---
description: Scaffold a new agent with manifest, prompt, and config
argument-hint: "<agent-name> [--type TYPE]"
global: true
---

# Create Agent

Scaffold a new agent for your consumer repository with manifest, prompt template, and configuration.

## Usage

```
/local:create-agent <agent-name>                    # Interactive mode
/local:create-agent custom-reviewer --type reviewer # Create with type
/local:create-agent data-analyst --type specialist  # Create specialist agent
```

## Agent Types

| Type | Purpose | Tools Available |
|------|---------|----------------|
| `specialist` | Domain-specific expert | Selected tool subset |
| `reviewer` | Code/PR review | Read, Grep, Glob, Bash (read-only) |
| `developer` | Implementation agent | All tools except Task |
| `orchestrator` | Multi-agent coordinator | All tools including Task |

## Steps

### 1. Validate Agent Name

- Check naming conventions (lowercase, hyphens only)
- Verify agent doesn't already exist
- Suggest type based on name patterns

### 2. Gather Agent Details

Prompt for:
- **Description**: One-line summary of agent purpose
- **Type**: specialist, reviewer, developer, or orchestrator
- **Model**: haiku (fast/cheap), sonnet (balanced), opus (complex)
- **Tools**: Which tools the agent needs access to

### 3. Create Agent Prompt

Generate `.claude/agents/{agent-name}.md` with:

```markdown
# {Agent Name}

{Description}

## Role

You are a {type} agent specialized in {domain}.

## Responsibilities

- [List primary responsibilities]
- [What this agent should do]
- [What decisions it can make]

## Process

When invoked, follow these steps:

1. **Analyze**: [What to analyze first]
2. **Execute**: [What actions to take]
3. **Report**: [What to communicate back]

## Constraints

- [List any limitations]
- [What the agent should NOT do]
- [When to delegate to other agents]

## Output Format

[Describe expected output structure]
```

### 4. Create Agent Config (if needed)

For agents requiring custom tool access or settings, create config file.

### 5. Register in Manifest

Add entry to `.claude/.manifest.json`:

```json
{
  "core/agents/{agent-name}.md": {
    "target": "agents/{agent-name}.md",
    "category": "agents",
    "hash": "<computed-sha256>",
    "size": <file-size>
  }
}
```

### 6. Display Next Steps

Show:
- Agent created at: `.claude/agents/{agent-name}.md`
- Invoke via: `Task tool with subagent_type: "{agent-name}"`
- Edit the file to implement agent logic
- Test with simple task first

## Notes

- Agents are invoked via the Task tool
- Choose appropriate model for task complexity
- Restrict tools to minimum needed for security
- See AGENTS.md for agent development guide
