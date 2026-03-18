#!/bin/bash
set -euo pipefail
# validate-issue-architecture.sh
# Architecture validation gate for issue-to-container workflow
# Validates issue scope against current architecture before container launch
# Feature #608: Prevent wasted work from architecture mismatches

set -e

SCRIPT_NAME="validate-issue-architecture.sh"
VERSION="1.0.0"

# Get script directory for sourcing shared libraries
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared logging utilities
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    # Fallback logging if common.sh not available
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { [ -n "$DEBUG" ] && echo "[DEBUG] $*" >&2 || true; }
fi

# Architecture patterns to validate against
# These represent common mismatches discovered during container execution
declare -A ARCHITECTURE_RULES=(
    # Automation pattern: We use n8n workflows, not GitHub Actions
    ["github_actions"]="DEPRECATED:.github/workflows/|GitHub Actions|github-actions"
    ["automation_actual"]="CORRECT:n8n workflows|n8n-workflows/"

    # OAuth token limitation: Cannot modify .github/workflows/
    ["oauth_limitation"]="BLOCKED:.github/workflows/.*push|workflow push|workflow file"

    # Deployment pattern: Container-based, not manual
    ["manual_deployment"]="DEPRECATED:deploy manually|manual deployment"
    ["deployment_actual"]="CORRECT:container-based|containerized deployment"
)

# Severity levels for validation failures
declare -A SEVERITY=(
    ["github_actions"]="ERROR"      # Hard blocker - will fail
    ["oauth_limitation"]="ERROR"    # Hard blocker - OAuth scope limitation
    ["automation_actual"]="INFO"    # Positive match - good
    ["manual_deployment"]="WARN"    # Warning - may waste time
    ["deployment_actual"]="INFO"    # Positive match - good
)

usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Architecture validation for issues

Validates issue scope against repository architecture patterns before
container launch to prevent wasted work from architecture mismatches.

USAGE:
    $SCRIPT_NAME --issue <N> [OPTIONS]
    $SCRIPT_NAME --body <text> [OPTIONS]

OPTIONS:
    --issue <N>         Validate GitHub issue number N
    --body <text>       Validate raw issue body text
    --json              Output results as JSON
    --strict            Fail on warnings (not just errors)
    --fix-suggestions   Include remediation suggestions in output
    --arch-doc <path>   Path to architecture docs (default: docs/architecture/)
    --debug             Enable debug logging

OUTPUT:
    Exit codes:
        0 - Issue aligns with architecture
        1 - Hard blocker detected (ERROR severity)
        2 - Warnings detected (WARN severity, only with --strict)
        3 - Validation error (missing issue, API failure, etc.)

    JSON output (--json):
        {
          "valid": true|false,
          "issue": 123,
          "blockers": [...],
          "warnings": [...],
          "suggestions": [...],
          "patterns_matched": {...}
        }

EXAMPLES:
    # Validate issue before container launch
    $SCRIPT_NAME --issue 571 --json

    # Validate with strict mode (fail on warnings)
    $SCRIPT_NAME --issue 571 --strict

    # Validate raw text
    $SCRIPT_NAME --body "Create GitHub Actions workflow for CI" --json

ARCHITECTURE PATTERNS:
    This script validates against known architecture patterns:

    BLOCKERS (ERROR):
      - References to .github/workflows/ (we use n8n workflows)
      - GitHub Actions mentions (automation is via n8n)
      - Workflow file push attempts (OAuth token lacks scope)

    WARNINGS:
      - Manual deployment references (we use containers)
      - Deprecated technology stack mentions

    See docs/GITHUB_ACTIONS_DEPRECATION.md for background.

INTEGRATION:
    This script is called by:
      - container-launch.sh (before container spawn)
      - container-preflight.sh (preflight validation)
      - Issue capture workflows (early validation)

EOF
}

# Fetch issue body from GitHub API
fetch_issue_body() {
    local issue="$1"

    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GITHUB_TOKEN required to fetch issue"
        return 1
    fi

    # Determine repo from git remote or environment
    local repo="${REPO_FULL_NAME:-}"
    if [ -z "$repo" ]; then
        repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[/:]([^/]+/[^.]+).*|\1|' || echo "")
    fi

    if [ -z "$repo" ]; then
        log_error "Cannot determine repository (set REPO_FULL_NAME or run in git repo)"
        return 1
    fi

    log_debug "Fetching issue #$issue from $repo"

    local response
    response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$repo/issues/$issue") || {
        log_error "Failed to fetch issue #$issue"
        return 1
    }

    # Check for API error
    if echo "$response" | jq -e '.message' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.message')
        log_error "GitHub API error: $error_msg"
        return 1
    fi

    # Extract title and body
    local title body
    title=$(echo "$response" | jq -r '.title // ""')
    body=$(echo "$response" | jq -r '.body // ""')

    # Combine for full text analysis
    echo -e "# $title\n\n$body"
}

# Validate text against architecture patterns
validate_text() {
    local text="$1"
    local json_output="${2:-false}"
    local strict="${3:-false}"

    local blockers=()
    local warnings=()
    local suggestions=()
    local patterns_matched=()

    # Check for deprecated GitHub Actions pattern
    if echo "$text" | grep -qiE '\.github/workflows/|github actions|github-actions'; then
        blockers+=("References to GitHub Actions detected - repository uses n8n workflows")
        suggestions+=("Replace GitHub Actions references with n8n workflow approach (see n8n-workflows/)")
        patterns_matched+=("github_actions")

        log_error "BLOCKER: Issue references GitHub Actions (deprecated)"
        log_error "  Architecture: This repo uses n8n workflows, not GitHub Actions"
        log_error "  Location: n8n-workflows/ (not .github/workflows/)"
    fi

    # Check for OAuth limitation (workflow file push)
    if echo "$text" | grep -qiE '\.github/workflows/.*\.(yml|yaml)|push.*workflow.*file|create.*github.*action'; then
        blockers+=("Attempts to create/modify .github/workflows/ - OAuth token lacks workflow scope")
        suggestions+=("Container cannot push workflow files - use n8n workflows instead or update manually")
        patterns_matched+=("oauth_limitation")

        log_error "BLOCKER: Issue attempts to modify .github/workflows/"
        log_error "  Limitation: Container OAuth token lacks workflow write scope"
        log_error "  Result: Push will be rejected by GitHub API"
    fi

    # Check for manual deployment references
    if echo "$text" | grep -qiE 'deploy.*manual|manual.*deploy|manually.*deploy|deploy.*ssh|ssh.*deploy'; then
        warnings+=("References to manual deployment - repository uses automated container deployments")
        suggestions+=("Use container-based deployment instead of manual steps")
        patterns_matched+=("manual_deployment")

        log_warn "WARNING: Issue references manual deployment"
        log_warn "  Architecture: Repository uses containerized deployments"
    fi

    # Check for positive patterns (correct architecture)
    if echo "$text" | grep -qiE 'n8n workflow|n8n-workflows/'; then
        patterns_matched+=("automation_actual")
        log_debug "✓ Correct automation pattern detected (n8n workflows)"
    fi

    if echo "$text" | grep -qiE 'container|containerized|docker'; then
        patterns_matched+=("deployment_actual")
        log_debug "✓ Correct deployment pattern detected (containers)"
    fi

    # Determine validation result
    local valid=true
    local exit_code=0

    if [ ${#blockers[@]} -gt 0 ]; then
        valid=false
        exit_code=1
    elif [ "$strict" = "true" ] && [ ${#warnings[@]} -gt 0 ]; then
        valid=false
        exit_code=2
    fi

    # Output results
    if [ "$json_output" = "true" ]; then
        # JSON output
        local blockers_json warnings_json suggestions_json patterns_json

        # Handle empty arrays properly
        if [ ${#blockers[@]} -eq 0 ]; then
            blockers_json='[]'
        else
            blockers_json=$(printf '%s\n' "${blockers[@]}" | jq -R . | jq -s .)
        fi

        if [ ${#warnings[@]} -eq 0 ]; then
            warnings_json='[]'
        else
            warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
        fi

        if [ ${#suggestions[@]} -eq 0 ]; then
            suggestions_json='[]'
        else
            suggestions_json=$(printf '%s\n' "${suggestions[@]}" | jq -R . | jq -s .)
        fi

        if [ ${#patterns_matched[@]} -eq 0 ]; then
            patterns_json='[]'
        else
            patterns_json=$(printf '%s\n' "${patterns_matched[@]}" | jq -R . | jq -s .)
        fi

        jq -n \
            --argjson valid "$valid" \
            --argjson blockers "$blockers_json" \
            --argjson warnings "$warnings_json" \
            --argjson suggestions "$suggestions_json" \
            --argjson patterns "$patterns_json" \
            '{
                valid: $valid,
                blockers: $blockers,
                warnings: $warnings,
                suggestions: $suggestions,
                patterns_matched: $patterns
            }'
    else
        # Human-readable output
        echo ""
        echo "=== Architecture Validation Results ==="
        echo ""

        if [ "$valid" = "true" ]; then
            echo "✓ PASSED: Issue aligns with current architecture"
        else
            echo "✗ FAILED: Architecture mismatches detected"
        fi

        echo ""

        if [ ${#blockers[@]} -gt 0 ]; then
            echo "BLOCKERS (${#blockers[@]}):"
            for blocker in "${blockers[@]}"; do
                echo "  ✗ $blocker"
            done
            echo ""
        fi

        if [ ${#warnings[@]} -gt 0 ]; then
            echo "WARNINGS (${#warnings[@]}):"
            for warning in "${warnings[@]}"; do
                echo "  ⚠ $warning"
            done
            echo ""
        fi

        if [ ${#suggestions[@]} -gt 0 ]; then
            echo "SUGGESTIONS:"
            for suggestion in "${suggestions[@]}"; do
                echo "  → $suggestion"
            done
            echo ""
        fi

        if [ ${#patterns_matched[@]} -gt 0 ]; then
            echo "Patterns matched: ${patterns_matched[*]}"
        fi

        echo ""
    fi

    return $exit_code
}

# Main function
main() {
    local issue=""
    local body=""
    local json_output="false"
    local strict="false"
    local fix_suggestions="false"
    local arch_doc="docs/architecture/"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --issue)
                issue="$2"
                shift 2
                ;;
            --body)
                body="$2"
                shift 2
                ;;
            --json)
                json_output="true"
                shift
                ;;
            --strict)
                strict="true"
                shift
                ;;
            --fix-suggestions)
                fix_suggestions="true"
                shift
                ;;
            --arch-doc)
                arch_doc="$2"
                shift 2
                ;;
            --debug)
                DEBUG="1"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --version|-v)
                echo "$SCRIPT_NAME v$VERSION"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 3
                ;;
        esac
    done

    # Validate inputs
    if [ -z "$issue" ] && [ -z "$body" ]; then
        log_error "Either --issue or --body is required"
        usage
        exit 3
    fi

    # Fetch issue body if issue number provided
    if [ -n "$issue" ]; then
        log_info "Validating issue #$issue against architecture patterns..."
        body=$(fetch_issue_body "$issue") || exit 3
    else
        log_info "Validating text against architecture patterns..."
    fi

    # Validate
    validate_text "$body" "$json_output" "$strict"
}

# Run main
main "$@"
