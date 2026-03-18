---
description: Interactive wizard to customize framework settings for this repo
argument-hint: "[--reset] [--show]"
---

# Customize Framework

Interactive wizard to customize Claude Agent Framework settings for your repository.

## Usage

```
/local:customize        # Run interactive wizard
/local:customize --show # Show current settings
/local:customize --reset # Reset to framework defaults
```

## Customizable Settings

### 1. Model Preferences

Configure default models for different agent types:

| Agent Type | Default | Options |
|------------|---------|---------|
| Orchestrators | sonnet | sonnet, opus, haiku |
| Reviewers | haiku | haiku, sonnet |
| Developers | sonnet | sonnet, opus, haiku |
| Specialists | haiku | haiku, sonnet |

### 2. Permission Tiers

Enable/disable permission tiers:

- **Tier 1** (Read-only): Always enabled
- **Tier 2** (Write): Enable for repository modifications?
- **Tier 3** (Destructive): Enable for force-push, branch deletion?

### 3. Workflow Behavior

Customize workflow defaults:

- **Auto-merge PRs**: Auto-merge when all checks pass? (yes/no)
- **Auto-create issues**: Create issues from /capture? (yes/no)
- **Auto-checkout issues**: Claim issues when starting work? (yes/no)
- **Require PR reviews**: Minimum review count (0-3)

### 4. Branch Strategy

Configure branch names:

- **Main branch**: `main` or `master`
- **Development branch**: `dev`, `develop`, or custom
- **QA branch**: `qa`, `staging`, or none
- **Feature prefix**: `feat/`, `feature/`, or custom
- **Hotfix prefix**: `hotfix/`, `fix/`, or custom

### 5. CI/CD Integration

Configure CI/CD behavior:

- **Run tests on PR**: Always, on-demand, or never
- **Required checks**: List of required CI check names
- **Block merge on failure**: Strict or permissive

### 6. Skill Visibility

Choose which skill domains to enable:

- ✅ Issue management (issue:*)
- ✅ PR workflow (pr:*)
- ✅ Milestone tracking (milestone:*)
- ✅ Release management (release:*)
- ❌ Sprint automation (sprint:*) - disable if not using
- ✅ Repository audits (audit:*)
- ❌ Framework ops (ops:*) - disable for consumers
- ✅ Local tools (local:*)
- ✅ Tool utilities (tool:*)

## Configuration File

Settings saved to `.claude/project-config.json`:

```json
{
  "models": {
    "orchestrator": "sonnet",
    "reviewer": "haiku",
    "developer": "sonnet",
    "specialist": "haiku"
  },
  "permissions": {
    "tier2_enabled": true,
    "tier3_enabled": false
  },
  "workflow": {
    "auto_merge": false,
    "auto_create_issues": true,
    "auto_checkout": true,
    "min_reviews": 1
  },
  "branches": {
    "main": "main",
    "dev": "dev",
    "qa": "qa",
    "feature_prefix": "feat/",
    "hotfix_prefix": "hotfix/"
  },
  "ci": {
    "run_tests": "always",
    "required_checks": ["build", "test", "lint"],
    "block_on_failure": true
  },
  "skills": {
    "issue": true,
    "pr": true,
    "milestone": true,
    "release": true,
    "sprint": false,
    "audit": true,
    "ops": false,
    "local": true,
    "tool": true
  }
}
```

## Interactive Wizard Flow

1. **Welcome**: Explain customization options
2. **Model Selection**: Choose models for each agent type
3. **Permission Levels**: Select enabled tiers
4. **Workflow Preferences**: Configure automation behavior
5. **Branch Configuration**: Set branch names and prefixes
6. **CI/CD Settings**: Configure test and check requirements
7. **Skill Domains**: Enable/disable skill groups
8. **Review & Confirm**: Show settings preview
9. **Save**: Write to `.claude/project-config.json`
10. **Reload**: Suggest reloading Claude to apply changes

## Notes

- Changes take effect after reloading Claude
- Settings are repository-specific
- Can be version-controlled or gitignored
- Override framework defaults without modifying core files
- Use `--reset` to restore framework defaults
- Use `--show` to view current configuration without changing
