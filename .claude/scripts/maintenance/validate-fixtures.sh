#!/usr/bin/env bash
# ============================================================
# Script: validate-fixtures.sh
# Purpose: Validate test fixtures for format and freshness
# Usage: ./scripts/maintenance/validate-fixtures.sh [--strict]
# Dependencies: jq
# ============================================================

set -euo pipefail

STRICT="${1:-}"
ERRORS=0
WARNINGS=0
FIXTURE_DIR="tests/fixtures"

validate_json() {
  local file="$1"

  if ! jq empty "$file" 2>/dev/null; then
    echo "ERROR: Invalid JSON: $file"
    ((ERRORS++))
    return 1
  fi

  return 0
}

check_metadata() {
  local file="$1"

  if ! jq -e '._metadata' "$file" >/dev/null 2>&1; then
    echo "WARNING: Missing _metadata: $file"
    ((WARNINGS++))
    return 0
  fi

  # Check for required metadata fields
  local captured_at
  captured_at=$(jq -r '._metadata.capturedAt // empty' "$file")

  if [ -n "$captured_at" ]; then
    # Check age (warn if > 90 days)
    local captured_ts now_ts age_days
    captured_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$captured_at" "+%s" 2>/dev/null || echo "0")
    now_ts=$(date "+%s")

    if [ "$captured_ts" -gt 0 ]; then
      age_days=$(( (now_ts - captured_ts) / 86400 ))
      if [ "$age_days" -gt 90 ]; then
        echo "WARNING: Fixture older than 90 days: $file ($age_days days)"
        ((WARNINGS++))
      fi
    fi
  fi

  return 0
}

check_sanitization() {
  local file="$1"

  # Check for potential real email addresses
  if grep -qE '@(gmail|yahoo|hotmail|outlook|live)\.' "$file" 2>/dev/null; then
    echo "WARNING: Possible real email in fixture: $file"
    ((WARNINGS++))
  fi

  # Check for potential API keys
  if grep -qE '(sk_live|pk_live|api_key.*[a-zA-Z0-9]{32,})' "$file" 2>/dev/null; then
    echo "ERROR: Possible API key in fixture: $file"
    ((ERRORS++))
  fi

  return 0
}

validate_sql() {
  local file="$1"

  # Basic SQL syntax check (very simple)
  if ! grep -qE '^(INSERT|UPDATE|DELETE|SELECT|CREATE|ALTER|DROP)' "$file" 2>/dev/null; then
    if ! grep -qE '^--' "$file" 2>/dev/null; then
      echo "WARNING: SQL file may be empty or malformed: $file"
      ((WARNINGS++))
    fi
  fi

  return 0
}

main() {
  echo "# Fixture Validation Report"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""

  if [ ! -d "$FIXTURE_DIR" ]; then
    echo "No fixtures directory found at $FIXTURE_DIR"
    exit 0
  fi

  # Validate JSON fixtures
  echo "## JSON Fixtures"
  echo ""

  local json_count=0
  while IFS= read -r fixture; do
    [ -f "$fixture" ] || continue
    ((json_count++))

    validate_json "$fixture"
    check_metadata "$fixture"
    check_sanitization "$fixture"
  done < <(find "$FIXTURE_DIR" -name "*.json" -type f 2>/dev/null)

  echo "Validated $json_count JSON fixtures"
  echo ""

  # Validate SQL fixtures
  echo "## SQL Fixtures"
  echo ""

  local sql_count=0
  while IFS= read -r fixture; do
    [ -f "$fixture" ] || continue
    ((sql_count++))

    validate_sql "$fixture"
    check_sanitization "$fixture"
  done < <(find "$FIXTURE_DIR" -name "*.sql" -type f 2>/dev/null)

  echo "Validated $sql_count SQL fixtures"
  echo ""

  # Summary
  echo "## Summary"
  echo ""
  echo "| Metric | Count |"
  echo "|--------|-------|"
  echo "| JSON fixtures | $json_count |"
  echo "| SQL fixtures | $sql_count |"
  echo "| Errors | $ERRORS |"
  echo "| Warnings | $WARNINGS |"
  echo ""

  if [ "$ERRORS" -gt 0 ]; then
    echo "FAILED: $ERRORS errors found"
    exit 1
  fi

  if [ "$STRICT" = "--strict" ] && [ "$WARNINGS" -gt 0 ]; then
    echo "FAILED (strict mode): $WARNINGS warnings found"
    exit 1
  fi

  echo "PASSED: All fixtures valid"
}

main
