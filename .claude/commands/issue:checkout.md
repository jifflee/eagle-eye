---
description: Claim an issue for the current Claude instance to prevent parallel conflicts
---

# Issues Checkout

Claims an issue to prevent other Claude instances from working on it.

## Usage

```
/issue:checkout 42              # Checkout issue #42
/issue:checkout 42 --force      # Force checkout
/issue:checkout --current       # Show current checkouts
```

## Steps

### 1. Gather Data

```bash
./scripts/issue:checkout-data.sh <issue_number>
# OR for current checkouts:
./scripts/issue:checkout-data.sh --current
```

Returns JSON with issue state, checkout status, and eligibility.

### 2. Validate Eligibility

Check the returned JSON:
- `eligibility.can_checkout`: true/false
- `eligibility.block_reason`: none | issue_closed | already_checked_out

If already checked out: offer wait, force, or cancel.

### 3. Claim on GitHub

```bash
gh issue edit $ISSUE_NUMBER --add-label "wip:checked-out"
gh issue comment $ISSUE_NUMBER --body "$(cat <<'EOF'
:lock: **Checked out** by Claude instance

| Field | Value |
|-------|-------|
| Instance | `$INSTANCE_ID` |
| Started | $SESSION_START |
EOF
)"
```

Use values from `new_checkout.instance_id` and `new_checkout.session_start`.

### 4. Create Local Lock

```bash
jq --arg issue "$ISSUE_NUMBER" \
   --arg id "$INSTANCE_ID" \
   --arg start "$SESSION_START" \
  '.locks += [{issue: ($issue | tonumber), instance_id: $id, started_at: $start}]' \
  .claude-locks.json > tmp.json && mv tmp.json .claude-locks.json
```

### 5. Transition Labels

```bash
gh issue edit $ISSUE_NUMBER --remove-label "backlog"
```

## Output Format

```
## Issue Checked Out: #{number}

**Title:** {title}
**Instance:** {instance_id}
**Started:** {timestamp}

Issue is now locked. Other instances will see this as checked out.

When done:
- `/issue:release {number}` to release
- PR will auto-release on merge
```

## Token Optimization

- Uses `scripts/issue:checkout-data.sh` for all data gathering
- Returns structured JSON with eligibility pre-computed
- Single API call to fetch issue + labels
- ~300-400 tokens per invocation (vs ~1000 verbose)

## Notes

- WRITE operation - updates labels and comments
- Use --force to override existing checkout
- Creates `.claude-locks.json` for local tracking
