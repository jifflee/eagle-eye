#!/usr/bin/env bash
set -euo pipefail
#
# Skill File Size Validator
# Validates skill/command file sizes per Anthropic guidance
# Reference: Issue #1027 - Anthropic recommends SKILL.md files <500 lines
#
# Anthropic guidance:
# - CLAUDE.md should be <500 lines
# - SKILL.md files should be <500 lines
# - Skill descriptions share 2% context budget (~16K chars)
# - Large skills cause instructions to be ignored/excluded
#

set -e

# Get repo root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/../../.." && pwd )"

# Source shared logging utilities
if [ -f "${REPO_DIR}/scripts/lib/common.sh" ]; then
    source "${REPO_DIR}/scripts/lib/common.sh"
else
    # Fallback if common.sh not available
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
fi

# Size thresholds (per Anthropic guidance)
WARN_THRESHOLD=400
ERROR_THRESHOLD=500

# Counters
TOTAL=0
PASSED=0
WARNINGS=0
ERRORS=0

# Options
ERRORS_ONLY=false
VERBOSE=false
SPECIFIC_FILE=""
FIX_MODE=false

usage() {
    cat << 'EOF'
Usage: check-skill-sizes.sh [options] [file]

Validate skill/command file sizes per Anthropic guidance.

Anthropic recommends:
  - CLAUDE.md files should be <500 lines
  - SKILL.md files should be <500 lines
  - Large skills waste context tokens and cause instructions to be ignored

Options:
  --errors-only     Show only errors, skip warnings
  --verbose         Show all files including passing ones
  --fix             Show refactoring suggestions for oversized files
  -h, --help        Show this help message

Thresholds:
  Warning:  Files > 400 lines (getting large)
  Error:    Files > 500 lines (exceeds Anthropic guidance)

Examples:
  ./scripts/ci/validators/check-skill-sizes.sh
  ./scripts/ci/validators/check-skill-sizes.sh --fix
  ./scripts/ci/validators/check-skill-sizes.sh --errors-only

Exit codes:
  0 - All validations passed (warnings are OK)
  1 - Errors found (files > 500 lines)
EOF
}

# Get line count
get_line_count() {
    wc -l < "$1" | tr -d ' '
}

# Suggest refactoring approach for specific files
suggest_refactoring() {
    local file="$1"
    local lines="$2"
    local basename=$(basename "$file" .md)

    echo -e "        ${YELLOW}Refactoring suggestion for $basename:${NC}"

    case "$basename" in
        sprint-work)
            echo "          → Split into: sprint-work.md (dispatcher <200 lines)"
            echo "          → Reference: docs/skills/sprint-work-guide.md (implementation details)"
            echo "          → Reference: docs/skills/sprint-work-states.md (state machine)"
            echo "          → Keep core skill focused on: what/when/why, inputs, outputs"
            ;;
        capture)
            echo "          → Split into: capture.md (dispatcher <200 lines)"
            echo "          → Reference: docs/skills/capture-triage.md (triage logic)"
            echo "          → Reference: docs/skills/capture-templates.md (issue templates)"
            echo "          → Keep core skill focused on: capture types, when to use, quick workflow"
            ;;
        sprint-status)
            echo "          → Split into: sprint-status.md (dispatcher <200 lines)"
            echo "          → Reference: docs/skills/sprint-status-metrics.md (metric calculations)"
            echo "          → Reference: docs/skills/sprint-status-display.md (formatting logic)"
            ;;
        repo-init|repo-init-claudetastic)
            echo "          → Split into: $basename.md (dispatcher <200 lines)"
            echo "          → Reference: docs/skills/${basename}-steps.md (step-by-step guide)"
            echo "          → Reference: docs/skills/${basename}-templates.md (file templates)"
            echo "          → Move templates to separate files, load on-demand"
            ;;
        refactor)
            echo "          → Split into: refactor.md (dispatcher <200 lines)"
            echo "          → Reference: docs/skills/refactor-patterns.md (refactoring patterns)"
            echo "          → Reference: docs/skills/refactor-detection.md (detection rules)"
            ;;
        merge-resolve)
            echo "          → Split into: merge-resolve.md (dispatcher <200 lines)"
            echo "          → Reference: docs/skills/merge-strategies.md (resolution strategies)"
            echo "          → Reference: docs/skills/merge-patterns.md (conflict patterns)"
            ;;
        audit-ui)
            echo "          → Split into: audit-ui.md (dispatcher <200 lines)"
            echo "          → Reference: docs/skills/audit-ui-checks.md (validation rules)"
            echo "          → Reference: docs/skills/audit-ui-standards.md (standards reference)"
            ;;
        *)
            echo "          → Split into: $basename.md (core skill <200 lines)"
            echo "          → Reference: docs/skills/${basename}-reference.md (detailed docs)"
            echo "          → Pattern: Dispatcher skill + on-demand reference files"
            ;;
    esac

    echo "          → See: docs/standards/DOC_SIZE_STANDARDS.md for splitting guidelines"
}

# Check single file
check_file() {
    local file="$1"
    local rel_path="${file#$REPO_DIR/}"
    ((TOTAL++)) || true

    local lines
    lines=$(get_line_count "$file")

    # Check for errors (> ERROR_THRESHOLD)
    if [ "$lines" -gt "$ERROR_THRESHOLD" ]; then
        ((ERRORS++)) || true
        echo -e "  ${RED}ERROR${NC} $rel_path: ${lines} lines (max: ${ERROR_THRESHOLD})"
        if [ "$FIX_MODE" = true ]; then
            suggest_refactoring "$file" "$lines"
        fi
        return 1
    fi

    # Check for warnings (> WARN_THRESHOLD)
    if [ "$lines" -gt "$WARN_THRESHOLD" ]; then
        ((WARNINGS++)) || true
        if [ "$ERRORS_ONLY" = false ]; then
            echo -e "  ${YELLOW}WARN${NC}  $rel_path: ${lines} lines (approaching limit)"
            if [ "$FIX_MODE" = true ]; then
                echo "        ${GRAY}→ Consider refactoring before it exceeds ${ERROR_THRESHOLD} lines${NC}"
            fi
        fi
        return 0
    fi

    # Under warning threshold
    ((PASSED++)) || true
    if [ "$VERBOSE" = true ]; then
        echo -e "  ${GREEN}PASS${NC}  $rel_path: ${lines} lines"
    fi
    return 0
}

# Main
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --errors-only)
                ERRORS_ONLY=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --fix)
                FIX_MODE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                SPECIFIC_FILE="$1"
                shift
                ;;
        esac
    done

    echo "Skill File Size Validation"
    echo "=========================="
    echo ""
    echo "Anthropic guidance: SKILL.md and CLAUDE.md files should be <500 lines"
    echo ""

    if [ -n "$SPECIFIC_FILE" ]; then
        # Check specific file
        if [ ! -f "$SPECIFIC_FILE" ]; then
            echo -e "${RED}Error: File not found: $SPECIFIC_FILE${NC}"
            exit 1
        fi
        check_file "$SPECIFIC_FILE"
    else
        # Check all skill files in .claude/commands/
        if [ -d "$REPO_DIR/.claude/commands" ]; then
            while IFS= read -r -d '' file; do
                check_file "$file"
            done < <(find "$REPO_DIR/.claude/commands" -name "*.md" -type f -print0 2>/dev/null)
        fi

        # Check all skill files in core/commands/
        if [ -d "$REPO_DIR/core/commands" ]; then
            while IFS= read -r -d '' file; do
                check_file "$file"
            done < <(find "$REPO_DIR/core/commands" -name "*.md" -type f -print0 2>/dev/null)
        fi

        # Check CLAUDE.md files
        for claude_file in "$REPO_DIR/CLAUDE.md" "$REPO_DIR/core/CLAUDE.md" "$REPO_DIR/repo-template/CLAUDE.md"; do
            if [ -f "$claude_file" ]; then
                check_file "$claude_file"
            fi
        done
    fi

    echo ""
    echo "Summary"
    echo "-------"
    echo "Total:    $TOTAL files"
    echo "Passed:   $PASSED files"
    echo "Warnings: $WARNINGS files (>400 lines, approaching limit)"
    echo "Errors:   $ERRORS files (>500 lines, EXCEEDS Anthropic guidance)"

    if [ "$ERRORS" -gt 0 ]; then
        echo ""
        echo -e "${RED}Validation failed: $ERRORS file(s) exceed 500 lines${NC}"
        echo ""
        echo "Anthropic guidance: Large skill files waste context tokens and cause"
        echo "instructions to be ignored. Split into focused SKILL.md (<500 lines)"
        echo "+ reference files loaded on-demand."
        echo ""
        if [ "$FIX_MODE" = false ]; then
            echo "Run with --fix flag to see refactoring suggestions:"
            echo "  ./scripts/ci/validators/check-skill-sizes.sh --fix"
        fi
        echo ""
        echo "See: docs/standards/DOC_SIZE_STANDARDS.md"
        echo "See: Issue #1027 for context"
        exit 1
    fi

    if [ "$WARNINGS" -gt 0 ] && [ "$ERRORS_ONLY" = false ]; then
        echo ""
        echo -e "${YELLOW}$WARNINGS warning(s): Files approaching 500 line limit${NC}"
        echo "Consider refactoring before they exceed the threshold."
    fi

    echo ""
    echo -e "${GREEN}Validation passed${NC}"
    exit 0
}

main "$@"
