#!/bin/bash
#
# validate-skill-boundaries.sh
# Validates skill files against permission boundaries defined in skills-permissions.yaml
# size-ok: multi-rule boundary enforcement with permission parsing and violation detection
#
# Issue: #270 - Implement technical enforcement for skill boundary violations
# Related: #267 - Fix sprint-status incorrectly triggering sprint-work
#
# Usage:
#   ./scripts/validate-skill-boundaries.sh                    # Validate all skills
#   ./scripts/validate-skill-boundaries.sh sprint-status      # Validate single skill
#   ./scripts/validate-skill-boundaries.sh --json             # JSON output
#   ./scripts/validate-skill-boundaries.sh --ci               # CI mode (exit 1 on failure)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
PERMISSIONS_FILE="$REPO_ROOT/core/config/skills-permissions.yaml"
CORE_COMMANDS="$REPO_ROOT/core/commands"
PACK_COMMANDS="$REPO_ROOT/packs/*/commands"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TOTAL_SKILLS=0
PASSED=0
FAILED=0
WARNINGS=0

# Arguments
JSON_OUTPUT=false
CI_MODE=false
SINGLE_SKILL=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        *)
            SINGLE_SKILL="$1"
            shift
            ;;
    esac
done

# JSON output array
JSON_RESULTS="[]"

# Check if yq or similar is available, fall back to grep-based parsing
parse_yaml_list() {
    local file="$1"
    local path="$2"

    # Simple grep-based extraction for skill names under read_only_skills or write_full_skills
    if [[ "$path" == "read_only_skills" ]]; then
        grep -E "^  [a-z-]+:" "$file" | sed 's/://g' | awk '{print $1}' | head -20
    elif [[ "$path" == "write_full_skills" ]]; then
        # Find the write_full_skills section and extract skill names
        sed -n '/^write_full_skills:/,/^[a-z]/p' "$file" | grep -E "^  [a-z-]+:" | sed 's/://g' | awk '{print $1}'
    fi
}

# Get list of READ-ONLY skills from permissions file
get_read_only_skills() {
    if [[ ! -f "$PERMISSIONS_FILE" ]]; then
        echo "Error: Permissions file not found: $PERMISSIONS_FILE" >&2
        return 1
    fi

    # Extract skills under read_only_skills section
    sed -n '/^read_only_skills:/,/^write_full_skills:/p' "$PERMISSIONS_FILE" | \
        grep -E "^  [a-z-]+:" | \
        sed 's/://g' | \
        awk '{print $1}'
}

# Get list of WRITE-FULL skills from permissions file
get_write_full_skills() {
    if [[ ! -f "$PERMISSIONS_FILE" ]]; then
        echo "Error: Permissions file not found: $PERMISSIONS_FILE" >&2
        return 1
    fi

    # Extract skills under write_full_skills section
    sed -n '/^write_full_skills:/,/^validation_rules:/p' "$PERMISSIONS_FILE" | \
        grep -E "^  [a-z-]+:" | \
        sed 's/://g' | \
        awk '{print $1}'
}

# Check if a skill is READ-ONLY
is_read_only_skill() {
    local skill="$1"
    get_read_only_skills | grep -qx "$skill"
}

# Check if a skill is WRITE-FULL
is_write_full_skill() {
    local skill="$1"
    get_write_full_skills | grep -qx "$skill"
}

# Validate a single skill file
validate_skill() {
    local skill_file="$1"
    local skill_name=$(basename "$skill_file" .md)
    local errors=()
    local warnings=()
    local passed=true

    TOTAL_SKILLS=$((TOTAL_SKILLS + 1))

    # Read skill content
    local content
    content=$(cat "$skill_file")

    # Determine expected permission level
    local permission_level="UNKNOWN"
    if is_read_only_skill "$skill_name"; then
        permission_level="READ-ONLY"
    elif is_write_full_skill "$skill_name"; then
        permission_level="WRITE-FULL"
    fi

    # Only validate READ-ONLY skills for boundary violations
    if [[ "$permission_level" == "READ-ONLY" ]]; then
        # Check 1: Must contain READ-ONLY declaration
        if ! echo "$content" | grep -qi "READ-ONLY"; then
            errors+=("Missing READ-ONLY declaration")
            passed=false
        fi

        # Check 2: Description should include READ-ONLY marker
        local description
        description=$(grep "^description:" "$skill_file" | head -1)
        if ! echo "$description" | grep -qi "READ-ONLY"; then
            warnings+=("Description missing READ-ONLY marker (recommended)")
        fi

        # Check 3: Must include safeguard warnings
        if ! echo "$content" | grep -qi "SAFEGUARD\|BOUNDARY ENFORCEMENT"; then
            warnings+=("Missing SAFEGUARD or BOUNDARY ENFORCEMENT section")
        fi

        # Check 4: Must not invoke WRITE-FULL skills (except in "NEVER" or "DO NOT" context)
        local write_full_skills
        write_full_skills=$(get_write_full_skills)

        for write_skill in $write_full_skills; do
            # Check for Skill tool invocation patterns (excluding safeguard contexts)
            # First, filter out lines that are clearly safeguards (contain NEVER, DO NOT, prohibited, etc.)
            local non_safeguard_lines
            non_safeguard_lines=$(echo "$content" | grep -viE "NEVER|DO NOT|prohibited|must not|cannot|safeguard" || true)

            if echo "$non_safeguard_lines" | grep -qiE "Skill.*tool.*$write_skill|invoke.*Skill.*$write_skill"; then
                errors+=("Invokes WRITE-FULL skill: /$write_skill (boundary violation)")
                passed=false
            fi

            # Check for imperative command patterns (skip "User action:" context)
            if echo "$non_safeguard_lines" | grep -qE "Quick fix:.*/$write_skill|Command:.*/$write_skill"; then
                errors+=("Uses imperative language for /$write_skill (should use 'User action:' instead)")
                passed=false
            fi

            # Check for backtick references that aren't in safeguard context
            # This catches patterns like `/sprint-work` that might be actionable
            # But exclude references in NEVER/DO NOT sections
            local actionable_refs
            actionable_refs=$(echo "$non_safeguard_lines" | grep -oE "\`/$write_skill\`" || true)
            if [[ -n "$actionable_refs" ]]; then
                # Count total refs vs refs in User action context
                local total_refs user_action_refs
                total_refs=$(echo "$content" | grep -cE "\`/$write_skill\`" || true)
                user_action_refs=$(echo "$content" | grep -cE "User action:.*\`/$write_skill\`|User should run.*\`/$write_skill\`" || true)
                safeguard_refs=$(echo "$content" | grep -ciE "NEVER.*/$write_skill|DO NOT.*/$write_skill" || true)

                # If there are more refs than user action + safeguard refs, it's a potential violation
                if [[ $((user_action_refs + safeguard_refs)) -lt $total_refs ]]; then
                    # Check if remaining refs are in acceptable contexts
                    local remaining=$((total_refs - user_action_refs - safeguard_refs))
                    if [[ $remaining -gt 0 ]]; then
                        warnings+=("Has $remaining reference(s) to /$write_skill not in 'User action:' or safeguard context")
                    fi
                fi
            fi
        done

        # Check 5: Must use "User action:" language for recommendations
        if echo "$content" | grep -qiE "recommended.*action|next.*step|suggestion" && \
           ! echo "$content" | grep -qi "User action:"; then
            warnings+=("Has recommendations but missing 'User action:' language")
        fi

        # Check 6: Must not call sprint-work-preflight.sh directly
        if echo "$content" | grep -qE "sprint-work-preflight\.sh"; then
            # Check if it's in a "DO NOT" context
            if ! echo "$content" | grep -qE "DO NOT.*sprint-work-preflight|NEVER.*sprint-work-preflight"; then
                errors+=("References sprint-work-preflight.sh (potential boundary violation)")
                passed=false
            fi
        fi

        # Check 7: Notes section should mention READ-ONLY
        local notes
        notes=$(sed -n '/^## Notes/,/^## /p' "$skill_file" 2>/dev/null || echo "")
        if [[ -n "$notes" ]] && ! echo "$notes" | grep -qi "READ-ONLY"; then
            warnings+=("Notes section does not emphasize READ-ONLY operation")
        fi
    fi

    # Record results
    if [[ "$passed" == true ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi

    WARNINGS=$((WARNINGS + ${#warnings[@]}))

    # Output results
    if [[ "$JSON_OUTPUT" == true ]]; then
        local error_json="[]"
        local warning_json="[]"

        for e in "${errors[@]:-}"; do
            [[ -n "$e" ]] && error_json=$(echo "$error_json" | jq --arg err "$e" '. + [$err]')
        done

        for w in "${warnings[@]:-}"; do
            [[ -n "$w" ]] && warning_json=$(echo "$warning_json" | jq --arg warn "$w" '. + [$warn]')
        done

        local result
        result=$(jq -n \
            --arg skill "$skill_name" \
            --arg permission "$permission_level" \
            --arg file "$skill_file" \
            --argjson passed "$([[ "$passed" == true ]] && echo true || echo false)" \
            --argjson errors "$error_json" \
            --argjson warnings "$warning_json" \
            '{skill: $skill, permission: $permission, file: $file, passed: $passed, errors: $errors, warnings: $warnings}')

        JSON_RESULTS=$(echo "$JSON_RESULTS" | jq --argjson r "$result" '. + [$r]')
    else
        # Human-readable output
        if [[ "$passed" == true ]] && [[ ${#warnings[@]} -eq 0 ]]; then
            echo -e "${GREEN}✓${NC} $skill_name ($permission_level)"
        elif [[ "$passed" == true ]]; then
            echo -e "${YELLOW}✓${NC} $skill_name ($permission_level) - ${#warnings[@]} warning(s)"
            for w in "${warnings[@]:-}"; do
                [[ -n "$w" ]] && echo -e "  ${YELLOW}⚠${NC} $w"
            done
        else
            echo -e "${RED}✗${NC} $skill_name ($permission_level)"
            for e in "${errors[@]:-}"; do
                [[ -n "$e" ]] && echo -e "  ${RED}✗${NC} $e"
            done
            for w in "${warnings[@]:-}"; do
                [[ -n "$w" ]] && echo -e "  ${YELLOW}⚠${NC} $w"
            done
        fi
    fi
}

# Main execution
main() {
    if [[ "$JSON_OUTPUT" != true ]]; then
        echo "==========================================="
        echo "Skill Boundary Validation"
        echo "Issue #270: Technical Enforcement"
        echo "==========================================="
        echo ""
    fi

    # Validate single skill or all skills
    if [[ -n "$SINGLE_SKILL" ]]; then
        local skill_file="$CORE_COMMANDS/$SINGLE_SKILL.md"
        if [[ ! -f "$skill_file" ]]; then
            # Try packs
            skill_file=$(find "$REPO_ROOT/packs" -name "$SINGLE_SKILL.md" -path "*/commands/*" 2>/dev/null | head -1)
        fi

        if [[ -f "$skill_file" ]]; then
            validate_skill "$skill_file"
        else
            echo -e "${RED}Error:${NC} Skill not found: $SINGLE_SKILL" >&2
            exit 1
        fi
    else
        # Validate all skills in core/commands
        for skill_file in "$CORE_COMMANDS"/*.md; do
            [[ -f "$skill_file" ]] && validate_skill "$skill_file"
        done

        # Validate all skills in packs/*/commands
        for pack_dir in "$REPO_ROOT"/packs/*/commands; do
            if [[ -d "$pack_dir" ]]; then
                for skill_file in "$pack_dir"/*.md; do
                    [[ -f "$skill_file" ]] && validate_skill "$skill_file"
                done
            fi
        done
    fi

    # Output summary
    if [[ "$JSON_OUTPUT" == true ]]; then
        jq -n \
            --argjson results "$JSON_RESULTS" \
            --arg total "$TOTAL_SKILLS" \
            --arg passed "$PASSED" \
            --arg failed "$FAILED" \
            --arg warnings "$WARNINGS" \
            '{
                summary: {
                    total: ($total | tonumber),
                    passed: ($passed | tonumber),
                    failed: ($failed | tonumber),
                    warnings: ($warnings | tonumber)
                },
                results: $results
            }'
    else
        echo ""
        echo "==========================================="
        echo "Summary"
        echo "==========================================="
        echo "Total skills: $TOTAL_SKILLS"
        echo -e "${GREEN}Passed: $PASSED${NC}"
        if [[ $FAILED -gt 0 ]]; then
            echo -e "${RED}Failed: $FAILED${NC}"
        fi
        if [[ $WARNINGS -gt 0 ]]; then
            echo -e "${YELLOW}Warnings: $WARNINGS${NC}"
        fi
    fi

    # Exit with error code in CI mode if failures detected
    if [[ "$CI_MODE" == true ]] && [[ $FAILED -gt 0 ]]; then
        exit 1
    fi
}

main
