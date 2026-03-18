---
description: Analyze milestone health and surface issues needing attention (READ-ONLY - query only)
argument-hint: "[MILESTONE_NAME] [--include-closed]"
---

# Milestone Audit

**🔒 READ-ONLY OPERATION - This skill NEVER modifies milestones or issues**

Analyze the active milestone for health issues, orphaned work, and recommendations.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- All suggested commands are for USER execution, not automatic invocation
- NEVER invoke `/milestone-update`, `/sprint-work`, or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/milestone-audit
/milestone-audit MVP
/milestone-audit --include-closed
```

## Steps

### 1. Gather Data

```bash
./scripts/milestone-audit-data.sh [milestone_name] [--include-closed]
```

Returns JSON: milestone metadata, counts, issues with details, orphans, and `closed_with_open_issues` flag for completion correctness.

### 2. Check Completion Correctness

**First, check `closed_with_open_issues` field:**
- If `true`: The milestone is CLOSED but still has open issues — these are orphaned and need triage
- Flag this as a **Critical** finding at the top of the report

**Check `closed_milestones_with_orphans` array (when --include-closed used):**
- Lists all other closed milestones that also have open issues
- Each entry: `{number, title, open_issues}`

### 3. Analyze Health

**Calculate:**
- Progress: `closed / total * 100`
- Days remaining: `due_date - today`
- Velocity needed: `open / days_remaining`

**Problem detection:**

| Check | Condition | Severity |
|-------|-----------|----------|
| Closed with open issues | `milestone_state == "closed"` and `open > 0` | Critical |
| Stale in-progress | `in-progress` + `updatedAt < 7 days ago` | Warning |
| Blocked no context | `blocked` + no linked issue/comment | Warning |
| Overloaded | open > days remaining | Info |
| Empty milestone | No issues | Error |
| Low quality | Missing required sections | Warning |

### 3. Calculate Quality Score

Per issue:
- +10 type label, +10 priority, +10 body >= 50 chars
- +40 * (required_sections_found / required_sections_total)
- Threshold: Ready (70+), Could improve (40-69), Needs triage (<40)

### 4. Find Orphans

From `orphan_issues` in JSON: issues with `bug`/`feature` label but no milestone.

### 5. Calculate Health Score

| Condition | Impact |
|-----------|--------|
| On track | +20 |
| Has in-progress | +20 |
| No blocked | +20 |
| No stale | +20 |
| All labeled | +20 |
| Stale (each) | -15 |
| Blocked no context (each) | -10 |
| Needs triage (each) | -5 |

Thresholds: Good (80+), Warning (50-79), Critical (<50)

## Output Format

```
## Milestone Audit: {name}

**Health Score:** {status} ({score}/100)
**Progress:** {pct}% ({closed}/{total})
**Days Remaining:** {days}
**Velocity Needed:** {rate} issues/day

---

### Issues Needing Attention

#### Stale Work (7+ days)
| # | Title | Status | Last Update |
|---|-------|--------|-------------|
| #{n} | {title} | in-progress | {days} ago |

#### Blocked Without Context
| # | Title | Missing |
|---|-------|---------|
| #{n} | {title} | No linked blocker |

---

### Issue Quality

| # | Title | Type | Score | Issues |
|---|-------|------|-------|--------|
| #{n} | {title} | {type} | {score}/100 | {missing} |

Run `/issue-triage {n}` to improve.

---

### Orphaned Issues (no milestone)

| # | Title | Labels | Why flagged |
|---|-------|--------|-------------|
| #{n} | {title} | {labels} | {reason} |

```
gh issue edit {n} --milestone "{name}"
```

---

### Recommendations

1. **{priority}** {action}

---

### Quick Actions

```bash
gh issue edit {n} --remove-label "in-progress" --add-label "blocked"
gh issue edit {n} --milestone "{name}"
```
```

## Token Optimization

- **Data script:** `scripts/milestone-audit-data.sh`
- **API calls:** 2-3 batched (milestone + issues + optional closed milestones)
- **Savings:** ~65% reduction from inline gh calls

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Uses batch script for efficiency
- Run weekly or before sprint planning
- Use `--include-closed` to surface orphaned open issues in other closed milestones
- For a comprehensive audit across ALL epics and milestones, use `/epic-milestone-audit`
- **NEVER automatically invoke**:
  - `/milestone-update` command
  - `/sprint-work` command
  - `gh issue edit` commands
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Milestone-update and sprint-work are WRITE-FULL. Never cross this boundary.

**User actions:**
- Run `/milestone-update` manually to apply recommended changes
- Run `/epic-milestone-audit` for full cross-cutting audit of all epics and milestones
