#!/usr/bin/env bash
#
# validate-github-conventions.sh
# Validates GitHub issues and PRs against conventions defined in docs/GITHUB_CONVENTIONS.md
# size-ok: comprehensive validation with multiple check categories for issues, PRs, and repo setup
#
# Usage:
#   ./validate-github-conventions.sh --issue 123    # Validate specific issue
#   ./validate-github-conventions.sh --pr 45        # Validate specific PR
#   ./validate-github-conventions.sh --audit        # Audit all open issues
#   ./validate-github-conventions.sh --check        # Check repo setup (labels, milestones)
#   ./validate-github-conventions.sh --init         # Initialize repo with conventions
#
# Exit codes:
#   0 - All validations passed
#   1 - Validation errors found (blocking)
#   2 - Usage error

set -euo pipefail

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Standard labels per GITHUB_CONVENTIONS.md
STANDARD_LABELS=("in-progress" "backlog" "blocked" "bug" "feature" "docs" "tech-debt")

# Counters
ERRORS=0
WARNINGS=0

# Mode: "strict" blocks all violations, "advisory" only warns
MODE="${VALIDATION_MODE:-strict}"

#------------------------------------------------------------------------------
# Utility functions - override to track counts
#------------------------------------------------------------------------------

print_error() {
    log_error "$@"
    ((ERRORS++))
}

print_warning() {
    log_warn "$@"
    ((WARNINGS++))
}

print_success() {
    echo -e "${GREEN:-}PASS:${NC:-} $1"
}

print_info() { log_info "$@"; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --issue NUM    Validate a specific issue by number"
    echo "  --pr NUM       Validate a specific pull request by number"
    echo "  --audit        Audit all open issues for convention compliance"
    echo "  --check        Check repo setup (labels, milestones exist)"
    echo "  --init         Initialize repo with standard labels and milestone"
    echo "  --bypass       Skip validation (emergency use only)"
    echo "  --mode MODE    Set validation mode: 'strict' (default) or 'advisory'"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  VALIDATION_MODE    Set to 'advisory' for warnings-only mode"
    exit 2
}

check_gh_cli() {
    if ! command -v gh &> /dev/null; then
        print_error "gh CLI not found. Install from: https://cli.github.com/"
        exit 2
    fi

    if ! gh auth status &> /dev/null; then
        print_error "gh CLI not authenticated. Run: gh auth login"
        exit 2
    fi
}

#------------------------------------------------------------------------------
# Security validation functions
#------------------------------------------------------------------------------

check_secrets_in_content() {
    local content="$1"
    local context="$2"

    # Check for common secret patterns
    if echo "$content" | grep -qiE 'api[_-]?key\s*[:=]|secret\s*[:=]|token\s*[:=]|password\s*[:=]|credential'; then
        print_error "$context: Possible secrets detected (api_key, token, password, secret)"
        return 1
    fi

    return 0
}

check_username_paths() {
    local content="$1"
    local context="$2"

    # Check for paths containing usernames
    if echo "$content" | grep -qE '/Users/[^/]+/|/home/[^/]+/|C:\\Users\\[^\\]+\\'; then
        print_error "$context: File path contains username (violates privacy)"
        return 1
    fi

    return 0
}

check_stack_traces() {
    local content="$1"
    local context="$2"

    # Check for full stack traces with local paths
    if echo "$content" | grep -qE 'at .+\(.+:[0-9]+:[0-9]+\)' && \
       echo "$content" | grep -qE '/Users/|/home/'; then
        print_error "$context: Stack trace contains local paths"
        return 1
    fi

    return 0
}

validate_security() {
    local content="$1"
    local context="$2"
    local has_errors=0

    check_secrets_in_content "$content" "$context" || has_errors=1
    check_username_paths "$content" "$context" || has_errors=1
    check_stack_traces "$content" "$context" || has_errors=1

    return $has_errors
}

#------------------------------------------------------------------------------
# Issue validation functions
#------------------------------------------------------------------------------

validate_issue_title() {
    local title="$1"

    if [[ -z "$title" || "$title" == "null" ]]; then
        print_error "Issue title is empty"
        return 1
    fi

    if [[ ${#title} -lt 5 ]]; then
        print_error "Issue title too short (min 5 characters): '$title'"
        return 1
    fi

    print_success "Issue title is valid"
    return 0
}

validate_issue_body() {
    local body="$1"

    if [[ -z "$body" || "$body" == "null" ]]; then
        print_error "Issue body is empty"
        return 1
    fi

    # Check for acceptance criteria (strict mode)
    if [[ "$MODE" == "strict" ]]; then
        if ! echo "$body" | grep -qiE 'acceptance criteria|criteria:|requirements:|must:|should:|\- \[ \]'; then
            print_error "Issue body missing acceptance criteria (strict mode)"
            return 1
        fi
    fi

    print_success "Issue body is valid"
    return 0
}

validate_issue_milestone() {
    local milestone="$1"

    if [[ -z "$milestone" || "$milestone" == "null" ]]; then
        if [[ "$MODE" == "strict" ]]; then
            print_error "Issue has no milestone assigned (strict mode requires milestone)"
            return 1
        else
            print_warning "Issue has no milestone assigned"
            return 0
        fi
    fi

    print_success "Issue has milestone: $milestone"
    return 0
}

validate_issue_labels() {
    local labels="$1"

    if [[ -z "$labels" || "$labels" == "[]" || "$labels" == "null" ]]; then
        if [[ "$MODE" == "strict" ]]; then
            print_error "Issue has no labels (strict mode requires labels)"
            return 1
        else
            print_warning "Issue has no labels"
            return 0
        fi
    fi

    print_success "Issue has labels: $labels"
    return 0
}

validate_issue() {
    local issue_num="$1"

    print_info "Validating issue #$issue_num..."

    # Fetch issue data
    local issue_data
    issue_data=$(gh issue view "$issue_num" --json title,body,milestone,labels 2>/dev/null) || {
        print_error "Failed to fetch issue #$issue_num"
        return 1
    }

    local title body milestone labels
    title=$(echo "$issue_data" | jq -r '.title // ""')
    body=$(echo "$issue_data" | jq -r '.body // ""')
    milestone=$(echo "$issue_data" | jq -r '.milestone.title // ""')
    labels=$(echo "$issue_data" | jq -r '[.labels[].name] | join(", ")')

    local has_errors=0

    # Validate each field
    validate_issue_title "$title" || has_errors=1
    validate_issue_body "$body" || has_errors=1
    validate_issue_milestone "$milestone" || has_errors=1
    validate_issue_labels "$labels" || has_errors=1

    # Security validation
    validate_security "$title" "Title" || has_errors=1
    validate_security "$body" "Body" || has_errors=1

    return $has_errors
}

#------------------------------------------------------------------------------
# PR validation functions
#------------------------------------------------------------------------------

validate_pr() {
    local pr_num="$1"

    print_info "Validating PR #$pr_num..."

    # Fetch PR data
    local pr_data
    pr_data=$(gh pr view "$pr_num" --json title,body,labels 2>/dev/null) || {
        print_error "Failed to fetch PR #$pr_num"
        return 1
    }

    local title body labels
    title=$(echo "$pr_data" | jq -r '.title // ""')
    body=$(echo "$pr_data" | jq -r '.body // ""')
    labels=$(echo "$pr_data" | jq -r '[.labels[].name] | join(", ")')

    local has_errors=0

    # Validate title
    if [[ -z "$title" || "$title" == "null" ]]; then
        print_error "PR title is empty"
        has_errors=1
    else
        print_success "PR title is valid"
    fi

    # Validate body
    if [[ -z "$body" || "$body" == "null" ]]; then
        print_error "PR description is empty"
        has_errors=1
    else
        print_success "PR has description"
    fi

    # Security validation
    validate_security "$title" "Title" || has_errors=1
    validate_security "$body" "Body" || has_errors=1

    return $has_errors
}

#------------------------------------------------------------------------------
# Repo setup validation
#------------------------------------------------------------------------------

check_labels() {
    print_info "Checking standard labels..."

    local existing_labels
    existing_labels=$(gh label list --json name --jq '.[].name' 2>/dev/null) || {
        print_error "Failed to fetch labels"
        return 1
    }

    local missing=0
    for label in "${STANDARD_LABELS[@]}"; do
        if echo "$existing_labels" | grep -q "^${label}$"; then
            print_success "Label exists: $label"
        else
            print_error "Missing standard label: $label"
            missing=1
        fi
    done

    return $missing
}

check_milestone() {
    print_info "Checking for active milestone..."

    local milestones
    milestones=$(gh api repos/:owner/:repo/milestones --jq '.[] | select(.state=="open") | .title' 2>/dev/null) || {
        print_error "Failed to fetch milestones"
        return 1
    }

    if [[ -z "$milestones" ]]; then
        print_error "No active milestone found (create one with: gh api repos/:owner/:repo/milestones -X POST -f title='MVP')"
        return 1
    fi

    print_success "Active milestone(s): $milestones"
    return 0
}

check_repo_setup() {
    print_info "Checking repository setup..."
    echo ""

    local has_errors=0

    check_labels || has_errors=1
    echo ""
    check_milestone || has_errors=1

    return $has_errors
}

#------------------------------------------------------------------------------
# Initialization
#------------------------------------------------------------------------------

init_labels() {
    print_info "Creating standard labels..."

    local label_colors=(
        "in-progress:FFA500:Actively being worked on"
        "backlog:D3D3D3:Planned but not started"
        "blocked:FF0000:Waiting on dependency"
        "bug:d73a4a:Something isn't working"
        "feature:00FF00:New functionality"
        "docs:0075ca:Documentation task"
        "tech-debt:FFA500:Refactoring or cleanup"
        "needs-attention:FF6600:Requires immediate attention"
    )

    for item in "${label_colors[@]}"; do
        local name color desc
        name=$(echo "$item" | cut -d: -f1)
        color=$(echo "$item" | cut -d: -f2)
        desc=$(echo "$item" | cut -d: -f3)

        if gh label create "$name" --color "$color" --description "$desc" 2>/dev/null; then
            print_success "Created label: $name"
        else
            print_info "Label already exists: $name"
        fi
    done
}

init_milestone() {
    local name="${1:-MVP}"

    print_info "Creating milestone: $name..."

    # Calculate due date (30 days from now)
    local due_date
    due_date=$(date -v+30d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -d "+30 days" +%Y-%m-%dT00:00:00Z)

    if gh api repos/:owner/:repo/milestones -X POST \
        -f title="$name" \
        -f state="open" \
        -f description="Initial sprint milestone" \
        -f due_on="$due_date" &>/dev/null; then
        print_success "Created milestone: $name (due in 30 days)"
    else
        print_info "Milestone may already exist: $name"
    fi
}

init_repo() {
    local milestone_name="${1:-MVP}"

    print_info "Initializing repository with GitHub conventions..."
    echo ""

    init_labels
    echo ""
    init_milestone "$milestone_name"
    echo ""

    print_info "Verifying setup..."
    check_repo_setup
}

#------------------------------------------------------------------------------
# Audit functions
#------------------------------------------------------------------------------

audit_all_issues() {
    print_info "Auditing all open issues..."
    echo ""

    local issues
    issues=$(gh issue list --state open --json number --jq '.[].number' 2>/dev/null) || {
        print_error "Failed to fetch issues"
        return 1
    }

    if [[ -z "$issues" ]]; then
        print_info "No open issues found"
        return 0
    fi

    local total=0
    local failed=0

    while read -r issue_num; do
        ((total++))
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if ! validate_issue "$issue_num"; then
            ((failed++))
        fi
    done <<< "$issues"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_info "Audit complete: $total issues checked, $failed with violations"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    local action=""
    local target=""
    local bypass=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)
                action="issue"
                target="${2:-}"
                shift 2
                ;;
            --pr)
                action="pr"
                target="${2:-}"
                shift 2
                ;;
            --audit)
                action="audit"
                shift
                ;;
            --check)
                action="check"
                shift
                ;;
            --init)
                action="init"
                target="${2:-MVP}"
                shift
                [[ "${1:-}" != --* && -n "${1:-}" ]] && { target="$1"; shift; }
                ;;
            --bypass)
                bypass=true
                shift
                ;;
            --mode)
                MODE="${2:-strict}"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$action" ]]; then
        usage
    fi

    if [[ "$bypass" == true ]]; then
        print_warning "Bypass mode enabled - skipping validation"
        exit 0
    fi

    check_gh_cli

    echo ""
    echo "GitHub Convention Validator"
    echo "Mode: $MODE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local exit_code=0

    case "$action" in
        issue)
            if [[ -z "$target" ]]; then
                print_error "Issue number required"
                exit 2
            fi
            validate_issue "$target" || exit_code=1
            ;;
        pr)
            if [[ -z "$target" ]]; then
                print_error "PR number required"
                exit 2
            fi
            validate_pr "$target" || exit_code=1
            ;;
        audit)
            audit_all_issues || exit_code=1
            ;;
        check)
            check_repo_setup || exit_code=1
            ;;
        init)
            init_repo "$target"
            ;;
    esac

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ $ERRORS -gt 0 ]]; then
        print_error "Validation failed with $ERRORS error(s) and $WARNINGS warning(s)"
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        print_warning "Validation passed with $WARNINGS warning(s)"
        exit 0
    else
        print_success "All validations passed"
        exit 0
    fi
}

main "$@"
