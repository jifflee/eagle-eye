---
description: Audit skills for token efficiency improvements and identify scripting opportunities (READ-ONLY - query only)
---

# Skill Analyzer

**🔒 READ-ONLY OPERATION - This skill NEVER modifies skill files**

Analyze skills to identify where Claude API calls can be replaced with shell scripting.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- All recommendations are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work` or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/audit-skills                 # Analyze all skills
/audit-skills capture         # Analyze specific skill
/audit-skills --detailed      # Show pattern matches
```

## Steps

### 1. Gather Data

```bash
./scripts/audit-skills-data.sh [skill_name]
```

Returns JSON: skills list, pattern matches, optimizations detected, recommendations.

### 2. Pattern Detection

| Pattern | Alternative |
|---------|-------------|
| `gh issue list` + Claude parse | Use `jq` directly |
| Multiple sequential `gh` calls | Batch into script |
| Read file + analyze | `grep`/`awk` patterns |
| JSON parsing in prose | `jq` queries |
| "Count"/"aggregate" language | `wc`/`sort`/`uniq` |
| "Format as table" | `printf`/`column` |
| No `scripts/` reference | Create data script |

### 3. Calculate Score

```
Base: 100
- No script reference: -30
- Multiple gh without batch: -5 each (max -25)
- "Parse the output": -10
- JSON without jq: -10
- Manual counting: -10
- No Token Optimization section: -15

+ Has Token Optimization section: +10
+ References data script: +15
+ Uses jq: +10
+ "batch"/"single pass" language: +5
```

### 4. Generate Report

## Output Format

```
## Skill Efficiency Audit

**Skills analyzed:** {n}
**Average score:** {score}/100
**Optimized:** {n}
**Needs attention:** {n}

---

### Summary by Score

| Range | Count | Skills |
|-------|-------|--------|
| 80-100 (Good) | {n} | {list} |
| 50-79 (Fair) | {n} | {list} |
| 0-49 (Needs Work) | {n} | {list} |

---

### Skills Needing Optimization

| Skill | Score | Issues |
|-------|-------|--------|
| {name} | {score} | {issues} |

---

### Optimization Opportunities

**{skill}** (Score: {n}/100)
- [ ] {recommendation}

---

### Already Optimized

| Skill | Score | Optimizations |
|-------|-------|---------------|
| {name} | {score} | {optimizations} |
```

## Token Optimization

This skill is optimized for minimal token usage:

**Data gathering via script:**
- Single call to `./scripts/audit-skills-data.sh` returns all needed data
- Script uses `jq` for efficient JSON parsing and scoring calculations
- Batch file analysis reduces individual file reads
- Pattern detection runs server-side in bash/jq, not in Claude

**Token savings:**
- Before optimization: ~2,000 tokens (read all skills, parse manually, calculate scores in Claude)
- After optimization: ~500 tokens (single structured JSON response with pre-calculated scores)
- Savings: **75%**

**Measurement:**
- Baseline: 2,000 tokens without data script (manual skill file reading + Claude analysis)
- Current: 500 tokens with data script (pre-analyzed JSON input)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Key optimizations:**
- ✅ All skill analysis done in bash script using file I/O and `jq`
- ✅ Scores calculated server-side (pattern matching, token estimates)
- ✅ Claude receives only final structured results, not raw skill files
- ✅ Single-pass data gathering (reads all skills once)

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Use to identify token reduction opportunities
- Run after adding new skills
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - Skill modification operations
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Never cross this boundary.

**User action:** Apply recommended optimizations to skills manually
