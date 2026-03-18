---
description: Validate GitHub issue tracking against actual PR deliveries (READ-ONLY - audit only)
---

# Delivery Audit

**🔒 READ-ONLY OPERATION - This skill NEVER modifies issues or PRs**

Validate that GitHub issue tracking accurately reflects actual PR deliveries. Identifies alignment gaps, orphaned work, and delivery discrepancies for sprint retrospectives and release validation.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents audit reports
- All suggested commands are for USER execution, not automatic invocation
- NEVER invoke `/issue:close`, `/pr-merge`, or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/delivery:audit
/delivery:audit "Sprint 1"
```

## Steps

### 1. Gather Data

```bash
./scripts/delivery:audit-data.sh [milestone_name]
```

Returns JSON with:
- Milestone metadata
- All closed issues in milestone
- All merged PRs linked to milestone
- Open issues with `pr:merged` label (stale labels)
- Epic issues for child completion validation
- All issues for reference

### 2. Analyze Issue-PR Alignment

**For each closed issue:**
1. Extract PR references from issue body (look for `#NNN`, `closes #NNN`, `fixes #NNN`)
2. Check if referenced PR exists in `merged_prs` array
3. If no PR reference found in body, check if any PR in `merged_prs` has this issue in `closingIssuesReferences`
4. Flag issues with neither as **Closed Without PR**

**Detection patterns:**
- Issue body contains: `#123`, `closes #123`, `fixes #123`, `resolves #123`
- PR's `closingIssuesReferences` array contains the issue number
- Cross-reference both directions for accuracy

### 3. Find Orphaned PRs

**For each merged PR:**
1. Check if `closingIssuesReferences` array is empty or null
2. Check if PR body contains issue references
3. If neither found, flag as **Orphaned PR** (merged without linked issues)

**Note:** Some PRs may legitimately have no issue (e.g., hotfixes, documentation updates). Use judgment to classify severity.

### 4. Detect Stale PR Labels

**From `stale_pr_merged` in JSON:**
- Issues with `pr:merged` label that are still OPEN
- These should be either:
  - Closed (if PR truly merged)
  - Label removed (if PR was not actually merged)

### 5. Validate Epic Completion

**For each epic issue:**
1. Parse epic body to find child issue references (look for task lists with `- [ ] #NNN` or `- [x] #NNN`)
2. For closed epics:
   - Verify ALL child issues are also closed
   - Check if child issues have merged PRs
   - Flag epics closed with open children or children without PRs
3. Calculate epic completion: `closed_children / total_children * 100`

### 6. Timeline Analysis

**Velocity calculation:**
- Group closed issues by week/month using `closedAt` timestamp
- Group merged PRs by week/month using `mergedAt` timestamp
- Calculate: issues closed per week, PRs merged per week
- Identify trends: accelerating, steady, declining

**Time-to-delivery:**
- For issues with linked PRs, calculate: `PR mergedAt - Issue closedAt` (should be same day or PR before close)
- Flag anomalies: issue closed days/weeks before PR merged (tracking error)

### 7. Calculate Alignment Score

```
aligned_issues = closed_issues_with_prs
total_closed = total closed issues

alignment_score = (aligned_issues / total_closed) * 100
```

**Score thresholds:**
- Excellent: 95%+ (nearly perfect tracking)
- Good: 85-94% (acceptable with minor gaps)
- Fair: 70-84% (needs improvement)
- Poor: <70% (significant tracking issues)

## Output Format

```markdown
## Delivery Audit: {milestone}

**Alignment Score:** {score}% ({score_level})
**Issues Closed:** {closed} | **PRs Merged:** {merged}
**Aligned Issues:** {aligned}/{closed} ({pct}%)

---

### 📊 Delivery Summary

| Metric | Count | Notes |
|--------|-------|-------|
| Closed Issues | {n} | |
| Merged PRs | {n} | |
| Issues with PR | {n} | {pct}% |
| PRs with Issue | {n} | {pct}% |
| Stale Labels | {n} | Open issues with pr:merged |

---

### ⚠️ Discrepancies Found

#### Closed Without PR ({count})

Issues closed without a merged PR reference:

| # | Title | Closed Date | Labels | Notes |
|---|-------|-------------|--------|-------|
| #{n} | {title} | {date} | {labels} | {reason} |

**Possible reasons:**
- Manual closure (won't fix, duplicate, etc.)
- PR in different milestone
- Tracking error (PR not linked correctly)

---

#### Orphaned PRs ({count})

PRs merged without linked issue references:

| PR | Title | Merged Date | Author | Files Changed |
|----|-------|-------------|--------|---------------|
| #{n} | {title} | {date} | {author} | {files} |

**Possible reasons:**
- Hotfix (no issue needed)
- Documentation update
- Forgot to link issue
- Issue in different repository

---

#### Stale pr:merged Labels ({count})

Issues with pr:merged label still OPEN:

| # | Title | PR | Status | Last Update |
|---|-------|----|--------|-------------|
| #{n} | {title} | #{pr} | open | {days} ago |

**Action needed:**
```bash
# If PR actually merged, close the issue:
gh issue close {n} --reason completed

# If PR NOT merged, remove label:
gh issue edit {n} --remove-label "pr:merged"
```

---

#### Epic Completion Issues ({count})

Epics with child delivery problems:

| Epic | Status | Children | Closed | With PR | Issue |
|------|--------|----------|--------|---------|-------|
| #{n} | {state} | {total} | {closed} | {with_pr} | {problem} |

**Problems detected:**
- Epic closed with {n} children still open
- {n} closed children without merged PRs
- Epic marked complete but delivery incomplete

---

### 📈 Timeline Analysis

#### Delivery Velocity

| Period | Issues Closed | PRs Merged | Avg/Week |
|--------|---------------|------------|----------|
| Last 7 days | {n} | {n} | {rate} |
| Last 30 days | {n} | {n} | {rate} |
| Milestone total | {n} | {n} | {rate} |

**Trend:** {increasing/steady/declining}

#### Time-to-Delivery Anomalies

Issues where close date and PR merge date don't align:

| # | Issue Closed | PR Merged | Gap | Status |
|---|--------------|-----------|-----|--------|
| #{n} | {date} | {date} | {days} | {problem} |

---

### ✅ Recommendations

**Priority Actions:**
1. **{priority}** {action} - {reason}
2. **{priority}** {action} - {reason}

**Process Improvements:**
- Always link PRs to issues using `closes #NNN` in PR description
- Remove pr:merged label automation if unreliable
- Close issues only after PR is merged
- For epics, verify all children delivered before closing

**For Sprint Retrospective:**
- Alignment score: {score}% ({trend} from last sprint)
- Top gap: {issue_type}
- Recommendation: {improvement}

---

### 🔍 Quick Actions

```bash
# Fix stale labels
gh issue edit {n} --remove-label "pr:merged"

# Close issues with merged PRs
gh issue close {n} --reason completed

# Link orphaned PR to issue (edit PR description)
gh pr edit {pr} --body "Closes #{issue}\n\n{existing_body}"
```

---

## Token Optimization

- **Data script:** `scripts/delivery:audit-data.sh`
- **API calls:** 6 batched (milestone, issues, PRs, labels, epics, all issues)
- **Savings:** ~70% reduction from inline gh calls
- **Analysis:** All correlation done in Claude, not bash

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents audit reports only
- **Best used for:**
  - Weekly sprint health checks
  - Pre-release validation (before marking milestone complete)
  - Sprint retrospectives (identify tracking improvements)
  - Audit trail for delivery claims
- **NEVER automatically invoke**:
  - `/issue:close` command
  - `/pr-merge` command
  - `gh issue edit` commands
  - `gh pr edit` commands
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Issue and PR modification commands are WRITE-FULL. Never cross this boundary.

**User action:** Manually run suggested `gh` commands to fix discrepancies after reviewing audit results.
