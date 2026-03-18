#!/usr/bin/env bash
# =============================================================================
# policy-validator.sh - Comprehensive repo policy validation
# =============================================================================
# Usage: ./policy-validator.sh [--verbose] [--json] [--fix]
#
# Implements policy-as-code validation pattern from repo-automation-bots:
#   - Validates branch protection rules
#   - Checks required labels exist
#   - Verifies required files are present
#   - Validates GitHub feature configuration
#
# Exit Codes:
#   0 - All policies compliant
#   1 - Policy violations found
#   2 - Error
#
# Related:
#   - Issue #1029 - repo-automation-bots pattern evaluation
#   - docs/REPO_AUTOMATION_BOTS_EVALUATION.md
#   - .claude/hooks/repo-settings-drift-hook.sh
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Required labels for SDLC
REQUIRED_LABELS=(
    "CHECK_PASS:0E8A16:Local CI validation passed"
    "CHECK_FAIL:D93F0B:Local CI validation failed"
    "automerge:0366d6:Auto-merge when CI passes"
    "do-not-merge:e11d21:Block auto-merge"
    "dependencies:0366d6:Dependency updates"
)

# Required files in repo
REQUIRED_FILES=(
    "README.md"
    "CLAUDE.md"
    ".gitignore"
)

# Protected branches
PROTECTED_BRANCHES=(
    "main"
    "dev"
    "qa"
)

usage() {
    echo "Usage: $0 [--verbose] [--json] [--fix]"
    echo ""
    echo "Validate repository policies and configuration."
    echo ""
    echo "Options:"
    echo "  --verbose    Verbose output with details"
    echo "  --json       Output JSON format"
    echo "  --fix        Attempt to fix violations (where possible)"
    echo ""
    echo "Checks:"
    echo "  - Branch protection rules"
    echo "  - Required labels"
    echo "  - Required files"
    echo "  - GitHub features"
    echo ""
    exit 2
}

# Parse arguments
VERBOSE=false
JSON_OUTPUT=false
FIX=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --fix)
            FIX=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            usage
            ;;
    esac
done

log() {
    if ! $JSON_OUTPUT; then
        echo -e "$1" >&2
    fi
}

log_verbose() {
    if $VERBOSE && ! $JSON_OUTPUT; then
        echo -e "$1" >&2
    fi
}

# Get repo owner and name
get_repo_info() {
    local repo_url
    repo_url=$(git remote get-url origin 2>/dev/null || echo "")

    if [[ -z "$repo_url" ]]; then
        log "${RED}Error: Not a git repository or no remote 'origin'${NC}"
        exit 2
    fi

    # Extract owner/repo from URL
    if [[ "$repo_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
        REPO_OWNER="${BASH_REMATCH[1]}"
        REPO_NAME="${BASH_REMATCH[2]}"
    else
        log "${RED}Error: Cannot parse GitHub repo from: $repo_url${NC}"
        exit 2
    fi

    log_verbose "Repository: ${REPO_OWNER}/${REPO_NAME}"
}

# Check if required labels exist
check_labels() {
    log_verbose "\n${BLUE}Checking required labels...${NC}"

    local violations=0
    local missing_labels=()

    # Get existing labels
    local existing_labels
    existing_labels=$(gh label list --json name --jq '.[].name' 2>/dev/null || true)

    for label_spec in "${REQUIRED_LABELS[@]}"; do
        IFS=':' read -r label_name label_color label_desc <<< "$label_spec"

        if echo "$existing_labels" | grep -q "^${label_name}$"; then
            log_verbose "  ${GREEN}✓${NC} Label exists: ${label_name}"
        else
            log_verbose "  ${RED}✗${NC} Missing label: ${label_name}"
            missing_labels+=("$label_spec")
            ((violations++)) || true
        fi
    done

    # Fix if requested
    if [[ ${#missing_labels[@]} -gt 0 ]] && $FIX; then
        log "\n${YELLOW}Attempting to create missing labels...${NC}"
        for label_spec in "${missing_labels[@]}"; do
            IFS=':' read -r label_name label_color label_desc <<< "$label_spec"

            if gh label create "$label_name" --color "$label_color" --description "$label_desc" 2>/dev/null; then
                log "  ${GREEN}✓${NC} Created label: ${label_name}"
                ((violations--)) || true
            else
                log "  ${RED}✗${NC} Failed to create label: ${label_name}"
            fi
        done
    fi

    echo "$violations"
}

# Check if required files exist
check_required_files() {
    log_verbose "\n${BLUE}Checking required files...${NC}"

    local violations=0

    for file in "${REQUIRED_FILES[@]}"; do
        if [[ -f "$REPO_DIR/$file" ]]; then
            log_verbose "  ${GREEN}✓${NC} File exists: ${file}"
        else
            log_verbose "  ${RED}✗${NC} Missing file: ${file}"
            ((violations++)) || true
        fi
    done

    echo "$violations"
}

# Check branch protection rules
check_branch_protection() {
    log_verbose "\n${BLUE}Checking branch protection...${NC}"

    local violations=0

    for branch in "${PROTECTED_BRANCHES[@]}"; do
        # Check if branch exists
        if ! git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
            log_verbose "  ${YELLOW}⚠${NC} Branch does not exist: ${branch} (skipping)"
            continue
        fi

        # Check protection via GitHub API
        local protection_status
        protection_status=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/branches/${branch}/protection" 2>/dev/null || echo "null")

        if [[ "$protection_status" == "null" || -z "$protection_status" ]]; then
            log_verbose "  ${RED}✗${NC} Branch not protected: ${branch}"
            ((violations++)) || true
        else
            log_verbose "  ${GREEN}✓${NC} Branch protected: ${branch}"

            # Check specific protection rules if verbose
            if $VERBOSE; then
                local required_reviews=$(echo "$protection_status" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo "0")
                local required_checks=$(echo "$protection_status" | jq -r '.required_status_checks.checks | length' 2>/dev/null || echo "0")

                log_verbose "      Required reviews: ${required_reviews}"
                log_verbose "      Required checks: ${required_checks}"
            fi
        fi
    done

    echo "$violations"
}

# Check GitHub features
check_github_features() {
    log_verbose "\n${BLUE}Checking GitHub features...${NC}"

    local violations=0

    # Get repo settings
    local repo_settings
    repo_settings=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}" 2>/dev/null || echo "{}")

    # Check if issues are enabled
    local has_issues=$(echo "$repo_settings" | jq -r '.has_issues // false')
    if [[ "$has_issues" == "true" ]]; then
        log_verbose "  ${GREEN}✓${NC} Issues enabled"
    else
        log_verbose "  ${YELLOW}⚠${NC} Issues not enabled"
        # Not counted as violation (may be intentional)
    fi

    # Check if PRs are enabled
    local has_pr=$(echo "$repo_settings" | jq -r '.has_pull_requests // true')
    if [[ "$has_pr" == "true" || "$has_pr" == "null" ]]; then
        log_verbose "  ${GREEN}✓${NC} Pull requests enabled"
    else
        log_verbose "  ${RED}✗${NC} Pull requests not enabled"
        ((violations++)) || true
    fi

    # Check default branch
    local default_branch=$(echo "$repo_settings" | jq -r '.default_branch // "main"')
    if [[ "$default_branch" == "main" ]]; then
        log_verbose "  ${GREEN}✓${NC} Default branch is 'main'"
    else
        log_verbose "  ${YELLOW}⚠${NC} Default branch is '${default_branch}' (expected 'main')"
        # Not counted as violation (may be intentional)
    fi

    echo "$violations"
}

# Generate remediation guidance
generate_remediation() {
    local label_violations="$1"
    local file_violations="$2"
    local branch_violations="$3"
    local feature_violations="$4"

    if [[ $((label_violations + file_violations + branch_violations + feature_violations)) -eq 0 ]]; then
        return
    fi

    log "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${YELLOW}Remediation Steps${NC}"
    log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ $label_violations -gt 0 ]]; then
        log "\n${BLUE}Missing Labels:${NC}"
        log "  Run with --fix to create missing labels:"
        log "    ${CYAN}./scripts/policy-validator.sh --fix${NC}"
        log ""
        log "  Or create manually with gh CLI:"
        for label_spec in "${REQUIRED_LABELS[@]}"; do
            IFS=':' read -r label_name label_color label_desc <<< "$label_spec"
            log "    ${CYAN}gh label create \"${label_name}\" --color \"${label_color}\" --description \"${label_desc}\"${NC}"
        done
    fi

    if [[ $file_violations -gt 0 ]]; then
        log "\n${BLUE}Missing Files:${NC}"
        log "  Create the required files:"
        for file in "${REQUIRED_FILES[@]}"; do
            if [[ ! -f "$REPO_DIR/$file" ]]; then
                log "    ${CYAN}touch ${file}${NC}"
            fi
        done
    fi

    if [[ $branch_violations -gt 0 ]]; then
        log "\n${BLUE}Unprotected Branches:${NC}"
        log "  Enable branch protection in GitHub settings:"
        log "    ${CYAN}https://github.com/${REPO_OWNER}/${REPO_NAME}/settings/branches${NC}"
        log ""
        log "  For each protected branch (main, dev, qa):"
        log "    - Require pull request reviews"
        log "    - Require status checks to pass"
        log "    - Do not allow bypassing the above settings"
    fi

    if [[ $feature_violations -gt 0 ]]; then
        log "\n${BLUE}GitHub Features:${NC}"
        log "  Enable required features in repository settings:"
        log "    ${CYAN}https://github.com/${REPO_OWNER}/${REPO_NAME}/settings${NC}"
    fi
}

# Main validation
main() {
    get_repo_info

    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "${BLUE}Repository Policy Validation${NC}"
    log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "Repository: ${REPO_OWNER}/${REPO_NAME}"

    # Run all checks
    local label_violations
    local file_violations
    local branch_violations
    local feature_violations

    label_violations=$(check_labels)
    file_violations=$(check_required_files)
    branch_violations=$(check_branch_protection)
    feature_violations=$(check_github_features)

    local total_violations=$((label_violations + file_violations + branch_violations + feature_violations))

    # Output results
    if $JSON_OUTPUT; then
        jq -n \
            --argjson label_violations "$label_violations" \
            --argjson file_violations "$file_violations" \
            --argjson branch_violations "$branch_violations" \
            --argjson feature_violations "$feature_violations" \
            --argjson total "$total_violations" \
            '{
                compliant: ($total == 0),
                violations: {
                    labels: $label_violations,
                    files: $file_violations,
                    branches: $branch_violations,
                    features: $feature_violations,
                    total: $total
                }
            }'
    else
        log "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "${BLUE}Validation Summary${NC}"
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log "  Labels:   $label_violations violation(s)"
        log "  Files:    $file_violations violation(s)"
        log "  Branches: $branch_violations violation(s)"
        log "  Features: $feature_violations violation(s)"
        log "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        if [[ $total_violations -eq 0 ]]; then
            log "\n${GREEN}✓ Repository is compliant with all policies${NC}\n"
        else
            log "\n${RED}✗ Found $total_violations policy violation(s)${NC}"
            generate_remediation "$label_violations" "$file_violations" "$branch_violations" "$feature_violations"
            log ""
        fi
    fi

    # Exit with appropriate code
    if [[ $total_violations -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

main
