---
description: Audit agent model configurations for cost and efficiency optimization
---

# Claude Model Review

Reviews agents for appropriate model selection (haiku/sonnet/opus).

## Usage

```
/audit-model-configs                # Full audit
/audit-model-configs --summary      # Quick summary
/audit-model-configs --fix          # Show fix commands
```

## Steps

### 1. Gather Data

```bash
./scripts/audit-model-configs-data.sh
# OR for summary only:
./scripts/audit-model-configs-data.sh --summary
```

Returns JSON with agent configurations and recommendations.

### 2. Review Distribution

Check `distribution` against targets:

| Model | Target % | Use Cases |
|-------|----------|-----------|
| haiku | 90% | Docs, configs, scaffolding, coordination, simple code |
| sonnet | 9% | Security, financial calc, complex algorithms |
| opus | 1% | Critical security, complex architecture |

### 3. Identify Misconfigurations

From `agents` array, filter where `misconfigured: true`:
- `reason`: Explains the issue
- `current_model`: What's configured
- `recommended_model`: What it should be

### 4. Generate Fix Commands (--fix)

For each misconfigured agent:
```bash
# Update {agent} from {old} to {new}
sed -i 's/model: {old}/model: {new}/' {path}
```

### 5. Calculate Cost Impact

From `summary.cost_impact`: normal | moderate | high

## Output Format

```
## Model Configuration Audit

**Agents reviewed:** {n}
**Misconfigurations:** {n}
**Estimated cost impact:** {impact}

---

### Current Distribution

| Model | Count | % | Target |
|-------|-------|---|--------|
| haiku | {n} | {pct}% | 90% |
| sonnet | {n} | {pct}% | 9% |
| opus | {n} | {pct}% | 1% |

---

### Misconfigurations

| Agent | Current | Recommended | Reason |
|-------|---------|-------------|--------|
| {name} | {model} | {model} | {reason} |

---

### Fix Commands

```bash
# Update {agent} from {old} to {new}
sed -i 's/model: {old}/model: {new}/' {path}
```

---

### Recommendations

1. {recommendation}
```

## Token Optimization

- Uses `scripts/audit-model-configs-data.sh` for all analysis
- Returns structured JSON with classifications pre-computed
- Single pass through agent files via shell
- ~400-600 tokens per invocation (vs ~1500 verbose)

## Notes

- READ-only operation
- Reference CLAUDE.md Section 2.1 for guidelines
- Run periodically to control costs
