---
description: Sync main repository to origin (reset-based safe sync)
---

# Sync Repository

Safely synchronizes the main repository to origin/main or origin/dev using reset-based sync.

## Usage

```
/repo-sync              # Sync to origin/main (default)
/repo-sync --dev        # Sync to origin/dev
/repo-sync --check      # Check status only, don't sync
```

## Design Philosophy

The main repository should **never** have local changes:
- All development work happens in worktrees
- Main repo exists only for coordination (running /sprint:status-pm, /milestone:list-all, etc.)
- Therefore, reset-based sync is safe and preferred over merge-based pull

## Steps

### 1. Check Current Status

```bash
./scripts/git/sync-main-repo.sh --check
```

This returns JSON with:
- `behind_target`: Commits behind origin
- `ahead_of_target`: Local commits (shouldn't exist)
- `has_uncommitted_changes`: Local changes (shouldn't exist)
- `recommendation`: One of `up_to_date`, `safe_to_sync`, `diverged_needs_reset`, `has_local_changes`

### 2. Safety Validation

Check for conditions that shouldn't exist in main repo:
- Uncommitted changes → Error (unless --force)
- Running in worktree → Error (worktrees shouldn't be synced this way)
- Local commits → Warning (will be discarded)

### 3. Execute Sync (if not --check)

```bash
# Default: sync to origin/main
./scripts/git/sync-main-repo.sh

# Or sync to origin/dev
./scripts/git/sync-main-repo.sh --dev
```

## Output Format

### Check Mode

```
## Repository Sync Status

| Metric | Value |
|--------|-------|
| Current branch | {branch} |
| Target | origin/{main|dev} |
| Behind by | {N} commits |
| Ahead by | {N} commits |
| Uncommitted changes | {yes/no} |

**Status:** {up_to_date | needs_sync | diverged | has_local_changes}
**Recommendation:** {actionable guidance}
```

### Sync Mode

```
## Repository Sync

**Syncing to origin/{branch}...**

- Behind by: {N} commits
- Ahead by: {N} commits (will be discarded)

**Result:** Sync complete
**Now at:** {short_sha} ({branch})
```

## Error Cases

| Condition | Message |
|-----------|---------|
| In worktree | "This command should be run from main repo, not a worktree" |
| Uncommitted changes | "You have uncommitted changes. Discard or move to worktree." |
| Not in git repo | "Not in a git repository" |

## Token Optimization

This skill has moderate optimization with room for improvement:

**Current optimizations:**
- ✅ Simple git operations (no complex logic)
- ✅ Uses system git commands (no Claude parsing)
- ✅ Minimal validation checks

**Token usage:**
- Current: ~1,250 tokens (moderate complexity with safety checks)
- Optimized target: ~725 tokens (with dedicated validation script)
- Potential savings: **42%**

**Remaining optimizations needed:**
- ❌ Inline validation checks (could be in pre-sync script)
- ❌ Error handling done in Claude (could be scripted)
- ❌ No `sync-repo-data.sh` script for pre-flight validation

**Measurement:**
- Baseline: 1,250 tokens (current implementation)
- Target: 725 tokens (with validation script)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Optimization strategy:**
Create `./scripts/repo-sync-preflight.sh` to:
- Check if in worktree (fail fast)
- Check for uncommitted changes
- Validate git repository status
- Return JSON with go/no-go decision
- Claude only executes sync if validated

**Key insight:**
All validation is rule-based (boolean checks) and doesn't need Claude reasoning. Move to bash.

## Notes

- WRITE operation (modifies local branch pointer)
- Safe for main repo (no local changes expected)
- Should NOT be used in worktrees
- Integrated into /sprint:status-pm warnings
