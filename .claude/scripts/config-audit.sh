#!/usr/bin/env bash
#
# config-audit.sh - Audit Claude Code configuration files for deprecated/obsolete settings
# Feature #990 - Add Claude config audit for deprecated capabilities
# size-ok: comprehensive configuration audit for Claude Code framework validation
#
# Usage:
#   ./scripts/config-audit.sh                          # Audit all config files
#   ./scripts/config-audit.sh --format json            # Output as JSON
#   ./scripts/config-audit.sh --check-deprecated       # Focus on deprecated features
#   ./scripts/config-audit.sh --report audit-report.md # Save to file
#
# Exit codes:
#   0 - All audits passed
#   1 - Validation errors found
#   2 - Usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration directory
CLAUDE_DIR="$REPO_ROOT/.claude"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TOTAL_AUDITED=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_WARNINGS=0
TOTAL_DEPRECATED=0

# Options
OUTPUT_FORMAT="text"
CHECK_DEPRECATED=false
REPORT_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --format)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    --check-deprecated)
      CHECK_DEPRECATED=true
      shift
      ;;
    --report)
      REPORT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --format FORMAT        Output format (text, json, markdown)"
      echo "  --check-deprecated     Focus on deprecated features"
      echo "  --report FILE          Save report to file"
      echo "  -h, --help             Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 2
      ;;
  esac
done

# Temporary files for results
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

HOOKS_RESULTS="$TMPDIR/hooks.json"
SETTINGS_RESULTS="$TMPDIR/settings.json"
PROJECT_CONFIG_RESULTS="$TMPDIR/project-config.json"
TIER_REGISTRY_RESULTS="$TMPDIR/tier-registry.json"
DEPRECATED_RESULTS="$TMPDIR/deprecated.json"

echo "[]" > "$HOOKS_RESULTS"
echo "[]" > "$SETTINGS_RESULTS"
echo "[]" > "$PROJECT_CONFIG_RESULTS"
echo "[]" > "$TIER_REGISTRY_RESULTS"
echo "[]" > "$DEPRECATED_RESULTS"

# ===========================
# HOOK VALIDATION FUNCTIONS
# ===========================

validate_hook_file() {
  local file="$1"
  local filename=$(basename "$file")
  local errors=()
  local warnings=()
  local improvements=()

  # Check 1: Must be executable
  if [ ! -x "$file" ]; then
    errors+=("Hook file is not executable (chmod +x needed)")
  fi

  # Check 2: Must have shebang
  local first_line=$(head -n 1 "$file")
  if [[ ! "$first_line" =~ ^#! ]]; then
    errors+=("Missing shebang line (#!/usr/bin/env bash or #!/bin/bash)")
  fi

  # Check 3: Check for deprecated hook patterns
  # Deprecated: old style hook registration (pre Claude SDK v2)
  if grep -q "CLAUDE_HOOK_V1" "$file" 2>/dev/null; then
    errors+=("Uses deprecated CLAUDE_HOOK_V1 format (migrate to Claude SDK v2 hooks)")
  fi

  # Check 4: Validate hook reads JSON from stdin
  if ! grep -q "stdin\|cat" "$file" 2>/dev/null; then
    warnings+=("Hook should read JSON input from stdin")
  fi

  # Check 5: Check for proper error handling
  if ! grep -q "set -e" "$file" 2>/dev/null; then
    warnings+=("Consider adding 'set -e' for error handling")
  fi

  # Check 6: Hook should exit 0 to allow operation
  if ! grep -q "exit 0" "$file" 2>/dev/null; then
    warnings+=("Hook should exit 0 to allow operation to proceed")
  fi

  # Check 7: Check for deprecated env variables
  if grep -qE "CLAUDE_V1_|OLD_CLAUDE_" "$file" 2>/dev/null; then
    warnings+=("Uses deprecated environment variables")
  fi

  # Build JSON result
  local errors_json="[]"
  local warnings_json="[]"
  local improvements_json="[]"

  if [ ${#errors[@]} -gt 0 ]; then
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  fi

  if [ ${#warnings[@]} -gt 0 ]; then
    warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
  fi

  if [ ${#improvements[@]} -gt 0 ]; then
    improvements_json=$(printf '%s\n' "${improvements[@]}" | jq -R . | jq -s .)
  fi

  # Calculate score
  local score=100
  score=$((score - ${#errors[@]} * 20))
  score=$((score - ${#warnings[@]} * 5))
  [ "$score" -lt 0 ] && score=0

  cat <<EOF
{
  "name": "$filename",
  "path": "$file",
  "type": "hook",
  "score": $score,
  "status": "$([ ${#errors[@]} -eq 0 ] && echo "passed" || echo "failed")",
  "errors": $errors_json,
  "warnings": $warnings_json,
  "improvements": $improvements_json
}
EOF
}

audit_hooks() {
  echo -e "${BLUE}Auditing Hooks...${NC}" >&2

  local results="["
  local first=true

  if [ -d "$CLAUDE_DIR/hooks" ]; then
    for file in "$CLAUDE_DIR/hooks"/*; do
      [ -f "$file" ] || continue

      # Skip non-executable text files like README
      if [[ "$file" =~ \.(md|txt|json)$ ]]; then
        continue
      fi

      local result
      result=$(validate_hook_file "$file")

      if [ "$first" = true ]; then
        first=false
      else
        results+=","
      fi
      results+="$result"

      ((TOTAL_AUDITED++))

      local status
      status=$(echo "$result" | jq -r '.status')
      if [ "$status" = "passed" ]; then
        ((TOTAL_PASSED++))
      else
        ((TOTAL_FAILED++))
      fi

      local warning_count
      warning_count=$(echo "$result" | jq '.warnings | length')
      TOTAL_WARNINGS=$((TOTAL_WARNINGS + warning_count))
    done
  fi

  results+="]"
  echo "$results" > "$HOOKS_RESULTS"
}

# ===========================
# SETTINGS.JSON VALIDATION
# ===========================

validate_settings_json() {
  local file="$CLAUDE_DIR/settings.json"
  local errors=()
  local warnings=()
  local improvements=()

  if [ ! -f "$file" ]; then
    errors+=("settings.json not found in .claude/ directory")

    cat <<EOF
{
  "name": "settings.json",
  "path": "$file",
  "type": "settings",
  "score": 0,
  "status": "failed",
  "errors": $(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .),
  "warnings": [],
  "improvements": []
}
EOF
    return
  fi

  # Check 1: Must be valid JSON
  if ! jq empty "$file" 2>/dev/null; then
    errors+=("Invalid JSON syntax")
  else
    # Check 2: Validate hook configuration structure
    local has_hooks=$(jq 'has("hooks")' "$file")
    if [ "$has_hooks" = "false" ]; then
      warnings+=("No hooks configuration found (consider adding hooks)")
    else
      # Check for deprecated hook event names
      if jq -e '.hooks | has("PreApprovalHook")' "$file" >/dev/null 2>&1; then
        errors+=("Deprecated hook event 'PreApprovalHook' found (use PreToolUse instead)")
      fi

      if jq -e '.hooks | has("PostApprovalHook")' "$file" >/dev/null 2>&1; then
        errors+=("Deprecated hook event 'PostApprovalHook' found (use PostToolUse instead)")
      fi

      # Check hook matchers are valid
      local matchers=$(jq -r '.hooks | to_entries[] | .value[] | .matcher // empty' "$file" 2>/dev/null)
      while IFS= read -r matcher; do
        if [[ -n "$matcher" && ! "$matcher" =~ ^(Bash|Read|Write|Edit|Glob|Grep|Task|WebFetch|WebSearch|\|)+$ ]]; then
          warnings+=("Potentially invalid hook matcher: '$matcher'")
        fi
      done <<< "$matchers"
    fi

    # Check 3: Check for deprecated settings
    if jq -e 'has("approvalMode")' "$file" >/dev/null 2>&1; then
      errors+=("Deprecated setting 'approvalMode' found (removed in Claude SDK v2)")
    fi

    if jq -e 'has("sessionId")' "$file" >/dev/null 2>&1; then
      warnings+=("'sessionId' in settings.json is deprecated (managed automatically)")
    fi

    # Check 4: Validate hook command paths
    local hook_commands=$(jq -r '.. | .command? // empty' "$file" 2>/dev/null)
    while IFS= read -r cmd; do
      if [[ -n "$cmd" ]]; then
        local cmd_path="$REPO_ROOT/$cmd"
        if [[ ! -f "$cmd_path" && ! -x "$cmd_path" ]]; then
          warnings+=("Hook command not found or not executable: $cmd")
        fi
      fi
    done <<< "$hook_commands"
  fi

  # Build JSON result
  local errors_json="[]"
  local warnings_json="[]"
  local improvements_json="[]"

  if [ ${#errors[@]} -gt 0 ]; then
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  fi

  if [ ${#warnings[@]} -gt 0 ]; then
    warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
  fi

  if [ ${#improvements[@]} -gt 0 ]; then
    improvements_json=$(printf '%s\n' "${improvements[@]}" | jq -R . | jq -s .)
  fi

  # Calculate score
  local score=100
  score=$((score - ${#errors[@]} * 20))
  score=$((score - ${#warnings[@]} * 5))
  [ "$score" -lt 0 ] && score=0

  cat <<EOF
{
  "name": "settings.json",
  "path": "$file",
  "type": "settings",
  "score": $score,
  "status": "$([ ${#errors[@]} -eq 0 ] && echo "passed" || echo "failed")",
  "errors": $errors_json,
  "warnings": $warnings_json,
  "improvements": $improvements_json
}
EOF
}

audit_settings() {
  echo -e "${BLUE}Auditing settings.json...${NC}" >&2

  local result=$(validate_settings_json)
  echo "[$result]" > "$SETTINGS_RESULTS"

  ((TOTAL_AUDITED++))

  local status=$(echo "$result" | jq -r '.status')
  if [ "$status" = "passed" ]; then
    ((TOTAL_PASSED++))
  else
    ((TOTAL_FAILED++))
  fi

  local warning_count=$(echo "$result" | jq '.warnings | length')
  TOTAL_WARNINGS=$((TOTAL_WARNINGS + warning_count))
}

# ===========================
# PROJECT-CONFIG.JSON VALIDATION
# ===========================

validate_project_config() {
  local file="$CLAUDE_DIR/project-config.json"
  local errors=()
  local warnings=()
  local improvements=()

  if [ ! -f "$file" ]; then
    warnings+=("project-config.json not found (optional file)")

    cat <<EOF
{
  "name": "project-config.json",
  "path": "$file",
  "type": "project-config",
  "score": 95,
  "status": "passed",
  "errors": [],
  "warnings": $(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .),
  "improvements": []
}
EOF
    return
  fi

  # Check 1: Must be valid JSON
  if ! jq empty "$file" 2>/dev/null; then
    errors+=("Invalid JSON syntax")
  else
    # Check 2: Validate expected fields
    local has_github_repo=$(jq 'has("github_repo")' "$file")
    if [ "$has_github_repo" = "false" ]; then
      warnings+=("Missing 'github_repo' field (recommended)")
    fi

    local has_framework_repo=$(jq 'has("framework_repo")' "$file")
    if [ "$has_framework_repo" = "false" ]; then
      improvements+=("Consider adding 'framework_repo' field for framework updates")
    fi

    # Check 3: Check for deprecated fields
    if jq -e 'has("claude_version")' "$file" >/dev/null 2>&1; then
      warnings+=("Field 'claude_version' is deprecated (version managed automatically)")
    fi

    if jq -e 'has("api_key")' "$file" >/dev/null 2>&1; then
      errors+=("SECURITY: API keys should not be in config files (use environment variables)")
    fi
  fi

  # Build JSON result
  local errors_json="[]"
  local warnings_json="[]"
  local improvements_json="[]"

  if [ ${#errors[@]} -gt 0 ]; then
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  fi

  if [ ${#warnings[@]} -gt 0 ]; then
    warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
  fi

  if [ ${#improvements[@]} -gt 0 ]; then
    improvements_json=$(printf '%s\n' "${improvements[@]}" | jq -R . | jq -s .)
  fi

  # Calculate score
  local score=100
  score=$((score - ${#errors[@]} * 20))
  score=$((score - ${#warnings[@]} * 5))
  [ "$score" -lt 0 ] && score=0

  cat <<EOF
{
  "name": "project-config.json",
  "path": "$file",
  "type": "project-config",
  "score": $score,
  "status": "$([ ${#errors[@]} -eq 0 ] && echo "passed" || echo "failed")",
  "errors": $errors_json,
  "warnings": $warnings_json,
  "improvements": $improvements_json
}
EOF
}

audit_project_config() {
  echo -e "${BLUE}Auditing project-config.json...${NC}" >&2

  local result=$(validate_project_config)
  echo "[$result]" > "$PROJECT_CONFIG_RESULTS"

  ((TOTAL_AUDITED++))

  local status=$(echo "$result" | jq -r '.status')
  if [ "$status" = "passed" ]; then
    ((TOTAL_PASSED++))
  else
    ((TOTAL_FAILED++))
  fi

  local warning_count=$(echo "$result" | jq '.warnings | length')
  TOTAL_WARNINGS=$((TOTAL_WARNINGS + warning_count))
}

# ===========================
# TIER-REGISTRY.JSON VALIDATION
# ===========================

validate_tier_registry() {
  local file="$CLAUDE_DIR/tier-registry.json"
  local errors=()
  local warnings=()
  local improvements=()

  if [ ! -f "$file" ]; then
    warnings+=("tier-registry.json not found (optional for permission tiers)")

    cat <<EOF
{
  "name": "tier-registry.json",
  "path": "$file",
  "type": "tier-registry",
  "score": 95,
  "status": "passed",
  "errors": [],
  "warnings": $(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .),
  "improvements": []
}
EOF
    return
  fi

  # Check 1: Must be valid JSON
  if ! jq empty "$file" 2>/dev/null; then
    errors+=("Invalid JSON syntax")
  else
    # Check 2: Validate schema version
    local schema_version=$(jq -r '.schema_version // empty' "$file")
    if [ -z "$schema_version" ]; then
      warnings+=("Missing 'schema_version' field")
    elif [ "$schema_version" != "1.0" ]; then
      warnings+=("Schema version '$schema_version' may be outdated (current: 1.0)")
    fi

    # Check 3: Validate tier values
    local invalid_tiers=$(jq -r '.. | .tier? // empty | select(. != "T0" and . != "T1" and . != "T2" and . != "T3")' "$file" 2>/dev/null)
    if [ -n "$invalid_tiers" ]; then
      errors+=("Invalid tier values found (must be T0, T1, T2, or T3)")
    fi

    # Check 4: Check for deprecated categories or operations
    if jq -e '.categories.deprecated' "$file" >/dev/null 2>&1; then
      warnings+=("Contains deprecated category definitions")
    fi
  fi

  # Build JSON result
  local errors_json="[]"
  local warnings_json="[]"
  local improvements_json="[]"

  if [ ${#errors[@]} -gt 0 ]; then
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  fi

  if [ ${#warnings[@]} -gt 0 ]; then
    warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
  fi

  if [ ${#improvements[@]} -gt 0 ]; then
    improvements_json=$(printf '%s\n' "${improvements[@]}" | jq -R . | jq -s .)
  fi

  # Calculate score
  local score=100
  score=$((score - ${#errors[@]} * 20))
  score=$((score - ${#warnings[@]} * 5))
  [ "$score" -lt 0 ] && score=0

  cat <<EOF
{
  "name": "tier-registry.json",
  "path": "$file",
  "type": "tier-registry",
  "score": $score,
  "status": "$([ ${#errors[@]} -eq 0 ] && echo "passed" || echo "failed")",
  "errors": $errors_json,
  "warnings": $warnings_json,
  "improvements": $improvements_json
}
EOF
}

audit_tier_registry() {
  echo -e "${BLUE}Auditing tier-registry.json...${NC}" >&2

  local result=$(validate_tier_registry)
  echo "[$result]" > "$TIER_REGISTRY_RESULTS"

  ((TOTAL_AUDITED++))

  local status=$(echo "$result" | jq -r '.status')
  if [ "$status" = "passed" ]; then
    ((TOTAL_PASSED++))
  else
    ((TOTAL_FAILED++))
  fi

  local warning_count=$(echo "$result" | jq '.warnings | length')
  TOTAL_WARNINGS=$((TOTAL_WARNINGS + warning_count))
}

# ===========================
# DEPRECATED FEATURE DETECTION
# ===========================

check_deprecated_features() {
  echo -e "${BLUE}Checking for deprecated features...${NC}" >&2

  local results="["
  local first=true

  # Scan all files in .claude for deprecated patterns
  if [ -d "$CLAUDE_DIR" ]; then
    # Check for deprecated action files (old format)
    if [ -d "$CLAUDE_DIR/actions" ]; then
      local action_count=$(find "$CLAUDE_DIR/actions" -type f | wc -l)
      if [ "$action_count" -gt 0 ]; then
        if [ "$first" = true ]; then
          first=false
        else
          results+=","
        fi

        results+=$(cat <<EOF
{
  "location": ".claude/actions/",
  "type": "directory",
  "reason": "Actions directory is deprecated (actions now integrated into hooks)",
  "migration": "Migrate actions to PreToolUse/PostToolUse hooks in settings.json",
  "severity": "high"
}
EOF
)
        ((TOTAL_DEPRECATED++))
      fi
    fi

    # Check for deprecated command format (old style without YAML frontmatter)
    if [ -d "$CLAUDE_DIR/commands" ]; then
      for cmd_file in "$CLAUDE_DIR/commands"/*.md; do
        [ -f "$cmd_file" ] || continue

        if ! grep -q "^---$" "$cmd_file"; then
          if [ "$first" = true ]; then
            first=false
          else
            results+=","
          fi

          results+=$(cat <<EOF
{
  "location": "$cmd_file",
  "type": "command",
  "reason": "Command missing YAML frontmatter (old format)",
  "migration": "Add YAML frontmatter with description field",
  "severity": "medium"
}
EOF
)
          ((TOTAL_DEPRECATED++))
        fi
      done
    fi

    # Check for old manifest format
    if [ -f "$CLAUDE_DIR/manifest.json" ]; then
      if ! jq -e '.version' "$CLAUDE_DIR/manifest.json" >/dev/null 2>&1; then
        if [ "$first" = true ]; then
          first=false
        else
          results+=","
        fi

        results+=$(cat <<EOF
{
  "location": ".claude/manifest.json",
  "type": "manifest",
  "reason": "Old manifest format detected (missing version field)",
  "migration": "Update to new manifest schema with version field",
  "severity": "low"
}
EOF
)
        ((TOTAL_DEPRECATED++))
      fi
    fi
  fi

  results+="]"
  echo "$results" > "$DEPRECATED_RESULTS"
}

# ===========================
# OUTPUT FORMATTING
# ===========================

format_text_output() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║         CLAUDE CONFIG AUDIT REPORT                           ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Summary:"
  echo "  Total Audited:    $TOTAL_AUDITED"
  echo -e "  ${GREEN}Passed:${NC}           $TOTAL_PASSED"
  echo -e "  ${RED}Failed:${NC}           $TOTAL_FAILED"
  echo -e "  ${YELLOW}Warnings:${NC}         $TOTAL_WARNINGS"

  if [ "$CHECK_DEPRECATED" = true ]; then
    echo -e "  ${YELLOW}Deprecated:${NC}       $TOTAL_DEPRECATED"
  fi

  echo ""

  # Failed items
  if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo -e "${RED}━━━ Failed Configurations ━━━${NC}"

    jq -r '.[] | select(.status == "failed") | "  • \(.name) (\(.path))\n    Errors: \(.errors | join(", "))"' \
      "$HOOKS_RESULTS" "$SETTINGS_RESULTS" "$PROJECT_CONFIG_RESULTS" "$TIER_REGISTRY_RESULTS" 2>/dev/null || true

    echo ""
  fi

  # Warnings
  if [ "$TOTAL_WARNINGS" -gt 0 ]; then
    echo -e "${YELLOW}━━━ Warnings ━━━${NC}"

    jq -r '.[] | select((.warnings | length) > 0) | "  • \(.name):\n    \(.warnings | map("    - " + .) | join("\n"))"' \
      "$HOOKS_RESULTS" "$SETTINGS_RESULTS" "$PROJECT_CONFIG_RESULTS" "$TIER_REGISTRY_RESULTS" 2>/dev/null || true

    echo ""
  fi

  # Improvements
  echo -e "${BLUE}━━━ Improvement Recommendations ━━━${NC}"

  jq -r '.[] | select((.improvements | length) > 0) | "  • \(.name):\n    \(.improvements | map("    - " + .) | join("\n"))"' \
    "$HOOKS_RESULTS" "$SETTINGS_RESULTS" "$PROJECT_CONFIG_RESULTS" "$TIER_REGISTRY_RESULTS" 2>/dev/null || true

  echo ""

  # Deprecated features
  if [ "$CHECK_DEPRECATED" = true ] && [ "$TOTAL_DEPRECATED" -gt 0 ]; then
    echo -e "${YELLOW}━━━ Deprecated Features ━━━${NC}"
    jq -r '.[] | "  • \(.location) (\(.type))\n    Reason: \(.reason)\n    Migration: \(.migration)\n    Severity: \(.severity)"' \
      "$DEPRECATED_RESULTS" 2>/dev/null || true
    echo ""
  fi

  # Final verdict
  echo "══════════════════════════════════════════════════════════════"
  if [ "$TOTAL_FAILED" -eq 0 ]; then
    echo -e "${GREEN}✓ All configuration audits passed${NC}"
  else
    echo -e "${RED}✗ Configuration audit found $TOTAL_FAILED failed items${NC}"
  fi
  echo "══════════════════════════════════════════════════════════════"
}

format_json_output() {
  local hooks=$(cat "$HOOKS_RESULTS")
  local settings=$(cat "$SETTINGS_RESULTS")
  local project_config=$(cat "$PROJECT_CONFIG_RESULTS")
  local tier_registry=$(cat "$TIER_REGISTRY_RESULTS")
  local deprecated=$(cat "$DEPRECATED_RESULTS")

  cat <<EOF
{
  "summary": {
    "total_audited": $TOTAL_AUDITED,
    "passed": $TOTAL_PASSED,
    "failed": $TOTAL_FAILED,
    "warnings": $TOTAL_WARNINGS,
    "deprecated": $TOTAL_DEPRECATED
  },
  "hooks": $hooks,
  "settings": $settings,
  "project_config": $project_config,
  "tier_registry": $tier_registry,
  "deprecated": $deprecated,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

format_markdown_output() {
  cat <<EOF
# Claude Config Audit Report

**Generated:** $(date -u +%Y-%m-%d\ %H:%M:%S\ UTC)

## Summary

| Metric | Count |
|--------|-------|
| Total Audited | $TOTAL_AUDITED |
| Passed | $TOTAL_PASSED |
| Failed | $TOTAL_FAILED |
| Warnings | $TOTAL_WARNINGS |
| Deprecated | $TOTAL_DEPRECATED |

## Failed Configurations

EOF

  if [ "$TOTAL_FAILED" -eq 0 ]; then
    echo "✓ No failures"
  else
    jq -r '.[] | select(.status == "failed") | "### \(.name)\n\n**Path:** \(.path)\n\n**Errors:**\n\(.errors | map("- " + .) | join("\n"))\n"' \
      "$HOOKS_RESULTS" "$SETTINGS_RESULTS" "$PROJECT_CONFIG_RESULTS" "$TIER_REGISTRY_RESULTS" 2>/dev/null || true
  fi

  cat <<EOF

## Warnings

EOF

  jq -r '.[] | select((.warnings | length) > 0) | "### \(.name)\n\n\(.warnings | map("- " + .) | join("\n"))\n"' \
    "$HOOKS_RESULTS" "$SETTINGS_RESULTS" "$PROJECT_CONFIG_RESULTS" "$TIER_REGISTRY_RESULTS" 2>/dev/null || true

  cat <<EOF

## Improvement Recommendations

EOF

  jq -r '.[] | select((.improvements | length) > 0) | "### \(.name)\n\n\(.improvements | map("- " + .) | join("\n"))\n"' \
    "$HOOKS_RESULTS" "$SETTINGS_RESULTS" "$PROJECT_CONFIG_RESULTS" "$TIER_REGISTRY_RESULTS" 2>/dev/null || true

  if [ "$CHECK_DEPRECATED" = true ] && [ "$TOTAL_DEPRECATED" -gt 0 ]; then
    cat <<EOF

## Deprecated Features

EOF
    jq -r '.[] | "### \(.location)\n\n**Type:** \(.type)  \n**Reason:** \(.reason)  \n**Migration:** \(.migration)  \n**Severity:** \(.severity)\n"' \
      "$DEPRECATED_RESULTS" 2>/dev/null || true
  fi
}

# ===========================
# MAIN EXECUTION
# ===========================

main() {
  # Check if .claude directory exists
  if [ ! -d "$CLAUDE_DIR" ]; then
    echo -e "${RED}Error: .claude/ directory not found${NC}" >&2
    echo "This script must be run in a repository with Claude Code configuration" >&2
    exit 1
  fi

  # Run audits
  audit_hooks
  audit_settings
  audit_project_config
  audit_tier_registry

  if [ "$CHECK_DEPRECATED" = true ]; then
    check_deprecated_features
  fi

  # Format output
  case "$OUTPUT_FORMAT" in
    json)
      OUTPUT=$(format_json_output)
      ;;
    markdown|md)
      OUTPUT=$(format_markdown_output)
      ;;
    text|*)
      OUTPUT=$(format_text_output)
      ;;
  esac

  # Write to file or stdout
  if [ -n "$REPORT_FILE" ]; then
    echo "$OUTPUT" > "$REPORT_FILE"
    echo -e "${GREEN}Report saved to: $REPORT_FILE${NC}" >&2
  else
    echo "$OUTPUT"
  fi

  # Exit with appropriate code
  if [ "$TOTAL_FAILED" -gt 0 ]; then
    exit 1
  else
    exit 0
  fi
}

main
