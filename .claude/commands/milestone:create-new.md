---
description: Create a new GitHub milestone interactively
---

# New Milestone

Create a new milestone interactively or with a provided name.

## Usage

```
/milestone-create                    # Interactive mode
/milestone-create Sprint 1           # Direct name (no quotes needed)
/milestone-create "Phase 2 Release"  # Quoted name (also works)
```

## Argument Handling

If arguments are provided (ARGUMENTS section is non-empty):
1. Use the entire argument string as the milestone name
2. Strip surrounding quotes if present (for backwards compatibility)
3. Skip the interactive name prompt, proceed directly to due date

**Example parsing:**
- `/milestone-create Sprint 1` → name = "Sprint 1"
- `/milestone-create "Sprint 1"` → name = "Sprint 1" (quotes stripped)
- `/milestone-create` → interactive prompt

## Steps

### 1. Gather Data

```bash
./scripts/milestone-create-data.sh
```

Returns JSON with existing milestones and suggestions.

### 2. Get Name

**If arguments provided:** Use arguments as name (strip quotes if present).

**If no arguments:** Use AskUserQuestion with suggestions from `suggestions.names`:
- First suggestion (Recommended)
- Remaining suggestions
- Custom name

### 3. Validate Name

**First, validate naming convention:**

```bash
./scripts/validate/validate-milestone-name.sh "<name>"
```

Check the JSON response:
- If `valid: false`, show the error reason and suggest using the recommended name
- The script enforces the `sprint-MMYY-N` convention (e.g., `sprint-0226-7`)
- Historical milestones (MVP, n8n-mvp, backlog, sprint-1/13, sprint-2/7, sprint-2/8) are grandfathered

**Then, check if name already exists:**

```bash
./scripts/milestone-create-data.sh --check "<name>"
```

Check `name_check.exists` - if true, prompt for different name.

### 4. Get Due Date

Use `suggestions.due_dates` for options:
- 30 days (Recommended)
- 60 days
- 90 days
- No due date
- Custom

### 5. Create Milestone

```bash
gh api repos/:owner/:repo/milestone-list -X POST \
  -f title="{name}" \
  -f state="open" \
  -f description="Sprint milestone" \
  -f due_on="{ISO_DATE}"
```

### 6. Verify

```bash
gh api repos/:owner/:repo/milestone-list --jq '.[] | select(.title=="{name}")'
```

## Output Format

```
## Milestone Created

**Name:** {name}
**Due:** {date}

Assign issues: `gh issue edit [num] --milestone "{name}"`
View: https://github.com/{owner}/{repo}/milestone-list
```

## Token Optimization

- Uses `scripts/milestone-create-data.sh` for all data gathering
- Returns structured JSON with suggestions pre-computed
- Single API call to fetch existing milestones
- ~300-400 tokens per invocation (vs ~800 verbose)

## Notes

- WRITE operation - creates milestone
- Validates name doesn't already exist
- Due date optional but recommended
