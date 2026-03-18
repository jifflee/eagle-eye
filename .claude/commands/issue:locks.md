---
description: Show all currently checked-out issues across instances (READ-ONLY unless --clean flag)
---

# Issues Locks

**🔒 HYBRID OPERATION - READ-ONLY by default, WRITE with --clean flag**

Displays all checked-out issues (local and GitHub-wide).

**CRITICAL SAFEGUARD:**
- Without flags: This skill ONLY queries data and presents reports
- With --clean flag: This skill removes stale locks (WRITE operation)
- All suggested commands are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work` or other write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/issue:locks                    # Show all locks
/issue:locks --local            # Local only
/issue:locks --stale            # Stale locks (>2h)
/issue:locks --clean            # Remove stale
```

## Steps

### 1. Query Local Locks

```bash
if [ -f ".claude-locks.json" ]; then
  LOCAL_LOCKS=$(jq -r '.locks[]' .claude-locks.json)
fi
```

### 2. Query GitHub

```bash
GITHUB_LOCKS=$(gh issue list --label "wip:checked-out" --state open \
  --json number,title,updatedAt)
```

### 3. Calculate Duration

```bash
NOW=$(date +%s)
# For each lock, calculate minutes since started
DURATION=$(( (NOW - START_EPOCH) / 60 ))
STATUS=$([[ $DURATION -gt 120 ]] && echo "⚠️ Stale" || echo "Active")
```

### 4. Clean Stale (--clean)

```bash
# For locks > 2 hours
gh issue edit $N --remove-label "wip:checked-out"
jq 'del(.locks[] | select(.issue == $N))' .claude-locks.json > tmp && mv tmp .claude-locks.json
```

## Output Format

```
## Issue Locks

### This Instance

| Issue | Title | Branch | Duration | Status |
|-------|-------|--------|----------|--------|
| #{n} | {title} | {branch} | {duration} | {status} |

### Other Instances

| Issue | Title | Last Activity |
|-------|-------|---------------|
| #{n} | {title} | {time_ago} |

---

**Total:** {n} ({local} local, {remote} remote)

**Quick actions:**
- `/issue:release {n}` - Release issue
- `/issue:release --all` - Release all
- `/issue:locks --clean` - Remove stale
```

## Token Optimization

- **Data script:** `scripts/issue:locks-data.sh`
- **API calls:** 2 batched (local locks + GitHub label query)
- **Savings:** ~55% reduction from inline gh calls

## Notes

- **HYBRID OPERATION**: READ-ONLY by default, WRITE-FULL with --clean flag
- Shows both local and GitHub locks
- Stale threshold: 2 hours
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - `/issue:checkout` command (unless user explicitly chooses)
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: Without --clean, this skill is READ-ONLY. Never cross this boundary.

**User action:** Run `/issue:release` manually to release specific locks
