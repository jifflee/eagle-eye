---
description: Check current PR review status and display actionable summary
---

# PR Status

Check PR review status with lifecycle state and recommended actions.

## Usage

```
/pr-status                 # Current branch's PR
/pr-status --issue 123     # PR for specific issue
/pr-status --json          # JSON output only
/pr-status --verbose       # Include all findings
```

## Steps

### 1. Gather Data

```bash
# Use data script for batched API calls
./scripts/pr/pr-status-data.sh [--issue N]
```

Returns JSON with `has_pr`, `pr`, `github_state`, `checks`, `review_status`, `blocking_issues`, `recommended_action`.

### 2. Handle Errors

If `has_pr: false`, show error message and suggestion from JSON response.

### 3. Display Status

**For --json flag:** Output the data script JSON directly.

**For standard output:**

```
## PR Status

**PR:** #{number} - {title}
**Branch:** {head_ref} -> {base_ref}
**Lifecycle:** {lifecycle}

### GitHub State

| Metric | Value |
|--------|-------|
| Mergeable | {mergeable} |
| Merge State | {merge_state} |
| CI Checks | {passed}/{total} {status} |

### Review Status

**Status:** {status} | **Iteration:** {iteration}
{if blocking_count > 0}
**Blocking Issues:** {blocking_count}

| File | Line | Severity | Message | Agent |
|------|------|----------|---------|-------|
{for each blocking_issue}
{/if}

### Recommended Action

{recommended_action}

### Quick Actions

- `/pr-review-internal` - Run review
- `/pr-fix` - Fix issues
- `/pr-iterate` - Review-fix loop
- `gh pr merge --squash` - Merge
```

### 4. Verbose Mode

With `--verbose`, also show warnings, informational findings, and implementation agent file mappings from pr-status.json.

## Token Optimization

- **Data script:** `scripts/pr/pr-status-data.sh`
- **API calls:** 2 batched (PR info + checks)
- **Savings:** 68% reduction from inline gh calls

## Notes

- READ-ONLY operation
- Aggregates local pr-status.json with GitHub API data
- Lifecycle states: no-review, in-review, needs-fixes, approved, merged, closed
