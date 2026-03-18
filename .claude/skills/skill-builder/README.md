# Skill Builder

Interactive wizard to create, validate, test, and deploy Claude Code extensions locally.

**Feature:** #991 - Add skill builder for local hook/action/skill development

## Quick Start

```bash
# Interactive mode - wizard guides you through creation
./core/skills/skill-builder/skill-builder.sh

# Validate an existing extension
./core/skills/skill-builder/validate-extension.sh core/skills/my-skill

# Test an extension locally
./core/skills/skill-builder/test-extension.sh core/skills/my-skill

# Submit to framework repository
./core/skills/skill-builder/submit-to-framework.sh core/skills/my-skill
```

## What Can You Build?

The skill builder helps you create:

1. **Skills** - Custom slash commands (e.g., `/my-skill`)
2. **Hooks** - Runtime hooks for Claude operations
3. **Actions** - Event-driven actions
4. **Commands** - CLI tools
5. **Agents** - Specialized AI agents

## Features

- ✨ **Interactive wizard** - Guided step-by-step creation
- 📋 **Templates** - Pre-built templates for common patterns
- ✅ **Validation** - Ensure framework compliance
- 🧪 **Local testing** - Test before deployment
- 📤 **Easy submission** - Submit to framework repo
- 📚 **Documentation** - Auto-generated docs from input

## Files

```
skill-builder/
├── SKILL.md                      # Skill metadata
├── skill-builder.sh              # Main interactive wizard
├── validate-extension.sh         # Validation utility
├── test-extension.sh             # Testing utility
├── submit-to-framework.sh        # Submission utility
├── README.md                     # This file
└── templates/                    # Templates for each type
    ├── skills/
    │   ├── basic.template        # Basic skill template
    │   └── audit.template        # Audit skill template
    └── hooks/
        ├── basic.template        # Basic hook template
        ├── permission-check.template
        ├── validation.template
        └── webhook.template
```

## Templates

### Skill Templates

- **basic** - Simple read-only skill
- **audit** - Audit/analysis skill with reporting

### Hook Templates

- **basic** - Basic hook structure
- **permission-check** - Permission decision hook
- **validation** - Validation hook
- **webhook** - Webhook integration hook

## Usage Examples

### Create a New Skill

```bash
$ ./core/skills/skill-builder/skill-builder.sh

# Follow the interactive prompts:
# 1. Select "Skill - Custom slash command"
# 2. Enter skill name: my-audit-skill
# 3. Enter description
# 4. Select permission tier: T0
# 5. Choose template: Audit

# Result: core/skills/my-audit-skill/ created
```

### Create a Hook

```bash
$ ./core/skills/skill-builder/skill-builder.sh

# Follow the prompts:
# 1. Select "Hook - Runtime hook"
# 2. Enter hook name: my-validation-hook
# 3. Select hook type: Claude runtime hook
# 4. Choose template: Validation

# Result: .claude/hooks/my-validation-hook.sh created
```

### Validate Extension

```bash
# Validate a skill
./core/skills/skill-builder/validate-extension.sh core/skills/my-skill

# Validate a hook
./core/skills/skill-builder/validate-extension.sh .claude/hooks/my-hook.sh
```

### Test Extension

```bash
# Test skill locally (deploys to .claude/skills/)
./core/skills/skill-builder/test-extension.sh core/skills/my-skill

# Test hook
./core/skills/skill-builder/test-extension.sh .claude/hooks/my-hook.sh
```

### Submit to Framework

```bash
# Submit via GitHub issue (default)
./core/skills/skill-builder/submit-to-framework.sh core/skills/my-skill

# Submit via local branch
./core/skills/skill-builder/submit-to-framework.sh core/skills/my-skill --method branch

# Export as tarball
./core/skills/skill-builder/submit-to-framework.sh core/skills/my-skill --method tarball
```

## Validation Checks

The validator checks for:

### Skills
- ✅ SKILL.md exists and properly formatted
- ✅ YAML frontmatter present
- ✅ Required fields (name, description, permissions)
- ✅ Name matches directory
- ✅ Main script exists and executable
- ✅ Shebang present
- ✅ Error handling configured
- ✅ Usage function defined
- ✅ Naming convention (kebab-case)
- ✅ Shellcheck passes (if available)

### Hooks/Scripts
- ✅ File exists and executable
- ✅ Shebang present
- ✅ Error handling configured
- ✅ Logging implemented
- ✅ Shellcheck passes (if available)

## Testing Process

1. **Deploy** - Copies extension to `.claude/` directory
2. **Execute** - Tests basic execution
3. **Validate** - Checks structure and format
4. **Report** - Shows results and next steps

## Submission Methods

### 1. GitHub Issue (Recommended)

Creates an issue in the framework repository with:
- Extension description
- Files included
- Environment details
- Testing checklist

**Requirements:**
- GitHub CLI (`gh`) installed
- Framework repo configured in `config/corporate-mode.yaml`

### 2. Local Branch

Creates a local git branch with your extension:
- Branch name: `contrib/{type}/{name}`
- Ready for PR submission

### 3. Tarball

Exports extension as `.tar.gz` file for:
- Manual sharing
- Email to maintainers
- File transfer

## Configuration

### Framework Repository

To enable submission to framework, configure in `config/corporate-mode.yaml`:

```yaml
corporate_mode:
  framework_repo: "owner/claude-tastic"
```

### Permission Tiers

Choose appropriate tier for your skill:
- **T0** - Read-only operations (Grep, Read, Glob)
- **T1** - Safe writes (Edit, Write)
- **T2** - Bash commands (with restrictions)
- **T3** - Destructive operations (requires approval)

## Best Practices

1. **Use descriptive names** - kebab-case, clear purpose
2. **Add comprehensive documentation** - Help others understand usage
3. **Include examples** - Show real-world usage
4. **Validate early** - Run validator before testing
5. **Test thoroughly** - Test all code paths
6. **Handle errors gracefully** - Use `set -euo pipefail`
7. **Add logging** - Use structured logging
8. **Follow conventions** - Match existing patterns

## Troubleshooting

### Validation Fails

```bash
# Check what failed
./core/skills/skill-builder/validate-extension.sh core/skills/my-skill

# Common fixes:
chmod +x core/skills/my-skill/my-skill.sh  # Make executable
# Add shebang: #!/usr/bin/env bash
# Add error handling: set -euo pipefail
```

### Testing Fails

```bash
# Check logs
tail -f ~/.claude-tastic/hooks/my-hook.log

# Try manual execution
./core/skills/my-skill/my-skill.sh --help
```

### Submission Fails

```bash
# Check GitHub CLI auth
gh auth status

# Re-authenticate
gh auth login

# Check framework repo configured
grep framework_repo config/corporate-mode.yaml
```

## Advanced Usage

### Custom Templates

Add your own templates to `templates/` directory:

```bash
# Create custom template
cat > templates/skills/custom.template <<'EOF'
#!/usr/bin/env bash
# Custom template for {{NAME}}
set -euo pipefail
# Your custom boilerplate here
EOF
```

### Batch Validation

Validate multiple extensions:

```bash
for skill in core/skills/*/; do
    echo "Validating $(basename "$skill")..."
    ./core/skills/skill-builder/validate-extension.sh "$skill"
done
```

### CI Integration

Add to your CI pipeline:

```yaml
# .github/workflows/validate-skills.yml
- name: Validate Skills
  run: |
    for skill in core/skills/*/; do
      ./core/skills/skill-builder/validate-extension.sh "$skill" || exit 1
    done
```

## Related

- **/capture** - Quick issue capture
- **/capture-framework** - Submit framework feedback
- **/skill-sync** - Sync skills from framework
- **SKILL.md format** - See `core/skills/example-skill/SKILL.md`

## Development

### Run Tests

```bash
./tests/skills/test-skill-builder-simple.sh
```

### Debug Mode

```bash
# Enable debug output
bash -x ./core/skills/skill-builder/skill-builder.sh
```

## Contributing

This skill builder itself was created as part of feature #991. To contribute improvements:

1. Make changes locally
2. Test thoroughly
3. Submit via the skill builder itself! 😊

## License

Part of the Claude Agent Framework.
