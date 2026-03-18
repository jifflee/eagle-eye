---
description: Full comprehensive repository audit combining structure, code patterns, and health metrics (READ-ONLY - query only)
---

# Repo Audit Complete

**🔒 READ-ONLY OPERATION - This skill NEVER modifies the repository**

Comprehensive repository audit orchestrating structure and code analysis with cross-cutting concerns.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- Only orchestrates other READ-ONLY skills (/repo-structure, /repo-code)
- All recommendations are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work` or any write operations from this skill
- DO NOT use the Skill tool to execute WRITE-FULL operations

## Usage

```
/repo-audit-complete
```

## Steps

### 1. Run Sub-Audits

Orchestrate in sequence:
1. Run `/repo-structure` analysis
2. Run `/repo-code` analysis
3. Perform cross-cutting analysis
4. Calculate combined score
5. Generate report

### 2. Cross-Cutting Analysis

**Documentation:**
```bash
[[ -f "README.md" ]] && echo "README: present"
[[ -f "CONTRIBUTING.md" ]] && echo "CONTRIBUTING: present"
grep -rn "@param\|@returns\|Args:" --include="*.ts" --include="*.py" . 2>/dev/null | wc -l
```

**Test Coverage:**
```bash
TEST_FILES=$(find . -name "*.test.*" -o -name "*.spec.*" | grep -v node_modules | wc -l)
SOURCE_FILES=$(find . -name "*.ts" -o -name "*.py" | grep -v node_modules | grep -v test | wc -l)
```

**Security:**
```bash
grep -rn "password\s*=\|api_key\s*=" --include="*.ts" --include="*.py" . 2>/dev/null | grep -v node_modules
[[ -f ".env.example" ]] && echo ".env.example: present"
```

**CI/CD:**
```bash
[[ -d ".github/workflows" ]] && echo "GitHub Actions: present"
[[ -f "Dockerfile" ]] && echo "Docker: present"
[[ -f ".eslintrc*" ]] && echo "ESLint: present"
```

### 3. Calculate Combined Score

| Category | Weight |
|----------|--------|
| Structure | 25% |
| Code Quality | 30% |
| Documentation | 15% |
| Test Coverage | 15% |
| DevOps | 15% |

Thresholds: Good (80+), Warning (60-79), Needs Work (40-59), Critical (<40)

## Output Format

```
## Comprehensive Repository Audit

**Overall Health Score:** {score}/100 ({status})
**Repository:** {name}

---

## Executive Summary

{2-3 sentence assessment}

### Top Issues
1. **[{severity}]** {finding}
2. **[{severity}]** {finding}

### Strengths
- {strength}

---

## Score Breakdown

| Category | Score | Weight | Weighted |
|----------|-------|--------|----------|
| Structure | {x}/100 | 25% | {y} |
| Code Quality | {x}/100 | 30% | {y} |
| Documentation | {x}/100 | 15% | {y} |
| Test Coverage | {x}/100 | 15% | {y} |
| DevOps | {x}/100 | 15% | {y} |
| **Total** | - | **100%** | **{final}** |

---

## All Findings

| ID | Severity | Title |
|----|----------|-------|
| {id} | {severity} | {title} |

---

## Recommended Actions

1. **Now:** {action}
2. **This Sprint:** {action}
3. **Backlog:** {action}

Run `/repo-structure` or `/repo-code` for detailed analysis.
```

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Orchestrates /repo-structure and /repo-code (both READ-ONLY skills)
- Weighted scoring for balanced assessment
- Saves report to `.repo-audit/audit-complete.md`
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - WRITE-FULL skills
  - File or code modification operations
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill and its sub-skills are READ-ONLY. Never cross this boundary.

**User action:** Apply recommended improvements manually
