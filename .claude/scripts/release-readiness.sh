#!/usr/bin/env bash
set -euo pipefail

# Release Readiness Check Script
# Comprehensive release gate required for dev -> qa -> main promotions.
# Usage: ./scripts/release-readiness.sh [VERSION] [OPTIONS]
#
# OPTIONS:
#   --dry-run           Preview mode - skip live checks (tests, security)
#   --target-branch     Branch to check (default: current branch)
#   --report FILE       Write JSON report to FILE (default: /tmp/release-readiness-report.json)
#   --no-report         Skip JSON report generation
#   --changelog         Auto-generate CHANGELOG from git log
#   --help              Show this help
#
# EXIT CODES:
#   0  All gates passed (release ready)
#   1  Blocking gates failed (release blocked)
#   2  Warnings present (release ready with warnings)
#
# INTEGRATION:
#   Called by pr-to-qa-data.sh and pr-to-main-data.sh for release gating.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
COVERAGE_THRESHOLD=70
TODO_THRESHOLD=150
DOC_STALENESS_DAYS=30

# Parse arguments
VERSION="${1:-HEAD}"
DRY_RUN=false
TARGET_BRANCH=""
REPORT_FILE="/tmp/release-readiness-report-$$.json"
WRITE_REPORT=true
GENERATE_CHANGELOG=false

# Handle positional arg that might be an option
if [[ "$VERSION" == --* ]]; then
  VERSION="HEAD"
fi

shift 0
ARGS=("$@")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  arg="${ARGS[$i]}"
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    --target-branch)
      i=$((i + 1))
      TARGET_BRANCH="${ARGS[$i]}"
      ;;
    --report)
      i=$((i + 1))
      REPORT_FILE="${ARGS[$i]}"
      ;;
    --no-report)
      WRITE_REPORT=false
      ;;
    --changelog)
      GENERATE_CHANGELOG=true
      ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0
      ;;
  esac
  i=$((i + 1))
done

# Initialize variables
EXIT_CODE=0
WARNINGS=()
BLOCKED=false

# Gate result tracking (for JSON report)
GATE_RESULTS=()

# Helper: record gate result
record_gate() {
  local name="$1"
  local status="$2"
  local details="$3"
  local blocking="${4:-true}"
  GATE_RESULTS+=("{\"gate\":\"$name\",\"status\":\"$status\",\"details\":$(echo "$details" | jq -Rs .),\"blocking\":$blocking}")
}

echo "## Release Readiness Check"
echo ""

# Step 1: Validate Version
if [[ "$VERSION" != "HEAD" ]]; then
  # Validate semver format
  if ! [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$ ]]; then
    echo -e "${RED}❌ Invalid version format: $VERSION${NC}"
    echo "Expected format: v1.2.3 or 1.2.3 (with optional pre-release suffix)"
    exit 1
  fi

  # Check if version tag already exists (for new releases, it should NOT exist)
  if git rev-parse "$VERSION" >/dev/null 2>&1; then
    COMMIT=$(git rev-parse "$VERSION")
    BRANCH="N/A (existing tag)"
  else
    COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    echo -e "${BLUE}ℹ Version $VERSION does not exist yet (will be created on release)${NC}"
  fi
else
  COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  BRANCH="${TARGET_BRANCH:-$(git branch --show-current 2>/dev/null || echo "unknown")}"
fi

# Determine effective branch for checks
EFFECTIVE_BRANCH="${TARGET_BRANCH:-$BRANCH}"

echo "**Version:** $VERSION"
echo "**Branch:** $EFFECTIVE_BRANCH"
echo "**Commit:** ${COMMIT:0:7}"
echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "**Mode:** DRY RUN (preview only)"
  echo ""
fi

echo "### Gates"
echo ""
echo "| Gate | Status | Details |"
echo "|------|--------|---------|"

# ─── Gate 1: All PRs Merged (BLOCKING) ────────────────────────────────────────
# Validates no open PRs to the target branch (all work integrated)

if command -v gh >/dev/null 2>&1; then
  OPEN_PR_COUNT=0
  if [ -n "$EFFECTIVE_BRANCH" ] && [ "$EFFECTIVE_BRANCH" != "unknown" ]; then
    OPEN_PR_COUNT=$(gh pr list --base "$EFFECTIVE_BRANCH" --state open --json number --jq 'length' 2>/dev/null || echo "0")
  fi

  if [ "$OPEN_PR_COUNT" -eq 0 ]; then
    GATE_MERGED_PRS="✅ PASS | All PRs merged to $EFFECTIVE_BRANCH"
    record_gate "merged_prs" "pass" "All PRs merged to $EFFECTIVE_BRANCH"
  else
    GATE_MERGED_PRS="❌ FAIL | $OPEN_PR_COUNT open PR(s) not yet merged to $EFFECTIVE_BRANCH"
    EXIT_CODE=1
    BLOCKED=true
    record_gate "merged_prs" "fail" "$OPEN_PR_COUNT open PR(s) not yet merged"
  fi
else
  GATE_MERGED_PRS="⚠️ SKIP | gh CLI not available"
  record_gate "merged_prs" "skip" "gh CLI not available" "false"
fi

echo "| Merged PRs | $GATE_MERGED_PRS |"

# ─── Gate 2: Tests Passing (BLOCKING) ─────────────────────────────────────────

if [ "$DRY_RUN" = false ]; then
  echo -n "Running tests... " >&2

  if npm test >/tmp/test-output.log 2>&1; then
    TEST_EXIT=0
    TEST_COUNT=$(grep -oP '\d+(?= (passing|tests? passed))' /tmp/test-output.log 2>/dev/null | head -1 || echo "0")

    if [ "$TEST_COUNT" = "0" ]; then
      # Try alternative pattern
      TEST_COUNT=$(grep -oP 'ok \K\d+' /tmp/test-output.log 2>/dev/null | tail -1 || echo "unknown")
    fi

    GATE_TESTS="✅ PASS | $TEST_COUNT tests passing"
    record_gate "tests" "pass" "$TEST_COUNT tests passing"
    echo "done" >&2
  else
    TEST_EXIT=$?
    GATE_TESTS="❌ FAIL | Tests failed (exit code: $TEST_EXIT)"
    EXIT_CODE=1
    BLOCKED=true
    record_gate "tests" "fail" "Tests failed (exit code: $TEST_EXIT)"
    echo "failed" >&2
  fi
else
  GATE_TESTS="⏭️ SKIP | Dry run mode"
  record_gate "tests" "skip" "Dry run mode" "true"
fi

echo "| Tests | $GATE_TESTS |"

# ─── Gate 3: Security Scan Clean (BLOCKING) ───────────────────────────────────
# Runs security scanner and checks for high/critical findings

SECURITY_SCAN_SCRIPT="$SCRIPT_DIR/ci/security-scan.sh"
SECURITY_REPORT_FILE="/tmp/security-release-$$.json"

if [ "$DRY_RUN" = false ]; then
  if [ -f "$SECURITY_SCAN_SCRIPT" ]; then
    SECURITY_EXIT=0
    "$SECURITY_SCAN_SCRIPT" \
      --full \
      --severity high \
      --output "$SECURITY_REPORT_FILE" \
      --no-fail \
      2>/dev/null || SECURITY_EXIT=$?

    if [ -f "$SECURITY_REPORT_FILE" ] && command -v jq >/dev/null 2>&1; then
      SEC_CRITICAL=$(jq '.summary.critical // 0' "$SECURITY_REPORT_FILE" 2>/dev/null || echo "0")
      SEC_HIGH=$(jq '.summary.high // 0' "$SECURITY_REPORT_FILE" 2>/dev/null || echo "0")
      SEC_MEDIUM=$(jq '.summary.medium // 0' "$SECURITY_REPORT_FILE" 2>/dev/null || echo "0")
      SEC_TOTAL=$((SEC_CRITICAL + SEC_HIGH))
      rm -f "$SECURITY_REPORT_FILE"
    else
      # Fallback: check legacy findings file
      FINDINGS_FILE="security-findings.json"
      if [ -f "$FINDINGS_FILE" ] && command -v jq >/dev/null 2>&1; then
        SEC_CRITICAL=$(jq '[.[] | select(.severity=="critical")] | length' "$FINDINGS_FILE" 2>/dev/null || echo "0")
        SEC_HIGH=$(jq '[.[] | select(.severity=="high")] | length' "$FINDINGS_FILE" 2>/dev/null || echo "0")
        SEC_MEDIUM=0
      else
        SEC_CRITICAL=0
        SEC_HIGH=0
        SEC_MEDIUM=0
      fi
      SEC_TOTAL=$((SEC_CRITICAL + SEC_HIGH))
    fi

    if [ "$SEC_TOTAL" -eq 0 ]; then
      GATE_SECURITY="✅ PASS | No critical/high security findings"
      record_gate "security" "pass" "No critical/high findings"
    else
      GATE_SECURITY="❌ FAIL | $SEC_CRITICAL critical, $SEC_HIGH high security findings"
      EXIT_CODE=1
      BLOCKED=true
      record_gate "security" "fail" "$SEC_CRITICAL critical, $SEC_HIGH high findings"
    fi
  else
    # Legacy: check for pre-existing findings file
    FINDINGS_FILE="security-findings.json"
    if [ -f "$FINDINGS_FILE" ] && command -v jq >/dev/null 2>&1; then
      CRITICAL_COUNT=$(jq '[.[] | select(.severity=="critical")] | length' "$FINDINGS_FILE" 2>/dev/null || echo "0")
    else
      CRITICAL_COUNT=0
    fi

    if [ "$CRITICAL_COUNT" -eq 0 ]; then
      GATE_SECURITY="✅ PASS | No critical security findings"
      record_gate "security" "pass" "No critical findings"
    else
      GATE_SECURITY="❌ FAIL | $CRITICAL_COUNT critical security findings"
      EXIT_CODE=1
      BLOCKED=true
      record_gate "security" "fail" "$CRITICAL_COUNT critical findings"
    fi
  fi
else
  GATE_SECURITY="⏭️ SKIP | Dry run mode"
  record_gate "security" "skip" "Dry run mode" "true"
fi

echo "| Security | $GATE_SECURITY |"

# ─── Gate 4: Blocking Issues (BLOCKING) ───────────────────────────────────────

if command -v gh >/dev/null 2>&1; then
  if BLOCKER_COUNT=$(gh issue list --label blocker --state open --json number 2>/dev/null | jq 'length' 2>/dev/null); then
    if [ "$BLOCKER_COUNT" -eq 0 ]; then
      GATE_BLOCKERS="✅ PASS | 0 blocking issues"
      record_gate "blockers" "pass" "0 blocking issues"
    else
      GATE_BLOCKERS="❌ FAIL | $BLOCKER_COUNT blocking issues open"
      EXIT_CODE=1
      BLOCKED=true
      record_gate "blockers" "fail" "$BLOCKER_COUNT blocking issues open"
    fi
  else
    GATE_BLOCKERS="⚠️ SKIP | Unable to query issues"
    record_gate "blockers" "skip" "Unable to query issues" "false"
  fi
else
  GATE_BLOCKERS="⚠️ SKIP | gh CLI not available"
  record_gate "blockers" "skip" "gh CLI not available" "false"
fi

echo "| Blockers | $GATE_BLOCKERS |"

# ─── Gate 5: Refactor Findings Resolved (BLOCKING) ────────────────────────────
# Integrates with epic #799 refactor scanners

REFACTOR_LINT_SCRIPT="$SCRIPT_DIR/ci/refactor-lint.sh"

if [ -f "$REFACTOR_LINT_SCRIPT" ]; then
  REFACTOR_REPORT_FILE="/tmp/refactor-release-check-$$.json"
  REFACTOR_EXIT=0

  if [ "$DRY_RUN" = false ]; then
    "$REFACTOR_LINT_SCRIPT" \
      --scope changed \
      --severity high \
      --output-file "$REFACTOR_REPORT_FILE" \
      --quiet 2>/dev/null || REFACTOR_EXIT=$?

    if [ -f "$REFACTOR_REPORT_FILE" ] && command -v jq >/dev/null 2>&1; then
      REFACTOR_CRITICAL=$(jq '.summary.critical // 0' "$REFACTOR_REPORT_FILE" 2>/dev/null || echo "0")
      REFACTOR_HIGH=$(jq '.summary.high // 0' "$REFACTOR_REPORT_FILE" 2>/dev/null || echo "0")
      REFACTOR_TOTAL=$((REFACTOR_CRITICAL + REFACTOR_HIGH))
      rm -f "$REFACTOR_REPORT_FILE"
    else
      REFACTOR_CRITICAL=0
      REFACTOR_HIGH=0
      REFACTOR_TOTAL=0
      if [ "$REFACTOR_EXIT" -ge 2 ]; then
        REFACTOR_TOTAL=1
      fi
    fi

    if [ "$REFACTOR_EXIT" -ge 2 ] || [ "$REFACTOR_TOTAL" -gt 0 ]; then
      GATE_REFACTOR="❌ FAIL | ${REFACTOR_CRITICAL} critical, ${REFACTOR_HIGH} high findings (run /refactor --fix)"
      EXIT_CODE=1
      BLOCKED=true
      record_gate "refactor" "fail" "${REFACTOR_CRITICAL} critical, ${REFACTOR_HIGH} high refactor findings"
    else
      GATE_REFACTOR="✅ PASS | No critical/high refactor findings"
      record_gate "refactor" "pass" "No critical/high refactor findings"
    fi
  else
    GATE_REFACTOR="⏭️ SKIP | Dry run mode"
    record_gate "refactor" "skip" "Dry run mode" "true"
  fi
else
  GATE_REFACTOR="⚠️ SKIP | refactor-lint.sh not found"
  record_gate "refactor" "skip" "refactor-lint.sh not found at $REFACTOR_LINT_SCRIPT" "false"
fi

echo "| Refactor | $GATE_REFACTOR |"

# ─── Gate 6: Version Bump Validated (BLOCKING) ────────────────────────────────
# Validates semver version bump against latest tag

LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [ "$VERSION" = "HEAD" ]; then
  GATE_VERSION="⚠️ SKIP | No version specified (use: ./release-readiness.sh v1.2.3)"
  WARNINGS+=("No version specified - semver validation skipped")
  record_gate "version_bump" "skip" "No version specified" "false"
elif [ -z "$LATEST_TAG" ]; then
  # No prior tags - any valid semver is acceptable
  GATE_VERSION="✅ PASS | First release ($VERSION - no prior tags)"
  record_gate "version_bump" "pass" "First release $VERSION"
else
  # Validate version bump direction
  LATEST_CLEAN="${LATEST_TAG#v}"
  PROPOSED_CLEAN="${VERSION#v}"

  # Extract major.minor.patch
  LATEST_MAJOR=$(echo "$LATEST_CLEAN" | cut -d. -f1)
  LATEST_MINOR=$(echo "$LATEST_CLEAN" | cut -d. -f2)
  LATEST_PATCH=$(echo "$LATEST_CLEAN" | cut -d. -f3 | cut -d- -f1)

  PROPOSED_MAJOR=$(echo "$PROPOSED_CLEAN" | cut -d. -f1)
  PROPOSED_MINOR=$(echo "$PROPOSED_CLEAN" | cut -d. -f2)
  PROPOSED_PATCH=$(echo "$PROPOSED_CLEAN" | cut -d. -f3 | cut -d- -f1)

  VERSION_VALID=false
  VERSION_TYPE=""

  if [ "$PROPOSED_MAJOR" -gt "$LATEST_MAJOR" ]; then
    # Major bump: minor and patch must be 0
    if [ "$PROPOSED_MINOR" -eq 0 ] && [ "$PROPOSED_PATCH" -eq 0 ]; then
      VERSION_VALID=true
      VERSION_TYPE="major"
    fi
  elif [ "$PROPOSED_MAJOR" -eq "$LATEST_MAJOR" ] && [ "$PROPOSED_MINOR" -gt "$LATEST_MINOR" ]; then
    # Minor bump: patch must be 0
    if [ "$PROPOSED_PATCH" -eq 0 ]; then
      VERSION_VALID=true
      VERSION_TYPE="minor"
    fi
  elif [ "$PROPOSED_MAJOR" -eq "$LATEST_MAJOR" ] && [ "$PROPOSED_MINOR" -eq "$LATEST_MINOR" ] && [ "$PROPOSED_PATCH" -gt "$LATEST_PATCH" ]; then
    VERSION_VALID=true
    VERSION_TYPE="patch"
  fi

  if [ "$VERSION_VALID" = true ]; then
    GATE_VERSION="✅ PASS | Valid $VERSION_TYPE bump: $LATEST_TAG → $VERSION"
    record_gate "version_bump" "pass" "Valid $VERSION_TYPE bump: $LATEST_TAG → $VERSION"
  else
    GATE_VERSION="❌ FAIL | Invalid semver bump: $LATEST_TAG → $VERSION (must be forward semver)"
    EXIT_CODE=1
    BLOCKED=true
    record_gate "version_bump" "fail" "Invalid semver: $LATEST_TAG → $VERSION"
  fi
fi

echo "| Version | $GATE_VERSION |"

# ─── Gate 7: Documentation Freshness (WARNING) ────────────────────────────────
# Checks for stale docs for recently changed files

DOC_STALE_COUNT=0
DOC_STALE_FILES=""

# Find .md files that haven't been updated in DOC_STALENESS_DAYS but have corresponding changed code
if command -v git >/dev/null 2>&1; then
  # Get files changed in last 30 commits
  RECENT_CODE_FILES=$(git diff --name-only HEAD~30 HEAD 2>/dev/null | grep -vE '\.(md|json|yaml|yml|lock)$' | head -20 || true)

  if [ -n "$RECENT_CODE_FILES" ]; then
    while IFS= read -r code_file; do
      [ -z "$code_file" ] && continue
      # Look for a corresponding doc file
      base="${code_file%.*}"
      dirname=$(dirname "$code_file")
      basename=$(basename "$base")

      # Check if related doc exists and is stale
      for doc_candidate in "$dirname/$basename.md" "docs/$basename.md" "README.md"; do
        if [ -f "$doc_candidate" ]; then
          # Check if code was updated more recently than its doc
          CODE_TIME=$(git log -1 --format="%ct" -- "$code_file" 2>/dev/null || echo "0")
          DOC_TIME=$(git log -1 --format="%ct" -- "$doc_candidate" 2>/dev/null || echo "0")
          DOC_AGE_DAYS=$(( ($(date +%s) - DOC_TIME) / 86400 ))

          if [ "$CODE_TIME" -gt "$DOC_TIME" ] && [ "$DOC_AGE_DAYS" -gt "$DOC_STALENESS_DAYS" ]; then
            DOC_STALE_COUNT=$((DOC_STALE_COUNT + 1))
            DOC_STALE_FILES="$DOC_STALE_FILES $doc_candidate"
          fi
          break
        fi
      done
    done <<< "$RECENT_CODE_FILES"
  fi
fi

# Also check README exists
if [ ! -f "README.md" ]; then
  GATE_DOCS="⚠️ WARN | README.md missing"
  WARNINGS+=("README.md not found in repository")
  record_gate "documentation" "warn" "README.md missing" "false"
elif [ "$DOC_STALE_COUNT" -gt 0 ]; then
  GATE_DOCS="⚠️ WARN | $DOC_STALE_COUNT stale doc(s):$DOC_STALE_FILES"
  WARNINGS+=("$DOC_STALE_COUNT documentation file(s) may be stale for recently changed code")
  record_gate "documentation" "warn" "$DOC_STALE_COUNT stale doc files" "false"
else
  # Check CHANGELOG updated
  if [ -f "CHANGELOG.md" ]; then
    LAST_CHANGE=$(git log -1 --format=%ct CHANGELOG.md 2>/dev/null || echo "0")

    if [[ "$VERSION" != "HEAD" ]]; then
      LAST_COMMIT=$(git log -1 --format=%ct "$VERSION" 2>/dev/null || echo "$(git log -1 --format=%ct 2>/dev/null || echo 0)")
    else
      LAST_COMMIT=$(git log -1 --format=%ct 2>/dev/null || echo "0")
    fi

    if [ "$LAST_CHANGE" -lt "$LAST_COMMIT" ] && [ "$LAST_COMMIT" != "0" ]; then
      GATE_DOCS="⚠️ WARN | CHANGELOG not updated for current changes"
      WARNINGS+=("CHANGELOG.md not updated for this release")
      record_gate "documentation" "warn" "CHANGELOG not updated" "false"
    else
      GATE_DOCS="✅ PASS | Documentation current"
      record_gate "documentation" "pass" "Documentation current"
    fi
  else
    GATE_DOCS="⚠️ WARN | CHANGELOG.md missing"
    WARNINGS+=("CHANGELOG.md not found in repository")
    record_gate "documentation" "warn" "CHANGELOG.md missing" "false"
  fi
fi

echo "| Docs | $GATE_DOCS |"

# ─── Gate 8: Changelog Generated (WARNING) ────────────────────────────────────

CHANGELOG_CONTENT=""
CHANGELOG_GENERATED=false

if [ "$GENERATE_CHANGELOG" = true ] || [ "$VERSION" != "HEAD" ]; then
  # Generate changelog from git log
  if [ -n "$LATEST_TAG" ]; then
    CHANGELOG_COMMITS=$(git log --oneline "${LATEST_TAG}..HEAD" 2>/dev/null || git log --oneline -30 2>/dev/null || echo "")
  else
    CHANGELOG_COMMITS=$(git log --oneline -30 2>/dev/null || echo "")
  fi

  if [ -n "$CHANGELOG_COMMITS" ]; then
    # Categorize commits
    FEAT_COMMITS=$(echo "$CHANGELOG_COMMITS" | grep -iE "^[a-f0-9]+ feat" || true)
    FIX_COMMITS=$(echo "$CHANGELOG_COMMITS" | grep -iE "^[a-f0-9]+ fix" || true)
    OTHER_COMMITS=$(echo "$CHANGELOG_COMMITS" | grep -ivE "^[a-f0-9]+ (feat|fix)" || true)

    CHANGELOG_DATE=$(date +%Y-%m-%d)
    CHANGELOG_VERSION="${VERSION:-HEAD}"

    CHANGELOG_CONTENT="## [$CHANGELOG_VERSION] - $CHANGELOG_DATE"
    if [ -n "$FEAT_COMMITS" ]; then
      CHANGELOG_CONTENT="$CHANGELOG_CONTENT

### Features"
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        MSG=$(echo "$line" | sed 's/^[a-f0-9]* //')
        CHANGELOG_CONTENT="$CHANGELOG_CONTENT
- $MSG"
      done <<< "$FEAT_COMMITS"
    fi

    if [ -n "$FIX_COMMITS" ]; then
      CHANGELOG_CONTENT="$CHANGELOG_CONTENT

### Bug Fixes"
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        MSG=$(echo "$line" | sed 's/^[a-f0-9]* //')
        CHANGELOG_CONTENT="$CHANGELOG_CONTENT
- $MSG"
      done <<< "$FIX_COMMITS"
    fi

    if [ -n "$OTHER_COMMITS" ]; then
      CHANGELOG_CONTENT="$CHANGELOG_CONTENT

### Other Changes"
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        MSG=$(echo "$line" | sed 's/^[a-f0-9]* //')
        CHANGELOG_CONTENT="$CHANGELOG_CONTENT
- $MSG"
      done <<< "$OTHER_COMMITS"
    fi

    CHANGELOG_GENERATED=true

    # Write to CHANGELOG.md if it exists (prepend) or create it
    if [ "$DRY_RUN" = false ] && [ "$GENERATE_CHANGELOG" = true ]; then
      if [ -f "CHANGELOG.md" ]; then
        # Prepend new entry to existing CHANGELOG
        EXISTING_CONTENT=$(cat CHANGELOG.md)
        # Check if this version already has an entry
        if ! grep -q "\[$CHANGELOG_VERSION\]" CHANGELOG.md 2>/dev/null; then
          printf "%s\n\n%s\n" "$CHANGELOG_CONTENT" "$EXISTING_CONTENT" > CHANGELOG.md
          GATE_CHANGELOG="✅ PASS | Changelog generated and written to CHANGELOG.md"
          record_gate "changelog" "pass" "Generated and written to CHANGELOG.md"
        else
          GATE_CHANGELOG="✅ PASS | Changelog entry for $CHANGELOG_VERSION already exists"
          record_gate "changelog" "pass" "Entry already exists for $CHANGELOG_VERSION"
        fi
      else
        printf "# Changelog\n\nAll notable changes to this project will be documented in this file.\n\n%s\n" "$CHANGELOG_CONTENT" > CHANGELOG.md
        GATE_CHANGELOG="✅ PASS | CHANGELOG.md created with auto-generated content"
        record_gate "changelog" "pass" "CHANGELOG.md created"
      fi
    else
      GATE_CHANGELOG="✅ PASS | Changelog ready (${#CHANGELOG_COMMITS} commits found, use --changelog to write)"
      record_gate "changelog" "pass" "Changelog content ready"
    fi
  else
    GATE_CHANGELOG="⚠️ WARN | No commits found for changelog"
    WARNINGS+=("No commits found for changelog generation")
    record_gate "changelog" "warn" "No commits found" "false"
  fi
else
  # Not generating changelog - just check if CHANGELOG.md exists
  if [ -f "CHANGELOG.md" ]; then
    GATE_CHANGELOG="✅ PASS | CHANGELOG.md present"
    record_gate "changelog" "pass" "CHANGELOG.md present"
  else
    GATE_CHANGELOG="⚠️ WARN | CHANGELOG.md missing (use --changelog to auto-generate)"
    WARNINGS+=("CHANGELOG.md not found - use --changelog flag to auto-generate")
    record_gate "changelog" "warn" "CHANGELOG.md missing" "false"
  fi
fi

echo "| Changelog | $GATE_CHANGELOG |"

# ─── Gate 9: Test Coverage (WARNING) ──────────────────────────────────────────

COVERAGE_FILE="coverage/coverage-summary.json"

if [ -f "$COVERAGE_FILE" ]; then
  if command -v jq >/dev/null 2>&1; then
    COVERAGE=$(jq '.total.lines.pct' "$COVERAGE_FILE" 2>/dev/null || echo "0")
  else
    COVERAGE=$(grep -oP '"pct"[[:space:]]*:[[:space:]]*\K[0-9.]+' "$COVERAGE_FILE" 2>/dev/null | head -1 || echo "0")
  fi

  # Compare coverage (handle both integer and decimal)
  if command -v bc >/dev/null 2>&1; then
    COVERAGE_OK=$(echo "$COVERAGE >= $COVERAGE_THRESHOLD" | bc -l)
  else
    COVERAGE_INT=${COVERAGE%.*}
    COVERAGE_INT=${COVERAGE_INT:-0}
    if [ "$COVERAGE_INT" -ge "$COVERAGE_THRESHOLD" ]; then
      COVERAGE_OK=1
    else
      COVERAGE_OK=0
    fi
  fi

  if [ "$COVERAGE_OK" -eq 1 ]; then
    GATE_COVERAGE="✅ PASS | ${COVERAGE}% (threshold: ${COVERAGE_THRESHOLD}%)"
    record_gate "coverage" "pass" "${COVERAGE}% >= ${COVERAGE_THRESHOLD}%" "false"
  else
    GATE_COVERAGE="⚠️ WARN | ${COVERAGE}% (threshold: ${COVERAGE_THRESHOLD}%)"
    WARNINGS+=("Test coverage ${COVERAGE}% is below threshold ${COVERAGE_THRESHOLD}%")
    record_gate "coverage" "warn" "${COVERAGE}% < ${COVERAGE_THRESHOLD}%" "false"
  fi
else
  GATE_COVERAGE="⚠️ SKIP | No coverage data available"
  record_gate "coverage" "skip" "No coverage data" "false"
fi

echo "| Coverage | $GATE_COVERAGE |"

# ─── Gate 10: TODO Count (WARNING) ────────────────────────────────────────────

TODO_COUNT=$(grep -r "TODO\|FIXME" \
  --include="*.js" \
  --include="*.ts" \
  --include="*.py" \
  --include="*.sh" \
  --exclude-dir=node_modules \
  --exclude-dir=.git \
  --exclude-dir=dist \
  --exclude-dir=build \
  . 2>/dev/null | wc -l || echo "0")

if [ "$TODO_COUNT" -le "$TODO_THRESHOLD" ]; then
  GATE_TODOS="✅ PASS | $TODO_COUNT TODOs (threshold: $TODO_THRESHOLD)"
  record_gate "todos" "pass" "$TODO_COUNT TODOs" "false"
else
  GATE_TODOS="⚠️ WARN | $TODO_COUNT TODOs (threshold: $TODO_THRESHOLD)"
  WARNINGS+=("$TODO_COUNT TODOs found (threshold: $TODO_THRESHOLD)")
  record_gate "todos" "warn" "$TODO_COUNT TODOs found" "false"
fi

echo "| TODOs | $GATE_TODOS |"

echo ""

# ─── Step 3: Determine final result ───────────────────────────────────────────

RESULT_STATUS="ready"
if [ $EXIT_CODE -eq 1 ] || [ "$BLOCKED" = true ]; then
  echo -e "### Result: ${RED}❌ BLOCKED${NC}"
  echo ""
  echo "Release is BLOCKED due to failing gates. Fix issues above before releasing."
  RESULT_STATUS="blocked"
  EXIT_CODE=1
elif [ ${#WARNINGS[@]} -gt 0 ]; then
  echo -e "### Result: ${YELLOW}⚠️ READY (with warnings)${NC}"
  echo ""
  echo "${#WARNINGS[@]} warning(s) - review before release:"
  for warning in "${WARNINGS[@]}"; do
    echo "- $warning"
  done
  RESULT_STATUS="ready_with_warnings"
  EXIT_CODE=2
else
  echo -e "### Result: ${GREEN}✅ READY${NC}"
  echo ""
  echo "All gates passed. Release is ready for deployment."
  RESULT_STATUS="ready"
  EXIT_CODE=0
fi

# ─── Step 4: Generate JSON Report ─────────────────────────────────────────────

if [ "$WRITE_REPORT" = true ] && command -v jq >/dev/null 2>&1; then
  # Build gates JSON array
  GATES_JSON="["
  FIRST=true
  for gate in "${GATE_RESULTS[@]}"; do
    if [ "$FIRST" = true ]; then
      GATES_JSON="${GATES_JSON}${gate}"
      FIRST=false
    else
      GATES_JSON="${GATES_JSON},${gate}"
    fi
  done
  GATES_JSON="${GATES_JSON}]"

  # Build warnings JSON array
  WARNINGS_JSON="["
  FIRST=true
  for warning in "${WARNINGS[@]}"; do
    ESCAPED=$(echo "$warning" | jq -Rs .)
    if [ "$FIRST" = true ]; then
      WARNINGS_JSON="${WARNINGS_JSON}${ESCAPED}"
      FIRST=false
    else
      WARNINGS_JSON="${WARNINGS_JSON},${ESCAPED}"
    fi
  done
  WARNINGS_JSON="${WARNINGS_JSON}]"

  # Build changelog JSON
  if [ "$CHANGELOG_GENERATED" = true ]; then
    CHANGELOG_JSON=$(echo "$CHANGELOG_CONTENT" | jq -Rs .)
  else
    CHANGELOG_JSON="null"
  fi

  jq -n \
    --arg version "$VERSION" \
    --arg branch "$EFFECTIVE_BRANCH" \
    --arg commit "${COMMIT:0:7}" \
    --arg status "$RESULT_STATUS" \
    --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson gates "${GATES_JSON:-[]}" \
    --argjson warnings "${WARNINGS_JSON:-[]}" \
    --argjson changelog "$CHANGELOG_JSON" \
    --argjson blocked "$BLOCKED" \
    '{
      version: $version,
      branch: $branch,
      commit: $commit,
      status: $status,
      blocked: $blocked,
      checked_at: $checked_at,
      summary: {
        total_gates: ($gates | length),
        passed: ($gates | map(select(.status == "pass")) | length),
        failed: ($gates | map(select(.status == "fail")) | length),
        warned: ($gates | map(select(.status == "warn")) | length),
        skipped: ($gates | map(select(.status == "skip")) | length),
        warnings: ($warnings | length)
      },
      gates: $gates,
      warnings: $warnings,
      changelog: $changelog
    }' > "$REPORT_FILE"

  echo ""
  echo "**Report:** $REPORT_FILE"
fi

exit $EXIT_CODE
