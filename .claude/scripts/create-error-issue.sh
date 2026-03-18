#!/bin/bash
# create-error-issue.sh
# Automatically creates GitHub issues from error context
# Part of self-healing system (#625)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS_DIR="${LOGS_DIR:-$REPO_ROOT/logs}"

# Load shared utilities
if [[ -f "$SCRIPT_DIR/shared-utils.sh" ]]; then
    source "$SCRIPT_DIR/shared-utils.sh"
else
    # Minimal fallback logging
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARN] $*" >&2; }
fi

# Configuration
GITHUB_REPO="${GITHUB_REPO:-}"
MAX_LOG_LINES="${MAX_LOG_LINES:-50}"
ISSUE_LABEL_AUTO="auto-created"
ISSUE_LABEL_BUG="bug"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Create a GitHub issue from error context.

OPTIONS:
    -e, --error-type TYPE       Error type (required)
    -c, --container NAME        Container or script name (required)
    -l, --log-file FILE        Path to log file
    -s, --severity LEVEL       Severity level (critical, high, medium, low)
    -m, --message TEXT         Error message
    -t, --timestamp TIME       Error timestamp (default: now)
    -r, --run-url URL          Link to workflow run or logs
    -d, --dry-run              Print issue without creating it
    -h, --help                 Show this help message

ENVIRONMENT:
    GITHUB_TOKEN               GitHub token (required for issue creation)
    GITHUB_REPO                Repository in format owner/repo
    LOGS_DIR                   Directory containing log files

EXAMPLES:
    # Create issue from container failure
    $0 -e "ContainerExit" -c "n8n" -l /logs/n8n.log -s high

    # Create issue with workflow run link
    $0 -e "ScriptError" -c "backup.sh" -s medium -r "https://github.com/..."

    # Dry run to preview issue
    $0 -e "NetworkError" -c "api-service" -d
EOF
    exit 0
}

# Parse command line arguments
ERROR_TYPE=""
CONTAINER_NAME=""
LOG_FILE=""
SEVERITY="medium"
ERROR_MESSAGE=""
TIMESTAMP=""
RUN_URL=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--error-type)
            ERROR_TYPE="$2"
            shift 2
            ;;
        -c|--container)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -l|--log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        -s|--severity)
            SEVERITY="$2"
            shift 2
            ;;
        -m|--message)
            ERROR_MESSAGE="$2"
            shift 2
            ;;
        -t|--timestamp)
            TIMESTAMP="$2"
            shift 2
            ;;
        -r|--run-url)
            RUN_URL="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$ERROR_TYPE" ]]; then
    log_error "Error type is required (-e, --error-type)"
    exit 1
fi

if [[ -z "$CONTAINER_NAME" ]]; then
    log_error "Container/script name is required (-c, --container)"
    exit 1
fi

# Set default timestamp
if [[ -z "$TIMESTAMP" ]]; then
    TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
fi

# Validate GitHub configuration
if [[ "$DRY_RUN" == "false" ]]; then
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        log_error "GITHUB_TOKEN environment variable is required"
        exit 1
    fi

    if [[ -z "$GITHUB_REPO" ]]; then
        log_error "GITHUB_REPO environment variable is required (format: owner/repo)"
        exit 1
    fi
fi

# Generate error signature for duplicate detection
generate_error_signature() {
    local error_type="$1"
    local container="$2"
    echo "${error_type}:${container}"
}

# Check for existing open issues with same error signature
check_duplicate_issue() {
    local signature="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        return 1
    fi

    log_info "Checking for duplicate issues with signature: $signature"

    # Search for open issues with auto-created label and matching title
    local search_query="repo:${GITHUB_REPO} is:issue is:open label:${ISSUE_LABEL_AUTO} ${ERROR_TYPE} ${CONTAINER_NAME}"

    local existing_issues
    existing_issues=$(gh issue list \
        --repo "$GITHUB_REPO" \
        --search "$search_query" \
        --json number,title \
        --limit 5 2>/dev/null || echo "[]")

    local issue_count
    issue_count=$(echo "$existing_issues" | jq 'length')

    if [[ "$issue_count" -gt 0 ]]; then
        log_warning "Found $issue_count existing open issue(s) with similar error"
        echo "$existing_issues" | jq -r '.[] | "#\(.number): \(.title)"' | while read -r line; do
            log_warning "  $line"
        done
        return 0
    fi

    return 1
}

# Classify error and determine priority
classify_error() {
    local error_type="$1"
    local severity="$2"
    local classification=""
    local priority=""

    # Use classify-error.sh if available
    if [[ -x "$SCRIPT_DIR/classify-error.sh" ]] && [[ -n "$LOG_FILE" ]] && [[ -f "$LOG_FILE" ]]; then
        log_info "Running error classification"
        classification=$("$SCRIPT_DIR/classify-error.sh" -f "$LOG_FILE" -o json 2>/dev/null || echo "")

        if [[ -n "$classification" ]]; then
            severity=$(echo "$classification" | jq -r '.severity // "medium"')
            error_type=$(echo "$classification" | jq -r '.category // "'"$error_type"'"')
        fi
    fi

    # Map severity to priority label
    local severity_lower
    severity_lower=$(echo "$severity" | tr '[:upper:]' '[:lower:]')
    case "$severity_lower" in
        critical)
            priority="P1"
            ;;
        high)
            priority="P1"
            ;;
        medium)
            priority="P2"
            ;;
        low)
            priority="P2"
            ;;
        *)
            priority="P2"
            ;;
    esac

    echo "$priority"
}

# Extract log excerpt
extract_log_excerpt() {
    local log_file="$1"
    local max_lines="$2"

    if [[ ! -f "$log_file" ]]; then
        echo "Log file not available"
        return
    fi

    # Get last N lines from log file
    tail -n "$max_lines" "$log_file" 2>/dev/null || echo "Unable to read log file"
}

# Build issue body
build_issue_body() {
    local error_type="$1"
    local container="$2"
    local timestamp="$3"
    local severity="$4"
    local priority="$5"
    local error_msg="$6"
    local log_file="$7"
    local run_url="$8"

    cat <<EOF
## 🤖 Automated Error Report

This issue was automatically created by the self-healing system.

### Error Details

- **Error Type:** \`${error_type}\`
- **Container/Script:** \`${container}\`
- **Timestamp:** ${timestamp}
- **Severity:** ${severity}
- **Priority:** ${priority}

EOF

    if [[ -n "$error_msg" ]]; then
        cat <<EOF
### Error Message

\`\`\`
${error_msg}
\`\`\`

EOF
    fi

    if [[ -n "$log_file" ]] && [[ -f "$log_file" ]]; then
        cat <<EOF
### Log Excerpt

Last ${MAX_LOG_LINES} lines from \`${log_file}\`:

\`\`\`
$(extract_log_excerpt "$log_file" "$MAX_LOG_LINES")
\`\`\`

EOF
    fi

    if [[ -n "$run_url" ]]; then
        cat <<EOF
### Related Resources

- [Workflow Run / Logs]($run_url)

EOF
    fi

    cat <<EOF
### Classification

Based on error analysis:
- **Severity Level:** ${severity}
- **Suggested Priority:** ${priority}

### Suggested Resolution

1. Review the log excerpt above for error details
2. Check container/script configuration
3. Verify dependencies and environment variables
4. Review recent changes that may have introduced this error
5. Consider implementing retry logic or error handling

### Next Steps

- [ ] Investigate root cause
- [ ] Implement fix
- [ ] Add monitoring/alerting if needed
- [ ] Update documentation

---

*Part of [#625](https://github.com/${GITHUB_REPO}/issues/625) - Self-healing system*
*Created by: create-error-issue.sh*
EOF
}

# Create GitHub issue
create_github_issue() {
    local title="$1"
    local body="$2"
    local priority="$3"

    local labels="${ISSUE_LABEL_BUG},${ISSUE_LABEL_AUTO},${priority}"

    log_info "Creating GitHub issue: $title"

    # Create issue using gh CLI
    local issue_url
    issue_url=$(gh issue create \
        --repo "$GITHUB_REPO" \
        --title "$title" \
        --body "$body" \
        --label "$labels" 2>&1)

    if [[ $? -eq 0 ]]; then
        log_info "✓ Issue created successfully: $issue_url"
        echo "$issue_url"
        return 0
    else
        log_error "✗ Failed to create issue: $issue_url"
        return 1
    fi
}

# Main execution
main() {
    log_info "Starting error issue creation"
    log_info "Error Type: $ERROR_TYPE"
    log_info "Container: $CONTAINER_NAME"
    log_info "Severity: $SEVERITY"

    # Generate error signature
    local signature
    signature=$(generate_error_signature "$ERROR_TYPE" "$CONTAINER_NAME")

    # Check for duplicates
    if check_duplicate_issue "$signature"; then
        log_warning "Duplicate issue detected. Skipping creation to avoid spam."
        log_info "To create anyway, close existing issues or modify the error signature"
        exit 0
    fi

    # Classify error and determine priority
    local priority
    priority=$(classify_error "$ERROR_TYPE" "$SEVERITY")
    log_info "Determined priority: $priority"

    # Build issue title
    local issue_title="[Auto] ${ERROR_TYPE} in ${CONTAINER_NAME}"

    # Build issue body
    local issue_body
    issue_body=$(build_issue_body \
        "$ERROR_TYPE" \
        "$CONTAINER_NAME" \
        "$TIMESTAMP" \
        "$SEVERITY" \
        "$priority" \
        "$ERROR_MESSAGE" \
        "$LOG_FILE" \
        "$RUN_URL")

    # Dry run or create issue
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "=== DRY RUN MODE ==="
        log_info "Would create issue with:"
        echo ""
        echo "Title: $issue_title"
        echo "Labels: ${ISSUE_LABEL_BUG}, ${ISSUE_LABEL_AUTO}, ${priority}"
        echo ""
        echo "Body:"
        echo "---"
        echo "$issue_body"
        echo "---"
        exit 0
    fi

    # Create the issue
    local issue_url
    if issue_url=$(create_github_issue "$issue_title" "$issue_body" "$priority"); then
        log_info "Successfully created issue: $issue_url"

        # Optionally trigger notifications or webhooks here

        exit 0
    else
        log_error "Failed to create issue"
        exit 1
    fi
}

# Run main function
main
