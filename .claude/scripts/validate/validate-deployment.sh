#!/usr/bin/env bash
set -euo pipefail
#
# validate-deployment.sh
# Validate $FRAMEWORK_DIR directory structure and configuration
# Default: ~/.claude-agent/ (configurable via FRAMEWORK_NAME env var)
# size-ok: comprehensive validation with detailed error reporting
#
# Usage:
#   ./validate-deployment.sh              # Run all validations
#   ./validate-deployment.sh --quick      # Quick validation (structure only)
#   ./validate-deployment.sh --fix        # Attempt to fix issues
#   ./validate-deployment.sh --json       # Output results as JSON
#
# Exit codes:
#   0 - All validations passed
#   1 - Validation errors found
#   2 - Not initialized (run init-deployment.sh first)
#

set -eo pipefail

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    # Minimal fallback
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[OK] $*" >&2; }
fi

# Source framework config to get FRAMEWORK_DIR (default: ~/.claude-agent)
source "${SCRIPT_DIR}/lib/framework-config.sh"

# Configuration
CLAUDE_AGENTS_DIR="${FRAMEWORK_DIR}"
SYNC_STATE_FILE="${CLAUDE_AGENTS_DIR}/.sync-state.json"

# Parse arguments
QUICK_MODE=false
FIX_MODE=false
JSON_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK_MODE=true
            shift
            ;;
        --fix)
            FIX_MODE=true
            shift
            ;;
        --json)
            JSON_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--quick|--fix|--json|--help]"
            echo ""
            echo "Options:"
            echo "  --quick  Quick check (structure only)"
            echo "  --fix    Attempt to auto-fix issues"
            echo "  --json   Output results as JSON"
            echo "  --help   Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validation results (initialize as empty)
ERRORS=()
WARNINGS=()
FIXED=()

add_error() { ERRORS+=("$1"); }
add_warning() { WARNINGS+=("$1"); }
add_fixed() { FIXED+=("$1"); }

# Expected directories and permissions (in order)
# Format: "directory:permissions"
EXPECTED_DIRS=(
    "${CLAUDE_AGENTS_DIR}:755"
    "${CLAUDE_AGENTS_DIR}/credentials:700"
    "${CLAUDE_AGENTS_DIR}/overrides:755"
    "${CLAUDE_AGENTS_DIR}/overrides/agents:755"
    "${CLAUDE_AGENTS_DIR}/overrides/n8n-workflows:755"
    "${CLAUDE_AGENTS_DIR}/state:755"
)

# Get file permissions (cross-platform)
get_permissions() {
    local path="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f "%OLp" "$path" 2>/dev/null || echo "000"
    else
        stat -c "%a" "$path" 2>/dev/null || echo "000"
    fi
}

# Validate directory structure
validate_structure() {
    if ! $JSON_MODE; then
        log_info "Validating directory structure..."
    fi

    for entry in "${EXPECTED_DIRS[@]}"; do
        dir="${entry%%:*}"
        expected="${entry##*:}"

        if [ ! -d "$dir" ]; then
            if $FIX_MODE; then
                mkdir -p "$dir"
                chmod "$expected" "$dir"
                add_fixed "Created missing directory: $dir"
            else
                add_error "Missing directory: $dir"
            fi
        else
            actual=$(get_permissions "$dir")
            if [ "$actual" != "$expected" ]; then
                if $FIX_MODE; then
                    chmod "$expected" "$dir"
                    add_fixed "Fixed permissions on $dir ($actual -> $expected)"
                else
                    add_error "Wrong permissions on $dir: expected $expected, got $actual"
                fi
            fi
        fi
    done
}

# Validate sync state file
validate_sync_state() {
    if $QUICK_MODE; then
        return 0
    fi

    if ! $JSON_MODE; then
        log_info "Validating sync state file..."
    fi

    if [ ! -f "$SYNC_STATE_FILE" ]; then
        if $FIX_MODE; then
            # Create minimal sync state
            local timestamp
            timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            cat > "$SYNC_STATE_FILE" << EOF
{
  "schema_version": "1.0",
  "initialized_at": "$timestamp",
  "last_sync": null,
  "applied_versions": {
    "agents": null,
    "n8n-workflows": null,
    "settings": null
  },
  "sync_enabled": false
}
EOF
            add_fixed "Created missing sync state file"
        else
            add_error "Missing sync state file: $SYNC_STATE_FILE"
        fi
        return 0
    fi

    # Validate JSON syntax
    if ! jq empty "$SYNC_STATE_FILE" 2>/dev/null; then
        add_error "Invalid JSON in sync state file"
        return 0
    fi

    # Validate required fields
    local schema_version
    schema_version=$(jq -r '.schema_version // empty' "$SYNC_STATE_FILE")
    if [ -z "$schema_version" ]; then
        add_error "Missing schema_version in sync state"
    fi

    local initialized_at
    initialized_at=$(jq -r '.initialized_at // empty' "$SYNC_STATE_FILE")
    if [ -z "$initialized_at" ]; then
        add_error "Missing initialized_at in sync state"
    fi

    # Validate applied_versions structure
    if ! jq -e '.applied_versions' "$SYNC_STATE_FILE" >/dev/null 2>&1; then
        add_error "Missing applied_versions in sync state"
    fi
}

# Validate credentials security
validate_credentials() {
    if $QUICK_MODE; then
        return 0
    fi

    if ! $JSON_MODE; then
        log_info "Validating credentials security..."
    fi

    local cred_dir="${CLAUDE_AGENTS_DIR}/credentials"
    if [ ! -d "$cred_dir" ]; then
        return 0  # Already flagged in structure validation
    fi

    # Check credentials directory permissions
    local cred_perms
    cred_perms=$(get_permissions "$cred_dir")
    if [ "$cred_perms" != "700" ]; then
        if $FIX_MODE; then
            chmod 700 "$cred_dir"
            add_fixed "Fixed credentials directory permissions"
        else
            add_error "Credentials directory should have mode 700, has $cred_perms"
        fi
    fi

    # Check individual credential file permissions
    for cred_file in "$cred_dir"/*; do
        if [ -f "$cred_file" ]; then
            local file_perms
            file_perms=$(get_permissions "$cred_file")
            if [ "$file_perms" != "600" ]; then
                if $FIX_MODE; then
                    chmod 600 "$cred_file"
                    add_fixed "Fixed permissions on $(basename "$cred_file")"
                else
                    add_warning "Credential file $(basename "$cred_file") should have mode 600, has $file_perms"
                fi
            fi
        fi
    done
}

# Detect sensitive data outside credentials directory
detect_sensitive_leaks() {
    if $QUICK_MODE; then
        return 0
    fi

    if ! $JSON_MODE; then
        log_info "Checking for sensitive data leaks..."
    fi

    # Look for files that might contain secrets outside credentials dir
    local sensitive_patterns=(
        "token"
        "secret"
        "password"
        "api.key"
        "apikey"
    )

    for pattern in "${sensitive_patterns[@]}"; do
        while IFS= read -r -d '' file; do
            # Skip the credentials directory
            if [[ "$file" == "${CLAUDE_AGENTS_DIR}/credentials"* ]]; then
                continue
            fi
            add_warning "Potentially sensitive file outside credentials: $file"
        done < <(find "$CLAUDE_AGENTS_DIR" -type f -iname "*${pattern}*" -print0 2>/dev/null || true)
    done
}

# Output JSON results
output_json() {
    local status="pass"
    local error_count=${#ERRORS[@]}
    local warning_count=${#WARNINGS[@]}

    if [ "$error_count" -gt 0 ]; then
        status="fail"
    elif [ "$warning_count" -gt 0 ]; then
        status="warn"
    fi

    echo "{"
    echo "  \"status\": \"$status\","
    echo "  \"directory\": \"$CLAUDE_AGENTS_DIR\","
    echo -n "  \"errors\": ["

    local first=true
    for err in "${ERRORS[@]+"${ERRORS[@]}"}"; do
        if [ -z "$err" ]; then continue; fi
        if $first; then
            first=false
            echo ""
        else
            echo ","
        fi
        printf '    "%s"' "$err"
    done
    if [ "$error_count" -gt 0 ]; then echo ""; fi
    echo "  ],"

    echo -n "  \"warnings\": ["
    first=true
    for warn in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do
        if [ -z "$warn" ]; then continue; fi
        if $first; then
            first=false
            echo ""
        else
            echo ","
        fi
        printf '    "%s"' "$warn"
    done
    if [ "$warning_count" -gt 0 ]; then echo ""; fi
    echo "  ],"

    echo -n "  \"fixed\": ["
    first=true
    local fix_count=${#FIXED[@]}
    for fix in "${FIXED[@]+"${FIXED[@]}"}"; do
        if [ -z "$fix" ]; then continue; fi
        if $first; then
            first=false
            echo ""
        else
            echo ","
        fi
        printf '    "%s"' "$fix"
    done
    if [ "$fix_count" -gt 0 ]; then echo ""; fi
    echo "  ]"
    echo "}"
}

# Output human-readable results
output_human() {
    echo ""

    if [ ${#FIXED[@]} -gt 0 ]; then
        echo "Fixed:"
        for fix in "${FIXED[@]}"; do
            log_success "  $fix"
        done
        echo ""
    fi

    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo "Errors:"
        for err in "${ERRORS[@]}"; do
            log_error "  $err"
        done
        echo ""
    fi

    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo "Warnings:"
        for warn in "${WARNINGS[@]}"; do
            log_warn "  $warn"
        done
        echo ""
    fi

    if [ ${#ERRORS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
        log_success "All validations passed"
    elif [ ${#ERRORS[@]} -eq 0 ]; then
        log_warn "Validation passed with warnings"
    else
        log_error "Validation failed with ${#ERRORS[@]} error(s)"
    fi
}

# Main validation
main() {
    # Check if initialized
    if [ ! -d "$CLAUDE_AGENTS_DIR" ]; then
        if $JSON_MODE; then
            echo '{"status": "not_initialized", "error": "Run init-deployment.sh first"}'
        else
            log_error "Deployment not initialized. Run init-deployment.sh first."
        fi
        exit 2
    fi

    # Run validations
    validate_structure
    validate_sync_state
    validate_credentials
    detect_sensitive_leaks

    # Output results
    if $JSON_MODE; then
        output_json
    else
        output_human
    fi

    # Exit code based on results
    if [ ${#ERRORS[@]} -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main
