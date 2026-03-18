---
description: Close a milestone safely with validation and optional next milestone creation
---

# Close Milestone

Safely close a milestone after validating issues are complete and branch state is ready.

## Usage

```
/milestone-close              # Close active milestone
/milestone-close MVP          # Close specific milestone
/milestone-close --no-release # Skip release workflow prompt
/milestone-close --auto-promote  # Auto-promote dev→qa without prompts
/milestone-close --auto-promote --dry-run  # Preview auto-promotion
```

## Steps

### 1. Gather Data

```bash
./scripts/milestone-close-data.sh --validate "<name>"
# OR for active milestone:
./scripts/milestone-close-data.sh --validate
```

Returns JSON with milestone state, issues, and branch status.

### 2. Check Readiness

Review the returned JSON:
- `readiness.all_issues_complete`: true/false
- `issues.open_details`: Array of open issues
- `branch_state.can_release`: true/false

**If open issues exist:**
- Option 1: Run `/milestone-complete` for intelligent triage (MVP-critical vs deferrable analysis)
- Option 2: Move all to next milestone (create if needed)
- Option 3: Close anyway (not recommended)
- Option 4: Cancel

**Recommended:** Use `/milestone-complete` for smart analysis of which issues are MVP-critical
vs deferrable. This avoids blindly moving all issues and ensures critical work is completed.

### 3. Validate Branch State

From `branch_state`:
- `dev_ahead_of_qa`: Commits ready for QA promotion
- `qa_ahead_of_main`: Commits ready for release
- `open_prs_to_dev`: Should be 0
- `ci_status`: Should be "success"

### 4. Release Prompt (if validation passes)

Unless `--no-release`:
- If `dev_ahead_of_qa`: offer to run `/pr-to-qa` for QA promotion
- If `qa_ahead_of_main`: offer to run `/pr-to-main` for release

### 4a. Auto-Promote (if --auto-promote flag)

When `--auto-promote` flag is used, automatically promote dev→qa:

```bash
./scripts/milestone-complete-promotion.sh --milestone "${milestone_name}" --auto-merge
```

**Behavior:**
- Validates all issues are complete
- Checks CI status on dev branch
- Creates PR from dev→qa with milestone summary (changelog included)
- Auto-merges when `--auto-merge` is passed

**Flags:**
- `--auto-promote`: Enable automatic dev→qa promotion
- `--auto-promote --dry-run`: Preview what would happen without action
- `--auto-promote --no-merge`: Create PR but skip auto-merge (user merges later)

**Related Scripts:**
- `scripts/milestone-complete-promotion.sh` - Human-readable promotion (for CLI/interactive use)
- `scripts/auto-promote-to-qa.sh` - JSON output promotion (for automation/scripting)
- `scripts/auto-promote-to-qa-data.sh` - Data gathering (readiness check)
- `.github/workflows-disabled/milestone-complete-promotion.yml` - Disabled workflow (reference only)

**Exit Codes:**
- `0`: Success (PR created and/or merged)
- `1`: Promotion blocked (not ready - open issues, CI failing, etc.)
- `2`: Error (API failure, script error)

**Example Output:**
```
==========================================
  Milestone: MVP
==========================================

Issue Status:
  Completed: 12 issues
  Open:      0 issues
  Progress:  100%

Branch Status:
  dev ahead of qa: 15 commits
  qa branch exists: true
  CI on dev:        success

[OK] PR created: https://github.com/owner/repo/pull/123
[OK] Auto-merge enabled for PR #123
```

### 5. Close Milestone

```bash
gh api repos/:owner/:repo/milestones/{milestone.number} -X PATCH -f state=closed
```

## Output Format

```
## Milestone Validation: {name}

### Issue Status
[check] All issues complete ({closed}/{total})
[or]
[warning] {count} open issues remaining

### Branch Status
| Check | Status |
|-------|--------|
| dev ahead of qa | [check] {n} commits |
| qa ahead of main | [check] {n} commits |
| Open PRs to dev | [check] 0 |
| CI on dev | [check] passing |

### Ready for Release
[If passing] Would you like to create a release PR?

## Milestone Closed: {name}

| Metric | Value |
|--------|-------|
| Completed | {n} issues |
| Duration | {days} days |
| Release PR | #{n} (if created) |

Issues Moved (if any): #X, #Y -> {next_milestone}
```

## Token Optimization

- Uses `scripts/milestone-close-data.sh` for all data gathering
- Returns structured JSON with readiness pre-computed
- Single batch of API calls (milestone + issues + branch state)
- ~400-600 tokens per invocation (vs ~1500 verbose)

## Automatic Promotion on Milestone Close

When a milestone is closed (either via `/milestone-close` or the GitHub UI), the system can automatically promote `dev` to `qa`.

**Trigger Methods:**
1. `/milestone-close --auto-promote` - Manual with auto-promotion
2. Direct script invocation - `./scripts/milestone-complete-promotion.sh`

> **Note:** The GitHub Actions workflow `milestone-complete-promotion.yml` has been
> disabled. Use the local script or `/milestone-close --auto-promote` instead.

## Related Commands

- `/milestone-complete` - Intelligent issue triage with MVP-critical vs deferrable analysis
- `/milestone-list` - View current milestone state
- `/pr-to-qa` - Manual dev→qa promotion
- `/pr-to-main` - QA→main release

## Notes

- WRITE operation - modifies milestones and issues
- Validates branch state before offering release
- Integrates with `/pr-to-main` for seamless releases
- Use `/milestone-list` to view current state first
- Use `/milestone-complete` for intelligent issue triage before closure
- `--auto-promote` enables automatic dev→qa merge on completion
- Uses `scripts/milestone-complete-promotion.sh` for promotion logic
- Auto-promotion requires all issues complete and local validation passing
