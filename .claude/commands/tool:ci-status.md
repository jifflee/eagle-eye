---
description: Local CI status dashboard showing pass/fail per check, trends, and run history
argument-hint: "[--branch NAME] [--pr NUMBER] [--mode MODE] [--history N] [--full] [--cleanup]"
---

# CI Status Dashboard

**🔒 READ-ONLY** - Queries local `.ci/` data and displays results. Use `--cleanup` to remove old history.

Displays local CI pipeline status: last run time, pass/fail per check, trend analysis, and run history. Replaces the GitHub Actions checks tab for local development.

## Usage

```
/tool:ci-status                      # Current branch CI status
/tool:ci-status --branch feat/123    # Status for specific branch
/tool:ci-status --pr 456             # Status for specific PR
/tool:ci-status --mode pre-pr        # Show only pre-pr mode results
/tool:ci-status --history 10         # Include 10 history entries per mode
/tool:ci-status --full               # Show full check output including logs
/tool:ci-status --cleanup            # Clean up old CI history (>30 days)
/tool:ci-status --cleanup --days 7   # Clean up history older than 7 days
```

## Steps

### 1. Gather Data

```bash
./scripts/tool:ci-status-data.sh [--branch NAME] [--pr NUMBER] [--mode MODE] [--history N]
```

Returns JSON with `current_branch`, `overall_status`, `last_run_time`, `summary`, `modes[]`, `history{}`.

### 2. Handle --cleanup

If `--cleanup` flag is provided:
```bash
./scripts/ci/cleanup-results.sh [--days N] [--dry-run]
```
Show cleanup summary and exit.

### 3. Render Dashboard

**If `overall_status == "unknown"` (no CI data found):**
```
## CI Status: No Local Data

No CI results found in `.ci/` for branch: {current_branch}

To generate CI results, run:
  ./scripts/ci/run-pipeline.sh --pre-commit    # Quick checks
  ./scripts/ci/run-pipeline.sh --pre-pr        # Full pipeline

Results are stored automatically in `.ci/` after each run.
```

**Standard Output:**

```
## CI Status: {overall_status_emoji} {overall_status}

**Branch:** {display_branch}
**Last Run:** {last_run_time (formatted)}
**Summary:** {passing}/{total_modes} modes passing

### Mode Results

| Mode | Status | Last Run | Duration | Trend | Checks |
|------|--------|----------|----------|-------|--------|
| pre-commit | ✅ pass | 2m ago | 3s | 📈 stable | 4/4 |
| pre-pr | ❌ fail | 10m ago | 45s | 📉 degrading | 3/4 |
| pre-merge | - | never | - | - | - |
| pre-release | - | never | - | - | - |

### Failed Checks

{if any mode has failed checks}

**pre-pr:**
| Check | Status | Duration | Output (excerpt) |
|-------|--------|----------|-----------------|
| security-full | ❌ fail | 12s | Found 2 high-severity issues... |

### Run History

{if --history or --full flag}

**pre-commit** (last {history_count} runs):
| Run | Time | Status | Duration | Branch |
|-----|------|--------|----------|--------|
| 1 | 2026-02-18 12:00 | ✅ | 3s | feat/issue-851 |
| 2 | 2026-02-18 11:45 | ✅ | 4s | feat/issue-851 |

### Quick Actions

- Run CI: `./scripts/ci/run-pipeline.sh --pre-commit`
- Full pipeline: `./scripts/ci/run-pipeline.sh --pre-pr`
- Clean history: `/tool:ci-status --cleanup`
- Sprint overview: `/sprint:status-pm --full`
```

## Status Emoji Mapping

| Status | Emoji | Meaning |
|--------|-------|---------|
| passing | ✅ | All modes passing |
| failing | ❌ | One or more modes failing |
| unknown | ⚪ | No CI data found |

## Trend Emoji Mapping

| Trend | Emoji | Meaning |
|-------|-------|---------|
| stable | 📈 | All recent runs passed |
| improving | 📊 | More passes than failures |
| degrading | 📉 | More failures than passes |
| unknown | - | No history available |

## Check Status Formatting

- `pass` → `✅`
- `fail` → `❌`
- `skip` → `⏭️`

## Time Formatting

Format `last_run_time` as relative time:
- < 60s → "Xs ago"
- < 3600s → "Xm ago"
- < 86400s → "Xh ago"
- else → "YYYY-MM-DD HH:MM"

Show "never" if timestamp is "never" or missing.

## --full Mode

When `--full` flag is used, include full check output in the Failed Checks section instead of just excerpt. Also show history for all modes.

## Integration with /sprint-status

The `/sprint:status-pm --full` command includes a CI Status section that references this dashboard. When `repo_ci_status.has_failures` is true in sprint-status data, it links here for details.

## Token Optimization

- **Data script:** `scripts/tool:ci-status-data.sh`
- **Storage:** `.ci/latest/` for current status, `.ci/history/` for runs
- **No API calls:** Pure local data, no GitHub API needed
- **Target output:** 200-500 tokens (default), 500-1000 tokens (--full)

## Notes

- READ-ONLY by default; `--cleanup` flag enables write operations (history deletion)
- CI results are stored by `scripts/ci/run-pipeline.sh` automatically after each run
- Results in `.ci/latest/` always reflect the most recent run per mode
- History in `.ci/history/` is date-partitioned for easy cleanup
- The `.ci/` directory is git-ignored (except README)
- **Related:** `/sprint:status-pm`, `scripts/ci/run-pipeline.sh`, `scripts/ci/store-results.sh`
