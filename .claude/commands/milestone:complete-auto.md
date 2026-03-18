---
description: Orchestrate milestone completion with MVP analysis, issue triage, and auto-transition
---

# Milestone Complete

Automated milestone completion workflow: analyze MVP-critical vs deferrable issues, move deferrals to backlog, complete in-progress work, and transition to the next milestone.

**Critical for n8n orchestration** - enables fully automated sprint cycles.

## Usage

```
/milestone-complete                  # Analyze active milestone
/milestone-complete "sprint-1/13"    # Analyze specific milestone
/milestone-complete --auto           # Auto-move deferrals without prompts
/milestone-complete --dry-run        # Preview analysis without action
/milestone-complete --close          # Close milestone after validation
```

## Steps

### 1. Gather Analysis Data

```bash
./scripts/milestone-complete-analysis.sh [milestone]
```

Returns JSON with:
- `analysis.mvp_critical`: Issues that must be completed
- `analysis.deferrable`: Issues that can move to backlog
- `analysis.in_progress`: Active work with worktree info
- `recommendation`: Closure readiness and blockers

### 2. Display Analysis Results

Present a clear summary table:

```
## Milestone Analysis: {milestone}

### MVP-Critical Issues ({count})
Must be completed before milestone closure.

| # | Title | Reason | Action |
|---|-------|--------|--------|
| #362 | Fix auth timeout | P0 - highest priority | complete |
| #225 | Add user model | in-progress - work started | complete |

### Deferrable Issues ({count})
Can be moved to backlog for future sprints.

| # | Title | Reason | Action |
|---|-------|--------|--------|
| #388 | Optimize queries | P1 epic - no urgent children | move_to_backlog |
| #391 | Refactor auth | P2 - lower priority | move_to_backlog |

### In-Progress Work ({count})
Active work that must complete or be explicitly abandoned.

| # | Title | Worktree |
|---|-------|----------|
| #362 | Fix auth timeout | claude-tastic-issue-362 |
```

### 3. Prompt for Deferral Action

Unless `--auto` or `--dry-run`:

```
Move {count} deferrable issues to backlog milestone? [y/n/select]

y = Move all to backlog
n = Keep in current milestone
select = Choose which issues to move
```

**If --auto flag:**
```bash
./scripts/milestone-complete-analysis.sh --milestone "{name}" --auto
```

### 4. Handle In-Progress Work

If `recommendation.blockers` is not empty:

```
{count} issues are in-progress and must complete before closure:

| # | Title | Worktree |
|---|-------|----------|
| #362 | Fix auth timeout | claude-tastic-issue-362 |

Options:
1. Wait for completion (run /sprint-status to check progress)
2. Abandon work (remove in-progress label, move to backlog)
3. Cancel milestone closure
```

### 5. Validate Closure Readiness

Check `recommendation.ready_to_close`:
- `true`: All critical work done, deferrals handled
- `false`: Blockers remain (see `recommendation.blockers`)

### 6. Close Milestone

When ready:

```bash
# Close the milestone via GitHub API
gh api repos/:owner/:repo/milestone-list/{number} -X PATCH -f state=closed
```

### 7. Trigger Release Workflow (Optional)

If `--close` flag and milestone is complete:

```
Milestone closed. Trigger release workflow?

This will:
1. Promote dev → qa (via milestone-complete-promotion.sh)
2. Run QA validation
3. Prepare for main release

[y/n]
```

If yes, invoke promotion:
```bash
./scripts/milestone-complete-promotion.sh --milestone "{name}" --auto-merge
```

See `/milestone-close --auto-promote` for the full promotion workflow.

## Output Format

### Standard Output

```
## Milestone Completion: {name}

### Summary
| Metric | Value |
|--------|-------|
| Total Open | {n} |
| MVP-Critical | {n} (must complete) |
| Deferrable | {n} (can move to backlog) |
| In-Progress | {n} (active work) |

### Analysis
[tables as described above]

### Recommendation
{ready_to_close ? "Ready for closure" : "Blockers remain"}

### Next Steps
1. {action items based on analysis}
```

### JSON Output (for n8n)

```json
{
  "milestone": "sprint-1/13",
  "total_open": 39,
  "analysis": {
    "mvp_critical": [
      {"number": 362, "reason": "P0 - highest priority", "action": "complete"}
    ],
    "deferrable": [
      {"number": 388, "reason": "P1 epic - no urgent children", "action": "move_to_backlog"}
    ],
    "in_progress": [
      {"number": 362, "worktree": "claude-tastic-issue-362"}
    ]
  },
  "recommendation": {
    "complete_count": 4,
    "defer_count": 35,
    "in_progress_count": 2,
    "ready_to_close": false,
    "blockers": ["#362 in-progress", "#225 in-progress"]
  }
}
```

## MVP-Critical Detection Rules

| Condition | Classification | Rationale |
|-----------|----------------|-----------|
| P0 priority | MVP-critical | Highest priority, must ship |
| In-progress status | MVP-critical | Work already started, finish it |
| Dependency of MVP-critical | MVP-critical | Required for critical item |
| P1 epic with no progress | Deferrable | Epic can wait if children not started |
| P2/P3 any status | Deferrable | Lower priority, can defer |
| Tech-debt/optimization | Deferrable | Nice-to-have, not functional |
| Blocked | Deferrable | Can't progress anyway |
| No priority set | Deferrable | Needs triage, not urgent |

## Integration with n8n

The milestone-complete workflow integrates with n8n for fully automated sprint cycles:

```
n8n Workflow: Milestone Completion
1. Trigger: All PRs merged OR scheduled check OR manual trigger
2. Run: ./scripts/milestone-complete-analysis.sh --json
3. Decision: Check recommendation.ready_to_close
   - If deferrable > 0: ./scripts/milestone-complete-analysis.sh --auto
   - If in-progress > 0: Wait or alert (post to Slack/webhook)
   - If ready_to_close: Continue
4. Close: gh api repos/:owner/:repo/milestone-list/{number} -X PATCH -f state=closed
5. Promote: ./scripts/milestone-complete-promotion.sh --auto-merge
6. Notify: Post completion summary to webhook
```

## Integration with #410

This command integrates with issue #410 (dev→qa merge on milestone completion):

When milestone is closed:
1. `milestone-complete-promotion.sh` creates PR from dev→qa
2. PR includes changelog of completed issues
3. Auto-merge when CI passes (if --auto-merge)
4. QA validation begins

## Token Optimization

- Uses `scripts/milestone-complete-analysis.sh` for all data gathering
- Returns structured JSON with analysis pre-computed
- Single batch of API calls (milestone + issues + worktrees)
- ~400-600 tokens per invocation

## Notes

- WRITE operation - modifies milestones and issues
- Validates in-progress work before allowing closure
- Integrates with `/milestone-close --auto-promote` for release workflow
- Use `/milestone-list` to view current state first
- Use `/sprint-status` to check in-progress work status
- JSON output enables n8n automation
- Auto-move creates backlog milestone if needed
