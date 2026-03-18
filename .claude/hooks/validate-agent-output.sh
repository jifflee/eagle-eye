#!/bin/bash
# validate-agent-output.sh
# Claude Code PostToolUse hook for validating agent output schema conformance
#
# Receives JSON via stdin with:
#   - tool_name: "Task"
#   - tool_input: { subagent_type, model, prompt, description, ... }
#   - tool_response: { output, ... }
#   - session_id, cwd, hook_event_name
#
# Validates that agent outputs conform to the structured XML schema defined in:
#   docs/standards/PROMPT_TEMPLATE_STANDARDS.md
#
# Schema rules by agent category:
#   planning  (architect, product-spec-ux, api-designer, pm-orchestrator, documentation):
#             Must contain <summary> tag
#   development (backend-developer, frontend-developer, database-migration, data-storage):
#               Must contain <summary> tag and one of <files> or <code_sections>
#   review    (code-reviewer, pr-code-reviewer, pr-documentation, pr-test, pr-security-iam, guardrails-policy):
#             Must contain <verdict> tag with value: approved|changes_required|rejected
#   testing   (test-qa, pr-test):
#             Must contain <test_cases> tag
#   security  (security-iam-design, security-iam-prepr, pr-security-iam):
#             Must contain <findings> tag
#
# Validation mode:
#   STRICT_OUTPUT_VALIDATION=true  → exit 1 on violation (blocks agent tool response propagation)
#   STRICT_OUTPUT_VALIDATION=false → exit 0 with warning (default, advisory only)
#
# Exit codes:
#   0 = validation passed or advisory warning only
#   1 = validation failed (only when STRICT_OUTPUT_VALIDATION=true)

set -euo pipefail

# Read JSON from stdin
json_input=$(cat)

# Only run on PostToolUse events
hook_event="${HOOK_EVENT_NAME:-unknown}"
if [ "$hook_event" = "unknown" ]; then
  hook_event=$(echo "$json_input" | jq -r '.hook_event_name // "unknown"')
fi

if [ "$hook_event" != "PostToolUse" ]; then
  exit 0
fi

# Only process Task tool invocations
tool_name=$(echo "$json_input" | jq -r '.tool_name // ""')
if [ "$tool_name" != "Task" ]; then
  exit 0
fi

# Extract agent type and output
subagent_type=$(echo "$json_input" | jq -r '.tool_input.subagent_type // ""')
tool_output=$(echo "$json_input" | jq -r '.tool_response.output // ""' 2>/dev/null || echo "")

# Skip validation if no output
if [ -z "$tool_output" ]; then
  exit 0
fi

# Skip validation if output validation is explicitly disabled
if [ "${SKIP_OUTPUT_VALIDATION:-false}" = "true" ]; then
  exit 0
fi

# Strict mode: fail hard on violations
STRICT_MODE="${STRICT_OUTPUT_VALIDATION:-false}"

# Determine agent category from subagent_type
get_agent_category() {
  local agent="$1"
  case "$agent" in
    architect|product-spec-ux|api-designer|pm-orchestrator|documentation|documentation-librarian|milestone-manager|repo-workflow)
      echo "planning"
      ;;
    backend-developer|frontend-developer|database-migration|data-storage|refactoring-specialist|dependency-manager|deployment)
      echo "development"
      ;;
    code-reviewer|pr-code-reviewer|pr-documentation|guardrails-policy|performance-engineering)
      echo "review"
      ;;
    test-qa|pr-test)
      echo "testing"
      ;;
    security-iam-design|security-iam-prepr|pr-security-iam)
      echo "security"
      ;;
    *)
      echo "other"
      ;;
  esac
}

CATEGORY=$(get_agent_category "$subagent_type")

# Skip validation for "other" category agents
if [ "$CATEGORY" = "other" ]; then
  exit 0
fi

# Validation result tracking
VIOLATIONS=()
WARNINGS=()

# Check if output contains XML agent_output tags
check_xml_wrapper() {
  if echo "$tool_output" | grep -q '<agent_output>'; then
    return 0  # XML schema format detected
  else
    WARNINGS+=("Agent '$subagent_type' ($CATEGORY) output does not use XML <agent_output> schema. See docs/standards/PROMPT_TEMPLATE_STANDARDS.md")
    return 1
  fi
}

# Validate planning agents: must have <summary>
validate_planning() {
  check_xml_wrapper || true
  if ! echo "$tool_output" | grep -q '<summary>'; then
    VIOLATIONS+=("Planning agent '$subagent_type' output missing required <summary> tag")
  fi
}

# Validate development agents: must have <summary> and <files> or <code_sections>
validate_development() {
  check_xml_wrapper || true
  if ! echo "$tool_output" | grep -q '<summary>'; then
    VIOLATIONS+=("Development agent '$subagent_type' output missing required <summary> tag")
  fi
  if ! echo "$tool_output" | grep -qE '<files>|<files/>|<code_sections>|<code_sections/>'; then
    WARNINGS+=("Development agent '$subagent_type' output missing <files> or <code_sections> tags (may be blocked/escalation response)")
  fi
}

# Validate review agents: must have <verdict>
validate_review() {
  check_xml_wrapper || true
  if echo "$tool_output" | grep -q '<verdict>'; then
    # Check verdict value is valid
    verdict=$(echo "$tool_output" | grep -o '<verdict>[^<]*</verdict>' | sed 's/<[^>]*>//g' | tr -d ' \n')
    case "$verdict" in
      approved|changes_required|rejected)
        ;;  # Valid verdict
      *)
        WARNINGS+=("Review agent '$subagent_type' has unexpected verdict value: '$verdict' (expected: approved|changes_required|rejected)")
        ;;
    esac
  else
    VIOLATIONS+=("Review agent '$subagent_type' output missing required <verdict> tag")
  fi
}

# Validate testing agents: must have <test_cases>
validate_testing() {
  check_xml_wrapper || true
  if ! echo "$tool_output" | grep -qE '<test_cases>|<test_cases/>'; then
    VIOLATIONS+=("Testing agent '$subagent_type' output missing required <test_cases> tag")
  fi
}

# Validate security agents: must have <findings>
validate_security() {
  check_xml_wrapper || true
  if ! echo "$tool_output" | grep -qE '<findings>|<findings/>'; then
    VIOLATIONS+=("Security agent '$subagent_type' output missing required <findings> tag (use <findings/> if none found)")
  fi
  # Check that verdict is present for security agents
  if ! echo "$tool_output" | grep -q '<verdict>'; then
    WARNINGS+=("Security agent '$subagent_type' output missing <verdict> tag (expected: safe|unsafe|conditional)")
  fi
}

# Run category-specific validation
case "$CATEGORY" in
  planning)    validate_planning ;;
  development) validate_development ;;
  review)      validate_review ;;
  testing)     validate_testing ;;
  security)    validate_security ;;
esac

# Report results
LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude"
LOG_FILE="$LOG_DIR/output-validation.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SESSION_ID=$(echo "$json_input" | jq -r '.session_id // "unknown"')

if [ ${#VIOLATIONS[@]} -gt 0 ] || [ ${#WARNINGS[@]} -gt 0 ]; then
  # Write to validation log
  {
    echo "[$TIMESTAMP] session=$SESSION_ID agent=$subagent_type category=$CATEGORY"
    for violation in "${VIOLATIONS[@]}"; do
      echo "  VIOLATION: $violation"
    done
    for warning in "${WARNINGS[@]}"; do
      echo "  WARNING: $warning"
    done
  } >> "$LOG_FILE" 2>/dev/null || true

  # Print to stderr for visibility
  if [ ${#VIOLATIONS[@]} -gt 0 ]; then
    echo "⚠️  Agent Output Schema Violations ($subagent_type / $CATEGORY):" >&2
    for violation in "${VIOLATIONS[@]}"; do
      echo "   ❌ $violation" >&2
    done
    echo "   See docs/standards/PROMPT_TEMPLATE_STANDARDS.md for required schema." >&2

    if [ "$STRICT_MODE" = "true" ]; then
      echo "   STRICT_OUTPUT_VALIDATION=true — blocking due to violations." >&2
      exit 1
    fi
  fi

  if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo "ℹ️  Agent Output Schema Warnings ($subagent_type / $CATEGORY):" >&2
    for warning in "${WARNINGS[@]}"; do
      echo "   ⚠️  $warning" >&2
    done
  fi
fi

# Always exit 0 in advisory mode (default)
exit 0
