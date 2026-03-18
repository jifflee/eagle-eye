---
description: Review and improve issue quality with suggested enhancements
---

# Issue Triage

Analyze issue content, identify missing information, and suggest improvements.

## Usage

```
/issue-triage <number>        # Triage specific issue
/issue-triage --milestone     # Triage all needs-triage in milestone
/issue-triage --auto          # Auto-update with confirmation
```

## Steps

### 1. Gather Data

```bash
./scripts/issue-triage-data.sh <number>
# OR for batch mode:
./scripts/issue-triage-data.sh --milestone "<name>"
```

Returns JSON with issue content, detected patterns, and quality scores.

### 2. Review Results

The script returns:
- `type`: Detected issue type from labels
- `score`: Quality score (0-100)
- `status`: needs_improvement | acceptable | ready
- `missing_sections`: Array of missing required sections
- `sections`: Boolean map of detected sections

### 3. Generate Suggestions

Based on `missing_sections`, provide templates:

**Bug - missing reproduction steps:**
```markdown
## Steps to Reproduce
1.
2.
3.

## Expected Behavior


## Actual Behavior

```

**Feature - missing acceptance criteria:**
```markdown
## Acceptance Criteria
- [ ]
- [ ]
```

**Tech-debt - missing problem/solution:**
```markdown
## Problem Statement


## Proposed Solution

```

### 4. Display Analysis

Format output using the data from script.

### 5. Apply Updates (if selected)

Options:
1. Update issue with suggestions
2. Edit suggestions first
3. Skip
4. Mark ready (remove needs-triage)

## Output Format

```
## Issue Triage: #{n} "{title}"

**Quality score:** {score}/100
**Status:** {Needs improvement|Acceptable|Ready}

---

### Missing Information

| Required | Status | Suggestion |
|----------|--------|------------|
| {section} | {status} | {suggestion} |

---

### Suggested Additions

```markdown
## Acceptance Criteria
- [ ] {criterion}
```

---

### Actions

1. Update issue
2. Edit suggestions
3. Skip
4. Mark ready
```

## Batch Mode Output

```
## Session Summary

| Issue | Before | After | Action |
|-------|--------|-------|--------|
| #{n} | {score} | {score} | {action} |
```

## Token Optimization

- Uses `scripts/issue-triage-data.sh` for all data gathering
- Returns structured JSON for efficient parsing
- Single API call per issue (batch mode: one list call + one per issue)
- ~400-600 tokens per invocation (vs ~1500 verbose)

## Notes

- WRITE operation (can modify issues)
- Requires confirmation before changes
- Use with `/milestone-audit` to identify issues needing triage
