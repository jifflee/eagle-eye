---
name: skill-builder
description: Interactive wizard to build and test Claude Code extensions (skills, hooks, actions, commands, agents) locally with scaffolding, validation, and optional framework contribution
permissions:
  max_tier: T1
  scripts:
    - name: skill-builder.sh
      tier: T1
    - name: validate-extension.sh
      tier: T0
    - name: test-extension.sh
      tier: T1
    - name: submit-to-framework.sh
      tier: T1
---

# Skill Builder

Interactive wizard to create, validate, test, and deploy Claude Code extensions locally.

**Feature:** #991 - Add skill builder for local hook/action/skill development

## When to Use

Claude will use this skill when the user wants to:
- Create a new skill, hook, action, command, or agent
- Build custom Claude Code extensions
- Scaffold boilerplate for framework extensions
- Test extensions locally before deployment
- Submit contributions to the framework repository
- Learn how to build Claude Code extensions

## Usage

```bash
# Interactive mode - wizard guides you through creation
/skill-builder

# Quick create with type specified
/skill-builder --type skill --name my-skill

# Create from template
/skill-builder --type hook --template pre-commit

# Validate existing extension
/skill-builder --validate path/to/extension

# Test extension locally
/skill-builder --test path/to/extension

# Submit to framework repo
/skill-builder --submit path/to/extension
```

## Instructions

When this skill is invoked:

### 1. Extension Type Selection

Present options to user:
- **Skill** - Custom slash command that Claude can invoke (e.g., `/my-skill`)
- **Hook** - Runtime hook for Claude operations (e.g., permission checks, validation)
- **Action** - Automated action triggered by events
- **Command** - CLI command for developer tools
- **Agent** - Specialized AI agent with specific capabilities

### 2. Interactive Wizard

Guide the user through:

#### For Skills:
- Skill name (kebab-case, e.g., `my-skill`)
- Description (when Claude should invoke it)
- Permission tier (T0=read, T1=safe write, T2=bash, T3=destructive)
- Required parameters
- Example usage
- Template selection (basic, audit, deployment, data-sync)

#### For Hooks:
- Hook type (pre-tool-use, permission-decision, validation, webhook)
- Trigger conditions
- Hook location (.claude/hooks/ or scripts/hooks/)
- Template selection (permission-check, validation, metrics-capture, webhook)

#### For Actions:
- Action name
- Trigger events
- Dependencies
- Configuration requirements

#### For Commands:
- Command name
- Purpose and functionality
- Arguments and flags
- Installation location

#### For Agents:
- Agent name and specialization
- Tools/capabilities
- Model configuration
- Integration points

### 3. Scaffolding

Generate appropriate file structure:

**For Skills:**
```
core/skills/<skill-name>/
├── SKILL.md           # Metadata and documentation
├── <skill-name>.sh    # Main implementation
└── lib/               # Optional: helper scripts
    └── utils.sh
```

**For Hooks:**
```
.claude/hooks/<hook-name>.sh    # Runtime hook
# OR
scripts/hooks/<hook-name>       # Git hook
```

**For Actions:**
```
.claude/actions/<action-name>/
├── action.yaml        # Action metadata
└── <action-name>.sh   # Implementation
```

**For Agents:**
```
src/agents/<agent-name>/
├── __init__.py        # Agent module
├── agent.py           # Agent implementation
└── config.yaml        # Agent configuration
```

### 4. Template Application

Apply selected template with:
- Correct boilerplate code
- Permission tier configuration
- Error handling patterns
- Logging setup
- Documentation structure
- Usage examples

### 5. Local Validation

Run validation checks:
- ✅ File structure correct
- ✅ Naming conventions followed
- ✅ SKILL.md/metadata properly formatted
- ✅ Required fields present
- ✅ Permission tiers declared correctly
- ✅ Shell scripts have proper shebang and permissions
- ✅ No syntax errors
- ✅ Dependencies available

### 6. Local Testing

Guide user through testing:
- Deploy to `.claude/` directory
- Run test cases
- Verify expected behavior
- Check logs for errors
- Test permission prompts (if applicable)
- Validate integration with framework

### 7. Optional Submission

If user approves, submit to framework:
- Prepare contribution bundle
- Include all necessary files
- Generate PR description
- Submit via GitHub API or create local branch
- Provide submission instructions

### 8. Completion

Show summary:
- ✅ Files created
- ✅ Location of extension
- ✅ How to use/invoke it
- ✅ Next steps (testing, deployment, submission)
- ✅ Documentation links

## Permissions

This skill has T1 (safe write) permissions:
- **skill-builder.sh (T1)** - Creates files in core/skills/, .claude/, scripts/
- **validate-extension.sh (T0)** - Reads and validates extension files
- **test-extension.sh (T1)** - Deploys and tests extensions locally
- **submit-to-framework.sh (T1)** - Creates GitHub issues/PRs for contributions

## Templates Provided

### Skill Templates
- **basic** - Simple skill with read-only operations
- **audit** - Audit/analysis skill pattern
- **deployment** - Deployment/orchestration skill
- **data-sync** - Data synchronization skill

### Hook Templates
- **permission-check** - Permission decision hook
- **validation** - Output validation hook
- **metrics-capture** - Metrics collection hook
- **webhook** - External webhook integration
- **pre-commit** - Git pre-commit hook
- **post-commit** - Git post-commit hook

### Action Templates
- **event-triggered** - React to framework events
- **scheduled** - Periodic execution
- **webhook-receiver** - Handle external webhooks

### Agent Templates
- **specialist** - Domain-specific agent
- **reviewer** - Code/PR review agent
- **orchestrator** - Multi-agent coordinator

### Command Templates
- **cli-tool** - Standard CLI command
- **dev-tool** - Developer utility

## Implementation Notes

- All generated files follow framework conventions
- Permission tiers are properly configured
- Scripts include error handling and logging
- Documentation is auto-generated from user input
- Validation ensures framework compatibility
- Local deployment allows immediate testing
- Submission workflow integrates with framework repo
- Templates are kept up-to-date with framework standards

## Security Considerations

- Only creates files in approved locations (core/, .claude/, scripts/)
- Validates all user input
- Sanitizes file names and paths
- Checks permission tiers before applying
- Prevents overwriting existing extensions without confirmation
- Submission to framework repo requires user approval
- All operations are logged

## Configuration

No additional configuration required. Works out of the box.

Optional: Configure framework repository for submissions in `config/corporate-mode.yaml`:

```yaml
corporate_mode:
  framework_repo: "owner/claude-tastic"  # For submitting contributions
```

## Related Skills

- **/capture** - Quick issue capture (simpler, less structured)
- **/capture-framework** - Submit feedback to framework
- **/skill-sync** - Sync skills from framework to local
- **/example** - Example skill to reference

## Examples

### Create a New Skill

```bash
$ /skill-builder

🎨 Claude Code Extension Builder
=================================

Select extension type:
  1. Skill - Custom slash command
  2. Hook - Runtime hook
  3. Action - Event-driven action
  4. Command - CLI tool
  5. Agent - Specialized AI agent

Your choice: 1

📝 Creating a new skill...

Skill name (kebab-case): my-audit-skill
Description: Audit code quality and generate improvement reports
Permission tier (T0/T1/T2/T3): T0

Select template:
  1. Basic (read-only)
  2. Audit (recommended for your use case)
  3. Deployment
  4. Data sync

Your choice: 2

✨ Generating skill...

Created:
  ✅ core/skills/my-audit-skill/SKILL.md
  ✅ core/skills/my-audit-skill/my-audit-skill.sh
  ✅ core/skills/my-audit-skill/lib/report-generator.sh

Validation:
  ✅ File structure correct
  ✅ Naming conventions followed
  ✅ SKILL.md properly formatted
  ✅ Permission tier (T0) configured
  ✅ No syntax errors

Next steps:
  1. Review and customize: core/skills/my-audit-skill/
  2. Test locally: /skill-builder --test my-audit-skill
  3. Deploy: ./scripts/deploy-skill.sh my-audit-skill
  4. Use: /my-audit-skill

Would you like to test it now? (y/n): y

🧪 Testing my-audit-skill...
  ✅ Deployed to .claude/skills/my-audit-skill/
  ✅ Skill is invocable
  ✅ All checks passed

Your skill is ready to use! Try: /my-audit-skill
```

### Create a Pre-Commit Hook

```bash
$ /skill-builder --type hook --template pre-commit

📝 Creating pre-commit hook...

Hook name: check-dependencies
Description: Verify all dependencies are available before commit

✨ Generating hook...

Created:
  ✅ scripts/hooks/pre-commit-check-dependencies.sh
  ✅ Hook template applied
  ✅ Made executable

Next steps:
  1. Customize: scripts/hooks/pre-commit-check-dependencies.sh
  2. Install: ./scripts/hooks/install-hooks.sh
  3. Test: git commit (will trigger hook)

Hook ready for use!
```

### Validate Existing Extension

```bash
$ /skill-builder --validate core/skills/my-skill

🔍 Validating extension: my-skill

Structure:
  ✅ Directory structure correct
  ✅ SKILL.md present and valid
  ✅ Main script present: my-skill.sh
  ✅ Executable permissions set

Metadata:
  ✅ Name matches directory: my-skill
  ✅ Description provided
  ✅ Permission tier declared: T1
  ✅ Scripts listed in permissions block

Code Quality:
  ✅ Shebang present: #!/usr/bin/env bash
  ✅ Error handling: set -euo pipefail
  ✅ No shellcheck errors
  ✅ Logging functions used

Documentation:
  ✅ Usage examples provided
  ✅ Instructions clear
  ✅ Examples present

✅ Validation passed! Extension is ready for deployment.
```

### Submit to Framework

```bash
$ /skill-builder --submit core/skills/my-skill

📤 Preparing submission to framework repository...

Extension: my-skill
Type: skill
Files:
  - core/skills/my-skill/SKILL.md
  - core/skills/my-skill/my-skill.sh
  - core/skills/my-skill/lib/utils.sh

Creating contribution bundle...

Would you like to:
  1. Create GitHub issue with contribution
  2. Create local branch for PR
  3. Export as tarball

Your choice: 1

Creating issue in framework repo: owner/claude-tastic...

✅ Issue created: #1234
   Title: [Contribution] New skill: my-skill
   URL: https://github.com/owner/claude-tastic/issues/1234

Your contribution has been submitted!
The maintainers will review and may contact you for additional information.
```

## Future Enhancements

- VSCode extension integration
- GUI-based builder (web interface)
- Template marketplace
- Automated testing framework
- CI/CD integration for extensions
- Collaborative extension development
- Extension analytics and metrics
- Dependency management for complex extensions
- Multi-file skill support with libraries
- Extension versioning and updates
