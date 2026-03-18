---
name: repo-spec
description: Generate comprehensive technical specification of the claude-agents repository for external review
permissions:
  max_tier: T0
  scripts:
    - name: repo-spec-data.sh
      tier: T0
---

# Repository Technical Specification Generator

Generate a comprehensive, machine-readable technical specification of the claude-agents repository architecture, SDLC workflow, and strategic decisions.

## When to Use

Use this skill when you need to:
- Generate a complete technical overview of the repository for external review
- Share architectural documentation with another Claude instance or external reviewer
- Capture the current state of the repository architecture for documentation
- Provide context to stakeholders about how the system works

## Instructions

When this skill is invoked:

1. Run the `repo-spec-data.sh` script to generate the technical specification
2. Present the generated specification to the user in a readable format
3. Explain what was captured and how it can be used

The specification includes:
- **Architecture**: Agent framework, multi-agent orchestration model, PM-centric delegation
- **SDLC Workflow**: Phases, agent routing, handoff patterns, gate conditions
- **Infrastructure**: Container execution, worktree management, branch strategy (dev→qa→main)
- **Skills System**: How skills work, dispatch patterns, token optimization
- **Hooks System**: Pre-commit, post-commit, UserPromptSubmit, PostToolUse
- **Configuration**: CLAUDE.md layers, agent manifests, sprint-state.json
- **Scripts**: Utility scripts, data scripts, CI/CD scripts
- **Strategy**: Haiku-90% model selection, micro-task pattern, parallel execution

## Output Format

The skill generates a structured JSON document suitable for:
- Machine parsing by other agents
- External review and feedback
- Architectural documentation
- Onboarding new contributors

## Usage Examples

```bash
# Generate full technical specification
/repo-spec

# Generate specification and save to file
/repo-spec --output repo-spec.json

# Generate specification with specific focus areas
/repo-spec --focus architecture,sdlc
```

## Permissions

This skill is **read-only (T0)**:
- **repo-spec-data.sh (T0)** - Reads repository structure and configuration files
- No modifications are made to any files
- Safe to run at any time

## Output Structure

The generated specification is organized into sections:

1. **Repository Metadata** - Name, description, version
2. **Architecture** - Agent framework, orchestration patterns
3. **SDLC Phases** - Design, implementation, review, governance
4. **Agent Catalog** - All agents with roles and capabilities
5. **Skills System** - Skill mechanics, dispatch, permissions
6. **Hooks System** - Git hooks, Claude hooks, webhook integrations
7. **Infrastructure** - Containers, worktrees, branching strategy
8. **Scripts Inventory** - Categorized list of all scripts
9. **Configuration System** - CLAUDE.md layers, manifests, state files
10. **Strategic Decisions** - Model selection, optimization patterns
11. **Integration Points** - n8n, MCP, GitHub, external systems

## Notes

- The specification reflects the **current state** of the repository
- Run periodically to capture changes over time
- The output is designed to be consumed by AI agents, not necessarily human-readable prose
- All information is gathered from existing files; no external API calls are made
