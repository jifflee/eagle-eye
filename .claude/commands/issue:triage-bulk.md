---
description: Review all open issues in the active milestone and apply intelligent labeling and prioritization
---

# PM Triage

Analyze open issues in the active milestone and recommend/apply intelligent labeling for priority, type, and status.

**Key difference from /sprint-status:**
- `/sprint-status` = READ-only, displays audit findings
- `/issue:triage-bulk` = WRITE operation, applies label changes

## Usage

```
/issue:triage-bulk              # Interactive - shows analysis, asks for approval
/issue:triage-bulk --apply      # Auto-apply all recommendations
/issue:triage-bulk --dry-run    # Show what would change (no modifications)
/issue:triage-bulk --fast       # Process only needs-triage issues (from /capture --fast)
```

## Prerequisites

**Resolve script path before running.**
The script may be in the local repo or in `~/.claude/scripts/` (synced via `/skill-sync`).

```bash
# Resolve script location (local repo or ~/.claude/scripts/)
SCRIPT_PATH="./scripts/issue:triage-bulk-data.sh"
if [ ! -x "$SCRIPT_PATH" ]; then
  SCRIPT_PATH="$HOME/.claude/scripts/issue:triage-bulk-data.sh"
fi
if [ ! -x "$SCRIPT_PATH" ]; then
  echo "Error: pm-triage-data.sh not found. Run /skill-sync to install."
  exit 1
fi
```

## Steps

### 1. Gather Data

```bash
# Use the resolved SCRIPT_PATH from Prerequisites
$SCRIPT_PATH
# OR for dry-run:
$SCRIPT_PATH --dry-run
# OR for specific milestone:
$SCRIPT_PATH --milestone "sprint-1/13"
```

Returns JSON with:
- `milestone`: Milestone metadata
- `issues_with_recommendations`: Issues needing label changes
- `similar_issues`: Potential duplicates to consolidate
- `summary`: Count of recommendations by category

### 1.5 Process Needs-Triage Issues (Fast Mode or Full Mode)

Issues captured with `/capture --fast` are created with the `needs-triage` label and require additional processing.

**Query needs-triage issues:**

```bash
# Get all issues pending triage
NEEDS_TRIAGE=$(gh issue list --label "needs-triage" --json number,title,body,labels --limit 50)
```

**For each needs-triage issue, perform:**

#### A. Parent Epic Detection

Search for related epics and suggest parent linking:

```bash
# Extract keywords from issue title
ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r '.title')

# Find potential parent epics
./scripts/find-parent-issues.sh "$ISSUE_TITLE" --limit 3
```

**If matches found with >50% relevance:**
- Recommend adding `parent:N` label
- Display epic context for confirmation

**Apply parent link:**
```bash
gh issue edit $ISSUE --add-label "parent:$EPIC_NUMBER"
```

#### B. Duplicate Detection

Search for similar existing issues:

```bash
# Search for duplicates
./scripts/search-similar-issues.sh "$ISSUE_TITLE" 5
```

**Duplicate scoring:**
| Similarity | Action |
|------------|--------|
| >80% match | Mark as `duplicate`, add comment linking to original |
| 50-80% match | Flag for review, suggest consolidation |
| <50% match | No action, likely distinct issue |

**If duplicate detected:**
```bash
# Mark as duplicate with reference
gh issue edit $ISSUE --add-label "duplicate"
gh issue comment $ISSUE --body "Duplicate of #$ORIGINAL_ISSUE. Consider closing in favor of the original."
```

#### C. Complete Triage

After processing, remove the `needs-triage` label:

```bash
# Remove needs-triage after processing
gh issue edit $ISSUE --remove-label "needs-triage"
```

**Fast Mode (`--fast`) Output:**

When using `--fast` flag, only process `needs-triage` issues:

```
## Fast Triage Report

**Issues Processed:** {count}

### Parent Links Detected

| Issue | Recommended Parent | Relevance |
|-------|--------------------|-----------|
| #150 | #143 (Sprint Orchestration) | 75% |

### Duplicates Detected

| Issue | Duplicate Of | Similarity |
|-------|--------------|------------|
| #151 | #120 | 85% |

### Labels Applied

| Issue | Labels Added | Labels Removed |
|-------|--------------|----------------|
| #150 | parent:143, P2 | needs-triage |
| #151 | duplicate | needs-triage |
```

### 2. Display Report

Format the JSON into a readable report:

```
## PM Triage Report

**Milestone:** {title}
**Due:** {due_on}
**Issues Analyzed:** {count}

---

### Priority Assignments

| Issue | Current | Recommended | Reason |
|-------|---------|-------------|--------|
| #{n} | (none) | P1 | Active work (in-progress) |
| #{n} | (none) | P2 | Standard feature priority |

**Changes:** {count} issues need priority labels

---

### Type Corrections

| Issue | Current | Recommended | Reason |
|-------|---------|-------------|--------|
| #{n} | feature | bug | Title uses fix: prefix |

**Changes:** {count} issues need type correction

---

### Status Updates

| Issue | Current | Recommended | Reason |
|-------|---------|-------------|--------|
| #{n} | in-progress | blocked | No activity for 5 days |

**Changes:** {count} status updates recommended

---

### Similar Issues (Consolidation Opportunities)

| Issues | Similarity | Suggestion |
|--------|------------|------------|
| #67, #68 | 50% | Consider consolidating or linking |

---

### Summary

| Category | Count |
|----------|-------|
| Priority assignments | {n} |
| Type corrections | {n} |
| Status updates | {n} |
| **Total changes** | {n} |
```

### 3. Handle User Selection

**If `--apply` flag:**
Apply all recommendations automatically.

**If `--dry-run` flag:**
Display report only, no changes made.

**Otherwise (interactive mode):**
Ask user to select action:

```
Apply these changes? [y/n/select]

y = Apply all recommendations
n = Cancel, no changes
select = Choose specific changes to apply
```

**If 'select':**
Present numbered list of all changes, let user choose which to apply (comma-separated numbers).

### 4. Apply Label Changes

For each approved change:

```bash
# Add priority label
gh issue edit $ISSUE --add-label "P2"

# Correct type label (remove old, add new)
gh issue edit $ISSUE --remove-label "feature" --add-label "bug"

# Update status
gh issue edit $ISSUE --remove-label "in-progress" --add-label "blocked"
```

### 5. Display Results

```
## Changes Applied

| Issue | Action | Result |
|-------|--------|--------|
| #105 | Added P1 | Success |
| #67 | Changed feature → bug | Success |

**Total:** {n} issues updated
```

## Priority Detection Rules

| Signal | Priority | Reason |
|--------|----------|--------|
| Title contains: critical, security, urgent, production, outage | P0 | Critical keyword in title |
| Status: in-progress | P1 | Active work |
| Type: bug OR title uses fix: prefix | P1 | Bug priority |
| Title contains: high priority, important | P1 | High priority keyword |
| Title contains: nice-to-have, low priority, minor, cleanup | P3 | Low priority keyword |
| Type: docs OR title uses docs: prefix | P3 | Documentation issue |
| Has parent:N label | P2 | Epic child (default) |
| Default | P2 | Standard feature priority |

### Four Wise Men Priority Validation (Optional)

For issues where priority is ambiguous (no clear signals), use the Four Wise Men framework:

```bash
# If issue has no priority signals, run debate
if [ -z "$DETECTED_PRIORITY" ]; then
  echo "No clear priority signals. Running Four Wise Men debate..."
  # Invoke /issue-prioritize for priority recommendation
fi
```

**When to use Four Wise Men:**
- Issue has no priority keywords
- Issue is not in-progress
- Issue type doesn't determine priority
- Multiple valid priority levels could apply

**Consensus-to-priority mapping:**

| Timing | Need | Consensus Priority |
|--------|------|--------------------|
| PROCEED NOW | ESSENTIAL | P0 or P1 |
| PROCEED NOW | VALUABLE | P1 |
| WAIT | ESSENTIAL | P1 |
| WAIT | VALUABLE | P2 |
| WAIT | OPTIONAL | P2 or P3 |
| DEFER | OPTIONAL | P3 |
| DEFER | UNNECESSARY | Close issue |

**Integration example:**
```
Issue #150: "Add keyboard shortcuts for navigation"

Priority Detection: No clear signals (default P2)

Four Wise Men Consensus:
- Timing: WAIT (other P1 bugs in queue)
- Scope: MVP (start with 5 essential shortcuts)
- Need: VALUABLE (user requested, improves efficiency)
- Vision: COMPATIBLE (aligns with UX goals)

Recommended Priority: P2 ✓ (default confirmed by consensus)
```

## Type Detection Rules

Types are detected from Conventional Commits prefixes in the title:

| Prefix | Type |
|--------|------|
| `fix:`, `fix(`, `bug:`, `bug(` | bug |
| `feat:`, `feat(`, `feature:`, `add:` | feature |
| `docs:`, `docs(`, `doc:` | docs |
| `refactor:`, `refactor(`, `chore:`, `perf:` | tech-debt |

## Status Detection Rules

| Condition | Recommendation |
|-----------|----------------|
| No status label present | Add `backlog` |
| `in-progress` but no activity for 3+ days | Change to `blocked` |

## Token Optimization

- Uses `pm-triage-data.sh` for all data gathering (local or `~/.claude/scripts/`)
- Single GitHub API call batch (milestone + issues list)
- JSON output for efficient parsing
- ~600-800 tokens per invocation

## Notes

- WRITE operation (modifies issue labels)
- Requires user confirmation in interactive mode
- Use `--dry-run` to preview without changes
- Use `--fast` to process only `needs-triage` issues (from `/capture --fast`)
- Pairs well with `/sprint-status` for full audit
- Pairs with `/capture --fast` for rapid issue capture → deferred triage workflow
- Related: `/issue:label` for single-issue label changes
- Related: `/issue-triage` for issue quality improvements
- Related: `/capture` for issue creation with optional fast mode
- Uses `find-parent-issues.sh` for epic parent detection
- Uses `search-similar-issues.sh` for duplicate detection
