#!/usr/bin/env bash
# =============================================================================
# validate-capture-output.sh
# Validates /capture command issue body against strict schema requirements
# before creation via the repo-workflow agent.
#
# Usage:
#   ./scripts/validate-capture-output.sh <body_file> [category] [--strict]
#
# Arguments:
#   body_file  - Path to file containing the issue body markdown
#   category   - Issue type: bug|feature|tech-debt|docs|epic (default: feature)
#   --strict   - Enable strict validation (all type-specific sections required)
#
# Exit codes:
#   0 - Validation passed
#   1 - Validation failed (errors printed to stdout)
#   2 - Usage error (bad arguments)
#
# Related: Issue #908 - Research: Standardize /capture output format
# Template version: v2.0
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="validate-capture-output.sh"
readonly TEMPLATE_VERSION="v2.0"
readonly MIN_AC_ITEMS=2
readonly MIN_SUMMARY_WORDS=3
readonly MAX_SUMMARY_SENTENCES=3

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
BODY_FILE="${1:-}"
CATEGORY="${2:-feature}"
STRICT_MODE=false

if [[ "$*" == *"--strict"* ]]; then
    STRICT_MODE=true
fi

if [[ -z "$BODY_FILE" ]]; then
    echo "Usage: ${SCRIPT_NAME} <body_file> [category] [--strict]"
    echo "  category: bug|feature|tech-debt|docs|epic (default: feature)"
    echo "  --strict: require all type-specific sections"
    exit 2
fi

if [[ ! -f "$BODY_FILE" ]]; then
    echo "Error: Body file not found: ${BODY_FILE}"
    exit 2
fi

BODY=$(cat "$BODY_FILE")

# ---------------------------------------------------------------------------
# Validation state
# ---------------------------------------------------------------------------
ERRORS=()
WARNINGS=()
PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

pass() {
    local msg="$1"
    echo "  ✅ ${msg}"
    ((PASS_COUNT++)) || true
}

warn() {
    local msg="$1"
    echo "  ⚠️  ${msg}"
    WARNINGS+=("$msg")
}

fail() {
    local msg="$1"
    echo "  ❌ ${msg}"
    ERRORS+=("$msg")
    ((FAIL_COUNT++)) || true
}

# Check if a markdown section (## Header) exists in body
has_section() {
    local section_name="$1"
    echo "$BODY" | grep -q "^## ${section_name}" 2>/dev/null
}

# Check if a section exists and is non-empty (has content after the header)
section_has_content() {
    local section_name="$1"
    # Get content between this section header and the next ## header
    local content
    content=$(echo "$BODY" | awk "/^## ${section_name}/{found=1; next} found && /^## /{exit} found{print}" 2>/dev/null || echo "")
    # Remove blank lines and trim
    local trimmed
    trimmed=$(echo "$content" | grep -v "^$" | grep -v "^<!--" | head -5 || echo "")
    [[ -n "$trimmed" ]]
}

# Count checkbox items (- [ ] pattern) in body
count_checkboxes() {
    echo "$BODY" | grep -c "^- \[ \]" 2>/dev/null || echo "0"
}

# Count words in a section
section_word_count() {
    local section_name="$1"
    echo "$BODY" | awk "/^## ${section_name}/{found=1; next} found && /^## /{exit} found{print}" 2>/dev/null | wc -w | tr -d ' ' || echo "0"
}

# Check if context field exists
has_context_field() {
    local field="$1"
    echo "$BODY" | grep -q "^${field}:" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Common validations (all issue types)
# ---------------------------------------------------------------------------

validate_common() {
    echo ""
    echo "Common Schema Validation:"
    echo "─────────────────────────"

    # 1. Summary section
    if has_section "Summary"; then
        if section_has_content "Summary"; then
            local word_count
            word_count=$(section_word_count "Summary")
            if [[ "$word_count" -ge "$MIN_SUMMARY_WORDS" ]]; then
                pass "## Summary section present and non-empty (${word_count} words)"
            else
                fail "## Summary section too brief (${word_count} words; minimum: ${MIN_SUMMARY_WORDS})"
            fi
        else
            fail "## Summary section is empty"
        fi
    else
        fail "MISSING REQUIRED SECTION: ## Summary"
    fi

    # 2. Acceptance Criteria section
    if has_section "Acceptance Criteria"; then
        local ac_count
        ac_count=$(count_checkboxes)
        if [[ "$ac_count" -ge "$MIN_AC_ITEMS" ]]; then
            pass "## Acceptance Criteria present with ${ac_count} checkbox items (minimum: ${MIN_AC_ITEMS})"
        else
            fail "## Acceptance Criteria has ${ac_count} checkbox items; minimum ${MIN_AC_ITEMS} required"
        fi
    else
        fail "MISSING REQUIRED SECTION: ## Acceptance Criteria"
    fi

    # 3. Context section
    if has_section "Context"; then
        local context_ok=true

        if has_context_field "Category"; then
            pass "Context.Category field present"
        else
            fail "CONTEXT SECTION: Missing required 'Category:' field"
            context_ok=false
        fi

        if has_context_field "Component"; then
            pass "Context.Component field present"
        else
            fail "CONTEXT SECTION: Missing required 'Component:' field"
            context_ok=false
        fi

        if has_context_field "Priority"; then
            pass "Context.Priority field present"
        else
            warn "Context.Priority field missing (recommended)"
        fi

        if has_context_field "Template-Version"; then
            pass "Context.Template-Version field present"
        else
            warn "Context.Template-Version missing — add 'Template-Version: ${TEMPLATE_VERSION}' for quality tracking"
        fi
    else
        fail "MISSING REQUIRED SECTION: ## Context"
    fi

    # 4. Category validation
    local category_line
    category_line=$(echo "$BODY" | grep "^Category:" | head -1 | sed 's/Category: *//' || echo "")
    if [[ -n "$category_line" ]]; then
        case "$category_line" in
            bug|feature|tech-debt|docs|epic)
                pass "Category value is valid: '${category_line}'"
                ;;
            *)
                fail "Category value '${category_line}' is not one of: bug, feature, tech-debt, docs, epic"
                ;;
        esac
    fi

    # 5. Priority validation
    local priority_line
    priority_line=$(echo "$BODY" | grep "^Priority:" | head -1 | sed 's/Priority: *//' || echo "")
    if [[ -n "$priority_line" ]]; then
        case "$priority_line" in
            P0|P1|P2|P3)
                pass "Priority value is valid: '${priority_line}'"
                ;;
            *)
                fail "Priority value '${priority_line}' is not one of: P0, P1, P2, P3"
                ;;
        esac
    fi

    # 6. No empty sections check
    local empty_sections=0
    while IFS= read -r line; do
        if [[ "$line" == "## "* ]]; then
            local section_title="${line#\#\# }"
            if ! section_has_content "$section_title"; then
                warn "Section '## ${section_title}' appears to be empty"
                ((empty_sections++)) || true
            fi
        fi
    done <<< "$BODY"

    if [[ "$empty_sections" -eq 0 ]]; then
        pass "No empty sections detected"
    fi
}

# ---------------------------------------------------------------------------
# Bug-specific validation
# ---------------------------------------------------------------------------

validate_bug() {
    echo ""
    echo "Bug-Specific Schema Validation:"
    echo "────────────────────────────────"

    if has_section "Steps to Reproduce"; then
        if section_has_content "Steps to Reproduce"; then
            # Check for numbered list items
            local step_count
            step_count=$(echo "$BODY" | awk "/^## Steps to Reproduce/{found=1; next} found && /^## /{exit} found{print}" | grep -c "^[0-9]\+\." 2>/dev/null || echo "0")
            if [[ "$step_count" -ge 2 ]]; then
                pass "## Steps to Reproduce: ${step_count} numbered steps found (minimum: 2)"
            else
                fail "## Steps to Reproduce: Only ${step_count} numbered step(s) found; minimum 2 required"
            fi
        else
            fail "## Steps to Reproduce section is empty"
        fi
    else
        fail "MISSING REQUIRED SECTION for bug: ## Steps to Reproduce"
    fi

    if has_section "Expected Behavior"; then
        if section_has_content "Expected Behavior"; then
            pass "## Expected Behavior section present and non-empty"
        else
            fail "## Expected Behavior section is empty"
        fi
    else
        fail "MISSING REQUIRED SECTION for bug: ## Expected Behavior"
    fi

    if has_section "Actual Behavior"; then
        if section_has_content "Actual Behavior"; then
            pass "## Actual Behavior section present and non-empty"
        else
            fail "## Actual Behavior section is empty"
        fi
    else
        fail "MISSING REQUIRED SECTION for bug: ## Actual Behavior"
    fi

    # Check that Expected != Actual (common mistake)
    local expected_content
    local actual_content
    expected_content=$(echo "$BODY" | awk "/^## Expected Behavior/{found=1; next} found && /^## /{exit} found{print}" | tr -d ' \n' || echo "")
    actual_content=$(echo "$BODY" | awk "/^## Actual Behavior/{found=1; next} found && /^## /{exit} found{print}" | tr -d ' \n' || echo "")
    if [[ -n "$expected_content" && "$expected_content" == "$actual_content" ]]; then
        warn "## Expected Behavior and ## Actual Behavior appear identical — verify these are distinct"
    fi

    # Check for reproduction/fix/regression in AC
    local ac_content
    ac_content=$(echo "$BODY" | awk "/^## Acceptance Criteria/{found=1; next} found && /^## /{exit} found{print}" || echo "")
    if echo "$ac_content" | grep -qi "reproduc\|steps"; then
        pass "Acceptance Criteria: Reproduction check present"
    else
        warn "Acceptance Criteria: Consider adding a reproduction verification step"
    fi

    if echo "$ac_content" | grep -qi "regress\|existing test\|no change"; then
        pass "Acceptance Criteria: Regression check present"
    else
        warn "Acceptance Criteria: Consider adding a regression verification step"
    fi
}

# ---------------------------------------------------------------------------
# Feature-specific validation
# ---------------------------------------------------------------------------

validate_feature() {
    echo ""
    echo "Feature-Specific Schema Validation:"
    echo "─────────────────────────────────────"

    # User story section
    if has_section "User Story"; then
        local story_content
        story_content=$(echo "$BODY" | awk "/^## User Story/{found=1; next} found && /^## /{exit} found{print}" || echo "")
        if echo "$story_content" | grep -qi "as a\|as an"; then
            if echo "$story_content" | grep -qi "i want\|want to"; then
                if echo "$story_content" | grep -qi "so that\|in order to"; then
                    pass "## User Story follows 'As a / I want / so that' format"
                else
                    warn "## User Story: Missing 'so that' clause (benefit statement)"
                fi
            else
                warn "## User Story: Missing 'I want' clause (capability statement)"
            fi
        else
            fail "## User Story: Does not follow required 'As a [user], I want [X], so that [Y]' format"
        fi
    else
        if [[ "$STRICT_MODE" == "true" ]]; then
            fail "MISSING REQUIRED SECTION for feature (strict mode): ## User Story"
        else
            warn "MISSING RECOMMENDED SECTION for feature: ## User Story"
        fi
    fi

    # Details section
    if has_section "Details"; then
        if section_has_content "Details"; then
            pass "## Details section present and non-empty"
        else
            fail "## Details section is empty"
        fi
    else
        fail "MISSING REQUIRED SECTION for feature: ## Details"
    fi

    # Check AC for testing criteria
    local ac_content
    ac_content=$(echo "$BODY" | awk "/^## Acceptance Criteria/{found=1; next} found && /^## /{exit} found{print}" || echo "")
    if echo "$ac_content" | grep -qi "test\|spec\|coverage"; then
        pass "Acceptance Criteria: Testing requirement present"
    else
        warn "Acceptance Criteria: Consider adding a testing requirement (e.g., '- [ ] Tests added for new functionality')"
    fi
}

# ---------------------------------------------------------------------------
# Tech-debt-specific validation
# ---------------------------------------------------------------------------

validate_tech_debt() {
    echo ""
    echo "Tech-Debt-Specific Schema Validation:"
    echo "───────────────────────────────────────"

    if has_section "Current State"; then
        if section_has_content "Current State"; then
            pass "## Current State section present and non-empty"
        else
            fail "## Current State section is empty"
        fi
    else
        fail "MISSING REQUIRED SECTION for tech-debt: ## Current State"
    fi

    if has_section "Target State"; then
        if section_has_content "Target State"; then
            pass "## Target State section present and non-empty"
        else
            fail "## Target State section is empty"
        fi
    else
        fail "MISSING REQUIRED SECTION for tech-debt: ## Target State"
    fi

    if has_section "Success Metrics"; then
        if section_has_content "Success Metrics"; then
            # Look for Before/After metrics
            local metrics_content
            metrics_content=$(echo "$BODY" | awk "/^## Success Metrics/{found=1; next} found && /^## /{exit} found{print}" || echo "")
            if echo "$metrics_content" | grep -qi "before\|after\|from\|to\|→"; then
                pass "## Success Metrics: Before/after measurement found"
            else
                warn "## Success Metrics: Should include explicit before→after metrics (e.g., '450 lines → <250 lines')"
            fi
        else
            fail "## Success Metrics section is empty"
        fi
    else
        if [[ "$STRICT_MODE" == "true" ]]; then
            fail "MISSING REQUIRED SECTION for tech-debt (strict mode): ## Success Metrics"
        else
            warn "MISSING RECOMMENDED SECTION for tech-debt: ## Success Metrics"
        fi
    fi

    # Check AC for behavior preservation
    local ac_content
    ac_content=$(echo "$BODY" | awk "/^## Acceptance Criteria/{found=1; next} found && /^## /{exit} found{print}" || echo "")
    if echo "$ac_content" | grep -qi "behavior\|no change\|existing test\|pass"; then
        pass "Acceptance Criteria: Behavior preservation check present"
    else
        warn "Acceptance Criteria: Should include behavior preservation check (e.g., '- [ ] All existing tests pass')"
    fi
}

# ---------------------------------------------------------------------------
# Docs-specific validation
# ---------------------------------------------------------------------------

validate_docs() {
    echo ""
    echo "Docs-Specific Schema Validation:"
    echo "──────────────────────────────────"

    if has_section "Target Audience"; then
        if section_has_content "Target Audience"; then
            pass "## Target Audience section present and non-empty"
        else
            fail "## Target Audience section is empty"
        fi
    else
        if [[ "$STRICT_MODE" == "true" ]]; then
            fail "MISSING REQUIRED SECTION for docs (strict mode): ## Target Audience"
        else
            warn "MISSING RECOMMENDED SECTION for docs: ## Target Audience"
        fi
    fi

    if has_section "Scope"; then
        if section_has_content "Scope"; then
            pass "## Scope section present and non-empty"
        else
            fail "## Scope section is empty"
        fi
    else
        if [[ "$STRICT_MODE" == "true" ]]; then
            fail "MISSING REQUIRED SECTION for docs (strict mode): ## Scope"
        else
            warn "MISSING RECOMMENDED SECTION for docs: ## Scope"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Epic-specific validation
# ---------------------------------------------------------------------------

validate_epic() {
    echo ""
    echo "Epic-Specific Schema Validation:"
    echo "──────────────────────────────────"

    if has_section "Goals"; then
        if section_has_content "Goals"; then
            pass "## Goals section present and non-empty"
        else
            fail "## Goals section is empty"
        fi
    else
        fail "MISSING REQUIRED SECTION for epic: ## Goals"
    fi

    if has_section "Child Issues"; then
        pass "## Child Issues section present"
    else
        fail "MISSING REQUIRED SECTION for epic: ## Child Issues"
    fi

    # Check context has Type: Epic
    if echo "$BODY" | grep -q "^Type: Epic"; then
        pass "Context.Type field set to 'Epic'"
    else
        warn "Context section should include 'Type: Epic' for epic issues"
    fi
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

echo "======================================================"
echo "  Capture Output Validation — Template ${TEMPLATE_VERSION}"
echo "  Category: ${CATEGORY}"
echo "  Mode: $([ "$STRICT_MODE" == "true" ] && echo "STRICT" || echo "STANDARD")"
echo "======================================================"

# Run common validations
validate_common

# Run category-specific validations
case "$CATEGORY" in
    bug)
        validate_bug
        ;;
    feature)
        validate_feature
        ;;
    tech-debt|techdebt|tech_debt)
        validate_tech_debt
        ;;
    docs|documentation)
        validate_docs
        ;;
    epic)
        validate_epic
        ;;
    *)
        warn "Unknown category '${CATEGORY}' — only common schema validated"
        ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================================"
echo "  Validation Summary"
echo "======================================================"
echo "  ✅ Passed: ${PASS_COUNT}"
echo "  ❌ Failed: ${FAIL_COUNT}"
echo "  ⚠️  Warnings: ${#WARNINGS[@]}"
echo ""

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "VALIDATION FAILED — Issue body does not meet schema requirements."
    echo ""
    echo "Required fixes:"
    for error in "${ERRORS[@]}"; do
        echo "  • ${error}"
    done
    echo ""
    echo "Re-generate the issue body with instructions to include all required sections."
    exit 1
else
    echo "VALIDATION PASSED — Issue body meets schema requirements."
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo ""
        echo "Improvement suggestions:"
        for warning in "${WARNINGS[@]}"; do
            echo "  • ${warning}"
        done
    fi
    exit 0
fi
