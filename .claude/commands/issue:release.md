---
description: Release a checked-out issue, removing the lock for other instances
---

# Issues Release

Releases a checked-out issue for other Claude instances.

## Usage

```
/issue:release 42               # Release issue #42
/issue:release --all            # Release all for this instance
/issue:release 42 --comment     # Release with comment
```

## Steps

### 1. Gather Data

```bash
./scripts/issue:release-data.sh <issue_number>
# OR for all locks:
./scripts/issue:release-data.sh --all
```

Returns JSON with lock status and release eligibility.

### 2. Validate Release

Check the returned JSON:
- `release.can_release`: true/false
- `release.release_type`: local_and_github | github_only | none
- `lock_status.duration_minutes`: Time held

### 3. Remove GitHub Label

```bash
gh issue edit $ISSUE_NUMBER --remove-label "wip:checked-out"
```

### 4. Post Release Comment

```bash
gh issue comment $ISSUE_NUMBER --body "$(cat <<'EOF'
:unlock: **Released** by Claude instance

| Field | Value |
|-------|-------|
| Instance | `$INSTANCE_ID` |
| Duration | ${DURATION_MIN} minutes |
| Branch | `$BRANCH` |
EOF
)"
```

Use values from `lock_status` and `context`.

### 5. Remove Local Lock

```bash
jq --arg issue "$ISSUE_NUMBER" \
  'del(.locks[] | select(.issue == ($issue | tonumber)))' \
  .claude-locks.json > tmp.json && mv tmp.json .claude-locks.json
```

### 6. Restore Backlog Label

```bash
gh issue edit $ISSUE_NUMBER --add-label "backlog"
```

## Output Format

```
## Issue Released: #{number}

| Field | Value |
|-------|-------|
| Duration | {minutes} minutes |
| Branch | {branch} |
| Status | backlog |

Issue is now available for other instances.
```

## Token Optimization

- Uses `scripts/issue:release-data.sh` for all data gathering
- Returns structured JSON with duration pre-calculated
- Single API call to fetch issue state
- ~300-400 tokens per invocation (vs ~900 verbose)

## Notes

- WRITE operation - updates labels and comments
- Use --all to release all locks for this instance
- Restores backlog label for incomplete work
