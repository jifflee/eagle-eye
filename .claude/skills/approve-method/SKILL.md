---
name: approve-method
description: Approve additional methods (tools, MCP servers, network hosts) for corporate mode
permissions:
  max_tier: T1
  scripts:
    - name: approve-method.sh
      tier: T1
---

# Approve Method Skill

This skill allows users to extend the approved methods list in corporate mode by approving additional tools, MCP servers, network hosts, or git remotes.

**Feature:** #686 - Corporate mode - approved methods and restrictions

## When to Use

Claude will use this skill when the user wants to:
- Approve a previously blocked tool (e.g., WebSearch, WebFetch)
- Approve an MCP server for use in corporate mode
- Approve a network host for external API access
- Approve a git remote for push/pull operations
- List current approved methods
- Revoke a previously granted approval

## Philosophy

**Deny by default. Minimal surface. Skills can extend.**

Corporate mode blocks most operations by default. This skill provides the mechanism to selectively approve operations while maintaining auditability.

## Usage

```bash
# Approve an MCP server
/approve-method --type mcp --target "context7" --reason "Documentation lookup"

# Approve a tool
/approve-method --type tool --target "WebSearch" --reason "Research tasks"

# Approve a network host
/approve-method --type network --target "api.example.com" --reason "Integration with Example API"

# Approve a git remote
/approve-method --type git --target "git@github.com:org/repo.git" --reason "Sync with upstream"

# List current approvals
/approve-method --list

# List approvals by type
/approve-method --list --type mcp

# Revoke an approval
/approve-method --revoke --type mcp --target "context7"
```

## Instructions

When this skill is invoked:

1. **Validation:**
   - Verify corporate mode is enabled (warn if not, but allow config changes)
   - Validate required parameters (--type, --target, --reason for approvals)
   - Verify the target is not already approved

2. **For Approvals (no --list or --revoke):**
   - Check that type is valid: mcp, tool, network, git
   - Require --reason to be provided (for audit trail)
   - Check max_dynamic_approvals limits
   - Add approval to config/corporate-mode.yaml under dynamic_approvals
   - Record: type, target, reason, approved_by (user), approved_at (timestamp)
   - Log the approval in audit trail
   - Confirm approval to user with summary

3. **For Listing (--list):**
   - Read dynamic_approvals from config/corporate-mode.yaml
   - Display approvals in a formatted table
   - Show: type, target, reason, approved_by, approved_at
   - Filter by --type if provided

4. **For Revocation (--revoke):**
   - Require --type and --target
   - Remove matching approval from dynamic_approvals
   - Log the revocation in audit trail
   - Confirm revocation to user

5. **Output:**
   - Clear confirmation message
   - Show current approval count by type
   - Remind user of corporate mode policy

## Permissions

This skill has T1 (safe write) permissions:
- **approve-method.sh (T1)** - Updates corporate mode configuration file

## Implementation Notes

- Approvals are stored in config/corporate-mode.yaml under dynamic_approvals
- Each approval includes metadata: type, target, reason, approved_by, approved_at
- Changes require explicit user action (no auto-approve)
- Audit trail logs all approvals and revocations
- Maximum limits prevent approval sprawl (configurable in corporate-mode.yaml)

## Security Considerations

- Approvals are session-scoped to the project configuration
- All approvals are logged in the audit trail
- Revocations are immediate and logged
- Users should regularly review approvals using --list
- Corporate administrators can audit via audit logs in ~/.claude-tastic/corporate-audit/

## Related Skills

- **/revoke-method** - Alias for `/approve-method --revoke`
- **/approved-methods** - Alias for `/approve-method --list`
- **/capture --framework** - Submit feedback to framework repo (uses approved GitHub API access)

## Examples

### Approve WebSearch for Research

```bash
$ /approve-method --type tool --target "WebSearch" --reason "Research competitive analysis"

✅ Approved: tool 'WebSearch'
Reason: Research competitive analysis
Approved by: user@example.com
Approved at: 2024-01-15T10:30:00Z

Current approvals:
- MCP servers: 1/10
- Tools: 1/5
- Network hosts: 0/5
- Git remotes: 0/3

Note: This approval is stored in config/corporate-mode.yaml and logged in the audit trail.
```

### List Current Approvals

```bash
$ /approve-method --list

Corporate Mode Approved Methods
================================

MCP Servers (1/10):
  - context7
    Reason: Documentation lookup
    Approved: 2024-01-15T09:00:00Z by user@example.com

Tools (1/5):
  - WebSearch
    Reason: Research competitive analysis
    Approved: 2024-01-15T10:30:00Z by user@example.com

Network Hosts (0/5):
  (none)

Git Remotes (0/3):
  (none)
```

### Revoke an Approval

```bash
$ /approve-method --revoke --type tool --target "WebSearch"

✅ Revoked: tool 'WebSearch'

Current approvals:
- MCP servers: 1/10
- Tools: 0/5
- Network hosts: 0/5
- Git remotes: 0/3
```

## Future Enhancements

- Expiration dates for temporary approvals
- Role-based approval workflows
- Integration with corporate policy management systems
- Automated approval suggestions based on usage patterns
