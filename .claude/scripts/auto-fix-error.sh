#!/bin/bash
# auto-fix-error.sh - Automatically fix errors using the solution database
#
# Usage:
#   ./scripts/auto-fix-error.sh <error_message|error_file>
#   ./scripts/auto-fix-error.sh --solution-id <solution_id>
#
# Examples:
#   ./scripts/auto-fix-error.sh "exit code 137"
#   ./scripts/auto-fix-error.sh --solution-id oom_kill
#   cat error.log | ./scripts/auto-fix-error.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOLUTIONS_FILE="${PROJECT_ROOT}/config/error-solutions.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    local input="$1"

    if [ -f "$input" ]; then
        # Read from file
        cat "$input"
    elif [ -p /dev/stdin ]; then
        # Read from pipe
        cat
    else
        # Use as direct message
        echo "$input"
    fi
}

# Find matching solutions for error message
find_solutions() {
    local error_msg="$1"
    local min_confidence="${2:-80}"

    if [ ! -f "$SOLUTIONS_FILE" ]; then
        log_error "Solutions file not found: $SOLUTIONS_FILE"
        exit 1
    fi

    log_info "Searching for matching solutions..."

    # Get number of solutions
    local num_solutions=$(yq eval '.solutions | length' "$SOLUTIONS_FILE")
    local matches=()

    for ((i=0; i<num_solutions; i++)); do
        local pattern=$(yq eval ".solutions[$i].error_pattern" "$SOLUTIONS_FILE")
        local solution_id=$(yq eval ".solutions[$i].id" "$SOLUTIONS_FILE")
        local confidence=$(yq eval ".solutions[$i].confidence_threshold" "$SOLUTIONS_FILE")
        local auto_fixable=$(yq eval ".solutions[$i].auto_fixable" "$SOLUTIONS_FILE")

        # Remove quotes and extract pattern
        pattern=$(echo "$pattern" | sed 's/^"//;s/"$//')

        # Check if error matches pattern (case-insensitive, extended regex)
        if echo "$error_msg" | grep -qiE "$pattern"; then
            if [ "$confidence" -ge "$min_confidence" ] && [ "$auto_fixable" = "true" ]; then
                matches+=("$solution_id:$confidence")
                log_success "Found match: $solution_id (confidence: $confidence%)"
            elif [ "$auto_fixable" = "false" ]; then
                log_warning "Match found but not auto-fixable: $solution_id"
            else
                log_warning "Match found but confidence too low: $solution_id ($confidence% < $min_confidence%)"
            fi
        fi
    done

    # Sort by confidence (descending) and return IDs
    if [ ${#matches[@]} -gt 0 ]; then
        printf '%s\n' "${matches[@]}" | sort -t: -k2 -nr | cut -d: -f1
    fi
}

# Get solution by ID
get_solution() {
    local solution_id="$1"

    local num_solutions=$(yq eval '.solutions | length' "$SOLUTIONS_FILE")

    for ((i=0; i<num_solutions; i++)); do
        local id=$(yq eval ".solutions[$i].id" "$SOLUTIONS_FILE")
        if [ "$id" = "$solution_id" ]; then
            echo "$i"
            return 0
        fi
    done

    return 1
}

# Display solution details
display_solution() {
    local solution_idx="$1"

    local id=$(yq eval ".solutions[$solution_idx].id" "$SOLUTIONS_FILE")
    local description=$(yq eval ".solutions[$solution_idx].description" "$SOLUTIONS_FILE")
    local auto_fixable=$(yq eval ".solutions[$solution_idx].auto_fixable" "$SOLUTIONS_FILE")
    local confidence=$(yq eval ".solutions[$solution_idx].confidence_threshold" "$SOLUTIONS_FILE")

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Solution: $id"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Description: $description"
    echo "Auto-fixable: $auto_fixable"
    echo "Confidence: $confidence%"
    echo ""
    echo "Resolution Steps:"

    local num_steps=$(yq eval ".solutions[$solution_idx].resolution_steps | length" "$SOLUTIONS_FILE")
    for ((j=0; j<num_steps; j++)); do
        local step=$(yq eval ".solutions[$solution_idx].resolution_steps[$j]" "$SOLUTIONS_FILE")
        echo "  $((j+1)). $step"
    done
    echo ""
}

# Execute auto-fix command
execute_fix() {
    local solution_idx="$1"
    local dry_run="${2:-false}"

    local id=$(yq eval ".solutions[$solution_idx].id" "$SOLUTIONS_FILE")
    local fix_command=$(yq eval ".solutions[$solution_idx].fix_command" "$SOLUTIONS_FILE")

    # Remove leading/trailing quotes and pipes
    fix_command=$(echo "$fix_command" | sed 's/^["|]//;s/["|]$//')

    if [ "$dry_run" = "true" ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Fix Command (DRY RUN):"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$fix_command"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 0
    fi

    log_info "Executing auto-fix for solution: $id"
    echo ""

    # Execute fix command
    if eval "$fix_command"; then
        log_success "Auto-fix executed successfully!"
        return 0
    else
        log_error "Auto-fix failed with exit code: $?"
        return 1
    fi
}

# Main function
main() {
    local error_input=""
    local solution_id=""
    local dry_run=false
    local force=false
    local min_confidence=80

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --solution-id)
                solution_id="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --force)
                force=true
                shift
                ;;
            --min-confidence)
                min_confidence="$2"
                shift 2
                ;;
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS] [ERROR_MESSAGE|ERROR_FILE]

Auto-fix errors using the solution database.

OPTIONS:
    --solution-id ID        Apply specific solution by ID
    --dry-run               Show fix command without executing
    --force                 Skip confirmation prompt
    --min-confidence NUM    Minimum confidence threshold (default: 80)
    -h, --help              Show this help message

EXAMPLES:
    # Fix by error message
    $0 "exit code 137"

    # Fix by solution ID
    $0 --solution-id oom_kill

    # Read from file
    $0 error.log

    # Read from pipe
    cat error.log | $0

    # Dry run
    $0 --dry-run "timeout error"

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

    # Get error message if not using solution ID
    if [ -z "$solution_id" ]; then
        if [ -z "$error_input" ]; then
            log_error "No error message or solution ID provided"
            log_info "Use --help for usage information"
            exit 1
        fi

        local error_msg=$(get_error_message "$error_input")

        if [ -z "$error_msg" ]; then
            log_error "No error message found"
            exit 1
        fi

        log_info "Error message: $error_msg"

        # Find matching solutions
        local solutions=($(find_solutions "$error_msg" "$min_confidence"))

        if [ ${#solutions[@]} -eq 0 ]; then
            log_warning "No auto-fixable solutions found for this error"
            log_info "Try lowering --min-confidence or check solutions database"
            exit 1
        fi

        # Use highest confidence solution
        solution_id="${solutions[0]}"
    fi

    # Get solution index
    local solution_idx=$(get_solution "$solution_id")

    if [ -z "$solution_idx" ]; then
        log_error "Solution not found: $solution_id"
        exit 1
    fi

    # Display solution details
    display_solution "$solution_idx"

    # Confirm execution
    if [ "$force" = "false" ] && [ "$dry_run" = "false" ]; then
        echo -n "Execute auto-fix? (y/N): "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Auto-fix cancelled"
            exit 0
        fi
    fi

    # Execute fix
    if execute_fix "$solution_idx" "$dry_run"; then
        log_success "Auto-fix completed successfully!"
        exit 0
    else
        log_error "Auto-fix failed"
        exit 1
    fi
}

main "$@"
