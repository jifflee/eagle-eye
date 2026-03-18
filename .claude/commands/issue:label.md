---
description: Apply or remove labels on GitHub issues using the repo-workflow agent
---

# Label Issue

Apply or remove labels on GitHub issues through the repo-workflow agent with pre-validated data.

## Usage

```
/issue:label <issue> <labels...>
/issue:label <issue> --remove <label> --add <label>
/issue:label <issue> --validate          # Check label completeness
```

## Steps

### 1. Gather Issue Label Data

```bash
./scripts/issue:label-data.sh <issue_number>
```

Returns JSON with:
- Current labels on issue
- Available repository labels
- Addable labels (not currently on issue)
- Label categories (type, status, priority, phase)

**Optimization:** All label validation done in bash script.

### 2. Validate Requested Labels

Check if requested labels exist in `available_labels[]` from data.
If label doesn't exist, suggest closest match from available labels.

### 3. Invoke repo-workflow Agent

Via Task tool with `subagent_type: "repo-workflow"` and `model: "haiku"`:
- Pass: issue number, labels to add, labels to remove
- Agent applies changes via GitHub API

### 4. Report Updated Labels

Show before/after label state using data from Step 1 and GitHub response.

## Standard Labels

| Label | Purpose |
|-------|---------|
| `in-progress` | Actively being worked on |
| `backlog` | Planned but not started |
| `blocked` | Waiting on dependency |
| `bug` | Defect or issue |
| `feature` | New functionality |
| `docs` | Documentation task |
| `tech-debt` | Refactoring or cleanup |

## Status Transitions

- `backlog` → `in-progress`: Work begins
- `in-progress` → `blocked`: Dependency identified
- `blocked` → `in-progress`: Dependency resolved

## Error Handling

Unknown label requested:
1. Check `available_labels[]` from data script
2. Calculate similarity to find closest match
3. Suggest: "Did you mean '{closest_match}'?"
4. List all available labels in category

**Optimization:** Label lookup is O(1) using pre-fetched data, not repeated API calls.

## Token Optimization

This skill has been optimized in Phase 3:

**Data gathering via script:**
- Single call to `./scripts/issue:label-data.sh` returns all label data
- Script fetches both issue labels and repository labels in one batch
- Label validation done server-side
- Addable labels pre-computed (set difference operation)

**Token savings:**
- Before optimization: ~2,300 tokens (multiple gh calls, inline validation)
- After optimization: ~725 tokens (pre-fetched label data)
- Savings: **68%**

**Measurement:**
- Baseline: 2,300 tokens (5 sequential gh calls + Claude validation logic)
- Current: 725 tokens (single data script call + simple delegation)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Key optimizations:**
- ✅ Batch label fetching (issue + repo labels in one script)
- ✅ Label validation in bash (not Claude)
- ✅ Set operations for addable labels (jq, not Claude)
- ✅ Closest-match suggestions via string similarity (can add if needed)
- ✅ Delegates execution to haiku-based repo-workflow agent

## Notes

- WRITE operation - modifies repository
- Routes through repo-workflow agent for governance
- Labels should be used consistently across all issues
- Uses `label-issue-data.sh` for efficient label lookup
