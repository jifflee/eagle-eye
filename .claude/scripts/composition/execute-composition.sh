#!/usr/bin/env bash
# execute-composition.sh - Execute skill dependencies with output passing
# Part of the skill composition framework (#224)
#
# Usage:
#   ./scripts/composition/execute-composition.sh <skill-name> [--input key=value ...]
#   ./scripts/composition/execute-composition.sh --file <contract> [options]
#
# This script:
# 1. Parses dependencies from skill contract
# 2. Executes dependencies in topological order
# 3. Passes outputs between steps
# 4. Handles permission tiers (auto, prompt-once, prompt-each)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRIMITIVES_DIR="$REPO_ROOT/primitives"
SKILLS_DIR="$REPO_ROOT/core/skills"
PARSE_SCRIPT="$SCRIPT_DIR/parse-dependencies.sh"

# Session state
SESSION_APPROVALS_FILE="${TMPDIR:-/tmp}/composition-approvals-$$.json"
EXECUTION_CONTEXT_FILE="${TMPDIR:-/tmp}/composition-context-$$.json"

# Initialize files
echo '{}' > "$SESSION_APPROVALS_FILE"
echo '{}' > "$EXECUTION_CONTEXT_FILE"

# Cleanup on exit
trap 'rm -f "$SESSION_APPROVALS_FILE" "$EXECUTION_CONTEXT_FILE"' EXIT

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <skill-name>

Execute skill with dependency resolution and output passing.

Options:
  --file <path>       Use specific contract file
  --input key=value   Pass input to skill (can repeat)
  --dry-run           Show execution plan without running
  --auto-approve      Auto-approve T2 permissions (for testing)
  --verbose           Show detailed execution logs
  -h, --help          Show this help message

Examples:
  $(basename "$0") sprint-work-composed
  $(basename "$0") sprint-work-composed --input issue=123
  $(basename "$0") --file contracts/skills/sprint-work-composed.contract.yaml
  $(basename "$0") sprint-work-composed --dry-run
EOF
}

# Log with timestamp
log() {
    local level="$1"
    shift
    echo "[$(date '+%H:%M:%S')] [$level] $*" >&2
}

# Get value from execution context
get_context() {
    local path="$1"
    jq -r ".$path // empty" "$EXECUTION_CONTEXT_FILE"
}

# Set value in execution context
set_context() {
    local key="$1"
    local value="$2"
    local tmp_file="${EXECUTION_CONTEXT_FILE}.tmp"

    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$EXECUTION_CONTEXT_FILE" > "$tmp_file"
    mv "$tmp_file" "$EXECUTION_CONTEXT_FILE"
}

# Check if tier is approved for this session
is_tier_approved() {
    local tier="$1"
    local dep_name="$2"

    case "$tier" in
        T0|T1)
            # Always auto-approved
            return 0
            ;;
        T2)
            # Check session approval
            local approved
            approved=$(jq -r ".T2_approved // false" "$SESSION_APPROVALS_FILE")
            [[ "$approved" == "true" ]]
            ;;
        T3)
            # Check specific approval
            local approved
            approved=$(jq -r ".T3_approvals[\"$dep_name\"] // false" "$SESSION_APPROVALS_FILE")
            [[ "$approved" == "true" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# Request approval for tier
request_approval() {
    local tier="$1"
    local dep_name="$2"
    local dep_type="$3"

    if [[ "${AUTO_APPROVE:-}" == "true" ]]; then
        log "INFO" "Auto-approving $tier for $dep_name"
        return 0
    fi

    echo "" >&2
    echo "═══════════════════════════════════════════════════════════" >&2
    echo "  PERMISSION REQUEST: $tier" >&2
    echo "═══════════════════════════════════════════════════════════" >&2
    echo "" >&2
    echo "  Dependency: $dep_name" >&2
    echo "  Type: $dep_type" >&2
    echo "  Tier: $tier" >&2
    echo "" >&2

    case "$tier" in
        T2)
            echo "  T2 permissions will be approved for this session." >&2
            echo "  This includes: PR creation, file writes, commits" >&2
            ;;
        T3)
            echo "  T3 permissions require individual approval." >&2
            echo "  This action: $dep_name" >&2
            ;;
    esac

    echo "" >&2
    read -p "  Approve? [y/N]: " response >&2

    if [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]; then
        # Record approval
        local tmp_file="${SESSION_APPROVALS_FILE}.tmp"

        if [[ "$tier" == "T2" ]]; then
            jq '.T2_approved = true' "$SESSION_APPROVALS_FILE" > "$tmp_file"
        else
            jq --arg name "$dep_name" '.T3_approvals[$name] = true' "$SESSION_APPROVALS_FILE" > "$tmp_file"
        fi

        mv "$tmp_file" "$SESSION_APPROVALS_FILE"
        return 0
    else
        return 1
    fi
}

# Resolve input value from mapping
resolve_input() {
    local mapping="$1"
    local skill_inputs="$2"

    # Check for static value
    local value
    value=$(echo "$mapping" | jq -r '.value // empty')
    if [[ -n "$value" ]]; then
        echo "$value"
        return
    fi

    # Check for reference to prior output
    local from_ref
    from_ref=$(echo "$mapping" | jq -r '.from // empty')
    if [[ -n "$from_ref" ]]; then
        # Parse reference path (e.g., "state.recommended_issue")
        local step_name field_path
        step_name=$(echo "$from_ref" | cut -d. -f1)
        field_path=$(echo "$from_ref" | cut -d. -f2-)

        # Get from execution context
        local context_value
        context_value=$(get_context "${step_name}.${field_path}")

        if [[ -n "$context_value" ]]; then
            echo "$context_value"
            return
        fi

        # Try default
        local default_value
        default_value=$(echo "$mapping" | jq -r '.default // empty')
        if [[ -n "$default_value" && "$default_value" != "null" ]]; then
            echo "$default_value"
            return
        fi

        echo ""
        return
    fi

    # Check for reference to skill input
    local input_ref
    input_ref=$(echo "$mapping" | jq -r '.input // empty')
    if [[ -n "$input_ref" ]]; then
        echo "$skill_inputs" | jq -r ".$input_ref // empty"
        return
    fi

    echo ""
}

# Execute a primitive
execute_primitive() {
    local name="$1"
    local inputs="$2"

    log "INFO" "Executing primitive: $name"

    # Look for primitive script
    local primitive_script=""
    local search_paths=(
        "$REPO_ROOT/primitives/$name.sh"
        "$REPO_ROOT/scripts/$name.sh"
        "$REPO_ROOT/scripts/primitives/$name.sh"
    )

    for path in "${search_paths[@]}"; do
        if [[ -x "$path" ]]; then
            primitive_script="$path"
            break
        fi
    done

    if [[ -z "$primitive_script" ]]; then
        # Primitive not found - return mock output for development
        log "WARN" "Primitive script not found: $name (returning mock output)"

        # Return mock output based on primitive name
        case "$name" in
            get-sprint-state)
                echo '{"recommended_issue": 123, "milestone": "sprint-1", "pr_exists": false}'
                ;;
            validate-worktree)
                echo '{"valid": true, "branch": "feat/issue-123"}'
                ;;
            create-pr)
                echo '{"number": 456, "url": "https://github.com/org/repo/pull/456", "merged": false}'
                ;;
            close-issue)
                echo '{"closed": true}'
                ;;
            *)
                echo '{"status": "completed"}'
                ;;
        esac
        return 0
    fi

    # Execute primitive with inputs as environment variables
    local result
    if result=$(echo "$inputs" | "$primitive_script" 2>&1); then
        echo "$result"
        return 0
    else
        log "ERROR" "Primitive $name failed"
        echo '{"error": "Primitive execution failed"}'
        return 1
    fi
}

# Execute a skill dependency
execute_skill() {
    local name="$1"
    local inputs="$2"

    log "INFO" "Executing skill: $name"

    # Look for skill contract
    local skill_contract="$REPO_ROOT/contracts/skills/${name}.contract.yaml"

    if [[ -f "$skill_contract" ]]; then
        # Check if skill has dependencies (recursive composition)
        local has_deps
        has_deps=$("$PARSE_SCRIPT" --file "$skill_contract" | jq -r '.dependency_count')

        if [[ "$has_deps" -gt 0 ]]; then
            log "INFO" "Skill $name has dependencies, executing recursively"
            # Recursive execution
            "$0" --file "$skill_contract" --input "$(echo "$inputs" | jq -c '.')"
            return $?
        fi
    fi

    # Simple skill without composition - look for skill script
    local skill_script=""
    local search_paths=(
        "$SKILLS_DIR/$name/run.sh"
        "$REPO_ROOT/scripts/skills/$name.sh"
    )

    for path in "${search_paths[@]}"; do
        if [[ -x "$path" ]]; then
            skill_script="$path"
            break
        fi
    done

    if [[ -z "$skill_script" ]]; then
        log "WARN" "Skill script not found: $name (returning mock output)"
        echo '{"status": "completed", "skill": "'"$name"'"}'
        return 0
    fi

    # Execute skill
    local result
    if result=$(echo "$inputs" | "$skill_script" 2>&1); then
        echo "$result"
        return 0
    else
        log "ERROR" "Skill $name failed"
        echo '{"error": "Skill execution failed"}'
        return 1
    fi
}

# Evaluate condition expression
evaluate_condition() {
    local condition="$1"

    if [[ -z "$condition" || "$condition" == "null" ]]; then
        return 0  # No condition = always run
    fi

    # Read context
    local context
    context=$(cat "$EXECUTION_CONTEXT_FILE")

    # Use jq for condition evaluation with proper escaping
    # Parse condition and evaluate against context
    local result
    result=$(python3 << PYEOF
import sys
import json
import re

condition = """$condition"""
try:
    context = json.loads('''$(echo "$context" | jq -c '.')''')
except:
    context = {}

# Convert condition to Python expression
expr = condition

# Replace && with 'and', || with 'or'
expr = re.sub(r'\s*&&\s*', ' and ', expr)
expr = re.sub(r'\s*\|\|\s*', ' or ', expr)

# Replace !field.path with (not field_path)
expr = re.sub(r'!([a-zA-Z_][a-zA-Z0-9_.]*)', r'(not \1)', expr)

# Evaluate field references
def get_nested(obj, path):
    parts = path.split('.')
    for part in parts:
        if isinstance(obj, dict) and part in obj:
            obj = obj[part]
        else:
            return None
    return obj

# Replace field references with actual values
def replace_ref(match):
    path = match.group(0)
    # Skip Python keywords
    if path in ['and', 'or', 'not', 'True', 'False', 'None']:
        return path
    val = get_nested(context, path)
    if val is None:
        return 'None'
    elif isinstance(val, bool):
        return 'True' if val else 'False'
    elif isinstance(val, str):
        return repr(val)
    else:
        return str(val)

# Find and replace all field references
expr = re.sub(r'[a-zA-Z_][a-zA-Z0-9_.]*', replace_ref, expr)

# Evaluate
try:
    result = eval(expr)
    print('true' if result else 'false')
except Exception as e:
    print('false')
PYEOF
)

    [[ "${VERBOSE:-}" == "true" ]] && log "DEBUG" "Condition: $condition -> $result"

    [[ "$result" == "true" ]]
}

# Execute dependency graph
execute_dependencies() {
    local parsed="$1"
    local skill_inputs="$2"

    local dep_count
    dep_count=$(echo "$parsed" | jq -r '.dependency_count')

    if [[ "$dep_count" -eq 0 ]]; then
        log "INFO" "No dependencies to execute"
        return 0
    fi

    # Store skill inputs in context
    set_context "input" "$skill_inputs"

    # Execute each dependency in order (avoid subshell with for loop)
    local i=0
    while [[ $i -lt $dep_count ]]; do
        local dep
        dep=$(echo "$parsed" | jq -c ".dependencies[$i]")
        local name type tier output_as when required
        name=$(echo "$dep" | jq -r '.name')
        type=$(echo "$dep" | jq -r '.type')
        tier=$(echo "$dep" | jq -r '.tier')
        output_as=$(echo "$dep" | jq -r '.output_as')
        when=$(echo "$dep" | jq -r '.when')
        required=$(echo "$dep" | jq -r '.required')

        log "INFO" "Processing dependency: $name ($type, $tier)"

        # Check condition
        if [[ -n "$when" && "$when" != "null" ]]; then
            [[ "${VERBOSE:-}" == "true" ]] && log "DEBUG" "Context before $name: $(cat "$EXECUTION_CONTEXT_FILE")"
            if ! evaluate_condition "$when"; then
                log "INFO" "Skipping $name: condition not met ($when)"
                set_context "$output_as" '{"skipped": true, "reason": "condition not met"}'
                i=$((i + 1))
                continue
            fi
        fi

        # Check permission tier
        if ! is_tier_approved "$tier" "$name"; then
            if ! request_approval "$tier" "$name" "$type"; then
                if [[ "$required" == "true" ]]; then
                    log "ERROR" "Required dependency $name was not approved"
                    return 1
                else
                    log "WARN" "Optional dependency $name was not approved, skipping"
                    set_context "$output_as" '{"skipped": true, "reason": "not approved"}'
                    i=$((i + 1))
                    continue
                fi
            fi
        fi

        # Resolve inputs
        local resolved_inputs='{}'
        local input_mappings
        input_mappings=$(echo "$dep" | jq -c '.inputs // {}')

        for key in $(echo "$input_mappings" | jq -r 'keys[]'); do
            local mapping value
            mapping=$(echo "$input_mappings" | jq -c ".\"$key\"")
            value=$(resolve_input "$mapping" "$skill_inputs")

            if [[ -n "$value" ]]; then
                resolved_inputs=$(echo "$resolved_inputs" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
            fi
        done

        [[ "${VERBOSE:-}" == "true" ]] && log "DEBUG" "Resolved inputs: $resolved_inputs"

        # Execute dependency
        local output
        case "$type" in
            primitive)
                output=$(execute_primitive "$name" "$resolved_inputs")
                ;;
            skill)
                output=$(execute_skill "$name" "$resolved_inputs")
                ;;
            *)
                log "ERROR" "Unknown dependency type: $type"
                return 1
                ;;
        esac

        # Store output in context
        if [[ -n "$output" ]]; then
            # Parse output as JSON if possible
            if echo "$output" | jq -e '.' >/dev/null 2>&1; then
                set_context "$output_as" "$output"
            else
                set_context "$output_as" "{\"raw\": $(echo "$output" | jq -R -s '.')}"
            fi
        fi

        log "INFO" "Completed: $name -> $output_as"

        i=$((i + 1))
    done

    return 0
}

# Show execution plan (dry run)
show_execution_plan() {
    local parsed="$1"
    local skill_inputs="$2"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  EXECUTION PLAN"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "  Skill: $(echo "$parsed" | jq -r '.skill')"
    echo "  Effective Tier: $(echo "$parsed" | jq -r '.effective_tier')"
    echo "  Dependencies: $(echo "$parsed" | jq -r '.dependency_count')"
    echo ""

    if [[ -n "$skill_inputs" && "$skill_inputs" != "{}" ]]; then
        echo "  Inputs:"
        echo "$skill_inputs" | jq -r 'to_entries | map("    " + .key + " = " + (.value | tostring)) | .[]'
        echo ""
    fi

    echo "  Execution Order:"
    echo ""

    local step=1
    echo "$parsed" | jq -c '.dependencies[]' | while read -r dep; do
        local name type tier when
        name=$(echo "$dep" | jq -r '.name')
        type=$(echo "$dep" | jq -r '.type')
        tier=$(echo "$dep" | jq -r '.tier')
        when=$(echo "$dep" | jq -r '.when // "always"')

        local approval_note=""
        case "$tier" in
            T0|T1) approval_note="(auto)" ;;
            T2) approval_note="(prompt once)" ;;
            T3) approval_note="(prompt each)" ;;
        esac

        printf "    %d. [%s] %s (%s) %s\n" "$step" "$tier" "$name" "$type" "$approval_note"

        if [[ "$when" != "always" && "$when" != "null" ]]; then
            echo "       └─ when: $when"
        fi

        step=$((step + 1))
    done

    echo ""
    echo "═══════════════════════════════════════════════════════════"
}

# Main
main() {
    local skill_name=""
    local contract_file=""
    local dry_run=false
    local skill_inputs='{}'

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)
                contract_file="$2"
                shift 2
                ;;
            --input)
                # Parse key=value and add to JSON
                local key value
                key="${2%%=*}"
                value="${2#*=}"
                skill_inputs=$(echo "$skill_inputs" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --auto-approve)
                export AUTO_APPROVE=true
                shift
                ;;
            --verbose)
                export VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
            *)
                skill_name="$1"
                shift
                ;;
        esac
    done

    # Resolve contract file
    if [[ -z "$contract_file" ]]; then
        if [[ -z "$skill_name" ]]; then
            echo "Error: Must specify skill name or --file" >&2
            usage >&2
            exit 1
        fi

        contract_file="$REPO_ROOT/contracts/skills/${skill_name}.contract.yaml"
        if [[ ! -f "$contract_file" ]]; then
            echo "Error: Contract not found: $contract_file" >&2
            exit 1
        fi
    fi

    # Parse dependencies
    local parsed
    parsed=$("$PARSE_SCRIPT" --file "$contract_file")

    if echo "$parsed" | jq -e '.error' >/dev/null 2>&1; then
        echo "Error parsing contract: $(echo "$parsed" | jq -r '.error')" >&2
        exit 1
    fi

    if [[ "$dry_run" == "true" ]]; then
        show_execution_plan "$parsed" "$skill_inputs"
        exit 0
    fi

    # Validate before execution
    local validation
    validation=$("$PARSE_SCRIPT" --validate --file "$contract_file")

    if [[ $(echo "$validation" | jq -r '.valid') != "true" ]]; then
        echo "Validation failed:" >&2
        echo "$validation" | jq -r '.issues[]' >&2
        exit 1
    fi

    # Show warnings
    local warnings
    warnings=$(echo "$validation" | jq -r '.warnings[]')
    if [[ -n "$warnings" ]]; then
        echo "$warnings" | while read -r warning; do
            log "WARN" "$warning"
        done
    fi

    # Execute
    log "INFO" "Starting execution of $(echo "$parsed" | jq -r '.skill')"
    log "INFO" "Effective tier: $(echo "$parsed" | jq -r '.effective_tier')"

    if execute_dependencies "$parsed" "$skill_inputs"; then
        log "INFO" "Execution completed successfully"

        # Output final context
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  EXECUTION RESULTS"
        echo "═══════════════════════════════════════════════════════════"
        cat "$EXECUTION_CONTEXT_FILE" | jq '.'

        exit 0
    else
        log "ERROR" "Execution failed"
        exit 1
    fi
}

main "$@"
