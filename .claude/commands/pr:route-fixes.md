---
description: Route PR review findings to the agents that wrote the code for fixes
---

# PR Fix

Route PR review findings to the agents that originally wrote the code, enabling same-agent fixes.

This skill reads `pr-status.json`, groups blocking issues by owning agent, and invokes each agent to fix their own issues while maintaining the original design intent.

## Usage

```
/pr-fix                           # Fix all blocking issues
/pr-fix --issue-id finding-001    # Fix specific issue only
/pr-fix --agent backend-developer # Fix only this agent's issues
/pr-fix --dry-run                 # Show what would be fixed
/pr-fix --severity error          # Fix only error-severity issues (default)
/pr-fix --severity all            # Fix errors and warnings
```

## Prerequisites

- `pr-status.json` must exist in worktree root (created by `/pr-review-internal`)
- `blocking_issues` array must be populated with findings
- `implementation_agents` map should be populated (for accurate routing)

## Steps

### 1. Load PR Status

```bash
# Check for pr-status.json
if [ ! -f "./pr-status.json" ]; then
  echo "Error: pr-status.json not found. Run /pr-review-internal first."
  exit 1
fi

# Read status
PR_STATUS=$(cat ./pr-status.json)
BLOCKING_ISSUES=$(echo "$PR_STATUS" | jq '.blocking_issues')
IMPL_AGENTS=$(echo "$PR_STATUS" | jq '.implementation_agents')

# Count issues
ISSUE_COUNT=$(echo "$BLOCKING_ISSUES" | jq 'length')
if [ "$ISSUE_COUNT" -eq 0 ]; then
  echo "No blocking issues to fix. PR is ready for merge."
  exit 0
fi
```

### 2. Filter Issues by Severity

```bash
# Default: only error severity (blocking)
SEVERITY_FILTER="${SEVERITY:-error}"

if [ "$SEVERITY_FILTER" = "all" ]; then
  FILTERED_ISSUES="$BLOCKING_ISSUES"
elif [ "$SEVERITY_FILTER" = "error" ]; then
  FILTERED_ISSUES=$(echo "$BLOCKING_ISSUES" | jq '[.[] | select(.severity == "error")]')
else
  FILTERED_ISSUES=$(echo "$BLOCKING_ISSUES" | jq --arg sev "$SEVERITY_FILTER" '[.[] | select(.severity == $sev)]')
fi
```

### 3. Group Issues by Owning Agent

For each blocking issue, determine which agent should fix it:

```bash
# Group issues by owning_agent
# If owning_agent is null, try to derive from implementation_agents map

group_by_agent() {
  local issues="$1"
  local impl_agents="$2"

  echo "$issues" | jq --argjson impl "$impl_agents" '
    # For each issue, determine owning agent
    map(. as $issue |
      # Use explicit owning_agent if set
      if .owning_agent then
        . + {derived_agent: .owning_agent}
      # Otherwise, look up file in implementation_agents
      elif .file then
        ($impl | to_entries | map(select(.value | index($issue.file))) | .[0].key // "unknown") as $agent |
        . + {derived_agent: $agent}
      else
        . + {derived_agent: "unknown"}
      end
    ) |
    # Group by derived_agent
    group_by(.derived_agent) |
    map({
      agent: .[0].derived_agent,
      issues: .,
      files: [.[].file] | unique | map(select(. != null))
    })
  '
}

GROUPED=$(group_by_agent "$FILTERED_ISSUES" "$IMPL_AGENTS")
```

### 4. Dry Run Mode

If `--dry-run` flag is set, show what would be fixed without making changes:

```
## Dry Run: PR Fix Plan

**Total Issues:** {count}
**Agents to Invoke:** {agent_count}

### backend-developer (2 issues)

**Files:**
- src/auth/service.py
- src/auth/models.py

**Issues to Fix:**
1. **src/auth/service.py:45** (error) - Missing error handling for database connection
2. **src/auth/service.py:78** (error) - SQL injection risk via user input

### frontend-developer (1 issue)

**Files:**
- src/components/Login.tsx

**Issues to Fix:**
1. **src/components/Login.tsx:23** (error) - Unvalidated user input in form

---
No changes made (dry-run mode)
```

If dry-run, exit after displaying plan.

### 5. Invoke Agents to Fix Issues

For each agent group, invoke the agent with focused context:

**Agent Fix Prompt Template:**

```
You wrote the following files for this PR:
{files_list}

The PR review found issues you need to fix:

{issues_formatted}

Instructions:
1. Fix each issue while maintaining the original design intent
2. Do NOT over-refactor or change unrelated code
3. Focus only on the specific issues listed
4. After fixing each issue, stage the changes

For each fix, use the Edit tool to make targeted changes.
```

**Agent Invocation:**

Use the Task tool to launch the appropriate agent:

```
Task tool with subagent_type={agent_name}:

Prompt:
"You are fixing PR review issues for files you wrote.

Files you own:
{files}

Issues to fix:

{for each issue}
## Issue: {issue.id}
- **File:** {issue.file}:{issue.line}
- **Severity:** {issue.severity}
- **Message:** {issue.message}
- **Reported by:** {issue.agent}
{/for}

Fix these issues:
1. Read each file before editing
2. Make targeted fixes for each issue
3. Do not change unrelated code
4. Preserve original design intent

After fixing, confirm what was changed."
```

**Model Selection:**
- Use haiku for most agents (fast fixes)
- Use sonnet only for security-related fixes (deeper reasoning)

### 6. Commit After Each Agent

After each agent completes its fixes:

```bash
# Stage changed files
git add ${files_changed}

# Commit with conventional message
git commit -m "fix(review): ${agent_name} fixes from PR review

Issues fixed:
${issues_summary}

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

### 7. Update pr-status.json

Mark fixed issues as resolved:

```bash
# For each fixed issue, mark as resolved
for issue_id in $FIXED_ISSUES; do
  jq --arg id "$issue_id" \
    '(.blocking_issues[] | select(.id == $id)).resolved = true' \
    pr-status.json > pr-status.json.tmp && mv pr-status.json.tmp pr-status.json
done

# Update timestamp
jq --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '.updated_at = $now' \
  pr-status.json > pr-status.json.tmp && mv pr-status.json.tmp pr-status.json
```

### 8. Summary and Next Steps

After all agents complete:

```
## PR Fix Complete

**Issues Fixed:** {fixed_count}/{total_count}
**Commits Created:** {commit_count}
**Agents Invoked:** {agent_list}

### Fixes Applied

| Agent | Issues Fixed | Files Modified |
|-------|--------------|----------------|
| backend-developer | 2 | 2 |
| frontend-developer | 1 | 1 |

### Remaining Issues

{if remaining > 0}
The following issues could not be fixed automatically:

1. **{file}:{line}** - {message} (agent: unknown)

Manual intervention required.
{/if}

### Next Steps

1. Review the fixes: `git log --oneline -n {commit_count}`
2. Run tests: `npm test` or equivalent
3. Re-run review: `/pr-review-internal`
4. If approved, push: `git push`
```

## Output Format

### Standard Output

```
## PR Fix Session

**Status:** In Progress
**PR:** #156 - Add user authentication
**Issues to Fix:** 3

### Fixing: backend-developer issues (2)

[Agent working...]
✓ Fixed: src/auth/service.py:45 - Missing error handling
✓ Fixed: src/auth/service.py:78 - SQL injection risk
✓ Committed: fix(review): backend-developer fixes from PR review

### Fixing: frontend-developer issues (1)

[Agent working...]
✓ Fixed: src/components/Login.tsx:23 - Unvalidated user input
✓ Committed: fix(review): frontend-developer fixes from PR review

---

**Complete:** 3/3 issues fixed
**Commits:** 2 new commits

Next: Run `/pr-review-internal` to verify fixes
```

### Dry Run Output

```
## PR Fix Plan (Dry Run)

**Would fix:** 3 issues
**Would invoke:** 2 agents

### backend-developer

Files: src/auth/service.py, src/auth/models.py

Issues:
- src/auth/service.py:45 (error) - Missing error handling
- src/auth/service.py:78 (error) - SQL injection risk

### frontend-developer

Files: src/components/Login.tsx

Issues:
- src/components/Login.tsx:23 (error) - Unvalidated user input

---
No changes made (--dry-run)
```

## Error Handling

### No pr-status.json

```
Error: pr-status.json not found

Run /pr-review-internal first to generate review findings.
```

### No Blocking Issues

```
No blocking issues found.

The PR has no issues requiring fixes. Ready to merge.
```

### Unknown Agent

When a file's owning agent cannot be determined:

```
Warning: Cannot determine owning agent for src/unknown/file.py

This file is not tracked in implementation_agents.
Issue will be skipped. Fix manually or update implementation_agents.
```

### Agent Failure

If an agent fails to fix an issue:

```
Warning: backend-developer failed to fix issue finding-001

Error: {agent_error_message}

Issue marked as unresolved. Manual fix required.
```

## Filtering Options

### By Issue ID

```bash
/pr-fix --issue-id finding-001
```

Only fixes the specific issue, useful for targeted fixes.

### By Agent

```bash
/pr-fix --agent backend-developer
```

Only invokes the specified agent, ignores issues for other agents.

### By Severity

```bash
/pr-fix --severity error    # Default: only blocking errors
/pr-fix --severity warning  # Only warnings
/pr-fix --severity all      # All issues
```

## Token Optimization

This skill uses a data-gathering script for efficient token usage.

**Data script:** `./scripts/pr/pr-fix-data.sh`

```bash
# Gather all PR fix data in single execution
./scripts/pr/pr-fix-data.sh

# With filters
./scripts/pr/pr-fix-data.sh --severity error --agent backend-developer
./scripts/pr/pr-fix-data.sh --dry-run
./scripts/pr/pr-fix-data.sh --issue-id finding-001
```

**What the script does:**
- Reads pr-status.json once (no repeated file reads)
- Groups issues by owning agent using jq
- Filters by severity, agent, or issue ID
- Calculates summary statistics
- Returns structured JSON for Claude to act on

**Token savings:**
- Before: ~1,550 tokens (Claude reads pr-status.json, reasons about grouping)
- After: ~725 tokens (script handles grouping, Claude just fixes)
- **Savings: 53%**

**Output format:**
```json
{
  "status": "needs_fixes",
  "pr_number": "156",
  "summary": {
    "total_issues": 3,
    "filtered_issues": 3,
    "agents_to_invoke": 2
  },
  "agent_groups": [
    {
      "agent": "backend-developer",
      "issues": [...],
      "files": ["src/auth/service.py"],
      "issue_count": 2
    }
  ]
}
```

## Notes

- **WRITE operation** - Modifies code, creates commits, updates pr-status.json
- **Requires pr-status.json** - Created by /pr-review-internal
- **Same-agent routing** - Issues routed to agents that wrote the code
- **Focused context** - Each agent only sees their files and issues
- **Atomic commits** - One commit per agent's fixes
- **Idempotent** - Safe to run multiple times (skips resolved issues)
- **Model efficient** - Uses haiku for most fixes, sonnet for security only
- **Data script** - Uses `pr-fix-data.sh` for batch data gathering
