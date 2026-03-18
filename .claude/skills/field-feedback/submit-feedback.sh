#!/bin/bash
# submit-feedback.sh
# Submit bug reports, enhancements, and config issues from consumer repos
# to the claude-tastic framework source repository
# Part of feature #679

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source repository for claude-tastic framework
SOURCE_REPO="jifflee/claude-tastic"

# Minimal logging functions (avoid dependencies)
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warning() { echo "[WARN] $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 --bug|--enhancement|--config "feedback message"

Submit feedback from consumer repo to claude-tastic framework source.

FEEDBACK TYPES:
    --bug               Report a bug in the framework
    --enhancement       Suggest a new feature or enhancement
    --config            Report a configuration or compatibility issue

ARGUMENTS:
    MESSAGE             The feedback message (required)

OPTIONS:
    -h, --help          Show this help message

EXAMPLES:
    # Report a bug
    $0 --bug "Container launch fails on M1 Mac with arm64 architecture"

    # Suggest enhancement
    $0 --enhancement "Add support for custom Docker images in container mode"

    # Report config issue
    $0 --config "Keychain not found on Linux Ubuntu 22.04"

ENVIRONMENT:
    GITHUB_TOKEN        GitHub token for issue creation (required)

NOTE:
    This command creates issues in the source claude-tastic repository
    to help improve the framework for all users.
EOF
    exit 0
}

# Parse command line arguments
FEEDBACK_TYPE=""
FEEDBACK_MESSAGE=""

if [[ $# -eq 0 ]]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --bug)
            FEEDBACK_TYPE="bug"
            shift
            if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
                FEEDBACK_MESSAGE="$1"
                shift
            fi
            ;;
        --enhancement)
            FEEDBACK_TYPE="enhancement"
            shift
            if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
                FEEDBACK_MESSAGE="$1"
                shift
            fi
            ;;
        --config)
            FEEDBACK_TYPE="config"
            shift
            if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
                FEEDBACK_MESSAGE="$1"
                shift
            fi
            ;;
        -h|--help)
            usage
            ;;
        *)
            # Treat as message if no feedback type yet
            if [[ -z "$FEEDBACK_TYPE" ]]; then
                log_error "Unknown option: $1"
                log_error "Please specify feedback type: --bug, --enhancement, or --config"
                exit 1
            fi
            FEEDBACK_MESSAGE="$1"
            shift
            ;;
    esac
done

# Validate inputs
if [[ -z "$FEEDBACK_TYPE" ]]; then
    log_error "Feedback type is required (--bug, --enhancement, or --config)"
    exit 1
fi

if [[ -z "$FEEDBACK_MESSAGE" ]]; then
    log_error "Feedback message is required"
    exit 1
fi

# Validate GitHub token
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log_error "GITHUB_TOKEN environment variable is required"
    log_error "Please set GITHUB_TOKEN with a token that has repo access"
    exit 1
fi

# Gather context information
gather_context() {
    local consumer_repo=""
    local framework_version=""
    local git_branch=""
    local os_info=""
    local docker_info=""

    # Get consumer repository info
    if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        consumer_repo=$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || echo "unknown")
        git_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    else
        consumer_repo="not-a-git-repo"
        git_branch="N/A"
    fi

    # Get framework version from package.json if available
    if [[ -f "$REPO_ROOT/package.json" ]]; then
        framework_version=$(grep -m1 '"version"' "$REPO_ROOT/package.json" | sed 's/.*"version": "\(.*\)".*/\1/' || echo "unknown")
    else
        framework_version="unknown"
    fi

    # Get OS information
    os_info=$(uname -a 2>/dev/null || echo "unknown")

    # Get Docker information if available
    if command -v docker &>/dev/null; then
        docker_info=$(docker --version 2>/dev/null || echo "docker installed but version unknown")
    else
        docker_info="not installed"
    fi

    # Return as JSON-like structure
    cat <<EOF
{
  "consumer_repo": "$consumer_repo",
  "framework_version": "$framework_version",
  "git_branch": "$git_branch",
  "os_info": "$os_info",
  "docker_info": "$docker_info",
  "timestamp": "$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
}
EOF
}

# Build issue title
build_issue_title() {
    local type="$1"
    local message="$2"

    # Truncate message to reasonable title length
    local short_msg
    short_msg=$(echo "$message" | head -c 80)

    case "$type" in
        bug)
            echo "[Field Bug] $short_msg"
            ;;
        enhancement)
            echo "[Field Enhancement] $short_msg"
            ;;
        config)
            echo "[Field Config] $short_msg"
            ;;
        *)
            echo "[Field Feedback] $short_msg"
            ;;
    esac
}

# Build issue body
build_issue_body() {
    local type="$1"
    local message="$2"
    local context="$3"

    local emoji
    local type_label

    case "$type" in
        bug)
            emoji="🐛"
            type_label="Bug Report"
            ;;
        enhancement)
            emoji="✨"
            type_label="Enhancement Request"
            ;;
        config)
            emoji="⚙️"
            type_label="Configuration Issue"
            ;;
        *)
            emoji="📝"
            type_label="Feedback"
            ;;
    esac

    cat <<EOF
## $emoji Field Feedback: $type_label

This issue was submitted from a consumer repository using the \`/field-feedback\` skill.

### Description

$message

### Context Information

\`\`\`json
$context
\`\`\`

### Environment Details

- **Consumer Repository:** \`$(echo "$context" | grep -o '"consumer_repo": "[^"]*"' | cut -d'"' -f4)\`
- **Framework Version:** \`$(echo "$context" | grep -o '"framework_version": "[^"]*"' | cut -d'"' -f4)\`
- **Git Branch:** \`$(echo "$context" | grep -o '"git_branch": "[^"]*"' | cut -d'"' -f4)\`
- **OS:** \`$(echo "$context" | grep -o '"os_info": "[^"]*"' | cut -d'"' -f4 | head -c 60)...\`
- **Docker:** \`$(echo "$context" | grep -o '"docker_info": "[^"]*"' | cut -d'"' -f4)\`
- **Timestamp:** $(echo "$context" | grep -o '"timestamp": "[^"]*"' | cut -d'"' -f4)

### Next Steps

EOF

    case "$type" in
        bug)
            cat <<EOF
- [ ] Reproduce the issue in test environment
- [ ] Identify root cause
- [ ] Implement fix
- [ ] Add regression test
- [ ] Update documentation if needed
EOF
            ;;
        enhancement)
            cat <<EOF
- [ ] Evaluate feasibility and scope
- [ ] Gather additional requirements if needed
- [ ] Design implementation approach
- [ ] Plan development timeline
- [ ] Update roadmap
EOF
            ;;
        config)
            cat <<EOF
- [ ] Verify configuration issue
- [ ] Check compatibility with reported environment
- [ ] Document workaround if available
- [ ] Implement fix or improve error messages
- [ ] Update configuration documentation
EOF
            ;;
    esac

    cat <<EOF

---

*Part of [#586](https://github.com/$SOURCE_REPO/issues/586) - Framework feedback system*
*Submitted via: /field-feedback skill (Feature #679)*
EOF
}

# Check for duplicate issues
check_duplicate_issue() {
    local type="$1"
    local message="$2"

    log_info "Checking for duplicate issues..."

    # Create search query based on type and keywords from message
    local keywords
    keywords=$(echo "$message" | head -c 50)

    local label
    case "$type" in
        bug)
            label="field-bug"
            ;;
        enhancement)
            label="field-enhancement"
            ;;
        config)
            label="field-config"
            ;;
    esac

    # Search for similar open issues
    local existing_issues
    existing_issues=$(gh issue list \
        --repo "$SOURCE_REPO" \
        --label "$label" \
        --state open \
        --search "$keywords" \
        --json number,title \
        --limit 3 2>/dev/null || echo "[]")

    local issue_count
    issue_count=$(echo "$existing_issues" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$issue_count" -gt 0 ]]; then
        log_warning "Found $issue_count potentially similar open issue(s):"
        echo "$existing_issues" | jq -r '.[] | "#\(.number): \(.title)"' 2>/dev/null | while read -r line; do
            log_warning "  $line"
        done
        echo ""
        echo "Similar issues found. Do you still want to create a new issue? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Issue creation cancelled by user"
            exit 0
        fi
    fi
}

# Create GitHub issue
create_feedback_issue() {
    local title="$1"
    local body="$2"
    local type="$3"

    local label
    case "$type" in
        bug)
            label="field-bug,bug,field-feedback"
            ;;
        enhancement)
            label="field-enhancement,enhancement,field-feedback"
            ;;
        config)
            label="field-config,configuration,field-feedback"
            ;;
    esac

    log_info "Creating issue in $SOURCE_REPO..."

    # Create issue using gh CLI
    local issue_url
    issue_url=$(gh issue create \
        --repo "$SOURCE_REPO" \
        --title "$title" \
        --body "$body" \
        --label "$label" 2>&1)

    if [[ $? -eq 0 ]]; then
        log_info "✓ Issue created successfully!"
        echo ""
        echo "Issue URL: $issue_url"
        echo ""
        log_info "Thank you for helping improve the claude-tastic framework!"
        return 0
    else
        log_error "✗ Failed to create issue: $issue_url"
        return 1
    fi
}

# Main execution
main() {
    log_info "Starting field feedback submission"
    log_info "Type: $FEEDBACK_TYPE"
    log_info "Message: $FEEDBACK_MESSAGE"

    # Gather context
    local context
    context=$(gather_context)

    # Check for duplicates
    check_duplicate_issue "$FEEDBACK_TYPE" "$FEEDBACK_MESSAGE"

    # Build issue title and body
    local title
    title=$(build_issue_title "$FEEDBACK_TYPE" "$FEEDBACK_MESSAGE")

    local body
    body=$(build_issue_body "$FEEDBACK_TYPE" "$FEEDBACK_MESSAGE" "$context")

    # Create the issue
    if create_feedback_issue "$title" "$body" "$FEEDBACK_TYPE"; then
        exit 0
    else
        log_error "Failed to submit feedback"
        exit 1
    fi
}

# Run main function
main
