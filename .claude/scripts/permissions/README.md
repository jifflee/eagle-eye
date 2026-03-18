# Permission Decision Engine Scripts

This directory contains the implementation of the Permission Decision Engine with context-aware risk assessment.

## Overview

The Permission Decision Engine automatically evaluates permission requests based on:
- **Tier classification** (T0-T3) - Static risk levels
- **Context awareness** (Issue #597) - Dynamic risk adjustment based on work context
- **Command history** - Learning from past executions
- **Policy rules** - Explicit allow/deny patterns

## Scripts

### Core Engine

#### `tier-classifier.sh`
Classifies operations into permission tiers (T0-T3).

**Usage:**
```bash
echo '{"tool":"Bash","command":"git status"}' | ./tier-classifier.sh
```

**Output:**
```json
{"tier":"T0","reason":"git read command"}
```

#### `policy-evaluator.sh`
Evaluates permission requests against policy rules and context.

**Usage:**
```bash
echo '{"tier":"T2","tool":"Bash","command":"git push"}' | ./policy-evaluator.sh
```

**Output:**
```json
{"decision":"allow","reason":"T2 default allow (container mode)","original_tier":"T2","adjusted_tier":"T1"}
```

**Environment:**
- `CONTEXT_EVAL_ENABLED` - Enable/disable context evaluation (default: true)
- `DISABLE_CONTEXT_EVAL` - Disable context evaluation (default: false)
- `POLICY_FILE` - Path to policy YAML file
- `CACHE_DIR` - Permission cache directory
- `SESSION_ID` - Session identifier for caching

### Context-Aware Features (Issue #597)

#### `extract-issue-scope.sh`
Extracts file patterns and keywords from GitHub issue bodies.

**Usage:**
```bash
# From issue number
./extract-issue-scope.sh --issue-number 597

# From JSON input
echo '{"issue_body":"Update scripts/sync-*.sh"}' | ./extract-issue-scope.sh

# Auto-detect from current branch
./extract-issue-scope.sh
```

**Output:**
```json
{
  "issue_number": "597",
  "file_patterns": ["scripts/permissions/*", "tests/permissions/*"],
  "keywords": ["permission", "context", "risk"],
  "acceptance_files": ["policy-evaluator.sh"],
  "has_scope": true
}
```

**Features:**
- Extracts file paths from inline code and code blocks
- Parses acceptance criteria for file mentions
- Detects component/module patterns
- Caches results for 1 hour

#### `context-evaluator.sh`
Applies context-aware tier adjustments based on issue scope and history.

**Usage:**
```bash
echo '{
  "tier": "T2",
  "file_path": "scripts/permissions/test.sh",
  "command": "./test.sh",
  "issue_number": "597"
}' | ./context-evaluator.sh
```

**Output:**
```json
{
  "original_tier": "T2",
  "adjusted_tier": "T1",
  "adjustment": -1,
  "reasons": ["file in issue scope"],
  "context_applied": true
}
```

**Adjustment Rules:**
- File in issue scope: -1 tier
- Test file: -1 tier
- Historical success (3+): -1 tier
- Command matches keywords: -1 tier
- File outside scope: +1 tier

#### `track-command-history.sh`
Tracks command execution success/failure for risk assessment.

**Usage:**
```bash
# Record success
./track-command-history.sh --record --command "git push" --success

# Record failure
./track-command-history.sh --record --command "npm install" --failure

# Check history
echo '{"command":"git push"}' | ./track-command-history.sh --check

# Session stats
./track-command-history.sh --stats

# Cleanup old entries (>30 days)
./track-command-history.sh --cleanup
```

**Output (check):**
```json
{
  "command_pattern": "git push",
  "success_count": 5,
  "failure_count": 1,
  "total_executions": 6,
  "last_success": "2024-02-16T10:30:00Z"
}
```

**Features:**
- Command normalization (removes variable parts)
- 30-day retention
- Per-session statistics
- Background recording

## Integration

The scripts are integrated into the permission decision flow:

```
1. Tool/Command Invoked
   ↓
2. tier-classifier.sh → T2
   ↓
3. context-evaluator.sh → T2 - 1 = T1
   ↓
4. policy-evaluator.sh → "allow"
   ↓
5. track-command-history.sh (background)
   ↓
6. Execution Allowed
```

## Configuration

### Policy File

See `config/container-permission-policy.yaml` for:
- Default tier actions (allow/deny)
- Explicit allow/deny patterns
- Context rules configuration
- Webhook escalation settings
- Audit logging configuration

### Cache Directories

```bash
$FRAMEWORK_DIR/   # default: ~/.claude-agent/ (set FRAMEWORK_NAME=claude-tastic to use ~/.claude-tastic/)
├── permission-cache/
│   ├── issue-scope-*.json       # Issue scope cache (1 hour TTL)
│   └── session-*.json            # T2 session cache
├── command-history/
│   └── *.json                    # Command execution history
└── permission-audit/
    ├── decisions-*.jsonl         # Decision audit log
    └── hook-*.log                # Hook execution log
```

## Performance

- Context evaluation overhead: < 50ms (meets acceptance criteria)
- Issue scope caching: 1 hour TTL
- Command history indexed by hash
- Background history recording

## Testing

Run the test suite:

```bash
./tests/permissions/test-context-aware-risk.sh
```

**Test Coverage:**
- Issue scope extraction (file patterns, keywords)
- Command history tracking (record, check, stats)
- Context evaluation (adjustments, bounds checking)
- Integration tests (full workflow)

## Troubleshooting

### Context not applied

```bash
# Check if enabled
echo $CONTEXT_EVAL_ENABLED

# Check cache
ls -la "${FRAMEWORK_DIR:-$HOME/.claude-agent}/permission-cache/"

# Test manually
echo '{"tier":"T2","file_path":"test.sh"}' | ./context-evaluator.sh
```

### Issue scope not detected

```bash
# Check issue body
gh issue view 597 --json body

# Force refresh
rm "${FRAMEWORK_DIR:-$HOME/.claude-agent}/permission-cache/issue-scope-597.json"

# Test extraction
./extract-issue-scope.sh --issue-number 597
```

### Performance issues

```bash
# Disable context evaluation
export DISABLE_CONTEXT_EVAL=true

# Check cache hit rate
find "${FRAMEWORK_DIR:-$HOME/.claude-agent}/permission-cache" -name "*.json" -mtime -1
```

## Related Documentation

- [Context-Aware Permissions Guide](../../docs/context-aware-permissions.md)
- [Container Permission Policy](../../config/container-permission-policy.yaml)
- [Permission Decision Engine (Issue #596)](../../docs/policy-engine-features.md)
- [Test Suite](../../tests/permissions/)

## Issues

- **#596** - Permission Decision Engine (base implementation)
- **#597** - Context-Aware Risk Assessment (this implementation)
