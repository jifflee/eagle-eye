#!/bin/bash
# classify-error.sh - Classify errors and provide solution recommendations
#
# Usage:
#   ./scripts/classify-error.sh <error_message|error_file>
#   cat error.log | ./scripts/classify-error.sh
#
# Examples:
#   ./scripts/classify-error.sh "exit code 137"
#   ./scripts/classify-error.sh error.log
#   cat ci-failure.log | ./scripts/classify-error.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOLUTIONS_FILE="${PROJECT_ROOT}/config/error-solutions.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check dependencies
check_dependencies() {
    local missing_deps=()

    for cmd in yq grep sed; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Install with: apt-get install yq grep sed"
        exit 1
    fi
}

# Parse error message from input
get_error_message() {
    local input="${1:-}"

    if [ -z "$input" ]; then
        # Read from stdin if available
        if [ -p /dev/stdin ]; then
            cat
        else
            echo ""
        fi
    elif [ -f "$input" ]; then
        # Read from file
        cat "$input"
    else
        # Use as direct message
        echo "$input"
    fi
}

# Classify error severity based on patterns
classify_severity() {
    local error_msg="$1"

    # Critical patterns
    if echo "$error_msg" | grep -qiE "(segfault|core dump|panic|fatal|critical|OOMKilled|exit code 137)"; then
        echo "CRITICAL"
    # High severity patterns
    elif echo "$error_msg" | grep -qiE "(error|failed|failure|exception|timeout|denied|unauthorized|forbidden|refused|exited.*code|exit code|rate limit|token limit|exceeded)"; then
        echo "HIGH"
    # Medium severity patterns
    elif echo "$error_msg" | grep -qiE "(warning|deprecated|invalid|conflict)"; then
        echo "MEDIUM"
    # Low severity
    else
        echo "LOW"
    fi
}

# Extract error type/category
classify_type() {
    local error_msg="$1"

    if echo "$error_msg" | grep -qiE "(OOMKilled|out of memory|exit code 137)"; then
        echo "RESOURCE_EXHAUSTION"
    elif echo "$error_msg" | grep -qiE "(claude.*timeout|anthropic.*timeout|claude.*timed out|model.*timeout)"; then
        echo "CLAUDE_API"
    elif echo "$error_msg" | grep -qiE "(token limit|context.*too long|max.*tokens.*exceeded|prompt.*too large|context window)"; then
        echo "CLAUDE_API"
    elif echo "$error_msg" | grep -qiE "(anthropic.*rate limit|claude.*rate limit|overloaded_error)"; then
        echo "CLAUDE_API"
    elif echo "$error_msg" | grep -qiE "(container.*timeout|container.*failed|container.*exited|watchdog.*timeout)"; then
        echo "CONTAINER"
    elif echo "$error_msg" | grep -qiE "(401|403|unauthorized|forbidden|token.*expired)"; then
        echo "AUTHENTICATION"
    elif echo "$error_msg" | grep -qiE "(timeout|timed out|deadline exceeded)"; then
        echo "TIMEOUT"
    elif echo "$error_msg" | grep -qiE "(merge conflict|CONFLICT)"; then
        echo "VERSION_CONTROL"
    elif echo "$error_msg" | grep -qiE "(429|rate limit)"; then
        echo "RATE_LIMIT"
    elif echo "$error_msg" | grep -qiE "(not found|404|ENOENT|ModuleNotFoundError)"; then
        echo "NOT_FOUND"
    elif echo "$error_msg" | grep -qiE "(permission denied|EACCES)"; then
        echo "PERMISSION"
    elif echo "$error_msg" | grep -qiE "(connection.*failed|ECONNREFUSED)"; then
        echo "NETWORK"
    elif echo "$error_msg" | grep -qiE "(disk.*full|no space|ENOSPC)"; then
        echo "STORAGE"
    elif echo "$error_msg" | grep -qiE "(syntax error|parse error)"; then
        echo "SYNTAX"
    else
        echo "UNKNOWN"
    fi
}

# Find matching solutions from database
find_solutions() {
    local error_msg="$1"
    local min_confidence="${2:-60}"

    if [ ! -f "$SOLUTIONS_FILE" ]; then
        log_warning "Solutions file not found: $SOLUTIONS_FILE"
        return 0
    fi

    # Get number of solutions
    local num_solutions=$(yq eval '.solutions | length' "$SOLUTIONS_FILE")
    local matches=()

    for ((i=0; i<num_solutions; i++)); do
        local pattern=$(yq eval ".solutions[$i].error_pattern" "$SOLUTIONS_FILE")
        local solution_id=$(yq eval ".solutions[$i].id" "$SOLUTIONS_FILE")
        local confidence=$(yq eval ".solutions[$i].confidence_threshold" "$SOLUTIONS_FILE")

        # Remove quotes from pattern
        pattern=$(echo "$pattern" | sed 's/^"//;s/"$//')

        # Check if error matches pattern (case-insensitive, extended regex)
        if echo "$error_msg" | grep -qiE "$pattern"; then
            if [ "$confidence" -ge "$min_confidence" ]; then
                matches+=("$i:$confidence")
            fi
        fi
    done

    # Sort by confidence (descending) and return indices
    if [ ${#matches[@]} -gt 0 ]; then
        printf '%s\n' "${matches[@]}" | sort -t: -k2 -nr | cut -d: -f1
    fi
}

# Display solution details
display_solution() {
    local solution_idx="$1"
    local rank="${2:-1}"

    local id=$(yq eval ".solutions[$solution_idx].id" "$SOLUTIONS_FILE")
    local description=$(yq eval ".solutions[$solution_idx].description" "$SOLUTIONS_FILE")
    local auto_fixable=$(yq eval ".solutions[$solution_idx].auto_fixable" "$SOLUTIONS_FILE")
    local confidence=$(yq eval ".solutions[$solution_idx].confidence_threshold" "$SOLUTIONS_FILE")
    local tags=$(yq eval ".solutions[$solution_idx].tags[]" "$SOLUTIONS_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Solution #$rank: $id${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Description:${NC} $description"
    echo -e "${BLUE}Auto-fixable:${NC} $auto_fixable"
    echo -e "${BLUE}Confidence:${NC} $confidence%"
    if [ -n "$tags" ]; then
        echo -e "${BLUE}Tags:${NC} $tags"
    fi
    echo ""
    echo -e "${YELLOW}Resolution Steps:${NC}"

    local num_steps=$(yq eval ".solutions[$solution_idx].resolution_steps | length" "$SOLUTIONS_FILE")
    for ((j=0; j<num_steps; j++)); do
        local step=$(yq eval ".solutions[$solution_idx].resolution_steps[$j]" "$SOLUTIONS_FILE")
        echo "  $((j+1)). $step"
    done

    if [ "$auto_fixable" = "true" ]; then
        echo ""
        echo -e "${GREEN}✓ Auto-fix available${NC}"
        echo -e "  Run: ${MAGENTA}./scripts/auto-fix-error.sh --solution-id $id${NC}"
    fi
    echo ""
}

# Output classification results as JSON
output_json() {
    local error_msg="$1"
    local severity="$2"
    local error_type="$3"
    local solutions_indices="$4"

    # Calculate top-level confidence from best solution match
    local top_confidence=0
    if [ -n "$solutions_indices" ]; then
        for idx in $solutions_indices; do
            local conf=$(yq eval ".solutions[$idx].confidence_threshold" "$SOLUTIONS_FILE")
            if [ "$conf" -gt "$top_confidence" ]; then
                top_confidence="$conf"
            fi
        done
    fi

    echo "{"
    echo "  \"error_type\": \"$error_type\","
    echo "  \"confidence\": $top_confidence,"
    echo "  \"context\": {"
    echo "    \"error_message\": \"$(echo "$error_msg" | head -c 200 | sed 's/"/\\"/g')\","
    echo "    \"severity\": \"$severity\","
    echo "    \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
    echo "  },"

    if [ -n "$solutions_indices" ]; then
        echo "  \"solutions\": ["
        local first=true
        for idx in $solutions_indices; do
            if [ "$first" = false ]; then
                echo ","
            fi
            first=false

            local id=$(yq eval ".solutions[$idx].id" "$SOLUTIONS_FILE")
            local description=$(yq eval ".solutions[$idx].description" "$SOLUTIONS_FILE" | sed 's/"/\\"/g')
            local auto_fixable=$(yq eval ".solutions[$idx].auto_fixable" "$SOLUTIONS_FILE")
            local confidence=$(yq eval ".solutions[$idx].confidence_threshold" "$SOLUTIONS_FILE")

            echo -n "    {"
            echo -n "\"id\": \"$id\", "
            echo -n "\"description\": \"$description\", "
            echo -n "\"auto_fixable\": $auto_fixable, "
            echo -n "\"confidence\": $confidence"
            echo -n "}"
        done
        echo ""
        echo "  ]"
    else
        echo "  \"solutions\": []"
    fi

    echo "}"
}

# Main function
main() {
    local error_input=""
    local output_format="human"
    local min_confidence=60
    local max_solutions=3

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json)
                output_format="json"
                shift
                ;;
            --min-confidence)
                min_confidence="$2"
                shift 2
                ;;
            --max-solutions)
                max_solutions="$2"
                shift 2
                ;;
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS] [ERROR_MESSAGE|ERROR_FILE]

Classify errors and provide solution recommendations.

OPTIONS:
    --json                  Output results as JSON
    --min-confidence NUM    Minimum confidence threshold (default: 60)
    --max-solutions NUM     Maximum number of solutions to display (default: 3)
    -h, --help              Show this help message

EXAMPLES:
    # Classify error from message
    $0 "exit code 137"

    # Classify error from file
    $0 error.log

    # Read from pipe
    cat ci-failure.log | $0

    # JSON output
    $0 --json "authentication failed"

EOF
                exit 0
                ;;
            *)
                error_input="$1"
                shift
                ;;
        esac
    done

    check_dependencies

    # Get error message
    local error_msg=$(get_error_message "$error_input")

    if [ -z "$error_msg" ]; then
        log_error "No error message provided"
        exit 1
    fi

    # Classify error
    local severity=$(classify_severity "$error_msg")
    local error_type=$(classify_type "$error_msg")

    # Find matching solutions
    local solutions_indices=$(find_solutions "$error_msg" "$min_confidence")

    # Limit number of solutions
    if [ -n "$solutions_indices" ]; then
        solutions_indices=$(echo "$solutions_indices" | head -n "$max_solutions")
    fi

    # Output results
    if [ "$output_format" = "json" ]; then
        output_json "$error_msg" "$severity" "$error_type" "$solutions_indices"
    else
        # Human-readable output
        echo ""
        echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║            ERROR CLASSIFICATION RESULTS                    ║${NC}"
        echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${BLUE}Error Message:${NC}"
        echo "$error_msg" | head -c 500
        echo ""
        echo ""
        echo -e "${BLUE}Severity:${NC} ${RED}$severity${NC}"
        echo -e "${BLUE}Type:${NC} $error_type"
        echo -e "${BLUE}Timestamp:${NC} $(date -u +"%Y-%m-%d %H:%M:%S UTC")"

        if [ -n "$solutions_indices" ]; then
            local num_solutions=$(echo "$solutions_indices" | wc -l)
            echo ""
            echo -e "${GREEN}Found $num_solutions matching solution(s):${NC}"

            local rank=1
            for idx in $solutions_indices; do
                display_solution "$idx" "$rank"
                rank=$((rank + 1))
            done

            # Show auto-fix hint
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}Tip:${NC} Use ${MAGENTA}./scripts/auto-fix-error.sh${NC} to automatically apply fixes"
            echo ""
        else
            echo ""
            log_warning "No matching solutions found in database"
            log_info "Consider adding this error pattern to $SOLUTIONS_FILE"
            echo ""
        fi
    fi
}

main "$@"
