---
name: create-issue
description: Create a GitHub issue using the repo-workflow agent (enforces conventions)
argument-hint: "[--title TITLE] [--type bug|feature] [--priority P0-P3]"
---

# Create Issue

Creates a GitHub issue with enforced label conventions when assigning to milestones.

## Usage

```
/issue:create                           # Interactive issue creation
/issue:create --title "Bug: X fails"    # Quick create with title
/issue:create --milestone MVP           # Create in specific milestone (triggers validation)
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--title` | No | Issue title (prompted if not provided) |
| `--body` | No | Issue body/description |
| `--milestone` | No | Milestone to assign (triggers label validation) |
| `--type` | No | Issue type: `bug`, `feature`, `tech-debt`, `docs` |
| `--priority` | No | Priority: `P0`, `P1`, `P2`, `P3` |
| `--labels` | No | Additional labels (comma-separated) |
| `--lenient` | No | Use lenient mode (auto-add missing labels) |
| `--strict` | No | Use strict mode (block if labels missing) |

## Label Enforcement

When `--milestone` is specified, the skill enforces label conventions:

### Required Labels (when milestone specified)

1. **Type Label** (exactly one required):
   - `bug` - Defect/issue
   - `feature` - New functionality
   - `tech-debt` - Refactoring/cleanup
   - `docs` - Documentation task

2. **Status Label** (exactly one required):
   - `backlog` - Default for new issues
   - `in-progress` - Actively worked on
   - `blocked` - Waiting on dependency

### Enforcement Modes

| Mode | Behavior | Flag |
|------|----------|------|
| **Lenient** (default) | Auto-adds missing labels (`backlog` for status) | `--lenient` |
| **Strict** | Blocks creation if required labels missing | `--strict` |
| **Advisory** | Warns but creates anyway | (no flag, no milestone) |

## Workflow

### Step 1: Gather Information

First, load available milestones and labels:
```bash
./scripts/issue:create-data.sh
```

If arguments not provided, prompt user for:
- Title (required)
- Description/body
- Type (bug/feature/tech-debt/docs)
- Milestone (optional - triggers validation)
- Priority (optional)

### Step 2: Validate Labels (if milestone specified)

```
IF milestone specified:
  IF type label missing:
    IF lenient mode: prompt for type OR fail
    IF strict mode: BLOCK creation
  IF status label missing:
    IF lenient mode: auto-add "backlog"
    IF strict mode: BLOCK creation
```

### Step 3: Create Issue

```bash
# Build label string
LABELS=""
if [ -n "$TYPE" ]; then LABELS="$TYPE"; fi
if [ -n "$STATUS" ]; then LABELS="$LABELS,$STATUS"; fi
if [ -n "$PRIORITY" ]; then LABELS="$LABELS,$PRIORITY"; fi
if [ -n "$EXTRA_LABELS" ]; then LABELS="$LABELS,$EXTRA_LABELS"; fi

# Create issue
gh issue create \
  --title "$TITLE" \
  --body "$BODY" \
  --milestone "$MILESTONE" \
  --label "$LABELS"
```

### Step 4: Confirm Creation

Display:
- Issue number and URL
- Applied labels
- Assigned milestone
- Any auto-added labels (in lenient mode)

## Examples

### Quick Bug Report
```
/issue:create --title "Login fails with special characters" --type bug --milestone MVP
```
Result: Creates issue with `bug`, `backlog` labels in MVP milestone.

### Interactive Feature Creation
```
/issue:create
> Title: Add dark mode toggle
> Type: feature
> Milestone: MVP
> Priority: P2

Created #42: "Add dark mode toggle"
Labels: feature, backlog, P2
Milestone: MVP
```

### Strict Mode (CI/CD pipelines)
```
/issue:create --title "Test" --milestone MVP --strict
ERROR: Cannot create issue - missing required labels:
  - Type label required (bug, feature, tech-debt, docs)
Use --type to specify, or remove --strict flag.
```

## Integration with repo-workflow Agent

This skill delegates to the `repo-workflow` agent for actual issue creation.
The skill handles:
- Label validation logic
- User prompts for missing info
- Enforcement mode selection

The agent handles:
- GitHub API calls
- Issue hygiene checks
- Duplicate detection

## Configuration

Label enforcement can be configured in `.claude-tastic.config.yml`:

```yaml
label_enforcement:
  # Default mode: lenient, strict, or advisory
  default_mode: lenient

  # Required labels when milestone is specified
  milestone_labels:
    type:
      required: true
      values: [bug, feature, tech-debt, docs]
    status:
      required: true
      default: backlog
      values: [backlog, in-progress, blocked]
    priority:
      required: false
      values: [P0, P1, P2, P3]
```

## Error Messages

| Situation | Message |
|-----------|---------|
| Missing type (strict) | "Cannot create issue - type label required (bug, feature, tech-debt, docs)" |
| Missing milestone | "Issue created without milestone - no label validation applied" |
| Invalid type | "Invalid type '{value}' - must be: bug, feature, tech-debt, docs" |
| Label creation failed | "Failed to create label '{name}' - check repository permissions" |

## Token Optimization

This skill is optimized for minimal token usage through efficient data gathering:

**Data gathering via script:**
- Single call to `./scripts/issue:create-data.sh` returns all needed data
- Script batches multiple `gh api` calls and uses `jq` for efficient JSON processing
- Returns milestones, labels, and validation rules in one structured response
- Label categorization (type, status, priority) happens server-side in bash/jq

**Token savings:**
- Before optimization: ~2,000 tokens (multiple gh calls + Claude parsing of raw output)
- After optimization: ~725 tokens (single structured JSON with pre-categorized labels)
- Savings: **63%**

**Measurement:**
- Baseline: 2,000 tokens (3-4 separate `gh` calls + manual label categorization in Claude)
- Current: 725 tokens (single script call with pre-processed data)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Key optimizations:**
- ✅ Batched GitHub API calls (milestones + labels in one script execution)
- ✅ Label categorization done server-side using `jq` filters
- ✅ Validation rules embedded in script output
- ✅ Claude receives only structured, actionable data

**Example usage:**
```bash
# Get all data needed for issue creation
./scripts/issue:create-data.sh

# Get only milestones (for quick validation)
./scripts/issue:create-data.sh --milestones

# Get only labels (for label selection prompts)
./scripts/issue:create-data.sh --labels
```

## Notes

- This skill is WRITE operation (creates issues)
- Uses `repo-workflow` agent for GitHub operations
- Label validation only applies when milestone is specified
- Lenient mode is recommended for interactive use
- Strict mode is recommended for automation/CI
- See `GITHUB_CONVENTIONS.md` for label standards
