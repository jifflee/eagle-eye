---
description: Review action audit log - skill/agent operations, tier analysis, and policy recommendations
---

# Action Audit

**READ-ONLY OPERATION - This skill NEVER modifies the action log or triggers work**

Query and analyze the action audit log to understand what operations skills/agents performed, identify patterns, and generate policy recommendations for auto-approval tiers.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- All suggested actions are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work` or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/audit-actions                         # Summary dashboard
/audit-actions --tier T3               # High-risk actions only
/audit-actions --skill sprint-work     # Actions by skill
/audit-actions --session ID            # Full session timeline
/audit-actions --since 2026-01-15      # Date filter
/audit-actions --failures              # Failed actions
/audit-actions --unapproved            # Actions that ran without approval
/audit-actions --policy-suggest        # Generate auto-approve recommendations
/audit-actions --category github       # Filter by category
/audit-actions --json                  # Raw JSON output (no formatting)
```

## Steps

### 1. Gather Data

```bash
./scripts/audit-actions-data.sh [OPTIONS]
```

Pass through all user-provided flags. The script returns JSON.

### 2. Format and Present Results

Use the appropriate output format template below based on the mode:
- No special flags → Dashboard view
- `--session ID` → Session timeline view
- `--policy-suggest` → Policy recommendations view
- `--json` → Output raw JSON from script without formatting

## Output Formats

### Dashboard View (default)

```
## Action Audit Summary

**Period:** {earliest} to {latest}
**Total Actions:** {total_actions}
**Sessions:** {sessions}

### By Tier
| Tier | Count | % | Auto-Approved |
|------|-------|---|---------------|
| T0 | {count} | {pct}% | {auto_approved}/{count} |
| T1 | {count} | {pct}% | {auto_approved}/{count} |
| T2 | {count} | {pct}% | {auto_approved}/{count} |
| T3 | {count} | {pct}% | {auto_approved}/{count} |

### By Category
| Category | Count | Top Operations |
|----------|-------|----------------|
| {category} | {count} | {op1}, {op2}, {op3} |

### By Source (Top 10)
| Source Skill | Count | Categories |
|--------------|-------|------------|
| {source} | {count} | {categories} |

### Action Results
| Status | Count |
|--------|-------|
| success | {count} |
| failure | {count} |
| blocked | {count} |
| timeout | {count} |

### Recent T3 Actions (require review)
| Time | Source | Operation | Result |
|------|--------|-----------|--------|
| {timestamp} | {source} | {operation} | {status} |
```

### Session Timeline View (--session)

```
## Session Timeline

**Session:** {session_id}
**Duration:** {start_time} to {end_time}
**Total Actions:** {total_actions}

| # | Time | Source | Category | Operation | Tier | Status | Duration |
|---|------|--------|----------|-----------|------|--------|----------|
| 1 | {time} | {source} | {category} | {operation} | {tier} | {status} | {ms}ms |
| 2 | ... | ... | ... | ... | ... | ... | ... |
```

### Policy Recommendations View (--policy-suggest)

```
## Auto-Approve Policy Recommendations

**Based on:** {total_operations} actions across {unique_operations} operation types

### Recommend Promote to T0 (always auto-approve)
| Operation | Current Tier | Invocations | Success Rate | Reversible |
|-----------|--------------|-------------|--------------|------------|
| {operation} | {current} | {count} | {rate}% | Yes |

**Criteria:** 100% success rate, 10+ invocations, reversible

### Recommend Promote to T1 (auto-approve per session)
| Operation | Current Tier | Invocations | Success Rate | Reversible |
|-----------|--------------|-------------|--------------|------------|
| {operation} | {current} | {count} | {rate}% | Yes |

**Criteria:** 95%+ success rate, 5+ invocations, reversible

### Keep T2 (prompt once per session)
| Operation | Invocations | Success Rate | User Cancelled |
|-----------|-------------|--------------|----------------|
| {operation} | {count} | {rate}% | {cancelled} |

**Reason:** High success but occasionally cancelled by user

### Keep T3 (always prompt)
| Operation | Invocations | Success Rate | Reason |
|-----------|-------------|--------------|--------|
| {operation} | {count} | {rate}% | {reason} |

**Reason:** Irreversible, low success rate, or high failure count
```

### Filtered View (--tier, --skill, --category, --failures, --unapproved)

```
## Filtered Actions

**Filter:** {filter_description}
**Matching Actions:** {count}

| Time | Source | Category | Operation | Tier | Status |
|------|--------|----------|-----------|------|--------|
| {timestamp} | {source} | {category} | {operation} | {tier} | {status} |
| ... | ... | ... | ... | ... | ... |

{Show up to 50 most recent matching actions}
```

## Recommendations Logic

After presenting data, generate insights:

1. **Tier imbalance**
   - If T3 > 10% of total: "High proportion of T3 actions - review if any can be safely downgraded"
   - If T0 < 50%: "Low auto-approval rate - consider promoting stable operations"

2. **Failure patterns**
   - If any operation has > 5% failure rate: "Operation {name} has {rate}% failure rate - investigate"
   - If failures cluster in one skill: "{skill} has disproportionate failures"

3. **Unapproved actions**
   - If unapproved > 0: "{count} actions ran without explicit approval - verify these are safe"

4. **Session outliers**
   - If any session has > 100 actions: "Session {id} had {count} actions - review for automation loops"

## Data Source

The action audit log is stored at `.claude/actions.jsonl` in the main repository.

Each entry follows the schema defined in issue #216:
```json
{
  "timestamp": "ISO-8601",
  "action_id": "uuid",
  "session_id": "uuid",
  "source": {"type": "skill|agent", "name": "string"},
  "action": {"category": "string", "operation": "string"},
  "tier": {"assigned": "T0|T1|T2|T3"},
  "result": {"status": "success|failure|blocked|timeout"},
  "approval": {"approved": true, "auto_approved": true}
}
```

## Token Optimization

- **Data script:** `scripts/audit-actions-data.sh`
- **API calls:** Batched file reads and JSON parsing
- **Savings:** ~70% reduction from inline log parsing

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Action log is stored in `.claude/actions.jsonl` (git-ignored)
- Log is populated by the action logging system (issue #216, #228)
- Policy recommendations feed into the auto-approval mechanism (issue #225)
- Use `--json` for programmatic access by other tools
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - Any write operations
  - DO NOT use the Skill tool to execute write operations
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Never cross this boundary.

**User action:** User should apply policy recommendations manually via issue #225 mechanism
