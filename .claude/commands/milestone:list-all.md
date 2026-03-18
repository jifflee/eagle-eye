---
description: Show current milestones and their status (READ-ONLY - query only)
---

# Milestones

**🔒 READ-ONLY OPERATION - This skill NEVER modifies milestones or issues**

Display milestones with status, progress, and issue breakdown.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- All suggested commands are for USER execution, not automatic invocation
- NEVER invoke `/milestone-close`, `/milestone-create`, or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/milestone-list
```

## Steps

1. **Get milestones**
   `gh api repos/:owner/:repo/milestone-list --jq '.[] | {title, state, open_issues, closed_issues, due_on}'`

2. **Get issues per milestone** (for open milestones)
   `gh issue list --milestone "{name}" --state all --json number,title,state,labels`

3. **Calculate progress**
   - Progress = closed / (open + closed) * 100
   - Days remaining = due_on - today

4. **Generate report**

## Output Format

```
## Milestones

| Milestone | State | Progress | Issues | Due Date |
|-----------|-------|----------|--------|----------|
| {name} | {state} | {percent}% ({closed}/{total}) | {open} open | {due_on} |

**Active:** {active_milestone} ({days_remaining} days remaining)

---

### {milestone_name} Issues

| # | Title | Labels |
|---|-------|--------|
| #{number} | {title} | {labels} |

**By Status:**
- In Progress: {in_progress_count}
- Backlog: {backlog_count}
- Blocked: {blocked_count}

---

### Recommendations
- {actionable next step based on status}
```

## Token Optimization

- **Data script:** `scripts/milestone-list-data.sh`
- **API calls:** 2 batched (milestones + issues per milestone)
- **Savings:** ~60% reduction from inline gh calls

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Shows all milestones (open and closed)
- Groups issues by status for quick triage
- **NEVER automatically invoke**:
  - `/milestone-close` command
  - `/milestone-create` command
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Milestone management skills are WRITE-FULL. Never cross this boundary.

**User action:** User should run `/milestone-close` or `/milestone-create` manually if needed
