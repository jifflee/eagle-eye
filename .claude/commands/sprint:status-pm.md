---
description: Sprint/milestone status with PM orchestration (READ-ONLY; --auto-merge enables PR merging)
---

# Sprint Status

**🔒 READ-ONLY** - Queries data and presents reports. Use `--auto-merge` for write operations.

Provides: progress metrics, priority queue, issue health, label audit, unpushed work review, and PM recommendations.

**SAFEGUARD:** NEVER invoke `/sprint-work` or creates worktrees. All actions are user-executed.

## Required Sections (by Mode)

**Check `mode` field in JSON to determine rendering:**

### Minimal Mode (`mode: "minimal"`)
1. Sprint Header (compact) + Progress
2. Priority Queue (counts only)
3. Recommended Next (top 1)
4. Quick Actions (link to `--full`)

### Default Mode (`mode: "default"`)
1. Sprint Header + Progress Bar + Issue Distribution
2. Priority Queue
3. Active Work Summary (`active_issues[]`, `pr_status[]`)
4. Worktrees Pending Cleanup (`worktrees.worktrees_for_cleanup[]`)
5. Prioritized Next Actions (ALWAYS)
6. Recommended Next Actions (`recommended_next[]`)
7. Quick Actions

### Full Mode (`mode: "full"`)
All sections when data exists:
1. Sprint Header + Progress Bar + Issue Distribution
2. Priority Queue
3. Repo-Level CI Failures (`repo_ci_status.has_failures`)
4. Active Work Summary
5. Issue Health Analysis (`issue_health[]`)
6. Label Audit (`label_audit[]`)
7. Unpushed Work Review (`unpushed_work_review.total_with_unpushed > 0`)
8. Worktrees Pending Cleanup
9. Container Status (`container_status.summary.total > 0`)
10. Dependency & Parallel Work Analysis (`dependencies.parallel_analysis`, when --deps flag used)
11. Prioritized Next Actions (ALWAYS)
12. Recommended Next Actions (`recommended_next[]`)
13. Quick Actions

**Key Fields:** `mode`, `auto_merge_results`, `pr_status[]`, `open_issues[]`, `label_audit[]`, `unpushed_work_review`, `recommended_next[]`, `container_status`, `repo_ci_status`, `dependencies`

**Derived Fields:** `active_issues`, `blocked_issues`, `issue_health` are derived at render time from `open_issues[]`

**Dependency Fields (when --deps used):** `dependencies.graph`, `dependencies.file_overlaps`, `dependencies.parallel_analysis`

## Usage

```
/sprint-status              # Current milestone (default mode)
/sprint-status --minimal    # Quick status: counts + priority + next action
/sprint-status --full       # Full dashboard: all sections + health + audit
/sprint-status --all        # All open milestones
/sprint-status --velocity   # Include velocity metrics (default/full only)
/sprint-status --deps       # Include dependency graph (full only)
/sprint-status --auto-merge # Auto-merge mergeable PRs before reporting
```

**Output Modes:**

| Mode | Flag | Sections | Est. Time |
|------|------|----------|-----------|
| Minimal | `--minimal` | Progress, priority queue, recommended next | ~3s |
| Default | (none) | Core status + PM recommendations | ~5s |
| Full | `--full` | All sections + health, audit, containers | ~10s |

**`--auto-merge`:** Merges all MERGEABLE+CLEAN PRs, syncs repo, then shows status.

## Steps

1. **Gather data (cache-first)**
   ```bash
   # Cache from UserPromptSubmit hook; skip if --auto-merge (need fresh data)
   if [ -f /tmp/sprint-status-cache.json ] && [ $(($(date +%s) - $(stat -f %m /tmp/sprint-status-cache.json))) -lt 60 ] && [ "$AUTO_MERGE" != true ]; then
     cat /tmp/sprint-status-cache.json
   else
     ./scripts/sprint/sprint-status-data.sh [milestone] [--velocity] [--all] [--deps] [--minimal] [--full] [--auto-merge]
   fi
   ```

2. **Check mode** - Read `mode` field from JSON: `"minimal"`, `"default"`, or `"full"`

3. **Derive filtered lists** (if `open_issues[]` exists):
   ```javascript
   // Filter active issues (in-progress)
   const activeIssues = openIssues.filter(issue =>
     issue.labels.some(l => l.name === "in-progress")
   )

   // Filter blocked issues
   const blockedIssues = openIssues.filter(issue =>
     issue.labels.some(l => l.name === "blocked")
   )

   // Derive issue health
   function deriveHealth(labels, updatedAt) {
     const labelNames = labels.map(l => l.name)
     const isInProgress = labelNames.includes("in-progress")
     const isEpic = labelNames.includes("epic")
     const daysSinceUpdate = Math.floor(
       (Date.now() - new Date(updatedAt)) / (1000 * 60 * 60 * 24)
     )

     if (isEpic) return "epic"
     if (isInProgress && daysSinceUpdate >= 3) return "stale"
     if (isInProgress) return "active"
     if (daysSinceUpdate >= 5) return "idle"
     return "ok"
   }

   const issueHealth = openIssues.map(issue => ({
     number: issue.number,
     title: issue.title,
     labels: issue.labels.map(l => l.name),
     age_days: Math.floor(
       (Date.now() - new Date(issue.createdAt)) / (1000 * 60 * 60 * 24)
     ),
     health: deriveHealth(issue.labels, issue.updatedAt)
   }))
   ```

4. **PR check details** (default/full mode, if `pr_status[]` has unstable/ready PRs):
   `./scripts/pr/pr-checks-analysis.sh --milestone "$MILESTONE"`

5. **Render by mode** - Render sections appropriate to mode (see Required Sections above)

6. **Cleanup prompt** (default/full mode, if worktrees for closed issues exist):
   - `cleanup_allowed: true` (main repo) → Prompt "Clean up? [y/n]" → Use `/worktree-cleanup`
   - `cleanup_allowed: false` (worktree) → Show note to run from main repo

## Output Format

### Minimal Mode Format (`--minimal`)

```
## Sprint Status: {milestone}
Progress: {percent}% ({closed}/{total}) | Due: {due_date}

Priority: {p0} P0, {p1} P1, {p2} P2 open

Next: #{number} {title} ({priority}, {type})

Quick: /sprint-status --full for details
```

### Default/Full Mode Format

#### Core Sections (Always Render)

**Sprint Header:**
```
**Milestone:** {name} | **Due:** {date} ({days_remaining} days) | **Progress:** {percent}% ({closed}/{total})
[{bar}] {percent}%
```

**Issue Distribution:** Table with Backlog/In Progress/Blocked/Completed counts and percentages.

**Priority Queue:** Table with P0-P3 counts and next issue for each priority level.

### Conditional Sections

| Section | Condition | Template |
|---------|-----------|----------|
| Repo-Level CI Failures | `repo_ci_status.has_failures` | Workflow/branch/guidance table, resolution commands |
| Branch Hygiene Audit | `branch_audit.stale_merged_branches.count > 0` | Stale branches table, cleanup recommendations |
| Auto-Merge Results | `--auto-merge` used | Merged PRs table, summary counts |
| Active Work | `pr_status[]` or derived `activeIssues[]` | Issue/status/PR/action table with lifecycle states |
| PRs with Health Status | `pr_status[]` with health data | PR/Issue/Health/Action table with health indicators |
| Issue Health Analysis | derived `issueHealth[]` not empty | Issue/age/health table with recommendations |
| Label Audit | `label_audit[]` not empty | Missing labels table with suggestions |
| Unpushed Work Review | `unpushed_work_review.total > 0` | Risk summary table, link to `/worktree-audit` |
| Worktrees Pending Cleanup | Closed issue worktrees exist | Table, prompt for `/worktree-cleanup` |
| Container Status | `container_status.summary.total > 0` | Container table with status/age |
| Dependency & Parallel Work | `dependencies.parallel_analysis` exists | Sequential vs parallel work recommendations |

### PRs with Health Status (when pr_status[] exists)

Display PR health information with actionable recommendations:

```
### Pull Requests

| PR | Issue | Health | Action |
|----|-------|--------|--------|
| #{pr_number} | #{linked_issue} | {health_status} | {recommended_action} |
```

**Health Legend:**
- `READY` - Can merge immediately (all checks passing, no conflicts)
- `STALE` - All commits already in base branch, should close
- `NEEDS_REBASE` - Behind base branch, needs rebase
- `CONFLICTING` - Has merge conflicts that need resolution
- `BLOCKED` - CI checks failing or other blocking issues

**Recommended Actions:**
- `READY`: "Merge now" → Use `/pr-merge {PR#}` or merge via GitHub
- `STALE`: "Close (all upstream)" → Close PR as changes are already merged
- `NEEDS_REBASE`: "Rebase required" → Use `/pr-rebase {PR#}` to update branch
- `CONFLICTING`: "Resolve conflicts" → Use `/pr-rebase {PR#}` to resolve conflicts
- `BLOCKED`: "Fix CI checks" → Review failing checks and fix issues

**Implementation Note:** Health data is automatically collected by `scripts/sprint/sprint-status-data.sh` (lines 222-287) and included in each PR's `health` object within `pr_status[]`. The rendering agent should:
1. Check if `pr_status[]` exists and has entries
2. For each PR, extract `health.status` and `health.reason`
3. Map the health status to actionable recommendations
4. Display in the enhanced table format shown above

**Example health data structure:**
```json
{
  "pr_number": 190,
  "linked_issue": 166,
  "health": {
    "status": "NEEDS_REBASE",
    "commits_upstream": 0,
    "commits_behind_base": 5,
    "recommended_action": "rebase",
    "reason": "Branch is behind base by 5 commit(s)"
  }
}
```

### PR Merge Handling

When MERGEABLE PRs exist, show summary and prompt:
```
{count} PRs ready to merge. Merge MERGEABLE PRs? [y/n]
```
**If 'y':** Execute `/pr-merge` skill.

### Prioritized Next Actions (ALWAYS GENERATE)

| Priority | Action | Reason |
|----------|--------|--------|
| 1-3 | {action} | {reason} |

**Logic:** In-progress first → Stale issues → Safe cleanup → Unpushed work → Backlog (P0 > P1 > P2)

### Recommended Next Actions

From `recommended_next[]`: Table with issue/type/reasoning.

**User action:** Run `/sprint:work-auto --issue {N}` to start work on recommended issues.

### Quick Actions
- `/audit:milestone` - Full analysis
- `/issue:capture "desc"` - Add to backlog

## Velocity Format (--velocity flag)

```
### Velocity Metrics

| Metric | Value |
|--------|-------|
| Closed this week | {count} |
| Avg cycle time | {days} days |
| Velocity | {rate} issues/week |
| Projected completion | {date} |

**Trend:** {Accelerating|Stable|Slowing}
```

## All Milestones Format (--all flag)

```
## All Open Milestones

| Milestone | Due | Progress | Issues | Status |
|-----------|-----|----------|--------|--------|
| {name} | {date} | {pct}% | {closed}/{total} | {status} |
```

## Dependency & Parallel Work Analysis Format (--deps flag, full mode only)

Rendered when `dependencies.parallel_analysis` exists in the data.

```
### Dependency & Parallel Work Analysis

**Summary:**
- Total backlog issues: {summary.total_backlog}
- Sequential required: {summary.sequential_required}
- Parallel ready: {summary.parallel_ready}
- Conflict risks: {summary.conflict_risks}

#### Sequential Work Required

Issues with dependencies or blocking relationships that require specific ordering:

| Issue | Title | Constraints |
|-------|-------|-------------|
| #{number} | {title} | Depends on: #{deps}, Blocks: #{blocks}, Parent: #{epic} |

#### Parallel Work Safe

Issues with no dependencies that can be executed simultaneously:

| Issue | Title | Priority | Type |
|-------|-------|----------|------|
| #{number} | {title} | {priority} | {type} |

#### Conflict Risks

Issues that may have implicit ordering requirements:

| Risk Type | Issues | Description |
|-----------|--------|-------------|
| {risk_type} | #{issues} | {description} |

**File Overlap Risks** (if active worktrees exist):
| File | Affected Issues | Risk Level |
|------|----------------|------------|
| {file_path} | #{issues} | {high/medium/low} |

**Recommendations:**
1. {priority_1_action}: #{issues} - {reason}
2. {priority_2_action}: #{issues} - {reason}
3. {priority_3_action}: #{issues} - {reason}
```

**Rendering Logic:**
- Only show "Sequential Work Required" if any sequential work exists
- Only show "Parallel Work Safe" if 2+ parallel issues exist
- Only show "Conflict Risks" if risks detected
- Only show "File Overlap Risks" if overlaps detected in active worktrees
- Sort sequential work by: foundational first (blocks others), then epics, then dependent issues
- Sort parallel work by priority (P0 > P1 > P2 > P3)
- Recommendations provide actionable next steps for PM orchestration

## Branch Hygiene Audit (full mode only)

Rendered when `branch_audit.stale_merged_branches.count > 0`. Shows stale remote branches that have been merged and can be safely deleted.

```
### Branch Hygiene

**Summary:**
- Total remote branches: {total_remote_branches}
- Stale merged branches: {stale_merged_branches.count}
- Protected branches: {protected_branches.count}
- Active unmerged: {active_unmerged_branches.count}
- Open PR branches: {open_pr_branches.count}

#### Stale Merged Branches

These branches have been merged into `dev` and can be safely deleted:

| Branch | Type | Status |
|--------|------|--------|
| {branch_name} | {feat/fix/chore/docs/refactor} | Merged to dev |

**Recommendation:** {recommendation}

**Cleanup Actions:**
- Preview: `./scripts/git/branch-audit.sh --dry-run`
- Delete stale branches: `./scripts/git/branch-audit.sh --prune`
```

**Rendering Logic:**
- Only show this section if `branch_audit.stale_merged_branches.count > 0`
- Parse branch names to extract type (feat/, fix/, chore/, docs/, refactor/)
- Protected branches (main, dev, qa, release/*) are never included in stale list
- Branches with open PRs are excluded from stale list
- Recommendation field provides direct action command

**Protected Branches:**
The following branch patterns are protected and will never be pruned:
- `main` - Production branch
- `dev` - Development integration branch
- `qa` - QA testing branch
- `release/*` - Release branches

**Auto-Delete Configuration:**
GitHub can be configured to automatically delete head branches after PR merge:
1. Repository Settings → General → Pull Requests
2. Enable "Automatically delete head branches"
3. This removes merged feature branches without manual intervention

**Implementation Note:**
- Branch audit data is collected by `scripts/git/branch-audit.sh`
- Only runs in `--full` mode to minimize API calls
- Uses `git branch -r --merged origin/dev` to identify merged branches
- Cross-references with `gh pr list` to exclude branches with open PRs

## Self-Check (Before Completing)

Verify sections rendered match the mode:

**Minimal mode:**
- Header (compact), Priority counts, Next recommendation, Quick action link
- **Expected output:** 100-200 tokens

**Default mode:**
- Core: Header, Progress, Distribution, Priority Queue, Quick Actions
- Conditional: Active Work, Worktrees for cleanup
- Always: Prioritized Next Actions, Recommended Next
- **Expected output:** 500-800 tokens

**Full mode:**
- Core: Header, Progress, Distribution, Priority Queue, Quick Actions
- Conditional: CI Failures, Branch Hygiene, Active Work, Health, Labels, Unpushed, Cleanup, Containers, Dependencies
- Always: Prioritized Next Actions, Recommended Next
- **Expected output:** 800-1500 tokens (add ~200-400 tokens if --deps used)

## Container Status (Docker only)

Render when `container_status.summary.total > 0`. Shows issue/status/age table.
**Status:** running | stopped | failed | orphan (>24h)
**Cleanup:** `./scripts/container/container-cleanup.sh --issue {N}` or `--all-stopped` or `--orphans`

## Token Optimization

This skill has been optimized for minimal token usage:

**Before optimization (v1):**
- Skill file: 920 lines (~28KB)
- Cache JSON: 50KB
- Total context load: ~78KB

**After optimization (v2):**
- Skill file: ~350 lines (~10KB)
- Cache JSON: ~5KB (minimal mode)
- Total context load: ~15KB

**Savings: 81% reduction**

**Key optimizations applied:**
- ✅ Interactive flows extracted to dedicated skills
- ✅ Redundant data fields removed (issue_health, active_issues)
- ✅ Tiered output modes (--minimal, default, --full)
- ✅ Minimal cache by default, full on-demand
- ✅ Health/status derived at render time (not pre-computed)

**Measurement methodology:**
- Baseline: Full skill + full cache loaded
- Current: Core skill + minimal cache
- See `/docs/METRICS_OBSERVABILITY.md` for methodology

**Implementation details:**
- **Data script:** `scripts/sprint/sprint-status-data.sh`
- **Cache:** 60-second cache from UserPromptSubmit hook
- **Tiered loading:** Mode-based data fetching reduces API calls
  - Minimal: 3 API calls (milestone, issues, PRs)
  - Default: 4 API calls (+ worktrees)
  - Full: 7 API calls (+ unpushed, containers, CI status)
- **Target output by mode:**
  - Minimal: 100-200 tokens (~3s)
  - Default: 500-800 tokens (~5s)
  - Full: 800-1500 tokens (~10s)

## Container Health Metrics (Docker environments only)

Container data is automatically included in the main data script output as `container_status`.
This shows fire-and-forget sprint-work containers launched via `--fire-and-forget` or `--sprint-work --detach`.

### Active Containers [RENDER when container_status.summary.total > 0]

*Uses `container_status` from sprint-status-data.sh. Shows fire-and-forget container status with real-time health metrics.*

| Issue | Status | Phase | Heartbeat | CPU | Memory |
|-------|--------|-------|-----------|-----|--------|
| #{issue} | {health_indicator} {status} | {current_phase} | {heartbeat_display} | {cpu_percent} | {memory_usage} |

**Health Summary:** {healthy} healthy, {warning} warning, {unhealthy} unhealthy

{action_recommendations}

**Health Legend:**
- 🟢 Healthy: heartbeat < 60s, active processing
- 🟡 Warning: heartbeat 60-120s, approaching timeout
- 🔴 Unhealthy: heartbeat > 120s or container may be stuck
- ⚪ Stopped: Container exited cleanly

**Container Summary:**
- Running: {container_status.summary.running}
- Stopped: {container_status.summary.stopped}
- Failed: {container_status.summary.failed}
- Orphans (>{container_status.summary.orphan_threshold_hours}h): {container_status.summary.orphans}

**View Logs:**
- `docker logs -f claude-tastic-issue-{N}` (follow mode)
- `docker logs claude-tastic-issue-{N}` (view all logs)

**Cleanup Actions:**
- Single: `./scripts/container/container-cleanup.sh --issue {N}`
- All stopped: `./scripts/container/container-cleanup.sh --all-stopped`
- Orphans: `./scripts/container/container-cleanup.sh --orphans`

**Rendering Logic:**
- Format heartbeat: <60s show seconds (e.g., "5s ago"), 60-120s show minutes (e.g., "95s ago"), >120s show minutes (e.g., "5m ago"), -1 show "no logs"
- Show recommendations for unhealthy containers: "Container #{N} may be stuck. Check logs: docker logs claude-tastic-issue-{N}"
- Group recommendations by health status (unhealthy first, then warnings)
- Empty phase shows as "-"

## Notes

- **READ-ONLY** by default; WRITE delegated to `/pr-merge`, `/worktree-audit`, `/worktree-cleanup`
- **NEVER invoke** `/sprint-work` or create worktrees - all actions require explicit user approval
- Uses batch script for API efficiency; render ALL sections when data exists
- **Related:** `/pr-merge`, `/worktree-audit`, `/worktree-cleanup`

## SAFEGUARD: BOUNDARY ENFORCEMENT

**DO NOT use the Skill tool to execute /sprint-work or create worktrees.**

All recommended actions are for explicit USER approval and execution only. Sprint-status:
1. Displays status and recommendations
2. Presents "User action:" suggestions that the user should run
3. NEVER automatically triggers work execution

The Skill tool MUST NOT be used to invoke `/sprint-work` from within this skill.
