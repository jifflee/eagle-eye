#!/usr/bin/env bash
#
# check-dependencies.sh
# Validates dependency rules, circular imports, and security vulnerabilities
#
# Usage:
#   ./scripts/ci/check-dependencies.sh [--fix] [--verbose]
#
# Options:
#   --fix      Attempt to auto-fix issues where possible
#   --verbose  Show detailed output
#
# Exit codes:
#   0 - All checks passed
#   1 - Circular dependencies detected
#   2 - Dependency rule violations detected
#   3 - Security vulnerabilities detected
#   4 - Lock file out of sync

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Parse arguments
FIX_MODE=false
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "[DEBUG] $1"
    fi
}

# Track overall status
EXIT_CODE=0

cd "$PROJECT_ROOT"

# Check if we're in a Node.js project
if [ ! -f "package.json" ]; then
    log_warn "No package.json found. Dependency checks require Node.js project."
    exit 0
fi

# Check if dependencies are installed
if [ ! -d "node_modules" ]; then
    log_info "Installing dependencies..."
    npm ci
fi

echo "=========================================="
echo "Dependency Analysis Report"
echo "=========================================="
echo ""

# 1. Check for circular dependencies
log_info "Checking for circular dependencies..."
if command -v npx &> /dev/null; then
    if npx madge --circular --extensions ts,js src/ 2>/dev/null; then
        log_info "No circular dependencies found"
    else
        log_error "Circular dependencies detected!"
        echo ""
        echo "To visualize the dependency graph, run:"
        echo "  npm run deps:graph"
        echo ""
        EXIT_CODE=1
    fi
else
    log_warn "npx not available, skipping circular dependency check"
fi

echo ""

# 2. Check dependency rules
log_info "Validating dependency rules..."
if [ -f ".dependency-cruiser.cjs" ] || [ -f ".dependency-cruiser.js" ]; then
    if npx dependency-cruiser --validate src/ 2>/dev/null; then
        log_info "All dependency rules passed"
    else
        log_error "Dependency rule violations detected!"
        echo ""
        echo "Review the rules in .dependency-cruiser.cjs"
        echo "See docs/standards/DEPENDENCY_RULES.md for guidelines"
        echo ""
        if [ $EXIT_CODE -eq 0 ]; then
            EXIT_CODE=2
        fi
    fi
else
    log_warn "No .dependency-cruiser.cjs found, skipping rule validation"
fi

echo ""

# 3. Check for security vulnerabilities
log_info "Checking for security vulnerabilities..."
AUDIT_OUTPUT=$(npm audit --json 2>/dev/null || true)
CRITICAL_COUNT=$(echo "$AUDIT_OUTPUT" | jq '.metadata.vulnerabilities.critical // 0' 2>/dev/null || echo "0")
HIGH_COUNT=$(echo "$AUDIT_OUTPUT" | jq '.metadata.vulnerabilities.high // 0' 2>/dev/null || echo "0")

if [ "$CRITICAL_COUNT" -gt 0 ] || [ "$HIGH_COUNT" -gt 0 ]; then
    log_error "Security vulnerabilities found: $CRITICAL_COUNT critical, $HIGH_COUNT high"
    echo ""
    echo "Run 'npm audit' for details"
    echo "Run 'npm audit fix' to attempt automatic fixes"
    echo ""
    if [ "$FIX_MODE" = true ]; then
        log_info "Attempting to fix vulnerabilities..."
        npm audit fix || true
    fi
    if [ $EXIT_CODE -eq 0 ]; then
        EXIT_CODE=3
    fi
else
    log_info "No critical or high vulnerabilities found"
fi

echo ""

# 4. Check if lock file is in sync
log_info "Checking package-lock.json sync..."
if [ -f "package-lock.json" ]; then
    # Check if lock file matches package.json
    if npm ls --json 2>&1 | grep -q "ELSPROBLEMS"; then
        log_warn "package-lock.json may be out of sync"
        echo "Run 'npm install' to update"
        if [ $EXIT_CODE -eq 0 ]; then
            EXIT_CODE=4
        fi
    else
        log_info "Lock file is in sync"
    fi
else
    log_warn "No package-lock.json found"
fi

echo ""

# 5. Optional: Generate coupling metrics (verbose mode only)
if [ "$VERBOSE" = true ]; then
    log_info "Generating coupling metrics..."
    echo ""
    echo "Top 10 modules by outgoing dependencies (efferent coupling):"
    npx madge --json src/ 2>/dev/null | jq -r '
        to_entries |
        map({module: .key, efferent: (.value | length)}) |
        sort_by(-.efferent) |
        .[:10] |
        .[] |
        "  \(.module): \(.efferent) dependencies"
    ' || true
    echo ""
fi

# Summary
echo "=========================================="
echo "Summary"
echo "=========================================="
if [ $EXIT_CODE -eq 0 ]; then
    log_info "All dependency checks passed!"
else
    log_error "Some checks failed (exit code: $EXIT_CODE)"
    echo ""
    echo "Exit codes:"
    echo "  1 = Circular dependencies"
    echo "  2 = Dependency rule violations"
    echo "  3 = Security vulnerabilities"
    echo "  4 = Lock file out of sync"
fi

exit $EXIT_CODE
