#!/usr/bin/env bash
#
# capability-audit.sh - Audit skills/agents/frameworks for compliance and quality
# Feature #377 - Add capability audit system
# size-ok: comprehensive capability audit for format validation and improvement detection
#
# Usage:
#   ./scripts/capability-audit.sh                          # Audit all capabilities
#   ./scripts/capability-audit.sh --skills                 # Audit skills only
#   ./scripts/capability-audit.sh --agents                 # Audit agents only
#   ./scripts/capability-audit.sh --format json            # Output as JSON
#   ./scripts/capability-audit.sh --check-obsolete         # Flag obsolete capabilities
#   ./scripts/capability-audit.sh --report audit-report.md # Save to file
#
# Exit codes:
#   0 - All audits passed
#   1 - Validation errors found
#   2 - Usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Directories to audit
SKILLS_DIR="$REPO_ROOT/core/commands"
AGENTS_DIR="$REPO_ROOT/core/agents"
SKILLS_STRUCTURED_DIR="$REPO_ROOT/core/skills"

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
TOTAL_OBSOLETE=0

# Options
AUDIT_SKILLS=true
AUDIT_AGENTS=true
OUTPUT_FORMAT="text"
CHECK_OBSOLETE=false
REPORT_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skills)
      AUDIT_AGENTS=false
      shift
      ;;
    --agents)
      AUDIT_SKILLS=false
      shift
      ;;
    --format)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    --check-obsolete)
      CHECK_OBSOLETE=true
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
      echo "  --skills           Audit skills only"
      echo "  --agents           Audit agents only"
      echo "  --format FORMAT    Output format (text, json, markdown)"
      echo "  --check-obsolete   Check for obsolete capabilities"
      echo "  --report FILE      Save report to file"
      echo "  -h, --help         Show this help"
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

SKILL_RESULTS="$TMPDIR/skills.json"
AGENT_RESULTS="$TMPDIR/agents.json"
OBSOLETE_RESULTS="$TMPDIR/obsolete.json"

echo "[]" > "$SKILL_RESULTS"
echo "[]" > "$AGENT_RESULTS"
echo "[]" > "$OBSOLETE_RESULTS"

# ===========================
# SKILL VALIDATION FUNCTIONS
# ===========================

validate_skill_format() {
  local file="$1"
  local filename=$(basename "$file")
  local skill_name="${filename%.md}"
  local errors=()
  local warnings=()
  local improvements=()

  # Check 1: Must have YAML frontmatter
  local has_frontmatter=$(grep -c "^---$" "$file" 2>/dev/null || echo 0)
  if [ "$has_frontmatter" -lt 2 ]; then
    errors+=("Missing YAML frontmatter")
  else
    # Extract frontmatter
    local frontmatter=$(sed -n '/^---$/,/^---$/p' "$file" | sed '1d;$d')

    # Check for description field
    if ! echo "$frontmatter" | grep -q "^description:"; then
      errors+=("Missing 'description' field in frontmatter")
    fi

    # Check for permissions block (best practice)
    if ! echo "$frontmatter" | grep -q "^permissions:"; then
      improvements+=("Add permissions block for auto-approval (Issue #203)")
    fi
  fi

  # Check 2: File naming convention
  if [[ ! "$skill_name" =~ ^[a-z]+(-[a-z]+)*$ ]]; then
    errors+=("Filename must be kebab-case (lowercase with hyphens)")
  fi

  # Check 3: Must have content after frontmatter
  local content=$(awk '/^---$/{++n; next} n==2' "$file")
  if [ -z "$content" ] || [ "$(echo "$content" | tr -d '[:space:]')" = "" ]; then
    errors+=("Missing skill content after frontmatter")
  fi

  # Check 4: Should have key sections
  if ! grep -qi "^## Usage" "$file"; then
    warnings+=("Missing '## Usage' section")
  fi

  if ! grep -qi "^## Steps" "$file"; then
    warnings+=("Missing '## Steps' section")
  fi

  if ! grep -qi "^## Token Optimization" "$file"; then
    improvements+=("Add '## Token Optimization' section documenting efficiency")
  fi

  # Check 5: Data script reference (best practice)
  local has_data_script=$(grep -c '\-data\.sh' "$file" 2>/dev/null || echo 0)
  if [ "$has_data_script" -eq 0 ]; then
    improvements+=("Consider creating data script: scripts/${skill_name}-data.sh")
  fi

  # Check 6: Script references should use relative paths
  if grep -q "scripts/" "$file"; then
    if grep -q "[^./]scripts/" "$file"; then
      warnings+=("Use relative paths for scripts: ./scripts/")
    fi
  fi

  # Build JSON result
  local errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  local warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
  local improvements_json=$(printf '%s\n' "${improvements[@]}" | jq -R . | jq -s .)

  # Calculate score
  local score=100
  score=$((score - ${#errors[@]} * 20))
  score=$((score - ${#warnings[@]} * 5))
  [ "$score" -lt 0 ] && score=0

  cat <<EOF
{
  "name": "$skill_name",
  "path": "$file",
  "type": "skill",
  "score": $score,
  "status": "$([ ${#errors[@]} -eq 0 ] && echo "passed" || echo "failed")",
  "errors": $errors_json,
  "warnings": $warnings_json,
  "improvements": $improvements_json
}
EOF
}

audit_skills() {
  echo -e "${BLUE}Auditing Skills...${NC}" >&2

  local results="["
  local first=true

  # Audit command files
  if [ -d "$SKILLS_DIR" ]; then
    for file in "$SKILLS_DIR"/*.md; do
      [ -f "$file" ] || continue

      local result=$(validate_skill_format "$file")

      if [ "$first" = true ]; then
        first=false
      else
        results+=","
      fi
      results+="$result"

      ((TOTAL_AUDITED++))

      local status=$(echo "$result" | jq -r '.status')
      if [ "$status" = "passed" ]; then
        ((TOTAL_PASSED++))
      else
        ((TOTAL_FAILED++))
      fi

      local warning_count=$(echo "$result" | jq '.warnings | length')
      TOTAL_WARNINGS=$((TOTAL_WARNINGS + warning_count))
    done
  fi

  # Audit structured skill directories
  if [ -d "$SKILLS_STRUCTURED_DIR" ]; then
    for skill_dir in "$SKILLS_STRUCTURED_DIR"/*/; do
      [ -d "$skill_dir" ] || continue
      if [ -f "${skill_dir}SKILL.md" ]; then
        local result=$(validate_skill_format "${skill_dir}SKILL.md")

        if [ "$first" = true ]; then
          first=false
        else
          results+=","
        fi
        results+="$result"

        ((TOTAL_AUDITED++))

        local status=$(echo "$result" | jq -r '.status')
        if [ "$status" = "passed" ]; then
          ((TOTAL_PASSED++))
        else
          ((TOTAL_FAILED++))
        fi

        local warning_count=$(echo "$result" | jq '.warnings | length')
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + warning_count))
      fi
    done
  fi

  results+="]"
  echo "$results" > "$SKILL_RESULTS"
}

# ===========================
# AGENT VALIDATION FUNCTIONS
# ===========================

validate_agent_format() {
  local file="$1"
  local filename=$(basename "$file")
  local agent_name="${filename%.md}"
  local errors=()
  local warnings=()
  local improvements=()

  # Check 1: Must have YAML frontmatter
  local has_frontmatter=$(grep -c "^---$" "$file" 2>/dev/null || echo 0)
  if [ "$has_frontmatter" -lt 2 ]; then
    errors+=("Missing YAML frontmatter")
  else
    # Extract frontmatter
    local frontmatter=$(sed -n '/^---$/,/^---$/p' "$file" | sed '1d;$d')

    # Check required fields
    if ! echo "$frontmatter" | grep -q "^name:"; then
      errors+=("Missing 'name' field in frontmatter")
    else
      local yaml_name=$(echo "$frontmatter" | grep '^name:' | sed 's/name: *//' | tr -d '"' | tr -d "'" | xargs)
      if [ "$yaml_name" != "$agent_name" ]; then
        errors+=("Name field '$yaml_name' doesn't match filename '$agent_name'")
      fi
    fi

    if ! echo "$frontmatter" | grep -q "^description:"; then
      errors+=("Missing 'description' field in frontmatter")
    else
      local description=$(echo "$frontmatter" | grep '^description:' | sed 's/description: *//')
      if [[ ! "$description" =~ "Use this agent" ]]; then
        warnings+=("Description should start with 'Use this agent to...'")
      fi
    fi

    if ! echo "$frontmatter" | grep -q "^model:"; then
      errors+=("Missing 'model' field in frontmatter")
    else
      local model=$(echo "$frontmatter" | grep '^model:' | sed 's/model: *//' | tr -d '"' | tr -d "'" | xargs)
      if [[ ! "$model" =~ ^(sonnet|opus|haiku)$ ]]; then
        warnings+=("Model should be 'sonnet', 'opus', or 'haiku' (found: '$model')")
      fi
    fi
  fi

  # Check 2: File naming convention
  if [[ ! "$agent_name" =~ ^[a-z]+(-[a-z]+)*$ ]]; then
    errors+=("Filename must be kebab-case (lowercase with hyphens)")
  fi

  # Check 3: Must have content after frontmatter
  local content=$(awk '/^---$/{++n; next} n==2' "$file")
  if [ -z "$content" ] || [ "$(echo "$content" | tr -d '[:space:]')" = "" ]; then
    errors+=("Missing agent system prompt after frontmatter")
  fi

  # Check 4: Should have key sections
  if ! grep -qi "^## ROLE" "$file"; then
    warnings+=("Missing '## ROLE' section")
  fi

  if ! grep -qiE "^## (PRIMARY OBJECTIVES|OBJECTIVES)" "$file"; then
    warnings+=("Missing '## OBJECTIVES' section")
  fi

  if ! grep -qi "^## BOUNDARIES" "$file"; then
    warnings+=("Missing '## BOUNDARIES' section")
  fi

  # Build JSON result
  local errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  local warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
  local improvements_json=$(printf '%s\n' "${improvements[@]}" | jq -R . | jq -s .)

  # Calculate score
  local score=100
  score=$((score - ${#errors[@]} * 20))
  score=$((score - ${#warnings[@]} * 5))
  [ "$score" -lt 0 ] && score=0

  cat <<EOF
{
  "name": "$agent_name",
  "path": "$file",
  "type": "agent",
  "score": $score,
  "status": "$([ ${#errors[@]} -eq 0 ] && echo "passed" || echo "failed")",
  "errors": $errors_json,
  "warnings": $warnings_json,
  "improvements": $improvements_json
}
EOF
}

audit_agents() {
  echo -e "${BLUE}Auditing Agents...${NC}" >&2

  local results="["
  local first=true

  if [ -d "$AGENTS_DIR" ]; then
    for file in "$AGENTS_DIR"/*.md; do
      [ -f "$file" ] || continue

      local result=$(validate_agent_format "$file")

      if [ "$first" = true ]; then
        first=false
      else
        results+=","
      fi
      results+="$result"

      ((TOTAL_AUDITED++))

      local status=$(echo "$result" | jq -r '.status')
      if [ "$status" = "passed" ]; then
        ((TOTAL_PASSED++))
      else
        ((TOTAL_FAILED++))
      fi

      local warning_count=$(echo "$result" | jq '.warnings | length')
      TOTAL_WARNINGS=$((TOTAL_WARNINGS + warning_count))
    done
  fi

  results+="]"
  echo "$results" > "$AGENT_RESULTS"
}

# ===========================
# OBSOLESCENCE DETECTION
# ===========================

check_obsolete_capabilities() {
  echo -e "${BLUE}Checking for obsolete capabilities...${NC}" >&2

  local results="["
  local first=true

  # Check for skills with no usage references
  if [ -d "$SKILLS_DIR" ]; then
    for file in "$SKILLS_DIR"/*.md; do
      [ -f "$file" ] || continue

      local skill_name=$(basename "$file" .md)
      local script_name="${skill_name}-data.sh"

      # Check if skill has companion script
      local has_script=false
      if [ -f "$SCRIPT_DIR/$script_name" ]; then
        has_script=true
      fi

      # Check if skill is referenced in other files
      local reference_count=$(grep -r "/$skill_name" "$REPO_ROOT" --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null | wc -l | tr -d ' ')

      # Flag as potentially obsolete if:
      # - No references AND no companion script
      # - Or marked with obsolete comment
      local is_obsolete=false
      local reason=""

      if grep -q "obsolete\|deprecated\|TODO.*remove" "$file" 2>/dev/null; then
        is_obsolete=true
        reason="Marked as obsolete/deprecated in file"
        ((TOTAL_OBSOLETE++))
      elif [ "$reference_count" -eq 0 ] && [ "$has_script" = false ]; then
        is_obsolete=true
        reason="No references found and no companion script"
        ((TOTAL_OBSOLETE++))
      fi

      if [ "$is_obsolete" = true ]; then
        if [ "$first" = true ]; then
          first=false
        else
          results+=","
        fi

        results+=$(cat <<EOF
{
  "name": "$skill_name",
  "path": "$file",
  "type": "skill",
  "reason": "$reason",
  "reference_count": $reference_count,
  "has_script": $has_script
}
EOF
)
      fi
    done
  fi

  results+="]"
  echo "$results" > "$OBSOLETE_RESULTS"
}

# ===========================
# OUTPUT FORMATTING
# ===========================

format_text_output() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║         CAPABILITY AUDIT REPORT                              ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Summary:"
  echo "  Total Audited:    $TOTAL_AUDITED"
  echo -e "  ${GREEN}Passed:${NC}           $TOTAL_PASSED"
  echo -e "  ${RED}Failed:${NC}           $TOTAL_FAILED"
  echo -e "  ${YELLOW}Warnings:${NC}         $TOTAL_WARNINGS"

  if [ "$CHECK_OBSOLETE" = true ]; then
    echo -e "  ${YELLOW}Obsolete:${NC}         $TOTAL_OBSOLETE"
  fi

  echo ""

  # Failed items
  if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo -e "${RED}━━━ Failed Capabilities ━━━${NC}"

    if [ "$AUDIT_SKILLS" = true ]; then
      local failed_skills=$(jq -r '.[] | select(.status == "failed") | "  • \(.name) (\(.path))\n    Errors: \(.errors | join(", "))"' "$SKILL_RESULTS")
      if [ -n "$failed_skills" ]; then
        echo "$failed_skills"
      fi
    fi

    if [ "$AUDIT_AGENTS" = true ]; then
      local failed_agents=$(jq -r '.[] | select(.status == "failed") | "  • \(.name) (\(.path))\n    Errors: \(.errors | join(", "))"' "$AGENT_RESULTS")
      if [ -n "$failed_agents" ]; then
        echo "$failed_agents"
      fi
    fi

    echo ""
  fi

  # Warnings
  if [ "$TOTAL_WARNINGS" -gt 0 ]; then
    echo -e "${YELLOW}━━━ Warnings ━━━${NC}"

    if [ "$AUDIT_SKILLS" = true ]; then
      jq -r '.[] | select((.warnings | length) > 0) | "  • \(.name):\n    \(.warnings | map("    - " + .) | join("\n"))"' "$SKILL_RESULTS" 2>/dev/null || true
    fi

    if [ "$AUDIT_AGENTS" = true ]; then
      jq -r '.[] | select((.warnings | length) > 0) | "  • \(.name):\n    \(.warnings | map("    - " + .) | join("\n"))"' "$AGENT_RESULTS" 2>/dev/null || true
    fi

    echo ""
  fi

  # Improvements
  echo -e "${BLUE}━━━ Improvement Recommendations ━━━${NC}"

  if [ "$AUDIT_SKILLS" = true ]; then
    jq -r '.[] | select((.improvements | length) > 0) | "  • \(.name):\n    \(.improvements | map("    - " + .) | join("\n"))"' "$SKILL_RESULTS" 2>/dev/null || true
  fi

  if [ "$AUDIT_AGENTS" = true ]; then
    jq -r '.[] | select((.improvements | length) > 0) | "  • \(.name):\n    \(.improvements | map("    - " + .) | join("\n"))"' "$AGENT_RESULTS" 2>/dev/null || true
  fi

  echo ""

  # Obsolete capabilities
  if [ "$CHECK_OBSOLETE" = true ] && [ "$TOTAL_OBSOLETE" -gt 0 ]; then
    echo -e "${YELLOW}━━━ Obsolete Capabilities (Consider Deletion) ━━━${NC}"
    jq -r '.[] | "  • \(.name) (\(.type))\n    Reason: \(.reason)\n    References: \(.reference_count)"' "$OBSOLETE_RESULTS" 2>/dev/null || true
    echo ""
  fi

  # Final verdict
  echo "══════════════════════════════════════════════════════════════"
  if [ "$TOTAL_FAILED" -eq 0 ]; then
    echo -e "${GREEN}✓ All capability audits passed${NC}"
  else
    echo -e "${RED}✗ Capability audit found $TOTAL_FAILED failed items${NC}"
  fi
  echo "══════════════════════════════════════════════════════════════"
}

format_json_output() {
  local skills=$(cat "$SKILL_RESULTS")
  local agents=$(cat "$AGENT_RESULTS")
  local obsolete=$(cat "$OBSOLETE_RESULTS")

  cat <<EOF
{
  "summary": {
    "total_audited": $TOTAL_AUDITED,
    "passed": $TOTAL_PASSED,
    "failed": $TOTAL_FAILED,
    "warnings": $TOTAL_WARNINGS,
    "obsolete": $TOTAL_OBSOLETE
  },
  "skills": $skills,
  "agents": $agents,
  "obsolete": $obsolete,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

format_markdown_output() {
  cat <<EOF
# Capability Audit Report

**Generated:** $(date -u +%Y-%m-%d\ %H:%M:%S\ UTC)

## Summary

| Metric | Count |
|--------|-------|
| Total Audited | $TOTAL_AUDITED |
| Passed | $TOTAL_PASSED |
| Failed | $TOTAL_FAILED |
| Warnings | $TOTAL_WARNINGS |
| Obsolete | $TOTAL_OBSOLETE |

## Failed Capabilities

EOF

  if [ "$TOTAL_FAILED" -eq 0 ]; then
    echo "✓ No failures"
  else
    if [ "$AUDIT_SKILLS" = true ]; then
      jq -r '.[] | select(.status == "failed") | "### \(.name)\n\n**Path:** \(.path)\n\n**Errors:**\n\(.errors | map("- " + .) | join("\n"))\n"' "$SKILL_RESULTS"
    fi

    if [ "$AUDIT_AGENTS" = true ]; then
      jq -r '.[] | select(.status == "failed") | "### \(.name)\n\n**Path:** \(.path)\n\n**Errors:**\n\(.errors | map("- " + .) | join("\n"))\n"' "$AGENT_RESULTS"
    fi
  fi

  cat <<EOF

## Improvement Recommendations

EOF

  if [ "$AUDIT_SKILLS" = true ]; then
    jq -r '.[] | select((.improvements | length) > 0) | "### \(.name)\n\n\(.improvements | map("- " + .) | join("\n"))\n"' "$SKILL_RESULTS" 2>/dev/null || true
  fi

  if [ "$AUDIT_AGENTS" = true ]; then
    jq -r '.[] | select((.improvements | length) > 0) | "### \(.name)\n\n\(.improvements | map("- " + .) | join("\n"))\n"' "$AGENT_RESULTS" 2>/dev/null || true
  fi

  if [ "$CHECK_OBSOLETE" = true ] && [ "$TOTAL_OBSOLETE" -gt 0 ]; then
    cat <<EOF

## Obsolete Capabilities

Consider removing these capabilities:

EOF
    jq -r '.[] | "### \(.name) (\(.type))\n\n**Path:** \(.path)  \n**Reason:** \(.reason)  \n**References:** \(.reference_count)\n"' "$OBSOLETE_RESULTS"
  fi
}

# ===========================
# MAIN EXECUTION
# ===========================

main() {
  # Run audits
  if [ "$AUDIT_SKILLS" = true ]; then
    audit_skills
  fi

  if [ "$AUDIT_AGENTS" = true ]; then
    audit_agents
  fi

  if [ "$CHECK_OBSOLETE" = true ]; then
    check_obsolete_capabilities
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
