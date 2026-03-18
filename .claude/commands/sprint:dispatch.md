---
description: Lightweight dispatcher to launch workers (worktrees or containers) with optimized agent context
permissions:
  max_tier: T0
  scripts:
    - name: detect-infrastructure.sh
      tier: T0
---

# Sprint Continue

Dispatch work to a worker (worktree or container) with minimal context assembled from issue labels.

## Usage

```
/sprint-continue --issue N                    # Container mode (default since #531)
/sprint-continue --issue N --worktree         # Opt into worktree mode
/sprint-continue --issue N --agents "bug,test-qa"  # Override agents
/sprint-continue --issue N --container        # [DEPRECATED] Container is now default
```

## Steps

### 1. Fetch Issue Metadata

```bash
ISSUE_JSON=$(gh issue view $ISSUE --json labels,title,body)
LABELS=$(echo "$ISSUE_JSON" | jq -r '.labels[].name' | tr '\n' ',')
BODY=$(echo "$ISSUE_JSON" | jq -r '.body')
```

### 2. Determine Agents

**If --agents flag provided:** Use those directly (skip mapping).

**Otherwise, map labels to agents:**

Read `config/agent-bundles.json` and combine all matching bundles:

| Label | Agents |
|-------|--------|
| bug | bug, backend-developer, test-qa, pr-code-reviewer |
| feature | product-spec-ux, architect, backend-developer, test-qa, documentation |
| security | security-iam-design, financial-security-auditor, pr-security-iam |
| docs | documentation, documentation-librarian |
| tech-debt | architect, backend-developer, test-qa, refactoring-specialist |
| data | data-storage, backend-developer, test-qa |

**Body signal scan (additive):**

| Signal | Adds |
|--------|------|
| security, vulnerability, injection | security-iam-design |
| database, schema, migration | data-storage |
| UI, frontend, component | frontend-developer |
| performance, slow, optimize | performance-engineering |

**Trim if > 8 agents:** Keep core workflow agents, drop specialists.

### 3. Assemble Context

```bash
./scripts/assemble-worker-context.sh \
  --issue $ISSUE \
  --agents "$AGENTS" \
  --output /tmp/worker-$ISSUE/CLAUDE.md
```

### 4. Detect Infrastructure and Launch Worker

**Detect available infrastructure:**
```bash
INFRA_JSON=$(./scripts/detect-infrastructure.sh)
INFRA_TYPE=$(echo "$INFRA_JSON" | jq -r '.infrastructure_type')
RECOMMENDED_MODE=$(echo "$INFRA_JSON" | jq -r '.recommended_mode')
# Use resolved script paths from detect-infrastructure (supports both
# .claude/scripts/ in consumer repos and ./scripts/ in framework repo)
CONTAINER_SCRIPT=$(echo "$INFRA_JSON" | jq -r '.container_script')
WORKTREE_SCRIPT=$(echo "$INFRA_JSON" | jq -r '.worktree_script')

# Override with --worktree flag if provided
if [ "${WORKTREE_FLAG:-false}" = "true" ]; then
  if [ "$INFRA_TYPE" = "none" ]; then
    echo "⚠️  Cannot use --worktree flag: worktree infrastructure not available"
    echo "Falling back to direct execution mode..."
    RECOMMENDED_MODE="direct"
  else
    RECOMMENDED_MODE="worktree"
  fi
fi
```

**Container mode (when infrastructure available):**
```bash
if [ "$RECOMMENDED_MODE" = "container" ]; then
  # $CONTAINER_SCRIPT resolved by detect-infrastructure.sh above
  "$CONTAINER_SCRIPT" \
    --issue $ISSUE \
    --repo $(gh repo view --json nameWithOwner -q '.nameWithOwner') \
    --sprint-work
fi
```

**Worktree mode (when --worktree specified):**
```bash
if [ "$RECOMMENDED_MODE" = "worktree" ]; then
  # $WORKTREE_SCRIPT resolved by detect-infrastructure.sh above
  "$WORKTREE_SCRIPT" $ISSUE --worktree
  # Follow preflight JSON action (switch/created/continue)
fi
```

**Direct mode (consumer repos without infrastructure):**
```bash
if [ "$RECOMMENDED_MODE" = "direct" ]; then
  echo "## Direct Execution Mode"
  echo ""
  echo "⚠️  Container/worktree infrastructure not available"
  echo "📋 This appears to be a consumer repo without full framework scripts"
  echo "✅ Proceeding with direct in-session execution..."
  echo ""
  # Execute SDLC phases directly in current session
  # Use Task tool to invoke appropriate agents
fi
```

### 5. Report Status

```
## Dispatch Complete

**Issue:** #N - {title}
**Mode:** {worktree|container}
**Agents:** {agent_list}
**Context:** /tmp/worker-N/CLAUDE.md ({size} bytes)

{Next step instructions}
```

## Token Optimization

This skill is optimized for minimal token usage:

**Lightweight dispatcher design:**
- This skill is **97% smaller** than sprint-work (~2KB vs 32KB)
- Delegates heavy lifting to workers (worktrees/containers)
- Minimal context assembly in dispatcher, full context in worker

**Data gathering via JSON parsing:**
- Single `gh issue view` call with `--json` flag
- Uses `jq` for efficient label and body extraction
- Agent bundles read from config file (no Claude parsing needed)

**Token savings:**
- Before optimization: ~2,400 tokens (full sprint-work skill loaded for dispatch)
- After optimization: ~800 tokens (lightweight dispatcher only)
- Savings: **67%**

**Measurement:**
- Baseline: 2,400 tokens (loading full sprint-work for every dispatch)
- Current: 800 tokens (lightweight dispatcher pattern)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Key optimizations:**
- ✅ Minimal skill file size (dispatcher vs monolithic)
- ✅ Uses `jq` for JSON parsing (no Claude parsing)
- ✅ Config-driven agent bundles (no hardcoded logic)
- ✅ Defers work to workers (context assembled in worker, not dispatcher)

## Notes

- Lightweight dispatcher (~2KB vs 32KB sprint-work.md)
- Uses config/agent-bundles.json for label mapping
- Deduplicates agents automatically
- PM trims if > 8 agents selected
- Worktree preflight handles terminal switching
- Container mode runs isolated
