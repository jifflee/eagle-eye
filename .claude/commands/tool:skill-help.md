---
description: Interactive skill catalog - discover and explore available skills
argument-hint: "[CATEGORY|SKILL] [--search KEYWORD]"
global: true
---

# Skill Help

Interactive catalog of all available skills with descriptions, usage hints, and search.

## Usage

```
/skill-help                    # List all skills grouped by category
/skill-help pr                 # Show all pr: skills with descriptions
/skill-help sprint:work-auto   # Show detailed help for specific skill
/skill-help --search merge     # Search skills by keyword
```

## Instructions

When this command is invoked:

1. **Parse arguments** to determine mode (list all, filter by category, single skill, or search)
2. **Read skill files** from `core/commands/*.md` to extract frontmatter
3. **Group and display** according to mode
4. **Handle missing data** gracefully (missing frontmatter fields)

## Steps

### 1. Parse Arguments

Determine the operation mode based on arguments:

| Pattern | Mode | Action |
|---------|------|--------|
| No args | list-all | Show all skills grouped by category |
| `CATEGORY` (e.g., `pr`) | filter-category | Show skills in that category |
| `CATEGORY:NAME` (e.g., `pr:merge-batch`) | single-skill | Show detailed help for one skill |
| `--search KEYWORD` | search | Search skills by keyword |

**Validation:**
- Category names: `audit`, `delivery`, `issue`, `local`, `merge`, `milestone`, `ops`, `pr`, `release`, `repo`, `sprint`, `tool`, `validate`
- If category invalid, show error and list valid categories

### 2. Read Skill Files

Scan `core/commands/*.md` files and extract frontmatter:

**Required fields:**
- `description` - Short description of what the skill does

**Optional fields:**
- `argument-hint` - Usage hint (e.g., `[--flag] [args]`)
- `permissions.max_tier` - Permission tier (T0, T1, T2, etc.)
- Model information (inferred from skill or default to "haiku")

**Parsing approach:**

For each `.md` file in `core/commands/`:
1. Extract filename to get skill name (e.g., `pr:merge-batch.md` → `pr:merge-batch`)
2. Extract category from filename (text before `:`)
3. Read frontmatter between first `---` and second `---`
4. Parse YAML fields: `description`, `argument-hint`, `permissions.max_tier`
5. Handle missing fields:
   - Missing `description`: Use `"No description available"`
   - Missing `argument-hint`: Use `""`
   - Missing `permissions.max_tier`: Use `"READ-ONLY"` if description contains "READ-ONLY", else `"WRITE-FULL"`

**Example parsing:**

```bash
# For file: core/commands/pr:merge-batch.md
# Frontmatter:
# ---
# description: Batch merge mergeable PRs for milestone (validates before merging)
# argument-hint: "[--milestone NAME] [--dry-run] [--pr NUMBER]"
# ---

# Extracted data:
{
  "name": "pr:merge-batch",
  "category": "pr",
  "description": "Batch merge mergeable PRs for milestone (validates before merging)",
  "argument_hint": "[--milestone NAME] [--dry-run] [--pr NUMBER]",
  "permission": "WRITE-FULL"
}
```

### 3. Group and Display

Based on mode, format and display output:

#### Mode: list-all

Group skills by category and display catalog:

```
## Skill Catalog (63 skills across 13 categories)

### audit (7 skills)
  audit:code          Analyze code patterns, module boundaries, coupling
  audit:config        Audit Claude Code configuration files
  audit:epics         Audit all epics and milestones for completion
  audit:full          Full comprehensive repository audit
  audit:milestone     Analyze milestone health and surface issues
  audit:regression    Run regression audit for skills, hooks, and actions
  audit:structure     Analyze folder/file organization and conventions
  audit:ui-ux         Audit UI/UX design standard compliance

### delivery (1 skill)
  delivery:audit      Validate GitHub issue tracking against actual PR deliveries

### issue (9 skills)
  issue:capture       Quick capture for bugs, features, and observations
  issue:checkout      Claim an issue for the current Claude instance
  issue:close         Close GitHub issue(s) using the repo-workflow agent
  issue:create        Create a GitHub issue using the repo-workflow agent
  issue:label         Apply or remove labels on GitHub issues
  issue:locks         Show all currently checked-out issues across instances
  issue:prioritize-4wm Run the Four Wise Men decision framework
  issue:release       Release a checked-out issue, removing the lock
  issue:triage-bulk   Review all open issues in the active milestone
  issue:triage-single Review and improve issue quality with suggested enhancements

[... remaining categories ...]

---

**Tips:**
- Use `/skill-help CATEGORY` to filter by category (e.g., `/skill-help pr`)
- Use `/skill-help SKILL:NAME` for detailed help (e.g., `/skill-help pr:merge-batch`)
- Use `/skill-help --search KEYWORD` to search skills
```

**Formatting rules:**
- Sort categories alphabetically
- Within each category, sort skills alphabetically
- Align skill names to 20 characters for readability
- Truncate descriptions to 60 characters if needed

#### Mode: filter-category

Show only skills in the specified category:

```
## Skill Catalog: pr (7 skills)

  pr:dep-review-auto  Analyze dependency PRs for breaking changes
  pr:iterate-auto     Automated review-fix iteration loop
  pr:merge-batch      Batch merge mergeable PRs for milestone
  pr:rebase-dev       Rebase a PR branch on dev to resolve conflicts
  pr:review-local     Run all PR review agents locally
  pr:route-fixes      Route PR review findings to the agents that wrote the code
  pr:status-check     Check current PR review status

---

**Tips:**
- Use `/skill-help pr:SKILL` for detailed help on a specific skill
- Use `/skill-help` to see all categories
```

#### Mode: single-skill

Show detailed help for one skill:

```
## sprint:work-auto

Automatically work through milestone issues from backlog to completion following SDLC workflow

**Usage:** /sprint-work [args]

**Arguments:**
  --issue N        Work on specific issue
  --worktree       Use worktree mode instead of container
  --dry-run        Show what would be done
  --epic N         Work on children of epic
  --skip-review    Skip internal review phase

**Category:** sprint
**Permission:** WRITE-FULL
**Model:** haiku (inferred)

**Aliases:**
  /sprint-work (primary invocation)

---

For full documentation, read: `core/commands/sprint:work-auto.md`
```

**Data to display:**
- Skill name
- Description (full, not truncated)
- Usage pattern (from `argument-hint` if available)
- Category
- Permission tier
- Model (if available in frontmatter)
- Aliases (if documented)

#### Mode: search

Search across all skills for keyword matches:

```
## Search Results for "merge"

Found 5 skills matching "merge":

### pr:merge-batch
  Batch merge mergeable PRs for milestone (validates before merging)
  Category: pr | Permission: WRITE-FULL

### merge:resolve
  Interactive workflow for resolving PR conflicts and managing PRs
  Category: merge | Permission: WRITE-FULL

### milestone:close-safe
  Close a milestone safely with validation and optional next milestone
  Category: milestone | Permission: WRITE-FULL
  Match: Description mentions "merge"

[... remaining matches ...]

---

**Tips:**
- Use `/skill-help SKILL:NAME` for detailed help
- Use `/skill-help CATEGORY` to browse by category
```

**Search matching:**
- Match keyword against:
  1. Skill name (case-insensitive)
  2. Description text (case-insensitive)
  3. Category name
- Rank results:
  1. Exact name match (highest)
  2. Name contains keyword
  3. Description contains keyword
- Display top 20 results maximum

### 4. Handle Missing Data

Gracefully handle missing or malformed frontmatter:

**Missing description:**
```
  skill:name          No description available
```

**Missing argument-hint:**
- Don't show "Arguments:" section in detailed view
- Show "Usage: /skill-name" without arguments

**Missing file:**
```
Error: Skill 'pr:unknown' not found

Available skills in 'pr' category:
  pr:dep-review-auto
  pr:iterate-auto
  pr:merge-batch
  [...]
```

**Invalid category:**
```
Error: Category 'unknown' does not exist

Valid categories:
  audit, delivery, issue, local, merge, milestone, ops, pr, release, repo, sprint, tool, validate

Tip: Use `/skill-help` to see all skills
```

## Output Format

See examples in Steps section above.

## Error Handling

| Error | Message | Action |
|-------|---------|--------|
| Invalid category | "Category 'X' does not exist" | List valid categories |
| Skill not found | "Skill 'X' not found" | List skills in category if category valid |
| No search results | "No skills match 'X'" | Suggest broader search or list all |
| Malformed frontmatter | Skip field, use default | Continue with other fields |

## Notes

- READ-ONLY operation - no modifications to files
- Works in both container and worktree modes
- No external dependencies (no API calls)
- Fast execution (local file reads only)
- Parses YAML frontmatter manually (no yq required)
- Falls back gracefully for missing data
- Category names extracted from filename (text before `:`)
- Permission tier inferred from description if not in frontmatter
- Model information not stored in frontmatter currently, use "haiku (inferred)" as default

## Token Optimization

- No data scripts needed (reads files directly)
- No API calls
- Simple file I/O and text parsing
- Minimal token usage (~200-300 tokens per invocation)

## Implementation Notes

**Frontmatter parsing approach:**

Use Bash or Read tool to extract frontmatter:

```bash
# Extract frontmatter from a skill file
extract_frontmatter() {
  local file="$1"
  awk '
    BEGIN { in_frontmatter = 0; started = 0 }
    /^---$/ {
      if (!started) { started = 1; in_frontmatter = 1; next }
      else if (in_frontmatter) { exit }
    }
    in_frontmatter { print }
  ' "$file"
}

# Parse description field
parse_description() {
  local frontmatter="$1"
  echo "$frontmatter" | grep '^description:' | sed 's/^description: *//' | sed 's/^"//' | sed 's/"$//'
}

# Parse argument-hint field
parse_argument_hint() {
  local frontmatter="$1"
  echo "$frontmatter" | grep '^argument-hint:' | sed 's/^argument-hint: *//' | sed 's/^"//' | sed 's/"$//'
}
```

**Alternative: Use Read tool directly:**

For each skill file:
1. Use Read tool to read the file
2. Extract lines between first `---` and second `---`
3. Parse YAML fields using string matching
4. Build skill catalog in memory
5. Format and display according to mode

This approach is simpler and doesn't require Bash scripting.
