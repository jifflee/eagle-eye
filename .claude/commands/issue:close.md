---
description: Close GitHub issue(s) using the repo-workflow agent (validates before closing)
---

# Close Issue

Close one or more GitHub issues through the repo-workflow agent.

## Important

This command routes through the `repo-workflow` agent to ensure:
- Issues are ready to close (linked PRs merged, acceptance criteria met)
- Status transitions are valid
- Issue hygiene is maintained

## Instructions

When this command is invoked:

1. **Invoke the repo-workflow agent** using the Task tool with `subagent_type: "repo-workflow"` and `model: "haiku"`

2. **Pass the user's request** including:
   - Issue number(s) to close
   - Reason for closing (if provided)
   - Whether this is completion vs. won't-fix vs. duplicate

3. **The agent will:**
   - Verify each issue exists
   - Check if issue has linked PRs
   - Validate closure is appropriate
   - Close the issue(s)
   - Update any related labels
   - Report back with results

## Example Usage

User: `/issue:close 42`
Agent: Closes issue #42 after validation

User: `/issue:close 10 11 12 --reason "Completed in PR #50"`
Agent: Closes issues #10, #11, #12 with linked PR reference

## Validation

The agent will verify before closing:
- Issue is in closeable state (not already closed)
- If there are linked PRs, they should be merged
- If marked as duplicate, original issue exists
- **Worktree completeness:** Check for unpushed work (see Worktree Validation below)
- **If epic:** Check for open children (see Epic Validation below)

### Worktree Validation

Before closing an issue, check if a worktree exists with unpushed work:

```bash
# Validate worktree is safe to close
./scripts/worktree/worktree-validate-close.sh $ISSUE --json
```

**If unpushed work exists:**
```
⚠️ Issue #69 has unpushed work:

Worktree: ~/repos/my-repo-issue-69
Uncommitted files: 3
Unpushed commits: 5
Risk level: HIGH

Options:
1. Push changes first (recommended)
2. Force close (acknowledge data loss)
3. Cancel close
```

**User must confirm to close an issue with unpushed work.**

**Force close flag:**
```
/issue:close 69 --force
```

When `--force` is provided, the validation warning is bypassed and the user acknowledges potential data loss.

### Epic Validation

When closing an issue with the `epic` label, additional checks are performed:

```bash
# Check epic completion status
./scripts/find-parent-issues.sh --epic-status $ISSUE
```

**If open children exist:**
```
⚠️ Epic #45 has open children:

| # | Title | Status |
|---|-------|--------|
| #47 | Fix session timeout | in-progress |
| #48 | Add 2FA | backlog |

2/5 children still open (60% complete)

Options:
1. Close anyway (children remain open)
2. Cancel close
3. View children details
```

**User must confirm to close an epic with open children.**

**If all children closed:**
```
✓ Epic #45: All 5 children closed (100% complete)
Proceeding with close.
```

## Error Handling

If validation fails:
- Report which issue(s) couldn't be closed
- Explain the reason (e.g., "PR #50 not yet merged")
- Suggest next steps

## Token Optimization

This skill has moderate optimization with room for improvement:

**Current optimizations:**
- ✅ Routes through repo-workflow agent (delegates heavy lifting)
- ✅ Simple validation logic (minimal token overhead)

**Token usage:**
- Current: ~1,250 tokens (moderate complexity)
- Optimized target: ~725 tokens (with data script)
- Potential savings: **42%**

**Remaining optimizations needed:**
- ❌ No dedicated data script for batch close operations
- ❌ Issue validation done inline (could be batched)
- ❌ Multiple sequential `gh` calls for related checks

**Measurement:**
- Baseline: 1,250 tokens (current implementation)
- Target: 725 tokens (with `close-issue-data.sh` validation script)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Optimization strategy:**
Create `./scripts/issue:close-data.sh` to batch validation checks:
- Check PR merge status for all issues
- Check worktree status for all issues
- Check epic/child relationships
- Return single JSON with all validation results

**Related skills:**
- `/create-issue` - Similar pattern, could share optimization approach

## Notes

- This is a WRITE operation - it modifies the repository
- Always routes through repo-workflow agent for governance
- Closing updates issue status and may trigger notifications
- **Worktree check:** Warns before closing issues with unpushed worktree work
- **Epic check:** Warns before closing epics with open children
- **Child issues:** Closing a child issue does not affect the parent epic
- **Force flag:** Use `--force` to bypass worktree validation (data loss warning)
