---
name: capture-framework
description: Submit feedback about the framework to the source claude-tastic repository
permissions:
  max_tier: T1
  scripts:
    - name: capture-framework.sh
      tier: T1
---

# Capture Framework Feedback Skill

This skill enables cross-repo feedback by allowing consumer repositories to submit issues back to the claude-tastic framework repository.

**Feature:** #686 - Corporate mode - approved methods and restrictions

## When to Use

Claude will use this skill when the user wants to:
- Report a bug in the framework from a consumer repository
- Suggest an enhancement to the framework
- Report that a framework feature is broken or not working as expected
- Submit feedback about framework behavior
- Report skill-sync issues or configuration problems

## Usage

```bash
# Report a framework bug
/capture --framework "skill-sync purged a skill I still need"

# Suggest a framework enhancement
/capture --framework "Add support for custom agent templates"

# Report configuration issue
/capture --framework "Corporate mode config not loading correctly"
```

## Instructions

When this skill is invoked:

1. **Validation:**
   - Check that framework_repo is configured in corporate-mode.yaml
   - If not configured, prompt user to set framework_repo
   - Verify GitHub CLI (gh) is available

2. **Gather Information:**
   - Parse the feedback message from the command
   - Collect context information:
     - Consumer repository name/URL
     - Framework version (if detectable)
     - Current configuration snapshot (relevant sections)
     - Error logs or traces (if applicable)
     - User environment (OS, shell, etc.)

3. **Create Issue:**
   - Use GitHub API to create issue in framework repository
   - Title format: `[Consumer Feedback] <brief summary>`
   - Body includes:
     - Original feedback message
     - Source repository context
     - Environment details
     - Relevant configuration
   - Add labels: `feedback`, `from-consumer`
   - Add label for issue type if clear: `bug`, `enhancement`, `config`

4. **Confirmation:**
   - Show issue URL to user
   - Confirm successful submission
   - Provide issue number for reference

5. **Corporate Mode Integration:**
   - This operation is always approved in corporate mode
   - GitHub API access to framework_repo is a default approved method
   - Operation is logged in audit trail

## Permissions

This skill has T1 (safe write) permissions:
- **capture-framework.sh (T1)** - Creates GitHub issues in the framework repository

## Implementation Notes

- Framework repository URL is read from config/corporate-mode.yaml (framework_repo field)
- Uses GitHub CLI (gh) for API access
- Requires GH_TOKEN or GITHUB_TOKEN environment variable
- Automatically captures context to help with triage
- Duplicate detection prevents spam
- All submissions are logged in corporate mode audit trail

## Security Considerations

- Only submits to configured framework repository
- Does not expose sensitive data (credentials, secrets)
- Sanitizes error messages before submission
- Respects corporate mode network restrictions
- All operations are audited

## Configuration

Add framework repository to config/corporate-mode.yaml:

```yaml
corporate_mode:
  framework_repo: "owner/claude-tastic"  # Your framework repository
```

## Related Skills

- **/field-feedback** - Original field feedback skill (similar functionality)
- **/approve-method** - Manage corporate mode approvals
- **/capture** - General issue capture (creates issues in current repo)

## Examples

### Submit Framework Bug

```bash
$ /capture --framework "skill-sync purged a skill I still need"

Creating issue in framework repository: owner/claude-tastic

Issue created successfully:
  Title: [Consumer Feedback] skill-sync purged a skill I still need
  URL: https://github.com/owner/claude-tastic/issues/123
  Number: #123
  Labels: feedback, from-consumer, bug

Your feedback has been submitted to the framework maintainers.
They will review and respond in the GitHub issue.
```

### Framework Repository Not Configured

```bash
$ /capture --framework "Some feedback"

❌ Error: Framework repository not configured

To use /capture --framework, add the framework repository to config/corporate-mode.yaml:

corporate_mode:
  framework_repo: "owner/claude-tastic"

Then try again.
```

## Issue Template

Issues created by this skill use this template:

```markdown
## Consumer Feedback

**From Repository:** consumer-org/consumer-repo
**Submitted By:** user@example.com
**Date:** 2024-01-15T10:30:00Z

### Feedback

{user's feedback message}

### Environment

- OS: macOS 14.2
- Shell: bash 5.2.15
- Framework Version: {detected or unknown}

### Configuration

{relevant config sections}

### Additional Context

{any error logs or traces}

---

This issue was automatically created by the /capture --framework skill from a consumer repository.
```

## Future Enhancements

- Attachment support for logs/screenshots
- Automatic version detection
- Integration with framework issue templates
- Batch submission for multiple feedback items
- Anonymous submission option (privacy mode)
