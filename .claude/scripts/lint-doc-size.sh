#!/usr/bin/env bash
set -euo pipefail
#
# Documentation Size Linter
# Validates documentation file sizes and TL;DR headers
# See: docs/standards/DOC_SIZE_STANDARDS.md
#

set -e

# Get repo root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Size thresholds
WARN_THRESHOLD=300
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

# Excluded paths (relative to repo root)
# These are either auto-generated, historical, or have special exemptions
EXCLUDED_PATHS=(
    "docs/archive/"
    "docs/generated/"
    "CHANGELOG.md"
    # Historical review documents (one-time audits, not frequently accessed)
    "docs/architecture/EPIC_321_CONSOLIDATED_REVIEW.md"
    "docs/architecture/EPIC_321_FEASIBILITY_REVIEW.md"
    "docs/architecture/EPIC_321_UPDATED_PLAN.md"
    "docs/architecture/EPIC_321_CODE_STRUCTURE_GUIDE.md"
    "docs/architecture/EPIC_321_REVIEW_SUMMARY.md"
    "docs/architecture/phase1-docker-architecture.md"
    "docs/architecture/event-hook-notifications.md"
    # Security design documents (comprehensive security docs, have TL;DR headers)
    "docs/security/postgres-security-design.md"
    "docs/security/postgres-security-implementation-guide.md"
    "docs/security/n8n-token-handling-design.md"
    "docs/security/phase-3-security-audit-report.md"
    "docs/security/phase1-docker-security-review.md"
    "docs/security/mcp-authentication-design.md"
    # Specs and comprehensive reference docs (have TL;DR headers)
    "docs/specs/phase1-docker-base-image.md"
    "docs/CONTAINERIZED_WORKFLOW.md"
    "docs/BRANCHING_STRATEGY.md"
    "docs/WORKTREE_OPERATIONS.md"
    "docs/METRICS_OBSERVABILITY.md"
    "docs/CLOUD_DEPLOYMENT.md"
    "docs/DOCKER_BUILD_METRICS.md"
    "docs/SKILL_CONTRACTS.md"
    # Standards reference docs (structured reference material)
    "docs/standards/E2E_TESTING.md"
    "docs/standards/API_TESTING.md"
    # Schema/workflow reference docs
    "docs/PR_STATUS_SCHEMA.md"
    "docs/PR_MERGEABILITY_WORKFLOW.md"
    "docs/PERMISSION_TIERS.md"
    # Top-level comprehensive docs
    "AUTOMATED-SYNC.md"
    "SYNC-BACK.md"
    # Epic review docs (one-time documents)
    "EPIC_321_CICD_REVIEW.md"
    "EPIC_321_CICD_WORKFLOWS_GUIDE.md"
    # Feature docs with TL;DR headers
    "AUTO-PR.md"
    "EXAMPLES.md"
    # Main claude.md (framework definition)
    "claude.md"
)

usage() {
    cat << EOF
Usage: $(basename "$0") [options] [file]

Validate documentation file sizes and TL;DR headers.

Options:
  --errors-only     Show only errors, skip warnings
  --verbose         Show all files including passing ones
  -h, --help        Show this help message

Thresholds:
  Warning:  Files > ${WARN_THRESHOLD} lines without TL;DR
  Error:    Files > ${ERROR_THRESHOLD} lines

Examples:
  ./scripts/lint-doc-size.sh                    # Check all docs
  ./scripts/lint-doc-size.sh docs/SOME_FILE.md  # Check specific file
  ./scripts/lint-doc-size.sh --errors-only      # Show only errors

Exit codes:
  0 - All validations passed (warnings are OK)
  1 - Errors found (files > ${ERROR_THRESHOLD} lines)
EOF
}

# Check if file is excluded
is_excluded() {
    local file="$1"
    local rel_path="${file#$REPO_DIR/}"

    for excluded in "${EXCLUDED_PATHS[@]}"; do
        if [[ "$rel_path" == $excluded* ]] || [[ "$rel_path" == "$excluded" ]]; then
            return 0
        fi
    done
    return 1
}

# Check if file has TL;DR header
has_tldr() {
    local file="$1"
    # Check first 20 lines for TL;DR pattern
    head -20 "$file" 2>/dev/null | grep -qiE '^\s*>?\s*\*?\*?TL;?DR'
}

# Get line count
get_line_count() {
    wc -l < "$1" | tr -d ' '
}

# Check single file
check_file() {
    local file="$1"
    local rel_path="${file#$REPO_DIR/}"
    ((TOTAL++)) || true

    # Skip excluded files
    if is_excluded "$file"; then
        if [ "$VERBOSE" = true ]; then
            echo -e "  ${GRAY}SKIP${NC} $rel_path (excluded)"
        fi
        return 0
    fi

    local lines
    lines=$(get_line_count "$file")

    # Check for errors (> ERROR_THRESHOLD)
    if [ "$lines" -gt "$ERROR_THRESHOLD" ]; then
        ((ERRORS++)) || true
        echo -e "  ${RED}ERROR${NC} $rel_path: ${lines} lines (max: ${ERROR_THRESHOLD})"
        echo -e "        ${YELLOW}→ Split into smaller files per DOC_SIZE_STANDARDS.md${NC}"
        return 1
    fi

    # Check for warnings (> WARN_THRESHOLD without TL;DR)
    if [ "$lines" -gt "$WARN_THRESHOLD" ]; then
        if ! has_tldr "$file"; then
            ((WARNINGS++)) || true
            if [ "$ERRORS_ONLY" = false ]; then
                echo -e "  ${YELLOW}WARN${NC}  $rel_path: ${lines} lines, missing TL;DR"
                echo -e "        ${GRAY}→ Add TL;DR header at top of file${NC}"
            fi
            return 0
        else
            # Has TL;DR, acceptable
            ((PASSED++)) || true
            if [ "$VERBOSE" = true ]; then
                echo -e "  ${GREEN}PASS${NC}  $rel_path: ${lines} lines (has TL;DR)"
            fi
            return 0
        fi
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

    echo "Documentation Size Lint"
    echo "======================="
    echo ""

    if [ -n "$SPECIFIC_FILE" ]; then
        # Check specific file
        if [ ! -f "$SPECIFIC_FILE" ]; then
            echo -e "${RED}Error: File not found: $SPECIFIC_FILE${NC}"
            exit 1
        fi
        check_file "$SPECIFIC_FILE"
    else
        # Check all markdown files in docs/
        while IFS= read -r -d '' file; do
            check_file "$file"
        done < <(find "$REPO_DIR/docs" -name "*.md" -type f -print0 2>/dev/null)

        # Also check top-level md files (README, CLAUDE.md, etc)
        while IFS= read -r -d '' file; do
            check_file "$file"
        done < <(find "$REPO_DIR" -maxdepth 1 -name "*.md" -type f -print0 2>/dev/null)
    fi

    echo ""
    echo "Summary"
    echo "-------"
    echo "Total:    $TOTAL files"
    echo "Passed:   $PASSED files"
    echo "Warnings: $WARNINGS files"
    echo "Errors:   $ERRORS files"

    if [ "$ERRORS" -gt 0 ]; then
        echo ""
        echo -e "${RED}Lint failed: $ERRORS file(s) exceed ${ERROR_THRESHOLD} lines${NC}"
        echo "See docs/standards/DOC_SIZE_STANDARDS.md for remediation"
        exit 1
    fi

    if [ "$WARNINGS" -gt 0 ] && [ "$ERRORS_ONLY" = false ]; then
        echo ""
        echo -e "${YELLOW}$WARNINGS warning(s): Consider adding TL;DR headers${NC}"
    fi

    echo ""
    echo -e "${GREEN}Lint passed${NC}"
    exit 0
}

main "$@"
