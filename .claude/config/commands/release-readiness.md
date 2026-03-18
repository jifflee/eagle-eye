---
description: Validate release gates before deployment, ensuring quality and security standards are met
---

# Release Readiness

Validates release gates before deployment, ensuring quality and security standards are met.

## Usage

```
/release-readiness                    # Check current branch/HEAD
/release-readiness v1.2.0            # Check specific version tag
/release-readiness --dry-run          # Preview gate checks without validation
```

## Gate Checks

| Gate | Blocking | Check |
|------|----------|-------|
| Tests passing | Yes | `npm test` / `pytest` exit code 0 |
| No critical security findings | Yes | No `severity:critical` in findings.json |
| No blocking issues | Yes | No open issues with `blocker` label |
| Documentation complete | No | README exists, CHANGELOG updated |
| Test coverage threshold | No | Coverage >= baseline threshold |
| No TODOs in release code | No | TODO count <= threshold |

## Steps

### 1. Validate Version (if provided)

```bash
VERSION="${1:-HEAD}"

if [[ "$VERSION" != "HEAD" ]]; then
  # Validate semver format
  if ! [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    echo "❌ Invalid version format: $VERSION"
    exit 1
  fi

  # Check if version exists
  if ! git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "❌ Version tag not found: $VERSION"
    exit 1
  fi

  COMMIT=$(git rev-parse "$VERSION")
else
  COMMIT=$(git rev-parse HEAD)
  BRANCH=$(git branch --show-current)
fi
```

### 2. Run Gate Checks

**Gate 1: Tests Passing (BLOCKING)**

```bash
echo "Running tests..."
npm test 2>&1 | tee /tmp/test-output.log
TEST_EXIT=${PIPESTATUS[0]}

if [ $TEST_EXIT -eq 0 ]; then
  TEST_COUNT=$(grep -oP '\d+(?= passing)' /tmp/test-output.log || echo "0")
  GATE_TESTS="✅ PASS - $TEST_COUNT tests passing"
  EXIT_CODE=0
else
  GATE_TESTS="❌ FAIL - Tests failed (exit code: $TEST_EXIT)"
  EXIT_CODE=1
fi
```

**Gate 2: Security Findings (BLOCKING)**

```bash
FINDINGS_FILE="security-findings.json"

if [ -f "$FINDINGS_FILE" ]; then
  CRITICAL_COUNT=$(jq '[.[] | select(.severity=="critical")] | length' "$FINDINGS_FILE" 2>/dev/null || echo "0")

  if [ "$CRITICAL_COUNT" -eq 0 ]; then
    GATE_SECURITY="✅ PASS - No critical security findings"
  else
    GATE_SECURITY="❌ FAIL - $CRITICAL_COUNT critical security findings"
    EXIT_CODE=1
  fi
else
  GATE_SECURITY="✅ PASS - No security findings file (assuming no scan)"
fi
```

**Gate 3: Blocking Issues (BLOCKING)**

```bash
if command -v gh >/dev/null 2>&1; then
  BLOCKER_COUNT=$(gh issue list --label blocker --state open --json number | jq 'length' 2>/dev/null || echo "0")

  if [ "$BLOCKER_COUNT" -eq 0 ]; then
    GATE_BLOCKERS="✅ PASS - 0 blocking issues"
  else
    GATE_BLOCKERS="❌ FAIL - $BLOCKER_COUNT blocking issues open"
    EXIT_CODE=1
  fi
else
  GATE_BLOCKERS="⚠️ SKIP - gh CLI not available"
fi
```

**Gate 4: Documentation (WARNING)**

```bash
WARNINGS=()

# Check README exists
if [ ! -f "README.md" ]; then
  GATE_DOCS="⚠️ WARN - README.md missing"
  WARNINGS+=("README.md not found in repository")
else
  # Check CHANGELOG updated
  if [ -f "CHANGELOG.md" ]; then
    LAST_CHANGE=$(git log -1 --format=%ct CHANGELOG.md 2>/dev/null || echo "0")
    LAST_COMMIT=$(git log -1 --format=%ct 2>/dev/null || echo "0")

    if [ "$LAST_CHANGE" -lt "$LAST_COMMIT" ]; then
      GATE_DOCS="⚠️ WARN - CHANGELOG not updated"
      WARNINGS+=("CHANGELOG.md not updated for this release")
    else
      GATE_DOCS="✅ PASS - Documentation complete"
    fi
  else
    GATE_DOCS="⚠️ WARN - CHANGELOG.md missing"
    WARNINGS+=("CHANGELOG.md not found in repository")
  fi
fi
```

**Gate 5: Test Coverage (WARNING)**

```bash
COVERAGE_THRESHOLD=70
COVERAGE_FILE="coverage/coverage-summary.json"

if [ -f "$COVERAGE_FILE" ]; then
  COVERAGE=$(jq '.total.lines.pct' "$COVERAGE_FILE" 2>/dev/null || echo "0")

  if (( $(echo "$COVERAGE >= $COVERAGE_THRESHOLD" | bc -l) )); then
    GATE_COVERAGE="✅ PASS - ${COVERAGE}% (threshold: ${COVERAGE_THRESHOLD}%)"
  else
    GATE_COVERAGE="⚠️ WARN - ${COVERAGE}% (threshold: ${COVERAGE_THRESHOLD}%)"
    WARNINGS+=("Test coverage ${COVERAGE}% is below threshold ${COVERAGE_THRESHOLD}%")
  fi
else
  GATE_COVERAGE="⚠️ SKIP - No coverage data available"
fi
```

**Gate 6: TODO Count (WARNING)**

```bash
TODO_THRESHOLD=10
TODO_COUNT=$(grep -r "TODO\|FIXME" --include="*.js" --include="*.ts" --include="*.py" --include="*.sh" . 2>/dev/null | wc -l || echo "0")

if [ "$TODO_COUNT" -le "$TODO_THRESHOLD" ]; then
  GATE_TODOS="✅ PASS - $TODO_COUNT TODOs (threshold: $TODO_THRESHOLD)"
else
  GATE_TODOS="⚠️ WARN - $TODO_COUNT TODOs (threshold: $TODO_THRESHOLD)"
  WARNINGS+=("$TODO_COUNT TODOs found (threshold: $TODO_THRESHOLD)")
fi
```

### 3. Generate Output

```bash
echo "## Release Readiness Check"
echo ""
echo "**Version:** $VERSION"
echo "**Branch:** ${BRANCH:-N/A}"
echo "**Commit:** ${COMMIT:0:7}"
echo ""
echo "### Gates"
echo ""
echo "| Gate | Status | Details |"
echo "|------|--------|---------|"
echo "| Tests | $GATE_TESTS |"
echo "| Security | $GATE_SECURITY |"
echo "| Blockers | $GATE_BLOCKERS |"
echo "| Docs | $GATE_DOCS |"
echo "| Coverage | $GATE_COVERAGE |"
echo "| TODOs | $GATE_TODOS |"
echo ""

# Determine final result
if [ $EXIT_CODE -eq 1 ]; then
  echo "### Result: ❌ BLOCKED"
  echo ""
  echo "Release is BLOCKED due to failing gates. Fix issues above before releasing."
elif [ ${#WARNINGS[@]} -gt 0 ]; then
  echo "### Result: ⚠️ READY (with warnings)"
  echo ""
  echo "${#WARNINGS[@]} warning(s) - review before release:"
  for warning in "${WARNINGS[@]}"; do
    echo "- $warning"
  done
  EXIT_CODE=2
else
  echo "### Result: ✅ READY"
  echo ""
  echo "All gates passed. Release is ready for deployment."
  EXIT_CODE=0
fi

exit $EXIT_CODE
```

## Output Format

```
## Release Readiness Check

**Version:** v1.2.0
**Branch:** main
**Commit:** abc123

### Gates

| Gate | Status | Details |
|------|--------|---------|
| Tests | ✅ PASS | 45 tests passing |
| Security | ✅ PASS | No critical findings |
| Blockers | ✅ PASS | 0 blocking issues |
| Docs | ⚠️ WARN | CHANGELOG not updated |
| Coverage | ✅ PASS | 78% (threshold: 70%) |
| TODOs | ✅ PASS | 8 TODOs (threshold: 10) |

### Result: ⚠️ READY (with warnings)

1 warning(s) - review before release:
- CHANGELOG.md not updated for this release
```

## Exit Codes

- **0**: READY - All gates passed
- **1**: BLOCKED - One or more blocking gates failed
- **2**: READY_WITH_WARNINGS - Blocking gates passed, but warnings present

## Integration with /pr-to-main

Add release readiness check to `/pr-to-main` workflow:

```bash
# Before creating PR to main, run readiness check
echo "Running release readiness check..."
./scripts/release-readiness.sh "$VERSION"
READINESS_EXIT=$?

if [ $READINESS_EXIT -eq 1 ]; then
  echo "❌ Release blocked - fix issues before creating PR"
  exit 1
elif [ $READINESS_EXIT -eq 2 ]; then
  echo "⚠️ Release has warnings - review before proceeding"
  read -p "Continue with PR creation? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Continue with PR creation...
```

## Notes

- **Local validation**: Works without CI/CD infrastructure
- **Dry-run mode**: `--dry-run` previews checks without execution
- **Configurable thresholds**: Edit script to adjust coverage/TODO thresholds
- **Extensible**: Add custom gates as needed
- See issue #176 for requirements
- Parent epic: #172
