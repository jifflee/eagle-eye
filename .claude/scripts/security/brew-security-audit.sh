#!/usr/bin/env bash

###############################################################################
# Homebrew Security Audit Script
#
# Purpose: Audit installed Homebrew formulae and casks for security issues
# Usage: ./brew-security-audit.sh [--json] [--verbose]
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VERBOSE=false
JSON_OUTPUT=false
GITHUB_API="https://api.github.com"
CVE_API="https://services.nvd.nist.gov/rest/json/cves/2.0"
MIN_GITHUB_STARS=100
MIN_DAYS_SINCE_UPDATE=365

# Report arrays
declare -a CRITICAL_ISSUES=()
declare -a WARNINGS=()
declare -a INFO=()

###############################################################################
# Helper Functions
###############################################################################

log_info() {
    if [[ "$VERBOSE" == true ]] || [[ "$JSON_OUTPUT" == false ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
    WARNINGS+=("$1")
}

log_critical() {
    echo -e "${RED}[CRITICAL]${NC} $1" >&2
    CRITICAL_ISSUES+=("$1")
}

log_success() {
    if [[ "$VERBOSE" == true ]] || [[ "$JSON_OUTPUT" == false ]]; then
        echo -e "${GREEN}[OK]${NC} $1"
    fi
}

###############################################################################
# Check if brew is installed
###############################################################################

check_brew_installed() {
    if ! command -v brew &> /dev/null; then
        echo "Error: Homebrew is not installed"
        exit 1
    fi
}

###############################################################################
# Get installed formulae and casks
###############################################################################

get_installed_formulae() {
    brew list --formula 2>/dev/null || true
}

get_installed_casks() {
    brew list --cask 2>/dev/null || true
}

###############################################################################
# Check if package is from official tap
###############################################################################

is_official_tap() {
    local package_name="$1"
    local package_type="$2"

    local tap_info
    if [[ "$package_type" == "formula" ]]; then
        tap_info=$(brew info --json=v2 "$package_name" 2>/dev/null | jq -r '.formulae[0].tap // "homebrew/core"')
    else
        tap_info=$(brew info --json=v2 --cask "$package_name" 2>/dev/null | jq -r '.casks[0].tap // "homebrew/cask"')
    fi

    # Official taps are homebrew/core and homebrew/cask
    if [[ "$tap_info" =~ ^homebrew/(core|cask)$ ]]; then
        return 0
    else
        return 1
    fi
}

###############################################################################
# Get GitHub repository info
###############################################################################

get_github_info() {
    local package_name="$1"
    local package_type="$2"

    local homepage
    if [[ "$package_type" == "formula" ]]; then
        homepage=$(brew info --json=v2 "$package_name" 2>/dev/null | jq -r '.formulae[0].homepage // ""')
    else
        homepage=$(brew info --json=v2 --cask "$package_name" 2>/dev/null | jq -r '.casks[0].homepage // ""')
    fi

    # Extract GitHub repo from homepage
    if [[ "$homepage" =~ github\.com/([^/]+)/([^/]+) ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"

        # Remove .git suffix if present
        repo="${repo%.git}"

        # Query GitHub API (rate limited)
        local github_data
        github_data=$(curl -s -H "Accept: application/vnd.github.v3+json" \
            "$GITHUB_API/repos/$owner/$repo" 2>/dev/null || echo "{}")

        echo "$github_data"
    else
        echo "{}"
    fi
}

###############################################################################
# Check package reputation
###############################################################################

check_package_reputation() {
    local package_name="$1"
    local package_type="$2"

    log_info "Checking reputation for $package_type: $package_name"

    # Check if official tap
    if is_official_tap "$package_name" "$package_type"; then
        log_success "$package_name is from official Homebrew tap"
        INFO+=("$package_name: Official tap ✓")
    else
        log_warning "$package_name is from third-party tap"
        local tap
        if [[ "$package_type" == "formula" ]]; then
            tap=$(brew info --json=v2 "$package_name" 2>/dev/null | jq -r '.formulae[0].tap // "unknown"')
        else
            tap=$(brew info --json=v2 --cask "$package_name" 2>/dev/null | jq -r '.casks[0].tap // "unknown"')
        fi
        WARNINGS+=("$package_name: Third-party tap ($tap) - verify trustworthiness")
    fi

    # Get GitHub info
    local github_info
    github_info=$(get_github_info "$package_name" "$package_type")

    if [[ "$github_info" != "{}" ]] && [[ "$(echo "$github_info" | jq -r '.id // ""')" != "" ]]; then
        local stars=$(echo "$github_info" | jq -r '.stargazers_count // 0')
        local updated_at=$(echo "$github_info" | jq -r '.updated_at // ""')
        local archived=$(echo "$github_info" | jq -r '.archived // false')

        # Check stars
        if [[ "$stars" -lt "$MIN_GITHUB_STARS ]]; then
            log_warning "$package_name has low GitHub stars: $stars (threshold: $MIN_GITHUB_STARS)"
        else
            log_success "$package_name has $stars GitHub stars"
        fi

        # Check if archived
        if [[ "$archived" == "true" ]]; then
            log_critical "$package_name: GitHub repository is ARCHIVED - no longer maintained!"
        fi

        # Check last update
        if [[ -n "$updated_at" ]]; then
            local last_update_days=$(( ($(date +%s) - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null || date +%s)) / 86400 ))
            if [[ "$last_update_days" -gt "$MIN_DAYS_SINCE_UPDATE" ]]; then
                log_warning "$package_name: Last updated $last_update_days days ago (threshold: $MIN_DAYS_SINCE_UPDATE days)"
            fi
        fi
    fi
}

###############################################################################
# Check for outdated packages
###############################################################################

check_outdated_packages() {
    log_info "Checking for outdated packages..."

    local outdated_formulae
    outdated_formulae=$(brew outdated --formula 2>/dev/null || true)

    if [[ -n "$outdated_formulae" ]]; then
        log_warning "Outdated formulae detected (may contain security fixes):"
        while IFS= read -r formula; do
            if [[ -n "$formula" ]]; then
                log_warning "  - $formula"
                WARNINGS+=("Outdated formula: $formula")
            fi
        done <<< "$outdated_formulae"
    fi

    local outdated_casks
    outdated_casks=$(brew outdated --cask 2>/dev/null || true)

    if [[ -n "$outdated_casks" ]]; then
        log_warning "Outdated casks detected (may contain security fixes):"
        while IFS= read -r cask; do
            if [[ -n "$cask" ]]; then
                log_warning "  - $cask"
                WARNINGS+=("Outdated cask: $cask")
            fi
        done <<< "$outdated_casks"
    fi
}

###############################################################################
# Run brew audit
###############################################################################

run_brew_audit() {
    log_info "Running brew audit on installed packages..."

    # Audit formulae
    while IFS= read -r formula; do
        if [[ -n "$formula" ]]; then
            local audit_result
            audit_result=$(brew audit "$formula" 2>&1 || true)

            if [[ -n "$audit_result" ]] && [[ "$audit_result" != *"no offenses detected"* ]]; then
                log_warning "Audit issues found for $formula:"
                echo "$audit_result" | while IFS= read -r line; do
                    log_warning "  $line"
                done
            fi
        fi
    done < <(get_installed_formulae)
}

###############################################################################
# Search for CVEs (simplified - would need API key for full functionality)
###############################################################################

check_cves() {
    local package_name="$1"

    log_info "Checking CVEs for $package_name (basic search)..."

    # Note: This is a simplified check. Full implementation would require:
    # - API key for NVD
    # - Version matching logic
    # - More sophisticated package name mapping

    # For now, we'll just note that this check should be performed
    INFO+=("$package_name: Manual CVE check recommended at https://nvd.nist.gov")
}

###############################################################################
# Generate report
###############################################################################

generate_report() {
    echo ""
    echo "========================================================================"
    echo "  HOMEBREW SECURITY AUDIT REPORT"
    echo "========================================================================"
    echo "  Generated: $(date)"
    echo "========================================================================"
    echo ""

    local total_formulae=$(get_installed_formulae | wc -l | xargs)
    local total_casks=$(get_installed_casks | wc -l | xargs)

    echo "Summary:"
    echo "  - Total formulae installed: $total_formulae"
    echo "  - Total casks installed: $total_casks"
    echo "  - Critical issues: ${#CRITICAL_ISSUES[@]}"
    echo "  - Warnings: ${#WARNINGS[@]}"
    echo ""

    if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        echo -e "${RED}CRITICAL ISSUES:${NC}"
        for issue in "${CRITICAL_ISSUES[@]}"; do
            echo "  ❌ $issue"
        done
        echo ""
    fi

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}WARNINGS:${NC}"
        for warning in "${WARNINGS[@]}"; do
            echo "  ⚠️  $warning"
        done
        echo ""
    fi

    echo "========================================================================"
    echo "  RECOMMENDATIONS"
    echo "========================================================================"
    echo ""
    echo "1. Update all outdated packages:"
    echo "   $ brew update && brew upgrade"
    echo ""
    echo "2. Review third-party taps and verify trustworthiness"
    echo ""
    echo "3. Remove archived or unmaintained packages:"
    echo "   $ brew uninstall <package-name>"
    echo ""
    echo "4. Check for security advisories:"
    echo "   - Visit https://github.com/Homebrew/homebrew-core/security/advisories"
    echo "   - Check https://nvd.nist.gov for specific package CVEs"
    echo ""
    echo "5. Run 'brew doctor' to check for configuration issues:"
    echo "   $ brew doctor"
    echo ""
    echo "========================================================================"
}

###############################################################################
# Main execution
###############################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--json] [--verbose]"
                echo ""
                echo "Options:"
                echo "  --json      Output in JSON format"
                echo "  --verbose   Enable verbose output"
                echo "  --help      Show this help message"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    check_brew_installed

    log_info "Starting Homebrew security audit..."
    echo ""

    # Check outdated packages first
    check_outdated_packages
    echo ""

    # Audit formulae
    log_info "Auditing installed formulae..."
    while IFS= read -r formula; do
        if [[ -n "$formula" ]]; then
            check_package_reputation "$formula" "formula"
        fi
    done < <(get_installed_formulae)
    echo ""

    # Audit casks
    log_info "Auditing installed casks..."
    while IFS= read -r cask; do
        if [[ -n "$cask" ]]; then
            check_package_reputation "$cask" "cask"
        fi
    done < <(get_installed_casks)
    echo ""

    # Generate final report
    generate_report

    # Exit code based on findings
    if [[ ${#CRITICAL_ISSUES[@]} -gt 0 ]]; then
        exit 2
    elif [[ ${#WARNINGS[@]} -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# Run main function
main "$@"
