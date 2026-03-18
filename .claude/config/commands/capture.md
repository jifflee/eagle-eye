---
description: Quick capture for bugs, features, and observations with intelligent triage
---

# Capture

Capture bugs, features, or ideas with intelligent description processing, duplicate detection, and auto-categorization.

## Important

This command routes through the `repo-workflow` agent to ensure:
- Content is validated for security (no secrets, paths, credentials)
- Labels and milestones exist before assignment
- Issue creation follows governance standards

## Usage

```
/capture "description"           # Quick capture with processing
/capture                         # Interactive mode
/capture --raw "description"     # Skip processing (direct capture)
/capture --fast "description"    # Immediate creation, defer triage to PM
/capture --bug "description"     # Capture as bug (skip category prompt)
/capture --feature "description" # Capture as feature (skip category prompt)
/capture --idea "description"    # Capture as tech-debt/idea (skip category prompt)
/capture --epic "description"    # Create as epic (parent issue)
/capture --parent 45 "description" # Create as child of issue #45
```

**Fast Mode (`--fast`):**
Create issues immediately without any interactive prompts:
- Skips category detection (defaults to `feature`)
- Skips parent epic search
- Skips duplicate detection
- Skips preview/confirmation
- Adds `needs-triage` label for PM processing later

Use when you want to quickly capture an idea without breaking flow.
Run `/pm-triage` later to classify, link to epics, and detect duplicates.

**Category Flags (`--bug`, `--feature`, `--idea`):**
Pre-categorize captures to skip the interactive category detection, reducing token usage:
- `--bug` - Sets category to `bug`, skips category detection
- `--feature` - Sets category to `feature`, skips category detection
- `--idea` - Sets category to `tech-debt`, skips category detection

**Hierarchy Flags (`--epic`, `--parent`):**
Create hierarchical issue relationships:
- `--epic` - Creates issue with `epic` label (marks as parent issue)
- `--parent N` - Creates issue as child of #N (adds `parent:N` label)

**Examples:**
```bash
/capture --bug "Login fails after OAuth redirect"
/capture --feature "Add dark mode support"
/capture --idea "Refactor auth module for better testability"
/capture --epic "Auth System Refactor"           # Create an epic
/capture --parent 45 "Fix session timeout"       # Create child of #45
/capture --feature --parent 45 "Add OAuth login" # Feature child of #45
```

**Flag Combinations:**
- `--bug --raw "description"` - Bug category, skip all processing
- `--feature --raw "description"` - Feature category, skip all processing
- `--feature --parent 45 "description"` - Feature as child of epic #45

**`--raw` Flag:** Bypasses intelligent processing and creates an issue directly from your input. Use when:
- Your description is already well-formatted
- You want minimal transformation
- Speed is more important than standardization

## Instructions

When this command is invoked:

1. **Parse flags & get input** - Check for `--bug`, `--feature`, `--idea`, `--epic`, `--parent N`, `--raw` flags, then get description
2. **Analyze input** for category (unless flag provided), component, priority, action verb
3. **Find parent issues** - Search for related epics (unless `--parent` flag provided or `--epic` flag used)
4. **Scan for security issues** (secrets, paths, credentials)
5. **Search for duplicates** using processed title/summary
6. **Generate preview** with standardized format (including parent relationship if any)
7. **Allow edits** if user requests
8. **Determine milestone** - Inherit from parent or use active milestone (BEFORE creating issue)
9. **Invoke repo-workflow agent** to create the issue (with parent linking if applicable)

**Performance Tip:** Using `--bug`, `--feature`, or `--idea` flags skips the category detection prompt, reducing token usage by ~20-30%.

**Hierarchy Tip:** Using `--parent N` skips the parent detection step. Using `--epic` creates a new epic without parent detection.

## Steps

### 1. Get Input & Parse Flags

**1.1 Parse Flags**

Check for category flags, hierarchy flags, and `--raw` flag in arguments:

| Flag | Effect |
|------|--------|
| `--bug` | Set `category_override = "bug"` |
| `--feature` | Set `category_override = "feature"` |
| `--idea` | Set `category_override = "tech-debt"` |
| `--raw` | Set `skip_processing = true` |
| `--fast` | Set `fast_mode = true` (skip all prompts, add `needs-triage`) |
| `--epic` | Set `is_epic = true` (will add `epic` label) |
| `--parent N` | Set `parent_issue = N` (will add `parent:N` label) |

**Flag Parsing Rules:**
- Flags can appear in any order
- Only one category flag allowed (if multiple, use first)
- `--epic` and `--parent N` are mutually exclusive (epic cannot be child)
  - **Validation:** If both flags provided, ERROR: "Cannot use --epic and --parent together. An epic cannot be a child of another issue."
- `--fast` and `--raw` can be combined (both skip processing)
- `--fast` is mutually exclusive with `--epic` (epics need proper setup)
- `--parent` requires a number argument
- Extract remaining text after flags as the description
- Flags are case-insensitive

**1.2 Get Description**

If description provided after flags, use directly. Otherwise ask interactively.

**1.3 Fast Mode Shortcut**

**If `fast_mode = true`, skip to fast creation:**

```
Fast Mode Activated:
- Category: feature (default)
- Priority: P2 (default)
- Labels: backlog, feature, needs-triage
- Parent: none
- No duplicate check
- No preview
```

**Fast mode flow:**
1. Generate simple title from first 60 chars of description
2. Use description as summary
3. Add generic acceptance criteria
4. Skip steps 2-7 entirely
5. Jump directly to step 8 (Determine Milestone)
6. Create issue with `needs-triage` label added

**Fast mode body template:**
```markdown
## Summary
{description}

## Acceptance Criteria
- [ ] Feature implemented as specified
- [ ] Tests added for new functionality
- [ ] Documentation updated if needed

<details>
<summary>Original Input</summary>

> {raw_input}

</details>

---

## Context
Captured via /capture --fast command.
Pending triage - run /pm-triage to classify and organize.
```

### 2. Analyze Input (Intelligent Processing)

**Skip this step if `--raw` flag is used.**

Analyze the raw input to extract structured information:

**2.1 Category Detection**

**If `category_override` is set from flag parsing (step 1.1), use that value and skip detection.**

Otherwise, detect category from input patterns:

| Signal Type | Patterns | Category |
|-------------|----------|----------|
| Error keywords | broken, error, crash, bug, fail, not working, issue | bug |
| Feature keywords | add, need, want, should, new, implement, create, enable | feature |
| Refactor keywords | refactor, cleanup, optimize, improve, enhance, performance | tech-debt |
| Design keywords | design, UX, UI, architect, layout, flow | feature (phase:design) |
| Docs keywords | document, readme, guide, explain, describe, update docs | docs |
| Default | (no match) | feature |

**2.2 Component Detection**

Scan input for mentions of known components. Select first match (priority order):

| Pattern | Component |
|---------|-----------|
| `/capture`, `/sprint-work`, `/milestone`, skill(s), command(s) | skills |
| agent(s), workflow | agents |
| script(s), bash | scripts |
| test(s), spec | tests |
| doc(s), readme, md | docs |
| config, settings, claude.md | config |
| CI, action(s), pipeline | ci-cd |
| (file path mentioned) | extract from path |

**2.3 Severity/Priority Indicators**

| Signal | Priority | Label |
|--------|----------|-------|
| critical, urgent, blocking, ASAP, emergency | P0 | priority:P0 |
| important, high priority, soon | P1 | priority:P1 |
| (default - no urgency signals) | P2 | (no priority label) |
| minor, low priority, nice to have, eventually | P3 | priority:P3 |

**2.4 Action Verb Extraction**

Extract or infer the primary action for title generation:

| Input Pattern | Action Verb |
|---------------|-------------|
| "add...", "need to add..." | Add |
| "fix...", "broken...", "error..." | Fix |
| "update...", "change..." | Update |
| "remove...", "delete..." | Remove |
| "improve...", "enhance..." | Improve |
| "implement...", "create..." | Implement |
| "refactor...", "cleanup..." | Refactor |
| "document...", "describe..." | Document |
| (default for features) | Add |
| (default for bugs) | Fix |

### 2.5 Find Parent Issues (Hierarchical Linking)

**Skip this step if:**
- `--epic` flag is used (creating a new epic, not a child)
- `--parent N` flag is used (explicit parent specified)
- `--raw` flag is used (skip all processing)

**Purpose:** Detect related epic issues and prompt user to create hierarchical relationships.

**2.5.1 Search for Related Epics**

Run the find-parent-issues script with the processed title/summary:

```bash
./scripts/find-parent-issues.sh "{processed_title}"
```

**2.5.2 Evaluate Results**

If matches found with `relevance_score > 50`:

```
┌─────────────────────────────────────────────────────────────┐
│ Related to existing work:                                   │
│                                                             │
│ #45: Auth System Refactor [epic]                            │
│   Score: 75% | Updated: 2 hours ago                         │
│   Preview: "Refactor authentication for better..."          │
│                                                             │
│ #32: Security Improvements [epic]                           │
│   Score: 52% | Updated: 1 day ago                           │
│                                                             │
│ Options:                                                    │
│ 1. Create as child of #45 (recommended - highest match)     │
│ 2. Create as child of #32                                   │
│ 3. Create as standalone issue (no parent)                   │
│ 4. Cancel                                                   │
└─────────────────────────────────────────────────────────────┘
```

**2.5.3 Handle User Selection**

| Selection | Action |
|-----------|--------|
| Child of #N | Set `parent_issue = N` |
| Standalone | Set `parent_issue = null` |
| Cancel | Exit capture flow |

**2.5.4 If No Epics Found**

Continue without parent linking. Optionally prompt:

```
No related epics found. Create as:
1. Standalone issue
2. New epic (can have children later)
```

### 3. Security Content Scan

Scan input for prohibited content before proceeding:

**Patterns to REJECT (flag for user removal):**
- `/Users/{username}/` - user home paths
- `$ENV_VAR` patterns - environment variables
- `api[_-]?key`, `token`, `secret`, `password` with values - credentials
- Code blocks > 20 lines - reference file:line instead

**Patterns to ALLOW:**
- Generic paths like `src/`, `project/`, `./config/`
- References to "API" or "endpoint" without values

**If security issues found:**
```
⚠️ Security scan found potentially sensitive content:
- Line 3: Appears to contain a file path with username

Please remove sensitive content before creating the issue.
Options:
1. Edit input to remove sensitive content
2. Cancel capture
```

### 4. Generate Processed Output

**4.1 Title Generation**

Create concise, action-oriented title (max 60 characters):

```
Format: [Action Verb] [core description]
Example: "Add intelligent description processing to /capture"
```

Rules:
- Start with action verb
- Remove filler words (just, basically, kind of, etc.)
- Focus on the "what" not the "why"
- Truncate at 57 chars + "..." if exceeding 60 chars
- Truncate at word boundary when possible

**4.2 Summary Generation**

Transform raw input into a clear summary paragraph:
- Extract the core request/problem
- Remove redundancy and verbosity
- Maintain key details
- One concise paragraph (2-3 sentences max)

**4.3 Key Details Extraction**

Pull out specific details as bullet points:
- Affected components
- Specific behaviors mentioned
- Technical requirements
- Constraints or considerations

**4.4 Auto-Generate Acceptance Criteria**

Based on category, suggest initial acceptance criteria:

**For bugs:**
```markdown
- [ ] Bug is reproducible with documented steps
- [ ] Root cause identified
- [ ] Fix implemented and tested
- [ ] No regression in related functionality
```

**For features:**
```markdown
- [ ] Feature implemented as specified
- [ ] Tests added for new functionality
- [ ] Documentation updated if needed
```

**For tech-debt:**
```markdown
- [ ] Refactoring complete without behavior changes
- [ ] All existing tests pass
- [ ] Test coverage maintained or improved
- [ ] Code review approved
```

### 5. Search Duplicates

Search for similar issues using the **processed title/summary** (not raw input):

```bash
./scripts/search-similar-issues.sh "{processed_title}"
```

**Duplicate Detection:**
- Uses keyword-based similarity scoring (0-100%)
- Shows suggestions if similarity > 60%
- Displays top 5 matches ranked by score

**If duplicates found:**
```
Found similar issues:
| # | Title | State | Similarity |
|---|-------|-------|------------|
| #{n} | {title} | {state} | {score}% |

Options:
1. Create new anyway (issues are different)
2. Add comment to existing #{n}
3. Cancel and review existing
```

### 6. Preview Before Submission

Display the processed issue for user review:

```
## Preview: Processed Capture

**Title:** {title}
**Category:** {category}
**Component:** {component}
**Priority:** {priority}
**Labels:** {labels}

---

**Body Preview:**

## Summary
{summary}

## Details
{details}

## Acceptance Criteria
- [ ] {criterion_1}
- [ ] {criterion_2}

<details>
<summary>Original Input</summary>

> {raw_input}

</details>

---

## Context
Captured via /capture command.
Category: {category}
Component: {component}

---

**Options:**
1. Create issue as shown
2. Edit before creating
3. Cancel
```

### 7. Handle Edit Request

If user selects "Edit before creating":

```
What would you like to modify?
1. Title
2. Summary
3. Add/remove acceptance criteria
4. Change category/labels/component
5. Done editing - create issue
```

**Edit behavior:**
- Each selection prompts for new value
- After each edit, show updated preview
- "Done editing" returns to creation flow
- Edits override auto-generated values

### 8. Determine Milestone

**CRITICAL: Determine milestone BEFORE creating issue to avoid race condition with validate-conventions workflow.**

Run the determine-milestone helper script:

```bash
# If parent_issue is set, inherit from parent
if [[ -n "$parent_issue" ]]; then
    milestone=$(./scripts/determine-milestone.sh --parent "$parent_issue")
else
    milestone=$(./scripts/determine-milestone.sh)
fi
```

**Milestone Logic (in priority order):**

| Condition | Milestone Source |
|-----------|------------------|
| `--parent N` specified | Inherit from parent issue #N |
| Parent has no milestone | Fall back to active milestone |
| No parent specified | Use active milestone |
| No active milestone | Create without milestone (warn user) |

**Active Milestone Definition:**
- First open milestone sorted by `due_on` date
- If multiple milestones have same due date, order determined by GitHub API response

**Example:**
```
/capture --parent 70 "Fix auth timeout"
  → Parent #70 has milestone "sprint-1/13"
  → Child issue gets milestone "sprint-1/13" (inherited)

/capture "Add new feature"
  → No parent specified
  → Active milestone is "sprint-1/13" (due soonest)
  → Issue gets milestone "sprint-1/13"
```

### 9. Invoke Repo Workflow Agent

**Invoke the repo-workflow agent** using the Task tool with `subagent_type: "repo-workflow"` and `model: "haiku"`

**Pass the following data:**
- `title`: Generated or edited title
- `body`: Processed body (using template below)
- `labels`: Category label + priority label + "backlog" + triage labels + hierarchy labels (see below)
- `milestone`: Milestone from step 8 (determined before this call)
- `parent_issue`: Parent issue number (if linking to epic)
- `is_epic`: Boolean (if creating an epic)
- `fast_mode`: Boolean (if using fast capture mode)

**Triage Labels:**
| Condition | Additional Labels |
|-----------|-------------------|
| `fast_mode = true` | Add `needs-triage` label |

**Hierarchy Labels:**
| Condition | Additional Labels |
|-----------|-------------------|
| `is_epic = true` | Add `epic` label |
| `parent_issue = N` | Add `parent:N` label |

**The agent will:**
- Verify labels exist (create if missing, including `epic` and `parent:N` labels)
- Verify milestone exists
- Scan content for any remaining security issues
- Create the issue
- **If parent_issue is set:** Update parent's body with task list reference
- Report back with issue number and URL

**Step 9.1: Update Parent Task List (when creating child)**

When `parent_issue` is set, after creating the child issue:

1. Fetch parent issue body
2. Look for existing task list section (`## Child Issues` or similar)
3. Append new child reference: `- [ ] #{child_number}: {child_title}`
4. Update parent issue body

> **Note:** This update is performed by the `repo-workflow` agent as part of issue creation. The agent uses `gh issue edit` to modify the parent's body.

```bash
# Example: Add child #67 to parent #45's task list
gh issue view 45 --json body -q .body > /tmp/parent_body.md
# Append "- [ ] #67: Fix auth timeout" to task list section
gh issue edit 45 --body "$(cat /tmp/updated_body.md)"
```

**Body Template (sent to agent):**
```markdown
## Summary
{summary}

{parent_reference}

## Details
{details}

## Acceptance Criteria
- [ ] {criterion_1}
- [ ] {criterion_2}

<details>
<summary>Original Input</summary>

> {raw_input}

</details>

---

## Context
Captured via /capture command.
Category: {category}
Component: {component}
```

**Parent Reference (if parent_issue is set):**
```markdown
**Parent:** #{parent_issue}
```

**Epic Body Template (if is_epic = true):**
```markdown
## Summary
{summary}

## Child Issues
<!-- Children will be added here automatically -->
_No children yet. Use `/capture --parent {this_issue}` to add related work._

## Details
{details}

## Acceptance Criteria
- [ ] {criterion_1}
- [ ] {criterion_2}

<details>
<summary>Original Input</summary>

> {raw_input}

</details>

---

## Context
Captured via /capture command.
Category: {category}
Component: {component}
Type: Epic
```

## Output Format

```
## Captured: #{number}

**Title:** {title}
**Type:** {category}
**Component:** {component}
**Priority:** {priority}
**Milestone:** {milestone}
**Parent:** #{parent_issue} (if applicable)
**Is Epic:** Yes/No

**Processing applied:**
- Title: extracted action + core description
- Summary: reorganized for clarity
- Criteria: auto-generated based on type
- Parent: linked to #{parent_issue} (if applicable)

URL: {url}
```

**Output for Child Issue:**
```
## Captured: #{number} (child of #{parent})

**Title:** {title}
**Type:** {category}
**Parent:** #{parent_issue}
**Milestone:** {milestone}

Parent issue #{parent_issue} task list updated.

URL: {url}
```

**Output for Epic:**
```
## Captured Epic: #{number}

**Title:** {title}
**Type:** Epic ({category})
**Milestone:** {milestone}

Use `/capture --parent {number}` to add related work to this epic.

URL: {url}
```

**Output for Fast Mode:**
```
## Fast Captured: #{number}

**Title:** {title}
**Milestone:** {milestone}
**Status:** Pending triage

Issue created with `needs-triage` label.
Run `/pm-triage` to classify, set priority, and link to epics.

URL: {url}
```

## Example Transformation

**Raw Input:**
> "when using the capture skill, my description should be reviewed and analyzed and then organized for brevity and clarity for the agent"

**Processed Output:**

| Field | Value |
|-------|-------|
| Title | Add intelligent description processing to /capture |
| Category | feature |
| Component | skills |
| Summary | Enhance the capture skill to analyze and organize user descriptions for improved brevity and clarity before issue creation. |
| Details | - Analyze user input for structure and key points<br>- Reorganize for clarity<br>- Optimize for agent consumption |

## Error Handling

**If repo-workflow agent fails:**
- Report which validation failed
- Suggest corrections (e.g., "Label 'priority:P0' does not exist")
- Allow retry after fixing

**If no active milestone:**
- Create issue without milestone assignment
- Warn user: "No active milestone found. Issue created without milestone."
- Note: validate-conventions may still flag this - user should assign milestone manually

**If parent has no milestone:**
- Fall back to active milestone (automatic)
- Warn user: "Parent #N has no milestone, using active milestone."

**If search-similar-issues.sh fails:**
- Skip duplicate detection
- Warn user: "Duplicate search unavailable. Proceeding with creation."

## Notes

- WRITE operation - creates issues
- Always routes through repo-workflow agent for governance
- **Milestone determined BEFORE issue creation** to avoid race condition with validate-conventions workflow
- **Milestone inheritance:** Child issues inherit parent's milestone; falls back to active milestone
- Adds backlog label by default
- Use `--raw` flag to skip processing for quick captures
- Use `--fast` flag for immediate creation with deferred triage (adds `needs-triage` label)
- Processing is automatic but user can always edit before submission
- **Hierarchy:** Use `--epic` to create parent issues, `--parent N` to link as child
- **Auto-detection:** Searches for related epics when creating issues (can skip with `--raw` or `--fast`)
- **Labels created automatically:** `epic` and `parent:N` labels are created if they don't exist
- **Parent task list:** When creating a child, the parent's task list is automatically updated
- **Deferred triage:** Issues created with `--fast` get `needs-triage` label for PM processing via `/pm-triage`
