---
description: Run all PR review agents locally and write findings to pr-status.json
---

# PR Review Internal

Run all PR review agents locally and collect findings into pr-status.json.

This skill orchestrates the four PR review agents to provide comprehensive pre-merge review:
- **pr-code-reviewer** (haiku) - Code quality, patterns, maintainability
- **pr-test** (haiku) - Test coverage, quality, completeness
- **pr-documentation** (haiku) - Documentation accuracy, completeness
- **pr-security-iam** (sonnet) - Security vulnerabilities, IAM, secrets

## Usage

```
/pr-review-internal              # Review current branch's PR
/pr-review-internal --pr 156     # Review specific PR
/pr-review-internal --json       # JSON output only (no markdown report)
/pr-review-internal --agents code,test  # Run specific agents only
/pr-review-internal --skip-security     # Skip security review (faster)
```

## Steps

### 1. Gather PR Data

```bash
# Get PR data for review
PR_DATA=$(./scripts/pr/pr-review-data.sh $PR_NUMBER)

# Check for errors
if echo "$PR_DATA" | jq -e '.error' > /dev/null 2>&1; then
  echo "Error: $(echo "$PR_DATA" | jq -r '.error')"
  exit 1
fi

# Extract key fields
PR_NUMBER=$(echo "$PR_DATA" | jq -r '.pr.number')
PR_TITLE=$(echo "$PR_DATA" | jq -r '.pr.title')
CHANGED_FILES=$(echo "$PR_DATA" | jq -r '.changed_files | join("\n")')
DIFF=$(echo "$PR_DATA" | jq -r '.diff')
```

### 2. Initialize pr-status.json

```bash
# Initialize or verify pr-status.json exists
if [ ! -f "./pr-status.json" ]; then
  ./scripts/pr/update-pr-status.sh --init
fi

# Clear findings if starting new review iteration
./scripts/pr/update-pr-status.sh --clear-findings
```

### 3. Run Review Agents

**Agent Execution Strategy:**
- Run haiku agents in parallel (pr-code-reviewer, pr-test, pr-documentation)
- Run sonnet agent last (pr-security-iam) - needs full context from other reviews

**For each agent:**

1. **Invoke the agent** with Task tool
2. **Parse findings** from agent output
3. **Add findings** to pr-status.json
4. **Track reviewer** as having run

**Agent Invocation Template:**

```
Use the Task tool to launch the {agent_name} agent with subagent_type={agent_type}:

Prompt:
"Review PR #{pr_number}: {pr_title}

Changed files:
{changed_files}

Diff:
{diff}

Acceptance criteria:
{acceptance_criteria}

Provide findings in this JSON format:
{
  "summary": "Brief summary",
  "status": "approved|needs-fixes",
  "findings": [
    {
      "severity": "error|warning|info",
      "file": "path/to/file.py",
      "line": 42,
      "message": "Description of issue"
    }
  ]
}
"
```

**Parallel Haiku Agents (3 agents):**

```
# Launch all three haiku agents in parallel using a single message with multiple Task tool calls:
- pr-code-reviewer (haiku model)
- pr-test (haiku model)
- pr-documentation (haiku model)
```

**Sequential Sonnet Agent:**

After haiku agents complete, run security review:

```
# Launch security agent (sonnet model, deeper analysis)
- pr-security-iam (sonnet model)
```

### 4. Collect and Normalize Findings

After each agent returns, parse its findings and add to pr-status.json:

```bash
# For each finding from agent output
./scripts/pr/update-pr-status.sh --add-finding '{
  "agent": "pr-code-reviewer",
  "severity": "error",
  "file": "src/auth/service.py",
  "line": 45,
  "message": "Missing error handling for database connection"
}'
```

**Severity Mapping:**
- `error` - Must fix before merge (blocks approval)
- `warning` - Should fix, but doesn't block
- `info` - Informational, no action required

**Owning Agent Attribution:**

For each finding with a file path, map to the owning implementation agent:

```bash
# Read implementation_agents from pr-status.json
IMPL_AGENTS=$(jq '.implementation_agents' pr-status.json)

# For finding in file "src/auth/service.py", find which agent wrote it
OWNING_AGENT=$(echo "$IMPL_AGENTS" | jq -r 'to_entries[] | select(.value | index("src/auth/service.py")) | .key')
```

### 5. Determine Overall Status

After all agents complete:

```bash
# Count error-severity findings
ERROR_COUNT=$(jq '[.blocking_issues[] | select(.severity == "error")] | length' pr-status.json)

if [ "$ERROR_COUNT" -eq 0 ]; then
  ./scripts/pr/update-pr-status.sh --status approved
else
  ./scripts/pr/update-pr-status.sh --status needs-fixes
fi
```

### 6. Update GitHub State

```bash
# Get current GitHub PR state
GH_STATE=$(gh pr view $PR_NUMBER --json mergeable,mergeStateStatus,reviewDecision 2>/dev/null || echo '{}')

# Update pr-status.json with GitHub state
jq --argjson gh "$GH_STATE" \
  '.github_state = {
    mergeable: $gh.mergeable,
    merge_state: $gh.mergeStateStatus,
    review_decision: $gh.reviewDecision
  }' pr-status.json > pr-status.json.tmp && mv pr-status.json.tmp pr-status.json
```

### 7. Generate review-findings.md

Create human-readable report:

```markdown
# PR Review Findings

**PR:** #{number} - {title}
**Status:** {approved|needs-fixes}
**Iteration:** {n}
**Reviewed:** {timestamp}

## Summary by Agent

| Agent | Errors | Warnings | Info |
|-------|--------|----------|------|
| pr-code-reviewer | 2 | 1 | 0 |
| pr-test | 0 | 3 | 1 |
| pr-documentation | 0 | 0 | 2 |
| pr-security-iam | 1 | 0 | 0 |

## Blocking Issues (Must Fix)

### pr-code-reviewer

- **src/auth/service.py:45** - Missing error handling for database connection
  - Owner: backend-developer

### pr-security-iam

- **src/auth/service.py:78** - Potential SQL injection via user input
  - Owner: backend-developer

## Warnings (Should Fix)

### pr-test

- Missing edge case test for empty input
- Test relies on external service without mock

### pr-code-reviewer

- Function `process_request` exceeds 50 lines

## Informational

### pr-documentation

- Consider adding example for error response format
- API versioning not documented

## Next Steps

1. Fix blocking issues (errors)
2. Review and address warnings
3. Re-run review: `/pr-review-internal`

---
Generated by /pr-review-internal
```

## Output Format

### Standard Output

```
## PR Review Complete

**PR:** #156 - Add user authentication
**Status:** needs-fixes
**Iteration:** 1

### Summary

| Agent | Status | Errors | Warnings |
|-------|--------|--------|----------|
| pr-code-reviewer | Complete | 2 | 1 |
| pr-test | Complete | 0 | 3 |
| pr-documentation | Complete | 0 | 0 |
| pr-security-iam | Complete | 1 | 0 |

### Blocking Issues (3)

1. **src/auth/service.py:45** - Missing error handling (pr-code-reviewer)
2. **src/auth/service.py:52** - Unchecked null return (pr-code-reviewer)
3. **src/auth/service.py:78** - SQL injection risk (pr-security-iam)

### Files Updated

- pr-status.json
- review-findings.md

### Next Steps

Run `/pr-fix` to auto-fix issues, or fix manually and re-run review.
```

### JSON Output (--json flag)

```json
{
  "pr_number": 156,
  "title": "Add user authentication",
  "status": "needs-fixes",
  "iteration": 1,
  "agents": {
    "pr-code-reviewer": {"status": "complete", "errors": 2, "warnings": 1},
    "pr-test": {"status": "complete", "errors": 0, "warnings": 3},
    "pr-documentation": {"status": "complete", "errors": 0, "warnings": 0},
    "pr-security-iam": {"status": "complete", "errors": 1, "warnings": 0}
  },
  "blocking_issues": [
    {
      "agent": "pr-code-reviewer",
      "severity": "error",
      "file": "src/auth/service.py",
      "line": 45,
      "message": "Missing error handling"
    }
  ],
  "files_created": ["pr-status.json", "review-findings.md"]
}
```

## Agent Selection

By default, all four agents run. Use `--agents` to select specific agents:

```bash
# Quick review (code only)
/pr-review-internal --agents code

# Skip security (faster)
/pr-review-internal --skip-security

# Full review
/pr-review-internal --agents code,test,docs,security
```

**Agent Mapping:**
- `code` → pr-code-reviewer (haiku)
- `test` → pr-test (haiku)
- `docs` → pr-documentation (haiku)
- `security` → pr-security-iam (sonnet)

## Timeout Handling

Each agent has a 5-minute timeout:

```bash
# If agent times out
{
  "agent": "pr-security-iam",
  "status": "timeout",
  "error": "Agent exceeded 5 minute timeout"
}
```

On timeout:
1. Record timeout in pr-status.json
2. Continue with remaining agents
3. Mark overall status as "incomplete"
4. Recommend manual review for timed-out agent

## Worktree Context

This skill is designed to run from a worktree:

```bash
# In worktree for issue-387
cd ~/repos/project-issue-387
/pr-review-internal
```

The skill will:
1. Auto-detect PR from current branch
2. Create pr-status.json in worktree root
3. Generate review-findings.md in worktree root

## Integration with Sprint Work

This skill can be invoked from /sprint-work during the PR review phase:

```
/sprint-work --issue 387
# ... SDLC phases ...
# Phase: PR Review
/pr-review-internal  # Automatically invoked
```

## Token Optimization

- **Data script:** `scripts/pr/pr-review-data.sh`
- **Agent execution:** Haiku agents in parallel, sonnet (security) last
- **Savings:** ~60% from parallel agent execution

## Notes

- **WRITE operation** - Creates pr-status.json and review-findings.md
- **Requires PR** - Must have an open PR to review
- **Worktree aware** - Uses current worktree context
- **Idempotent** - Safe to run multiple times (increments iteration)
- **Token efficient** - Haiku agents run in parallel to minimize time
- **Sonnet last** - Security review uses more tokens, runs after others complete
