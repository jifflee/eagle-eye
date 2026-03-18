---
description: Audit all epics and milestones for completion correctness (READ-ONLY - query only)
argument-hint: "[--closed] [--milestone NAME] [--epics-only] [--milestones-only]"
---

# Epic & Milestone Completion Audit

**🔒 READ-ONLY OPERATION - This skill NEVER modifies epics, milestones, or issues**

Comprehensive audit of all epics and milestones to validate completion correctness: orphaned open issues in closed milestones, stale open epics with all children done, incorrectly closed epics with open children, and issues closed without linked PRs.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- All suggested commands are for USER execution, not automatic invocation
- NEVER invoke `/milestone:update-interactive`, `/sprint:work-auto`, or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/epic-milestone-audit                         # Full audit: all epics + milestones
/epic-milestone-audit --closed                # Include closed milestones in audit
/epic-milestone-audit --milestone "sprint-2"  # Audit specific milestone
/epic-milestone-audit --epics-only            # Only audit epics
/epic-milestone-audit --milestones-only       # Only audit milestones
```

## Steps

### 1. Gather Data

```bash
./scripts/epic-milestone-audit-data.sh [args]
```

Returns JSON with:
- `findings.orphan_issues_in_closed_milestones` – open issues inside closed milestones
- `findings.stale_open_epics` – epics still open but all children are closed
- `findings.incorrectly_closed_epics` – epics closed while children remain open
- `findings.empty_epics` – epics with no children at all
- `findings.closed_issues_missing_pr_link` – issues closed without referencing a PR
- `health.score` – 0-100 health score
- `summary` – aggregate counts

### 2. Analyze Each Finding Category

#### A. Orphaned Open Issues in Closed Milestones (CRITICAL)
For each item in `findings.orphan_issues_in_closed_milestones`:
- Issue is OPEN but belongs to a CLOSED milestone
- These are real bugs — work was missed or milestone closed prematurely
- Severity: **Critical** (work was lost/forgotten)

#### B. Stale Open Epics — All Children Done
For each item in `findings.stale_open_epics`:
- Epic is OPEN but every child issue is CLOSED
- Epic should be closed — this is administrative debt
- Severity: **Warning** (cosmetic but clutters backlog)

#### C. Incorrectly Closed Epics — Children Still Open
For each item in `findings.incorrectly_closed_epics`:
- Epic is CLOSED but has OPEN children
- Either children were orphaned or epic was closed too early
- Severity: **Critical** (work may be abandoned)

#### D. Empty Epics
For each item in `findings.empty_epics`:
- Epic exists but has zero child issues (via `parent:N` label)
- May need decomposition or removal
- Severity: **Warning**

#### E. Closed Issues Missing PR Link
For each item in `findings.closed_issues_missing_pr_link`:
- Issue closed but body contains no PR/commit reference
- May indicate issues closed manually without actual implementation
- Severity: **Info** (review individually)

### 3. Calculate Health Score

```
Start: 100 points
- Each orphaned open issue:          -10 pts (Critical)
- Each incorrectly closed epic:      -15 pts (Critical)
- Each stale open epic:               -5 pts (Warning)
- Each empty epic:                    -3 pts (Info)
```

Thresholds:
- **Good** (80-100): Minimal issues, system well-maintained
- **Warning** (50-79): Some administrative debt, action recommended
- **Critical** (<50): Significant problems, immediate action needed

### 4. Generate Report

Format the findings into a clear report with tables and quick-action commands.

## Output Format

```
## Epic & Milestone Completion Audit

**Health Score:** {status} ({score}/100)
**Audit Date:** {today}

---

### Summary

| Category | Count | Severity |
|----------|-------|----------|
| Orphaned open issues in closed milestones | {n} | 🔴 Critical |
| Incorrectly closed epics (open children) | {n} | 🔴 Critical |
| Stale open epics (all children done) | {n} | 🟡 Warning |
| Empty epics (no children) | {n} | 🟡 Warning |
| Closed issues missing PR link | {n} | 🔵 Info |

---

### 🔴 Orphaned Open Issues in Closed Milestones

These issues are OPEN but belong to CLOSED milestones. Work was missed.

| # | Title | Milestone | Labels | Last Updated |
|---|-------|-----------|--------|--------------|
| #{n} | {title} | {milestone} | {labels} | {date} |

**Fix:**
```bash
# Move to appropriate open milestone or backlog
gh issue edit {n} --milestone "backlog"
# Or reopen the milestone
gh api repos/:owner/:repo/milestones/{milestone_number} -X PATCH -f state=open
```

---

### 🔴 Incorrectly Closed Epics (Open Children Remain)

These epics are CLOSED but have open child issues. They may have been closed prematurely.

| # | Title | Open Children | Closed Children |
|---|-------|---------------|-----------------|
| #{n} | {title} | {open} | {closed} |

**Children still open:**
| # | Title | Labels |
|---|-------|--------|
| #{child} | {title} | {labels} |

**Fix:**
```bash
# Reopen the epic
gh issue reopen {n}
# Or if children should be closed, close them first, then re-audit
```

---

### 🟡 Stale Open Epics (All Children Done)

These epics are OPEN but every child issue is CLOSED. They should be closed.

| # | Title | Children Done | Created |
|---|-------|---------------|---------|
| #{n} | {title} | {total}/{total} | {date} |

**Fix:**
```bash
# Close the stale epic
gh issue close {n} --comment "All child issues completed. Closing epic."
```

---

### 🟡 Empty Epics (No Children)

These epics have no child issues linked via `parent:{n}` label.

| # | Title | State | Created |
|---|-------|-------|---------|
| #{n} | {title} | {state} | {date} |

**Fix:**
```bash
# Decompose the epic
/epic-decompose {n}
# Or close if obsolete
gh issue close {n}
```

---

### 🔵 Closed Issues Missing PR Link

These issues were closed but their body has no reference to a PR or commit.

| # | Title | Milestone | Closed At |
|---|-------|-----------|-----------|
| #{n} | {title} | {milestone} | {date} |

*Review these manually to verify implementation actually happened.*

---

### Recommendations

{ordered_by_severity list of actions}

---

### Quick Actions

```bash
# Close all stale open epics at once (verify list above first)
for epic in {stale_epic_numbers}; do
  gh issue close $epic --comment "All children completed. Closing epic."
done

# Move orphaned issues to backlog
gh issue edit {n} --milestone "backlog"
```
```

## Token Optimization

- **Data script:** `scripts/epic-milestone-audit-data.sh`
- **API calls:** Batched (milestones, epics, children, PRs)
- **Savings:** ~70% reduction vs inline gh calls
- **Cache:** Results stable within same day

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Run before closing milestones or at end of sprint
- Run monthly for ongoing epic hygiene
- **NEVER automatically invoke**:
  - `/milestone:update-interactive` command
  - `/sprint:work-auto` command
  - `gh issue edit` or `gh issue close` commands
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. All fix commands are for USER execution only.

**User actions:**
- Run `/milestone:close-safe` to close a milestone after fixing orphans
- Run `/milestone:epic-decompose {n}` to decompose an empty epic
- Run `/milestone:update-interactive` to reassign orphaned issues
