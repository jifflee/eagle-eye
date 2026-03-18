---
description: Interactive milestone updates based on audit recommendations
---

# Milestone Update

Run audit and interactively apply approved changes using pre-analyzed data.

## Usage

```
/milestone-update              # Update current milestone
/milestone-update "sprint-1/13" # Update specific milestone
```

## Steps

### 1. Gather Action Data

```bash
./scripts/milestone-update-data.sh [milestone]
```

Returns JSON with pre-analyzed actionable items:
- Stale in-progress issues (no updates in 3+ days)
- Orphaned issues (no milestone, has backlog label)
- Completed open issues (manual verification needed)
- Blocked issues without context

**Key Data Structure:**
```json
{
  "milestone": {"name": "sprint-1/13", "health_score": 75},
  "summary": {"total_actions": 6, "by_category": {...}},
  "actions": {
    "stale_issues": [{number, title, days_stale, prompt}],
    "orphaned_issues": [{number, title, labels, prompt}],
    "completed_open": [{number, title, prompt}],
    "blocked_no_context": [{number, title, prompt}]
  }
}
```

### 2. Present Summary

Use data from Step 1:

```
## Milestone Update: {milestone.name}

**Health Score:** {milestone.health_score}/100
**Total Actions Found:** {summary.total_actions}

### Action Categories
- Stale in-progress: {summary.by_category.stale_in_progress}
- Orphaned issues: {summary.by_category.orphaned_issues}
- Completed open: {summary.by_category.completed_open}
- Blocked without context: {summary.by_category.blocked_no_context}
```

### 3. Interactive Review

For each action category with items, use AskUserQuestion with **pre-generated prompts from data script**.

**Optimization:** Process items in batches by category, not individually. Prompts are pre-formatted in the data JSON.

**For stale_issues[] items:**
Use `item.prompt` directly from data (already formatted with context):
```
{item.prompt}  // Pre-generated: "Issue #N: \"title\"\nStatus: in-progress for X days..."

Options:
1. Mark as blocked (Recommended)
2. Keep as in-progress
3. Skip
```

**For orphaned_issues[] items:**
Use `item.prompt` directly from data:
```
{item.prompt}  // Pre-generated: "Issue #N: \"title\"\nLabels: ..."

Options:
1. Add to milestone (Recommended)
2. Leave orphaned
3. Skip
```

**For blocked_no_context[] items:**
```
{item.prompt}  // Pre-generated: "Issue #N: \"title\"\nStatus: blocked..."

Options:
1. Request blocker details (Recommended)
2. Skip
```

### 4. Apply Changes

Execute user-approved actions:

```bash
# Stale → blocked (batch if multiple)
for issue in $STALE_APPROVED; do
  gh issue edit $issue --remove-label "in-progress" --add-label "blocked"
done

# Add to milestone (batch if multiple)
for issue in $ORPHANED_APPROVED; do
  gh issue edit $issue --milestone "{milestone_name}"
done

# Request blocker context (add comment)
for issue in $BLOCKED_APPROVED; do
  gh issue comment $issue --body "What is blocking this issue?"
done
```

## Output Format

```
## Update Summary

| Action | Issues | Applied |
|--------|--------|---------|
| Marked blocked | {n} | #{list} |
| Added to milestone | {n} | #{list} |
| Closed | {n} | #{list} |
| Skipped | {n} | - |

**Health improvement:** {before} → {after}
```

## Token Optimization

This skill has been significantly optimized in Phase 3:

**Data gathering via script:**
- Single call to `./scripts/milestone-update-data.sh` returns all actionable items
- Script pre-analyzes audit data and categorizes issues
- Prompts are pre-generated in bash (not Claude)
- All classification logic runs server-side

**Token savings:**
- Before optimization: ~2,450 tokens (inline analysis, manual categorization)
- After optimization: ~725 tokens (pre-analyzed JSON with prompts)
- Savings: **70%**

**Measurement:**
- Baseline: 2,450 tokens (parsing audit, analyzing issues, generating prompts in Claude)
- Current: 725 tokens (receiving pre-computed actions with prompts)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Key optimizations:**
- ✅ All issue analysis done in data script (stale detection, orphan detection)
- ✅ Interactive prompts pre-generated server-side
- ✅ Risk assessment calculated in bash
- ✅ Batch operations for applying changes
- ✅ Claude only handles user interaction and command execution

## Notes

- WRITE operation - modifies issues
- Requires confirmation for each change
- Run `/milestone-audit` first for read-only view
