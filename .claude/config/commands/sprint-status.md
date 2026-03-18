---
description: Review sprint/project status by querying GitHub issues and cross-referencing documentation (READ-ONLY by default, --auto-merge enables PR merging)
---

# Sprint Status

**🔒 READ-ONLY OPERATION by default - This skill NEVER executes work or creates worktrees**

Quick view of current sprint/milestone progress, issue distribution, and **PM orchestration intelligence**.

This skill provides passive status reporting and PM recommendations including:
- Issue health analysis (staleness detection)
- Label audit (missing required labels)
- Unpushed work review with recommendations
- Prioritized next actions (presented for user to execute)
- Consolidation opportunities
- **Auto-merge mergeable PRs** (with `--auto-merge` flag)

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports (unless `--auto-merge` flag is used)
- All suggested commands (e.g., `/sprint-work`) are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work`, `sprint-work-preflight.sh`, or any write operations from this skill
- User-initiated cleanup prompts and `--auto-merge` are the ONLY write operations allowed
- DO NOT use the Skill tool to execute `/sprint-work` - all recommendations are informational only

## CRITICAL: Full Output Required

**⚠️ DO NOT simplify or abbreviate output. You MUST render ALL sections listed below when their data exists.**

This skill requires FULL output - not a summary. The user expects a comprehensive PM report.
Failure to render all sections is a bug that wastes the user's time.

**Mandatory Sections (always render):**
1. Sprint Header + Progress Bar + Issue Distribution
2. Priority Queue
3. Issue Health Analysis (when `issue_health[]` has entries)
4. Label Audit (when `label_audit[]` has entries)
5. Unpushed Work Review (when `unpushed_work_review.total_with_unpushed > 0`)
6. Prioritized Next Actions (ALWAYS - generate from analysis)
7. Recommended Next Actions (when `recommended_next[]` has entries)
8. Quick Actions

**JSON Field → Section Mapping:**
| Data Field | Section to Render |
|------------|-------------------|
| `auto_merge_results` | Auto-Merge Results (when --auto-merge flag used) |
| `pr_status[]` | Active Work (with lifecycle_state, action_needed) |
| `active_issues[]` | Currently Active, Active Work |
| `blocked_issues[]` | Blocked Issues |
| `issue_health[]` | Issue Health Analysis |
| `label_audit[]` | Label Audit |
| `unpushed_work_review` | Unpushed Work Review |
| `recommended_next[]` | Recommended Next Actions |
| `by_priority` | Priority Queue |
| `container_status` | Active Containers (fire-and-forget sprint-work) |
| `repo_ci_status` | Repo-Level CI Failures (failures on main/dev/qa branches) |

## Usage

```
/sprint-status              # Current milestone
/sprint-status --all        # All open milestones
/sprint-status --velocity   # Include velocity metrics
/sprint-status --deps       # Include full dependency graph
/sprint-status --auto-merge # Auto-merge mergeable PRs before reporting
```

**Auto-Merge Mode (`--auto-merge`):**

When `--auto-merge` flag is used, sprint-status will:
1. Find all PRs linked to milestone issues that are in mergeable state (MERGEABLE + CLEAN)
2. Merge them using squash merge with branch deletion
3. Sync the local repository to latest after merges complete
4. Then generate and display the status report reflecting the post-merge state

This ensures the status report shows the true current state of the sprint after all ready work is merged.

## Prerequisites

**Ensure you are in the repository root before running scripts.**
If the working directory may have changed, first run:
```bash
cd "$(git rev-parse --show-toplevel)"
```

**⚠️ SAFEGUARD CHECK:**
- Do NOT run `sprint-work-preflight.sh` from this skill
- Do NOT invoke `/sprint-work` command from this skill
- This is a READ-ONLY reporting skill (except when `--auto-merge` flag is explicitly used)
- All work execution suggestions should be presented to the user, not executed automatically
- **Exception:** `--auto-merge` flag enables WRITE operations (PR merging) when user explicitly requests it

## Steps

1. **Gather sprint data (cache-first)**
   Check for preprocessed cache before running the data script:
   ```bash
   # Cache populated by UserPromptSubmit hook (sprint-status-preprocess.sh)
   # NOTE: Skip cache if --auto-merge is used (we need fresh data after merges)
   if [ -f /tmp/sprint-status-cache.json ] && [ $(($(date +%s) - $(stat -f %m /tmp/sprint-status-cache.json))) -lt 60 ] && [ "$AUTO_MERGE" != true ]; then
     cat /tmp/sprint-status-cache.json  # Use cached data (no API calls needed)
   else
     ./scripts/sprint/sprint-status-data.sh [milestone] [--velocity] [--all] [--deps] [--auto-merge]
   fi
   ```

   Returns JSON including:
   - milestone metadata, counts by status/type/priority
   - `issue_health[]` - age, staleness, health status per issue
   - `label_audit[]` - issues with missing required labels
   - `unpushed_work_review` - worktrees with uncommitted/unpushed work
   - `recommended_next[]` - prioritized backlog issues with reasoning
   - `pr_status[]` - PRs with lifecycle_state and action_needed
   - `auto_merge_results` - results of auto-merge operation (when --auto-merge used)
   - velocity, worktree cleanup info, dependency graph

1b. **Gather PR check details (if pr_status has unstable/ready PRs)**
   `./scripts/pr/pr-checks-analysis.sh --milestone "$MILESTONE"`

   Returns JSON including:
   - Check status (passed, failed, pending) per PR
   - `remediations[]` - Suggestions for fixing failing checks
   - `can_merge` - Whether PR is ready to merge

2. **Pre-render validation (MANDATORY)**
   Before writing ANY output, check the JSON for these fields and note which sections are needed:
   ```
   □ repo_ci_status.repo_level_ci.has_failures? → MUST render Repo-Level CI Failures (FIRST - blocking issue)
   □ issue_health[] length > 0?  → MUST render Issue Health Analysis
   □ label_audit[] length > 0?   → MUST render Label Audit
   □ unpushed_work_review.total_with_unpushed > 0? → MUST render Unpushed Work Review
   □ recommended_next[] length > 0? → MUST render Recommended Next Actions
   □ by_priority has any > 0?    → MUST render Priority Queue
   □ pr_status[] has MERGEABLE PRs? → MUST prompt "Merge MERGEABLE PRs? [y/n/select]"
   □ pr_status[] has unstable/blocked PRs? → MUST render Non-MERGEABLE PR handling options
   ```

   **If you skip a section that should be rendered, you have a bug. Go back and fix it.**

3. **Calculate progress**
   - Progress = closed / total * 100
   - Days remaining = due_on - today

4. **Format report** using output template

   **⚠️ MANDATORY: You MUST render ALL sections marked [REQUIRED] below.**
   Check the data and include each section that has data available.

   **DO NOT abbreviate or summarize. Render the FULL template for each section.**

5. **Section checklist** (verify before completing response):
   - [ ] Repo-Level CI Failures (if `repo_ci_status.repo_level_ci.has_failures`) [REQUIRED when failures exist - SHOW FIRST]
   - [ ] Auto-Merge Results (if `auto_merge_results` exists with `merged_count > 0`) [REQUIRED when --auto-merge used]
   - [ ] Sprint header with milestone/progress [REQUIRED]
   - [ ] Progress Bar [REQUIRED]
   - [ ] Issue Distribution table [REQUIRED]
   - [ ] Priority Queue [REQUIRED]
   - [ ] Active Work (if `pr_status[]` or `active_issues[]` has entries) [REQUIRED when data exists]
   - [ ] PR Merge Prompt (if MERGEABLE PRs exist AND --auto-merge NOT used) [INTERACTIVE - prompt "Merge MERGEABLE PRs? [y/n/select]"]
   - [ ] Non-MERGEABLE PR Handling (if unstable/blocked PRs exist) [INTERACTIVE when applicable]
   - [ ] Issue Health Analysis (if `issue_health[]` has entries) [REQUIRED when data exists]
   - [ ] Label Audit (if `label_audit[]` has entries) [REQUIRED when data exists]
   - [ ] Unpushed Work Review (if `unpushed_work_review.total_with_unpushed > 0`) [REQUIRED when data exists]
   - [ ] Prioritized Next Actions [REQUIRED - always generate]
   - [ ] Recommended Next Actions (if `recommended_next[]` has entries) [REQUIRED when data exists]
   - [ ] Quick Actions [REQUIRED]

6. **Cleanup prompt** (if worktrees for closed issues exist AND cleanup_allowed is true)
   - Display "Worktrees Pending Cleanup" section
   - `cleanup_allowed` is a boolean field from sprint-status-worktrees.sh:
     - `true` when running from main repository (`.git` directory exists)
     - `false` when running from within a worktree
   - If `cleanup_allowed: false`, show note: "⚠️ Cleanup must be run from main repository"
   - If `cleanup_allowed: true`, prompt: "Clean up stale worktrees? [y/n/select]"
   - Execute cleanup based on user choice (see Output Format for details)

## Output Format

```
### Auto-Merge Results [RENDER when auto_merge_results exists with merged_count > 0]

*Shows results of automatic PR merging when --auto-merge flag was used.*

| PR | Issue | Title | Result |
|----|-------|-------|--------|
| #{pr_number} | #{linked_issue} | {title} | ✓ Merged |

**Summary:** {merged_count} PRs merged, {failed_count} failed, {skipped_count} skipped
**Repository synced to latest**

---

### Repo-Level CI Failures [RENDER when repo_ci_status.repo_level_ci.has_failures == true]

*Shows CI failures on main branches (main, dev, qa) that are distinct from PR/worktree-level failures.*
*These failures affect the entire repository and may block PR merges.*

**Status:** {failing_count} workflows failing on {branches_affected}

| Workflow | Branch | Guidance |
|----------|--------|----------|
| {workflow} | {branch} | {guidance} |

**Resolution Commands:**
```bash
# View failure details
{view_command}

# Re-run failed workflow
gh run rerun {run_id} --failed
```

**Why This Matters:**
- Repo-level CI failures can block all PR merges to affected branches
- These are NOT caused by your current worktree/PR changes
- Must be fixed at the repository level (usually on `dev` or `main`)

**Quick Actions:**
- `gh run list --branch dev` - List recent runs on dev
- `gh run view {run_id} --log-failed` - View specific failure logs
- Fix issues locally, commit to appropriate branch

---

## Sprint Status

**Milestone:** {name}
**Due:** {date} ({days_remaining} days remaining)
**Progress:** {percent}% complete ({closed}/{total} issues)

---

### Progress Bar

[{bar}] {percent}% ({closed}/{total})

---

### Issue Distribution

| Status | Count | % |
|--------|-------|---|
| Backlog | {backlog} | {pct}% |
| In Progress | {in_progress} | {pct}% |
| Blocked | {blocked} | {pct}% |
| Completed | {closed} | {pct}% |

---

### Priority Queue

| Priority | Open | Next Up |
|----------|------|---------|
| P0 | {count} | #{number}: {title} |
| P1 | {count} | #{number}: {title} |
| P2 | {count} | - |
| P3 | {count} | - |

---

### Currently Active

| Issue | Status | Started |
|-------|--------|---------|
| #{number}: {title} | in-progress | {time_ago} |

---

### Blocked Issues

| Issue | Blocker | Since |
|-------|---------|-------|
| #{number}: {title} | {reason} | {time_ago} |

---

### Active Work [REQUIRED when pr_status[] or active_issues[] is not empty]

*Bridges the gap between `wip:checked-out` and issue closure with PR lifecycle visibility.*

| Issue | Status | PR | Action Needed |
|-------|--------|-----|---------------|
| #{number}: {title} | {lifecycle_state} | #{pr_number} | {action_needed} |

**Lifecycle States:**
- `checked-out` - Worktree exists, development in progress
- `draft` - PR exists but marked as draft
- `open` - PR under review, awaiting feedback
- `ready` - PR approved and CI passing, ready to merge
- `unstable` - CI checks failing
- `blocked` - Merge blocked or changes requested
- `behind` - Branch needs update from base

**Actions:** Execute recommended action or run `/sprint-work --issue {N}` to continue

---

### PRs with Health Status [REQUIRED when pr_status[] has entries with health data]

*Enhanced PR section showing health indicators and specific actionable recommendations.*

| PR | Issue | Health | Action |
|----|-------|--------|--------|
| #{pr_number} | #{linked_issue} | {health.status} | {health_action_recommendation} |

**Health Legend:**
- `READY` - Can merge immediately (all checks passing, no conflicts)
- `STALE` - All commits already in base branch, should close
- `NEEDS_REBASE` - Behind base branch by N commits, needs rebase
- `CONFLICTING` - Has merge conflicts that need resolution
- `BLOCKED` - CI checks failing ({failed_count} check(s))

**Action Recommendations (based on health.status):**
- `READY` → "Merge now" (use `/pr-merge {PR#}` or merge via GitHub)
- `STALE` → "Close (all upstream)" (all commits already in base)
- `NEEDS_REBASE` → "Rebase required" (use `/pr-rebase {PR#}`)
- `CONFLICTING` → "Resolve conflicts" (use `/pr-rebase {PR#}`)
- `BLOCKED` → "Fix CI checks" (review {failed_count} failing check(s))

**Data Source:** Each PR in `pr_status[]` includes a `health` object with:
```json
{
  "status": "READY|STALE|NEEDS_REBASE|CONFLICTING|BLOCKED",
  "commits_upstream": 0,
  "commits_behind_base": 0,
  "recommended_action": "merge|close|rebase|fix",
  "reason": "Human-readable reason"
}
```

**Health data collection:** Already implemented in `scripts/sprint/sprint-status-data.sh` (lines 222-287). The script enhances each PR with inline health metrics including:
- Commits behind base branch
- Commits already upstream (merged into base)
- CI check failures
- Merge conflict detection

**Example rendering:**
```
### Pull Requests

| PR | Issue | Health | Action |
|----|-------|--------|--------|
| #185 | #144 | STALE | Close (all upstream) |
| #190 | #166 | NEEDS_REBASE | Rebase required (5 commits behind) |
| #192 | #173 | READY | Merge now |
| #194 | #175 | CONFLICTING | Resolve conflicts |
| #196 | #178 | BLOCKED | Fix CI checks (2 failing) |
```

---

### PR Merge Handling [INTERACTIVE - when pr_status[] has MERGEABLE PRs]

*Provides interactive merge prompts similar to worktree cleanup flow.*

**Step 1: Identify MERGEABLE PRs**

Filter `pr_status[]` for PRs where:
- `mergeable == "MERGEABLE"` AND
- `merge_state == "CLEAN"` AND
- (`review_decision == "APPROVED"` OR `review_decision == null` for repos without required reviews)

**Step 2: Display MERGEABLE PRs summary**

```
### PRs Ready to Merge

| # | PR | Issue | Title | Checks | Review |
|---|-----|-------|-------|--------|--------|
| 1 | #{pr_number} | #{linked_issue} | {title} | ✓ Passing | ✓ Approved |
| 2 | #{pr_number} | #{linked_issue} | {title} | ✓ Passing | - No review required |

**Total:** {count} PRs ready to merge
```

**Step 3: Batch merge prompt**

```
Merge MERGEABLE PRs? [y/n/select]
```

**If 'y' (merge all):**
- For each MERGEABLE PR, run pre-merge validation (Step 4)
- Execute merge for all that pass validation
- Report results for each

**If 'n':**
- Skip merge handling, continue to next section

**If 'select':**
- Present numbered list of PRs
- Let user choose which to merge (comma-separated numbers, e.g., "1,3")
- Run pre-merge validation and merge selected PRs only

---

**Step 4: Pre-merge validation (per PR)**

Before executing merge, verify:

```bash
# Re-check PR is still mergeable (state may have changed)
gh pr view {pr_number} --json mergeable,mergeStateStatus,reviewDecision
```

**Validation checklist:**
- [ ] `mergeable == "MERGEABLE"` - GitHub confirms merge is possible
- [ ] `mergeStateStatus == "CLEAN"` - All status checks passing
- [ ] No merge conflicts detected
- [ ] Review requirements met (if repo requires reviews)

**If validation fails:**
```
⚠️ PR #{pr_number} is no longer mergeable

Reason: {validation_failure_reason}

Options:
1. Skip this PR
2. View PR details
3. Abort remaining merges

Select [1/2/3]:
```

---

**Step 5: Execute merge**

```bash
gh pr merge {pr_number} --squash --delete-branch
```

**Merge options:**
- `--squash` - Squash commits into single commit (default)
- `--delete-branch` - Delete branch after merge (keeps repo clean)

**Note on linked issues:** If the PR body contains "Fixes #N", "Closes #N", or "Resolves #N",
GitHub will automatically close the linked issue when the PR merges.

---

**Step 6: Report results**

After all merges complete, display summary:

```
### Merge Results

| PR | Issue | Result | Notes |
|----|-------|--------|-------|
| #{pr_number} | #{linked_issue} | ✓ Merged | Issue auto-closed |
| #{pr_number} | #{linked_issue} | ✗ Failed | {error_reason} |

**Summary:** {merged_count}/{total_count} PRs merged successfully
```

**If any failures occurred:**
- Display error details
- Suggest remediation actions
- Offer to retry failed merges

---

### Handling Non-MERGEABLE PRs

*For PRs that aren't immediately mergeable, offer appropriate actions.*

#### Unstable - CI Failing (lifecycle_state = "unstable")

When a PR has `checks.failed > 0`:

```
PR #{pr_number} has failing CI checks

**Failing Checks:**
| Check | Suggestion |
|-------|------------|
| {check_name} | {remediation_suggestion} |

**Options:**
[r] Re-run failed checks
[v] View check details in browser
[s] Skip for now

Select action:
```

**If 'r' (re-run):**
```bash
gh run rerun --failed --repo {owner}/{repo}
```
Note: Requires identifying the workflow run ID from failed checks.

**If 'v' (view):**
```bash
gh pr checks {pr_number} --web
```

#### Blocked - Merge Conflicts (lifecycle_state = "blocked")

When merge_state is BLOCKED:

```
PR #{pr_number} is blocked

**Reason:** {merge_state_reason}

**To resolve:**
1. Fetch latest: `git fetch origin dev`
2. Rebase: `git rebase origin/dev`
3. Resolve conflicts manually
4. Force push: `git push --force-with-lease`

Skip for now? [y/n]
```

#### Behind - Needs Update (lifecycle_state = "behind")

When merge_state is BEHIND:

```
PR #{pr_number} needs update from base branch

**Options:**
[u] Update branch (merge base into PR)
[s] Skip for now

Select action:
```

**If 'u' (update):**
```bash
gh api repos/{owner}/{repo}/pulls/{pr_number}/update-branch -X PUT
```

---

### Health Indicators

| Metric | Status |
|--------|--------|
| On Track | {yes_no} |
| Blocked Issues | {count} |
| Stale In-Progress | {count} |

---

## PM Orchestration Sections [REQUIRED - DO NOT SKIP]

**⚠️ CRITICAL: The following sections MUST be rendered when their data exists.**
**Failure to render these sections is a bug. Always check the JSON for these fields.**

### Issue Health Analysis [REQUIRED when issue_health[] is not empty]

*Uses `issue_health[]` from data script. Shows health status per open issue.*
*If `issue_health` array has ANY entries, you MUST render this section.*

| Issue | Age | Last Update | Health |
|-------|-----|-------------|--------|
| #{number}: {title} | {age_days}d | {days_since_update}d ago | {health_icon} {health} |

**Health Status Legend:**
- `active` - In-progress with recent updates (good)
- `stale` - In-progress but no updates in 3+ days (needs attention)
- `idle` - Backlog with no updates in 5+ days (may need triage)
- `epic` - Epic issue (parent of child issues)
- `ok` - Normal backlog item

**Recommendations:**
*Generate from analysis. Example:*
- #{stale_issue} has been stale for {days}d - consider updating or reassigning
- #{idle_issue} may need triage - no activity in {days}d

**User action:** Run `/sprint-work --issue {stale_issue}` manually to continue work

---

### Label Audit [REQUIRED when label_audit[] is not empty]

*Uses `label_audit[]` from data script. Shows issues missing required labels.*
*If `label_audit` array has ANY entries, you MUST render this section.*

| Issue | Missing Labels | Suggestion |
|-------|----------------|------------|
| #{number} | {missing_type} | Add {suggested_label} |

**Required Label Categories:**
- **Status**: `backlog`, `in-progress`, `blocked`
- **Type**: `bug`, `feature`, `tech-debt`, `docs`, `epic`
- **Priority**: `P0`, `P1`, `P2`, `P3`

**Recommendations:**
*Generate from audit results. Example:*
- #{issue} missing priority label - suggest P2 based on type ({type})
- #{issue} missing status label - add `backlog` as default

**User action:** Run `/label-issue {issue} --add {label}` manually to fix labels

---

### Unpushed Work Review [REQUIRED when unpushed_work_review.total_with_unpushed > 0]

*Uses `unpushed_work_review` from data script. Surfaces work that may be lost.*
*If `unpushed_work_review.total_with_unpushed > 0`, you MUST render this section.*

**Risk Summary:**
| Risk Level | Count | Action |
|------------|-------|--------|
| HIGH | {risk_counts.HIGH} | Archive (work may be lost) |
| MED | {risk_counts.MED} | Review/commit changes |
| LOW | {risk_counts.LOW} | Safe to discard |

**Detailed View:**

| # | Issue | State | Risk | Commits | Recommended Action |
|---|-------|-------|------|---------|-------------------|
| 1 | #{number} | {state} | {risk_level} | {unpushed_commits} | {recommendation} |

**Risk Level Definitions:**
- **HIGH**: Issue CLOSED + NO PR merged + unpushed commits exist (work may be permanently lost)
- **MED**: Uncommitted changes OR open issue with unpushed work (needs attention)
- **LOW**: PR merged, commits are stale duplicates (safe to discard)

**Interactive Remediation:**

*After displaying the table, prompt user if HIGH or LOW risk items exist:*

```
Unpushed Work Detected ({total_with_unpushed} worktrees)

Risk Summary: {HIGH} HIGH, {MED} MED, {LOW} LOW

Actions:
[a] Archive all HIGH risk (push to archive/* branches)
[d] Discard all LOW risk (remove worktrees, PR already merged)
[r] Review specific issue (enter number)
[s] Skip for now

Select action:
```

**If 'a' (archive HIGH risk):**
For each HIGH risk worktree:
```bash
./scripts/worktree/worktree-archive.sh {issue_number} --cleanup
```
Report: "Archived {N} commits to archive/{branch}, worktree cleaned up"

**If 'd' (discard LOW risk):**
For each LOW risk worktree (where PR was merged):
```bash
./scripts/worktree/worktree-discard.sh {issue_number}
```
Report: "Discarded worktree for #{issue} (PR #{pr_number} already merged)"

**If 'r' (review specific):**
- Present numbered list
- Let user enter issue number
- Show details: `git -C ../repo-issue-{N} log --oneline @{upstream}..HEAD`
- Offer: Archive / Discard / Push / Skip

**HIGH Risk Confirmation:**
```
Worktree for #{N} has HIGH risk:
  - {unpushed_commits} unpushed commits
  - Issue is CLOSED
  - NO PR was merged

This work may be permanently lost. Archive it?
[y] Yes, archive to archive/{branch}
[n] No, skip for now
[v] View commits first

Select [y/n/v]:
```

**Audit Trail:**
All archive/discard operations are logged to:
- `~/.claude-tastic/logs/archive.log` (archives)
- `~/.claude-tastic/logs/worktree-cleanup.log` (discards)

Format: `timestamp|action|issue|branch|details`

**Manual Commands:**
- Review commits: `git -C ../repo-issue-{N} log --oneline @{upstream}..HEAD`
- Push work: `git -C ../repo-issue-{N} push`
- Archive: `./scripts/worktree/worktree-archive.sh {issue}`
- Discard: `./scripts/worktree/worktree-discard.sh {issue}`

---

### Prioritized Next Actions [REQUIRED - ALWAYS GENERATE]

*Generated by analyzing all status data. Provides actionable next steps.*
*You MUST always generate this section based on analysis of the sprint data.*

| Priority | Action | Reason |
|----------|--------|--------|
| 1 | {action} | {reason} |
| 2 | {action} | {reason} |
| 3 | {action} | {reason} |

**Prioritization Logic:**
1. Complete in-progress issues first (momentum)
2. Address stale in-progress issues (unblock)
3. Clean safe worktrees (reduce clutter)
4. Review unpushed commits (preserve work)
5. Triage idle backlog items (maintain hygiene)
6. Start highest priority backlog (P0 > P1 > P2)

**User action:** User should run `/sprint-work --issue {recommended_issue}` to begin work

---

### Consolidation Opportunities

*Identifies similar issues that may be duplicates or candidates for merging.*

| Issues | Similarity | Suggestion |
|--------|------------|------------|
| #{A}, #{B} | {score}% | {suggestion} |

**Similarity Detection:**
- Title keyword matching (tokenized comparison)
- Description overlap (common phrases)
- Label overlap (same type/priority)
- File reference overlap (same files mentioned)

**Score Thresholds:**
- **High (>70%)**: Likely duplicates - merge or close one
- **Medium (50-70%)**: Related - consider linking or epic grouping
- **Low (30-50%)**: Possibly related - review for dependencies

**Recommendations:**
*Generate from similarity analysis. Example:*
- #67 and #46 both mention "token optimization" - consider merging
- #68 and #69 both modify worktree scripts - may conflict

**Action:** Review similar issues and decide:
- Merge (close one, link to other)
- Link (add dependency reference)
- Keep separate (different scope)

---

### Issue Dependencies

*Only shown if dependencies or file overlaps detected*

**Dependency Graph:**
```
#{from} ──depends──▶ #{to} ({state})
#{from} ──related──▶ #{to} ({state})
```

**File Overlaps:**
| Worktree A | Worktree B | Overlapping Files |
|------------|------------|-------------------|
| issue-{N} | issue-{M} | {file1}, {file2} |

**Recommended Merge Order:**
1. #{number}: {title} (no dependencies)
2. #{number}: {title} (depends on #N)
...

---

### Worktrees Pending Cleanup

*Only shown if worktrees exist for closed issues*

| Worktree | Issue | Closed | Conflicts | Branch |
|----------|-------|--------|-----------|--------|
| {path} | #{number}: {title} | {time_ago} | {conflicts} | {branch} |

**Conflicts Legend:**
- `None` - Safe to remove
- `Uncommitted changes` - Has modified files (review before cleanup)
- `N unpushed commits` - Has commits not pushed to remote

**Total:** {cleanup_count} worktrees ready for cleanup (of {total} issue worktrees)

**If running from worktree (cleanup_allowed: false):**
```
⚠️ Worktree cleanup must be run from the main repository.
To clean up, switch to the main repo and run /sprint-status again.
```

**If running from main repo (cleanup_allowed: true):**

**Cleanup commands:**
- Batch (preferred): `./scripts/worktree/worktree-cleanup-batch.sh {issue1},{issue2},{issue3}`
- Single: `./scripts/worktree/worktree-cleanup.sh {issue_number}`
- With branch: `./scripts/worktree/worktree-cleanup.sh {issue_number} --delete-branch`

**Cleanup prompt (if worktrees found):**

After displaying the table, prompt user:
```
Clean up stale worktrees? [y/n/select]
```

**If 'y' (all safe) - USE BATCH CLEANUP:**
1. Collect all issue numbers with `conflicts: None` into comma-separated list
2. Run SINGLE command: `./scripts/worktree/worktree-cleanup-batch.sh {issue1},{issue2},{issue3}`
3. Parse JSON response to report results

**Example (16 worktrees → 1 command instead of 16):**
```bash
./scripts/worktree/worktree-cleanup-batch.sh 15,21,29,30,32,34,37,39,43,44,45,51,52,53,59,60
```

**Response format:**
```json
{
  "success": true,
  "cleaned": [15, 21, 29, 30],
  "skipped": [{"issue": 32, "reason": "uncommitted changes"}],
  "errors": [],
  "summary": "Cleaned 4 worktrees, skipped 1"
}
```

Report: "{summary} - see audit log for details"

**If 'n':**
- Skip cleanup, continue to Quick Actions

**If 'select':**
- Present numbered list of worktrees
- Let user choose which to clean up (comma-separated numbers)
- Use batch cleanup with selected issues: `./scripts/worktree/worktree-cleanup-batch.sh {selected}`
- For worktrees with conflicts, add `--force` flag only if user explicitly confirms

**Force cleanup (with conflicts):**
```bash
./scripts/worktree/worktree-cleanup-batch.sh {issues} --force
```
Only use `--force` when user explicitly confirms they want to discard uncommitted/unpushed work.

**Conflict handling:**
```
⚠️ Some worktrees have conflicts:
  #{N}: {conflict_details}

Options:
1. Skip conflicted (clean only safe ones)
2. Force all (discard changes)
3. Review individually

Select [1/2/3]:
```

For option 2, run: `./scripts/worktree/worktree-cleanup-batch.sh {all_issues} --force`

**Audit Trail:**
All cleanup operations are logged to `~/.claude-tastic/logs/worktree-cleanup.log` with format:
`timestamp|user|repo|action|details|outcome`

---

### Recommended Next Actions [REQUIRED when recommended_next[] is not empty]

*Uses `recommended_next[]` from data script. Shows prioritized backlog issues with reasoning.*
*If `recommended_next` array has ANY entries, you MUST render this section.*

| Priority | Issue | Type | Action | Reasoning |
|----------|-------|------|--------|-----------|
| 1 | #{number} | {type} | Start work | {reasoning} |
| 2 | #{number} | {type} | Start work | {reasoning} |
| 3 | #{number} | {type} | Start work | {reasoning} |

**PM Recommendation:** Start with #{top_issue_number} ({title_summary}) - {primary_reasoning}

**User action:** User should run `/sprint-work --issue {top_issue_number}` to begin work

---

### Quick Actions

- `/milestone-audit` - Full milestone analysis
- `/capture "desc"` - Add new issue to backlog
```

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

## Self-Check Before Completing Response (MANDATORY)

**⚠️ STOP. Before finishing your response, you MUST verify you have rendered ALL required sections.**

**Check each box against your output:**

1. □ Repo-Level CI Failures - Check: is `repo_ci_status.repo_level_ci.has_failures` true? If yes, DID YOU RENDER IT FIRST?
2. □ Sprint header with milestone info - DID YOU RENDER IT?
3. □ Progress bar - DID YOU RENDER IT?
4. □ Issue Distribution table - DID YOU RENDER IT?
5. □ Priority Queue table - DID YOU RENDER IT?
6. □ PR Merge Prompt - Check: does `pr_status[]` have MERGEABLE PRs? If yes, DID YOU PROMPT "Merge MERGEABLE PRs? [y/n/select]"?
7. □ Issue Health Analysis - Check: is `issue_health[]` NOT empty? If yes, DID YOU RENDER IT?
8. □ Label Audit - Check: is `label_audit[]` NOT empty? If yes, DID YOU RENDER IT?
9. □ Unpushed Work Review - Check: is `unpushed_work_review.total_with_unpushed > 0`? If yes, DID YOU RENDER IT?
10. □ Prioritized Next Actions - DID YOU RENDER IT? (Always required)
11. □ Recommended Next Actions - Check: is `recommended_next[]` NOT empty? If yes, DID YOU RENDER IT?
12. □ Quick Actions - DID YOU RENDER IT?

**If ANY checkbox above is unchecked for data that exists, GO BACK AND ADD THE SECTION NOW.**

**Common mistake:** You rendered a simple summary instead of the full PM orchestration sections.
This is WRONG. Go back and render the complete sections with tables.

## Minimum Expected Output Size

A proper sprint-status report should be **800-1500 tokens** when PM orchestration data exists.
If your output is under 500 tokens, you probably skipped sections. Check again.

## Container Status Section (Docker environments only)

Container data is automatically included in the main data script output as `container_status`.
This shows fire-and-forget sprint-work containers launched via `--fire-and-forget` or `--sprint-work --detach`.

### Active Containers [RENDER when container_status.summary.total > 0]

*Uses `container_status` from sprint-status-data.sh. Shows fire-and-forget container status.*

| Issue | Status | Age | Last Activity |
|-------|--------|-----|---------------|
| #{issue} | {status} | {age_hours}h | {last_activity} |

**Container Summary:**
- Running: {container_status.summary.running}
- Stopped: {container_status.summary.stopped}
- Failed: {container_status.summary.failed}
- Orphans (>{container_status.summary.orphan_threshold_hours}h): {container_status.summary.orphans}

**Health Legend:**
- `running` - Container actively running
- `stopped` - Exited cleanly (exit code 0)
- `failed` - Exited with error (exit code != 0)
- `orphan` - Running > 24h with no activity

**Cleanup Actions:**
- Single: `./scripts/container/container-cleanup.sh --issue {N}`
- All stopped: `./scripts/container/container-cleanup.sh --all-stopped`
- Orphans: `./scripts/container/container-cleanup.sh --orphans`

---

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

## Notes

- **READ-ONLY OPERATION** by default: This skill queries data and presents reports only
- **WRITE OPERATIONS** enabled in these cases:
  - `--auto-merge` flag: Automatically merges mergeable PRs before reporting (user explicitly requested)
  - Worktree cleanup (when user selects y/select in interactive prompt)
  - PR merge (when user selects y/select in interactive prompt)
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - `sprint-work-preflight.sh` script
  - Worktree creation operations
  - Any other write operations without explicit user approval
  - DO NOT use the Skill tool to execute `/sprint-work` under any circumstance
- Uses batch script to minimize API calls
- PM orchestration sections provide actionable intelligence
- All recommendations include executable commands **FOR USER TO RUN**
- Token-efficient: ~500-800 tokens for basic report, ~1000-1500 with PM sections
- Similarity detection uses simple keyword matching (no ML dependencies)
- Container status requires Docker to be running
- **CRITICAL: Always render PM Orchestration sections when data exists**
- **This is a COMPREHENSIVE report, not a summary. Render all sections.**
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. `/sprint-work` is WRITE-FULL. Never cross this boundary.
