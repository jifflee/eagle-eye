---
description: Visualize skill dependencies, primitive usage, and permission tier inheritance (READ-ONLY - query only)
---

# Skill Dependency Visualizer

**READ-ONLY OPERATION - This skill NEVER modifies files**

Visualize skill dependencies, primitive usage, and permission tier inheritance to help understand skill composition and identify optimization opportunities.

## Usage

```
/skill-deps                      # All skills overview
/skill-deps sprint-work          # Single skill deep dive
/skill-deps --tier T3            # Filter by tier
/skill-deps --graph              # ASCII dependency graph
/skill-deps --unused             # Primitives not used by any skill
```

## Steps

### 1. Gather Data

```bash
./scripts/skill-deps-data.sh [options]
```

Options:
- `skill_name` - Single skill deep dive
- `--tier T0|T1|T2|T3` - Filter by tier
- `--unused` - Show unused primitives
- `--json` - JSON output (default)

### 2. Format Output

Based on mode, format the JSON output into the appropriate display format.

## Output Formats

### Overview (default)

Display all skills with their dependencies and tier inheritance.

```
## Skill Dependency Overview

**Summary:**
- Primitives: {count} registered ({T0}/{T1}/{T2}/{T3} by tier)
- Skills: {count} with contracts
- Commands: {count} total

### Tier Distribution

| Type | T0 | T1 | T2 | T3 |
|------|----|----|----|----|
| Primitives | {n} | {n} | {n} | {n} |
| Skills | {n} | {n} | {n} | {n} |

### Skills with Dependencies

| Skill | Effective Tier | Dependencies | Tier Source |
|-------|----------------|--------------|-------------|
| {name} | {tier} | {dep_count} | {tier_source} |

### Primitives by Category

| Category | T0 | T1 | T2 | T3 | Examples |
|----------|----|----|----|----|----------|
| github | {n} | {n} | {n} | {n} | get-issue-context, create-pr |
| git | {n} | {n} | {n} | {n} | create-branch, push-branch |
```

### Single Skill Deep Dive

When a skill name is provided, show detailed dependency analysis.

```
## {skill_name} Dependencies

**Effective Tier:** {tier} (inherited from {tier_source})

### Dependency Graph

{skill_name} ({tier})
├── {dep1} ({type}, {tier})
│   └── {sub_dep} ({type}, {tier})
├── {dep2} ({type}, {tier}) <- Tier source
└── {dep3} ({type}, {tier})

### Permission Flow

The skill's effective tier is determined by its highest-tier dependency:

| Order | Dependency | Type | Tier | Approval |
|-------|------------|------|------|----------|
| 1 | {name} | primitive | T0 | Auto |
| 2 | {name} | skill | T1 | Auto |
| 3 | {name} | primitive | T2 | Once/session |
| 4 | {name} | primitive | T3 | Always prompt |

**Tier Explanation:**
- T0 (Read-Only): No risk, auto-approved
- T1 (Safe Write): Low risk, auto-approved
- T2 (Reversible): Medium risk, prompt once per session
- T3 (Destructive): High risk, always prompt
```

### Tier Filter

When `--tier` is specified, show only primitives and skills at that tier.

```
## Tier {tier} Analysis

**{tier_name}** ({risk_level} risk, {approval_mode})

### Primitives at Tier {tier}

| Primitive | Category | Description |
|-----------|----------|-------------|
| {name} | {category} | {description} |

### Skills at Tier {tier}

| Skill | Tier Source | Dependencies at T{n} |
|-------|-------------|---------------------|
| {name} | {source} | {deps} |
```

### Unused Primitives

When `--unused` is specified, show primitives not referenced by any skill.

```
## Unused Primitives Analysis

**Found {count} unused primitives** (not referenced by any skill contract)

### Unused by Tier

| Tier | Count | Primitives |
|------|-------|------------|
| T0 | {n} | {list} |
| T1 | {n} | {list} |
| T2 | {n} | {list} |
| T3 | {n} | {list} |

### Recommendations

- **Remove if unused:** Primitives with no scripts or consumers
- **Document usage:** Primitives used directly in commands
- **Add to contracts:** Primitives that should be in skill compositions
```

### ASCII Dependency Graph

When `--graph` is specified, generate an ASCII representation.

```
## Dependency Graph

sprint-work-composed (T3)
│
├─► get-sprint-state (primitive, T0) [AUTO]
│
├─► issues-checkout (skill, T1) [AUTO]
│   ├─► get-issue-context (primitive, T0)
│   └─► checkout-issue (primitive, T1)
│
├─► validate-worktree (primitive, T0) [AUTO]
│
├─► create-pr (primitive, T2) [ONCE]
│
└─► close-issue (primitive, T3) [PROMPT] <- TIER SOURCE

Legend:
  [AUTO]   = Auto-approved (T0/T1)
  [ONCE]   = Prompt once per session (T2)
  [PROMPT] = Always prompt (T3)
  <- TIER SOURCE = Determines skill's effective tier
```

## Token Optimization

This skill is optimized for minimal token usage:

**Data gathering via script:**
- Single call to `./scripts/skill-deps-data.sh` returns all needed data
- Script uses `yq` for YAML parsing and `jq` for JSON processing
- Dependency traversal and tier calculation done server-side
- Claude receives only final structured results

**Token savings:**
- Before optimization: ~2,500 tokens (read registry, contracts, manually traverse)
- After optimization: ~400 tokens (pre-computed JSON with traversed dependencies)
- Savings: **84%**

## Permissions

```yaml
permissions:
  max_tier: T0
  scripts:
    - name: skill-deps-data.sh
      tier: T0
      description: "Read and analyze skill/primitive registry"
```

## Notes

- **READ-ONLY OPERATION**: This skill queries data only
- Requires `yq` for YAML parsing (install: `brew install yq`)
- Data sources:
  - `primitives/registry.yaml` - Primitive definitions
  - `contracts/skills/*.yaml` - Skill contracts with dependencies
  - `core/commands/*.md` - Command files with script references
- Use to understand skill architecture before modifications
- Helps identify:
  - Tier inheritance chains
  - Unused primitives for cleanup
  - Missing compositions
  - Permission escalation paths
