---
description: Review agent performance metrics - token usage, execution timing, and model selection patterns (READ-ONLY - query only)
---

# Metrics Review

**🔒 READ-ONLY OPERATION - This skill NEVER modifies metrics or triggers work**

Query and analyze agent performance metrics to understand token consumption, execution patterns, and optimization opportunities.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- All suggested actions are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work` or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/audit-metrics                      # Dashboard: all metrics
/audit-metrics --agent NAME         # Filter by agent
/audit-metrics --model MODEL        # Filter by model (haiku|sonnet|opus)
/audit-metrics --phase PHASE        # Filter by SDLC phase
/audit-metrics --issue NUMBER       # Filter by worktree issue
/audit-metrics --since YYYY-MM-DD   # Filter from date
/audit-metrics --top-agents N       # Top N agents by tokens
/audit-metrics --top-invocations N  # Most expensive invocations
/audit-metrics --model-comparison   # Compare model efficiency
/audit-metrics --worktree-summary   # Aggregate by worktree/issue
/audit-metrics --sessions           # Show session timing patterns
/audit-metrics --reset-analysis     # Analyze usage reset windows
/audit-metrics --usage-timeline     # Graph usage over time
/audit-metrics --utilization        # Current utilization (from state file)
/audit-metrics --json               # Output as JSON
```

## Steps

1. **Check for metrics file**
   - Location: `.claude/metrics.jsonl`
   - If not found, report no metrics collected yet

2. **Run query script**
   ```bash
   ./scripts/metrics-query.sh [OPTIONS]
   ```

3. **Check utilization state (for --utilization flag)**
   ```bash
   ./scripts/utilization-state.sh --read
   ```

4. **Format and present results**
   - Use output format templates below
   - Highlight optimization recommendations

## Output Format

### Dashboard View (default)

```
## Agent Performance Metrics

**Reporting Period:** {earliest_date} to {latest_date}

---

### Summary

| Metric | Value |
|--------|-------|
| Total Invocations | {count} |
| Completed | {completed} |
| In Progress | {in_progress} |
| Blocked/Error | {blocked + error} |
| Total Tokens | {formatted_tokens} |
| Avg Tokens/Invocation | {avg_tokens} |
| Total Duration | {total_duration} min |

---

### Model Usage

| Model | Invocations | % | Tokens |
|-------|-------------|---|--------|
| haiku | {count} | {pct}% | {tokens} |
| sonnet | {count} | {pct}% | {tokens} |
| opus | {count} | {pct}% | {tokens} |

**Target:** 90% haiku / 9% sonnet / 1% opus

---

### Top Agents (by token usage)

| Rank | Agent | Tokens | Invocations | Avg/Inv |
|------|-------|--------|-------------|---------|
| 1 | {agent} | {tokens} | {count} | {avg} |
| ... | ... | ... | ... | ... |

---

### Phase Distribution

| Phase | Tokens | Invocations |
|-------|--------|-------------|
| {phase} | {tokens} | {count} |
| ... | ... | ... |

---

### Recommendations

{recommendations based on analysis}
```

### Model Comparison View

```
## Model Efficiency Analysis

| Model | Invocations | Total Tokens | Avg Tokens | Avg Duration | Success Rate |
|-------|-------------|--------------|------------|--------------|--------------|
| haiku | {count} | {tokens} | {avg} | {duration} | {rate}% |
| sonnet | {count} | {tokens} | {avg} | {duration} | {rate}% |
| opus | {count} | {tokens} | {avg} | {duration} | {rate}% |

### Analysis

{comparison insights}
```

### Top Invocations View

```
## Most Expensive Invocations

| # | Timestamp | Agent | Model | Tokens | Duration | Task |
|---|-----------|-------|-------|--------|----------|------|
| 1 | {ts} | {agent} | {model} | {tokens} | {dur} | {task} |
| ... | ... | ... | ... | ... | ... | ... |
```

### Worktree Summary View

```
## Metrics by Worktree/Issue

| Issue | Invocations | Total Tokens | Avg Duration | Models Used | Agents |
|-------|-------------|--------------|--------------|-------------|--------|
| #159 | {count} | {tokens} | {avg} min | haiku (90%), sonnet (10%) | backend-developer, test-qa |
| main | {count} | {tokens} | {avg} min | haiku (85%), sonnet (15%) | pm-orchestrator, repo-workflow |
| ... | ... | ... | ... | ... | ... |
```

This view aggregates metrics from worktree sessions, showing which issues consumed the most resources.

### Session Timing View

```
## Session Timing Patterns

| Session | Start Time | End Time | Duration | Gap to Next | Tokens Used |
|---------|------------|----------|----------|-------------|-------------|
| 1 | 2025-01-24 08:15 | 2025-01-24 09:30 | 1h 15m | 30m | 15,000 |
| 2 | 2025-01-24 10:00 | 2025-01-24 11:45 | 1h 45m | 45m | 22,000 |
| ... | ... | ... | ... | ... | ... |

### Session Statistics
- Average session duration: {avg_duration}
- Average gap between sessions: {avg_gap}
- Peak usage time: {peak_time}
- Idle time total: {idle_time}
```

### Reset Window Analysis View

```
## Usage Reset Window Analysis

### Detected Pattern: {pattern_type}

{pattern_type} can be one of:
- **Static:** Fixed time daily (e.g., midnight UTC)
- **Rolling window:** X hours from first usage
- **Calendar-based:** Weekly/monthly reset
- **Unknown:** Insufficient data to determine pattern

### Evidence
- Usage resets observed: {count}
- Reset times: {times}
- Confidence: {low/medium/high}

### Next Reset
- Estimated time: {next_reset}
- Time remaining: {minutes_until_reset} minutes
- Current utilization: {usage_pct}%

### Recommendations
{recommendations based on reset pattern}
```

### Current Utilization View

```
## Current Utilization Status

**Last Updated:** {timestamp} ({data_age} minutes ago)

| Metric | Value |
|--------|-------|
| Current Usage | {usage_pct}% |
| Remaining Capacity | {remaining_pct}% |
| Tokens Used Today | {tokens_used} |
| Estimated Daily Limit | {estimated_limit} |

### Reset Window
- Next reset: {next_reset}
- Time until reset: {minutes_until} minutes

### Session Status
- Work in progress: {work_in_progress}
- Last work completed: {last_work_completed}
- Last work duration: {last_duration} minutes

### Data Freshness
- Data age: {data_age} minutes
- Stale threshold: {stale_threshold} minutes
- Status: {is_stale ? "STALE - refresh recommended" : "FRESH"}

**Note:** This data is read from cached state file (`.claude/utilization-state.json`).
For n8n orchestration, use `./scripts/n8n/n8n-check-utilization.sh` for decision-making.
```

## Model Distribution Compliance Check

**CRITICAL**: Check model distribution against targets on every review.

### Target Distribution (from AGENT_OPTIMIZATION.md)

| Model | Target | Warning | Critical |
|-------|--------|---------|----------|
| haiku | 90% | < 80% | < 70% |
| sonnet | 9% | > 15% | > 25% |
| opus | 1% | > 5% | > 10% |

### Alert Logic

When generating the Model Usage section, apply these rules:

**If haiku < 80%:**
```
WARNING: Haiku usage ({actual}%) is below target (90%).
- Target: 90% haiku for routine tasks
- Current: {actual}%
- Gap: {gap}%

Most agents should use haiku by default. Review agent invocations
to ensure model is explicitly set or defaulting correctly.

See /docs/AGENT_OPTIMIZATION.md for agent-to-model mapping.
```

**If haiku < 70% (Critical):**
```
CRITICAL: Haiku usage ({actual}%) is critically low!
- This indicates significant model selection compliance issues
- Review recent agent invocations with --model-comparison
- Check that metrics-capture hook defaults to haiku
```

**If sonnet > 15%:**
```
WARNING: Sonnet usage ({actual}%) exceeds target (9%).
- Sonnet should be reserved for: security, financial calculations, complex algorithms
- Current overuse suggests routine tasks are using sonnet incorrectly
```

**If sonnet > 25% (Critical):**
```
CRITICAL: Sonnet usage ({actual}%) is critically high!
- This may indicate a configuration issue
- Check default model in .claude/hooks/metrics-capture.sh
```

### Display Format

Add to the Model Usage section:

```
### Model Usage

| Model | Invocations | % | Target | Status |
|-------|-------------|---|--------|--------|
| haiku | {count} | {pct}% | 90% | {OK/WARN/CRIT} |
| sonnet | {count} | {pct}% | 9% | {OK/WARN/CRIT} |
| opus | {count} | {pct}% | 1% | {OK/WARN/CRIT} |

{Alert message if any status is WARN or CRIT}
```

## Recommendations Logic

Generate recommendations based on:

1. **Model distribution off-target**
   - If haiku < 80%: "Consider using haiku for more routine tasks"
   - If sonnet > 15%: "Review sonnet usage - reserve for security/financial calculations"
   - If opus > 5%: "Opus usage is high - reserve for critical architectural decisions"

2. **High-token agents**
   - If any agent > 30% of total: "Consider breaking {agent} work into smaller micro-tasks"

3. **Phase imbalance**
   - If development > 50%: "Development phase dominates - ensure adequate testing/docs"
   - If testing < 15%: "Testing phase may be underutilized"

4. **Error rate**
   - If blocked + error > 10%: "High error/blocked rate ({pct}%) - investigate blockers"

## Token Optimization

This skill has moderate optimization with room for improvement:

**Current optimizations:**
- ✅ Reads metrics from local file (`.claude/metrics.jsonl`)
- ✅ No GitHub API calls required
- ✅ JSON parsing via `jq`

**Token usage:**
- Current: ~1,250 tokens (moderate complexity with inline analysis)
- Optimized target: ~725 tokens (with dedicated analysis script)
- Potential savings: **42%**

**Remaining optimizations needed:**
- ❌ Inline metric calculations (could be in data script)
- ❌ Recommendations generated in Claude (could be rule-based in bash)
- ❌ No `metrics-review-data.sh` script for pre-processing

**Measurement:**
- Baseline: 1,250 tokens (current implementation with inline analysis)
- Target: 725 tokens (with analysis script)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Optimization strategy:**
Create `./scripts/audit-metrics-data.sh` to:
- Parse metrics.jsonl and calculate all aggregations
- Apply threshold rules for recommendations
- Return single JSON with computed insights
- Claude only formats and presents pre-computed results

**Key insight:**
Most metric analysis is rule-based (thresholds, percentages, counts) and doesn't require Claude's reasoning. Move to bash/jq.

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Metrics are stored in `.claude/metrics.jsonl`
- Utilization state is stored in `.claude/utilization-state.json`
- Metrics from worktrees are automatically propagated to main repo
- Use `--json` for programmatic access
- Metrics file is git-ignored (not committed)
- Use `--worktree-summary` to see aggregation by issue
- Use `--utilization` to see current utilization status for n8n orchestration
- See `/docs/METRICS_OBSERVABILITY.md` for implementation details
- **Token data availability**: `tokens_input`, `tokens_output`, `tokens_total` are populated when Claude Code includes usage metadata in hook responses. Older entries have `null` token counts; all query scripts handle both gracefully via `// 0` fallback
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - Any write operations
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Sprint-work is WRITE-FULL. Never cross this boundary.

**User action:** User should run recommended optimizations manually if needed

## n8n Integration

For n8n orchestration, use the dedicated helper script:

```bash
./scripts/n8n/n8n-check-utilization.sh
```

This script:
- Reads cached utilization state (zero token cost)
- Returns decision: `can_trigger` true/false with reason
- Checks: work in progress, utilization thresholds, data staleness
- Optimized for minimal token consumption

See Feature #367 for full n8n integration documentation.
