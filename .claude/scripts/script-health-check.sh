#!/usr/bin/env bash
# Script Health Check - Comprehensive verification system
# Ensures documentation aligns with scripts, tracks usage, detects duplicates
#
# Usage: ./scripts/script-health-check.sh [options]
#
# Options:
#   --json                Output results as JSON
#   --verbose             Show detailed output
#   --baseline FILE       Path to baseline exceptions file
#   --scripts-dir DIR     Directory containing scripts (default: scripts/)
#   --docs-dir DIR        Directory containing docs (default: docs/)
#   --help               Show this help message
#
# Exit codes:
#   0 - All checks passed
#   1 - Health issues found
#   2 - Invalid arguments

set -euo pipefail

# Default values
SCRIPTS_DIR="scripts"
DOCS_DIR="docs"
OUTPUT_JSON=false
VERBOSE=false
BASELINE_FILE=""
REPO_ROOT="$(git rev-root 2>/dev/null || pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Results storage
declare -A ORPHANED_SCRIPTS
declare -A LOW_USAGE_SCRIPTS
declare -A DUPLICATE_CANDIDATES
declare -A DOC_MISALIGNMENTS
TOTAL_SCRIPTS=0
TOTAL_REFS=0
HEALTH_SCORE=100

usage() {
    grep '^#' "$0" | grep -v '#!/' | cut -c 3-
    exit 2
}

log() {
    if [[ "$VERBOSE" == "true" ]] || [[ "$OUTPUT_JSON" == "false" ]]; then
        echo -e "$@" >&2
    fi
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "$@" >&2
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json)
                OUTPUT_JSON=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --baseline)
                BASELINE_FILE="$2"
                shift 2
                ;;
            --scripts-dir)
                SCRIPTS_DIR="$2"
                shift 2
                ;;
            --docs-dir)
                DOCS_DIR="$2"
                shift 2
                ;;
            --help)
                usage
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                ;;
        esac
    done
}

# Extract script contract (usage, flags, arguments)
extract_script_contract() {
    local script="$1"
    local contract=""

    # Try to extract usage from header comments
    local usage_text=$(grep -E '^#.*Usage:' -A 10 "$script" 2>/dev/null | grep '^#' | sed 's/^# *//' || true)

    # Try to extract flags from getopts or case statements
    local flags=$(grep -oE '(-[a-zA-Z]|--[a-zA-Z0-9-]+)' "$script" 2>/dev/null | sort -u || true)

    # Extract options from header
    local options=$(grep -E '^#.*Options:' -A 20 "$script" 2>/dev/null | grep '^#' | grep -E '^\s*--?' | sed 's/^# *//' || true)

    echo "$usage_text"$'\n'"$options"$'\n'"$flags"
}

# Find all script references in documentation
find_script_references() {
    local script_name="$1"
    local count=0
    local references=""

    # Search in docs, skills, workflows, and other scripts
    local search_patterns=(
        "$DOCS_DIR"
        "skills"
        ".github"
        "CLAUDE.md"
        "README.md"
    )

    for pattern in "${search_patterns[@]}"; do
        if [[ -e "$pattern" ]]; then
            local results=$(grep -r -l "$script_name" "$pattern" 2>/dev/null || true)
            if [[ -n "$results" ]]; then
                count=$((count + $(echo "$results" | wc -l)))
                references="$references"$'\n'"$results"
            fi
        fi
    done

    echo "$count|$references"
}

# Detect potential duplicate scripts
detect_duplicates() {
    local script="$1"
    local script_name=$(basename "$script")
    local script_purpose=$(head -20 "$script" | grep -E '^#' | grep -v '#!/' | head -5 || true)

    # Compare with other scripts
    for other_script in "$SCRIPTS_DIR"/*.sh; do
        if [[ "$script" != "$other_script" ]] && [[ -f "$other_script" ]]; then
            local other_name=$(basename "$other_script")
            local other_purpose=$(head -20 "$other_script" | grep -E '^#' | grep -v '#!/' | head -5 || true)

            # Check name similarity
            local name_similarity=$(check_name_similarity "$script_name" "$other_name")

            # Check purpose similarity
            local purpose_similarity=$(check_text_similarity "$script_purpose" "$other_purpose")

            if [[ $name_similarity -gt 60 ]] || [[ $purpose_similarity -gt 70 ]]; then
                echo "$other_name|$name_similarity|$purpose_similarity"
            fi
        fi
    done
}

# Check name similarity (basic Levenshtein-like comparison)
check_name_similarity() {
    local name1="$1"
    local name2="$2"

    # Simple similarity check based on common substrings
    local common=$(comm -12 <(echo "$name1" | fold -w1 | sort) <(echo "$name2" | fold -w1 | sort) | wc -l)
    local total=$(( ${#name1} + ${#name2} ))

    if [[ $total -eq 0 ]]; then
        echo 0
    else
        echo $(( common * 200 / total ))
    fi
}

# Check text similarity
check_text_similarity() {
    local text1="$1"
    local text2="$2"

    # Count common words
    local words1=$(echo "$text1" | tr ' ' '\n' | sort -u)
    local words2=$(echo "$text2" | tr ' ' '\n' | sort -u)

    local common=$(comm -12 <(echo "$words1") <(echo "$words2") | wc -l)
    local total=$(comm -3 <(echo "$words1") <(echo "$words2") | wc -l)

    if [[ $total -eq 0 ]]; then
        echo 0
    else
        echo $(( common * 100 / (common + total) ))
    fi
}

# Check documentation alignment
check_doc_alignment() {
    local script="$1"
    local script_name=$(basename "$script")
    local misalignments=""

    # Extract script contract
    local contract=$(extract_script_contract "$script")

    # Find documentation references
    local doc_files=$(grep -r -l "$script_name" "$DOCS_DIR" 2>/dev/null || true)

    if [[ -z "$doc_files" ]]; then
        return 0
    fi

    # Extract flags from script
    local script_flags=$(echo "$contract" | grep -oE '(--[a-zA-Z0-9-]+)' | sort -u || true)

    # Check each doc file for flag mentions
    while IFS= read -r doc_file; do
        if [[ -n "$doc_file" ]]; then
            local doc_flags=$(grep -oE '(--[a-zA-Z0-9-]+)' "$doc_file" 2>/dev/null | sort -u || true)

            # Find flags in docs but not in script
            while IFS= read -r flag; do
                if [[ -n "$flag" ]] && ! echo "$script_flags" | grep -q "^$flag$"; then
                    misalignments="$misalignments|Doc mentions $flag but script doesn't have it ($doc_file)"
                fi
            done <<< "$doc_flags"
        fi
    done <<< "$doc_files"

    echo "$misalignments"
}

# Main health check
run_health_check() {
    log "${BLUE}=== Script Health Check ===${NC}\n"

    # Find all scripts
    if [[ ! -d "$SCRIPTS_DIR" ]]; then
        log "${RED}Error: Scripts directory not found: $SCRIPTS_DIR${NC}"
        exit 2
    fi

    local scripts=($(find "$SCRIPTS_DIR" -name "*.sh" -type f))
    TOTAL_SCRIPTS=${#scripts[@]}

    log_verbose "Found $TOTAL_SCRIPTS scripts in $SCRIPTS_DIR"

    # Analyze each script
    for script in "${scripts[@]}"; do
        local script_name=$(basename "$script")
        log_verbose "\nAnalyzing: $script_name"

        # Check last modification time
        local last_modified=$(stat -f "%Sm" -t "%Y-%m-%d" "$script" 2>/dev/null || stat -c "%y" "$script" 2>/dev/null | cut -d' ' -f1)
        local days_old=$(( ($(date +%s) - $(date -d "$last_modified" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$last_modified" +%s 2>/dev/null || echo 0)) / 86400 ))

        # Find references
        local ref_data=$(find_script_references "$script_name")
        local ref_count=$(echo "$ref_data" | cut -d'|' -f1)
        local ref_files=$(echo "$ref_data" | cut -d'|' -f2-)

        TOTAL_REFS=$((TOTAL_REFS + ref_count))

        # Classify scripts
        if [[ $ref_count -eq 0 ]]; then
            ORPHANED_SCRIPTS["$script_name"]="$last_modified|$days_old days ago"
            log_verbose "  ${RED}✗${NC} Orphaned (0 references)"
        elif [[ $ref_count -eq 1 ]]; then
            LOW_USAGE_SCRIPTS["$script_name"]="$ref_files"
            log_verbose "  ${YELLOW}!${NC} Low usage (1 reference)"
        else
            log_verbose "  ${GREEN}✓${NC} Active ($ref_count references)"
        fi

        # Check for duplicates
        local duplicates=$(detect_duplicates "$script")
        if [[ -n "$duplicates" ]]; then
            DUPLICATE_CANDIDATES["$script_name"]="$duplicates"
            log_verbose "  ${YELLOW}!${NC} Potential duplicates found"
        fi

        # Check documentation alignment
        local misalignments=$(check_doc_alignment "$script")
        if [[ -n "$misalignments" ]]; then
            DOC_MISALIGNMENTS["$script_name"]="$misalignments"
            log_verbose "  ${YELLOW}!${NC} Documentation misalignment detected"
        fi
    done

    # Calculate health score
    calculate_health_score
}

# Calculate overall health score
calculate_health_score() {
    local deductions=0

    # Deduct points for orphaned scripts (5 points each)
    deductions=$((deductions + ${#ORPHANED_SCRIPTS[@]} * 5))

    # Deduct points for low usage scripts (2 points each)
    deductions=$((deductions + ${#LOW_USAGE_SCRIPTS[@]} * 2))

    # Deduct points for duplicates (3 points each)
    deductions=$((deductions + ${#DUPLICATE_CANDIDATES[@]} * 3))

    # Deduct points for misalignments (4 points each)
    deductions=$((deductions + ${#DOC_MISALIGNMENTS[@]} * 4))

    HEALTH_SCORE=$((100 - deductions))
    if [[ $HEALTH_SCORE -lt 0 ]]; then
        HEALTH_SCORE=0
    fi
}

# Output results as JSON
output_json() {
    echo "{"
    echo "  \"health_score\": $HEALTH_SCORE,"
    echo "  \"total_scripts\": $TOTAL_SCRIPTS,"
    echo "  \"total_references\": $TOTAL_REFS,"
    echo "  \"orphaned_scripts\": {"

    local first=true
    for script in "${!ORPHANED_SCRIPTS[@]}"; do
        if [[ "$first" == "false" ]]; then echo ","; fi
        first=false
        local info="${ORPHANED_SCRIPTS[$script]}"
        local modified=$(echo "$info" | cut -d'|' -f1)
        local age=$(echo "$info" | cut -d'|' -f2)
        echo -n "    \"$script\": {\"last_modified\": \"$modified\", \"age\": \"$age\"}"
    done
    echo ""
    echo "  },"

    echo "  \"low_usage_scripts\": {"
    first=true
    for script in "${!LOW_USAGE_SCRIPTS[@]}"; do
        if [[ "$first" == "false" ]]; then echo ","; fi
        first=false
        echo -n "    \"$script\": \"${LOW_USAGE_SCRIPTS[$script]}\""
    done
    echo ""
    echo "  },"

    echo "  \"duplicate_candidates\": {"
    first=true
    for script in "${!DUPLICATE_CANDIDATES[@]}"; do
        if [[ "$first" == "false" ]]; then echo ","; fi
        first=false
        echo -n "    \"$script\": \"${DUPLICATE_CANDIDATES[$script]}\""
    done
    echo ""
    echo "  },"

    echo "  \"doc_misalignments\": {"
    first=true
    for script in "${!DOC_MISALIGNMENTS[@]}"; do
        if [[ "$first" == "false" ]]; then echo ","; fi
        first=false
        echo -n "    \"$script\": \"${DOC_MISALIGNMENTS[$script]}\""
    done
    echo ""
    echo "  }"
    echo "}"
}

# Output results as human-readable text
output_text() {
    echo ""
    echo "## Script Health Report"
    echo ""

    if [[ ${#ORPHANED_SCRIPTS[@]} -gt 0 ]]; then
        echo "### Orphaned Scripts (no references found)"
        for script in "${!ORPHANED_SCRIPTS[@]}"; do
            local info="${ORPHANED_SCRIPTS[$script]}"
            local modified=$(echo "$info" | cut -d'|' -f1)
            local age=$(echo "$info" | cut -d'|' -f2)
            echo "- $script - Last modified: $modified ($age)"
        done
        echo ""
    fi

    if [[ ${#LOW_USAGE_SCRIPTS[@]} -gt 0 ]]; then
        echo "### Low Usage Scripts (1 reference)"
        for script in "${!LOW_USAGE_SCRIPTS[@]}"; do
            local refs="${LOW_USAGE_SCRIPTS[$script]}"
            echo "- $script - Referenced in: $refs"
        done
        echo ""
    fi

    if [[ ${#DUPLICATE_CANDIDATES[@]} -gt 0 ]]; then
        echo "### Potential Duplicates"
        for script in "${!DUPLICATE_CANDIDATES[@]}"; do
            echo "- $script - Similar to: ${DUPLICATE_CANDIDATES[$script]}"
        done
        echo ""
    fi

    if [[ ${#DOC_MISALIGNMENTS[@]} -gt 0 ]]; then
        echo "### Documentation Misalignments"
        for script in "${!DOC_MISALIGNMENTS[@]}"; do
            echo "- $script: ${DOC_MISALIGNMENTS[$script]}"
        done
        echo ""
    fi

    echo "### Health Score: $HEALTH_SCORE/100"
    echo ""
    echo "Summary:"
    echo "- Total scripts: $TOTAL_SCRIPTS"
    echo "- Total references: $TOTAL_REFS"
    echo "- Orphaned: ${#ORPHANED_SCRIPTS[@]}"
    echo "- Low usage: ${#LOW_USAGE_SCRIPTS[@]}"
    echo "- Potential duplicates: ${#DUPLICATE_CANDIDATES[@]}"
    echo "- Doc misalignments: ${#DOC_MISALIGNMENTS[@]}"
}

# Main execution
main() {
    parse_args "$@"

    run_health_check

    if [[ "$OUTPUT_JSON" == "true" ]]; then
        output_json
    else
        output_text
    fi

    # Exit with error if health score is below threshold
    if [[ $HEALTH_SCORE -lt 70 ]]; then
        exit 1
    fi

    exit 0
}

main "$@"
