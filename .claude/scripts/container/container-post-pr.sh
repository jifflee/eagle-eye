#!/bin/bash
set -euo pipefail
# container-post-pr.sh
# Automatic cleanup trigger after PR creation in container
# Part of Phase 5: Automatic container cleanup (Issue #135)
#
# This script is called after a PR is successfully created inside a container.
# It handles:
#   1. Logging PR creation success
#   2. Optionally checking CI status (with wait and retry)
#   3. Triggering container cleanup (on host)
#   4. Preserving logs before cleanup
#
# Usage (inside container):
#   ./scripts/container-post-pr.sh --issue 107 --pr 456
#   ./scripts/container-post-pr.sh --issue 107 --pr 456 --check-ci
#
# The actual container removal happens from the HOST, not from inside
# the container. This script prepares the container for cleanup.

set -e

# Script metadata
SCRIPT_NAME="container-post-pr.sh"
VERSION="1.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/../lib/common.sh"

# Usage
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Post-PR cleanup trigger

USAGE:
    $SCRIPT_NAME --issue <N> --pr <N>

OPTIONS:
    --issue <N>     Issue number that was worked on
    --pr <N>        PR number that was created
    --check-ci      Check CI status before cleanup (with wait/retry)
    --ci-wait <N>   Initial wait before CI check in seconds (default: 60)
    --ci-timeout <N> Max CI wait time in seconds (default: 600)
    --keep          Don't trigger cleanup (keep container)
    --help          Show this help

DESCRIPTION:
    Called after PR is created to prepare container for cleanup.
    Creates a marker file that signals the container is ready for removal.

EOF
}

# Parse arguments
ISSUE=""
PR=""
KEEP="false"
CHECK_CI="false"
CI_WAIT=60
CI_TIMEOUT=600

while [ $# -gt 0 ]; do
    case "$1" in
        --issue)
            ISSUE="$2"
            shift 2
            ;;
        --pr)
            PR="$2"
            shift 2
            ;;
        --check-ci)
            CHECK_CI="true"
            shift
            ;;
        --ci-wait)
            CI_WAIT="$2"
            shift 2
            ;;
        --ci-timeout)
            CI_TIMEOUT="$2"
            shift 2
            ;;
        --keep)
            KEEP="true"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Validate
if [ -z "$ISSUE" ] || [ -z "$PR" ]; then
    echo "Error: --issue and --pr are required" >&2
    usage
    exit 1
fi

# Main logic
log_info "PR #$PR created for issue #$ISSUE"

# Check CI status if requested
CI_STATUS="unknown"
CI_RESULT=""
if [ "$CHECK_CI" = "true" ]; then
    log_info "Checking CI status with wait and retry..."
    log_info "Initial wait: ${CI_WAIT}s, Timeout: ${CI_TIMEOUT}s"

    if [ -x "$SCRIPT_DIR/check-pr-ci-status.sh" ]; then
        set +e
        CI_RESULT=$("$SCRIPT_DIR/check-pr-ci-status.sh" "$PR" \
            --wait "$CI_WAIT" \
            --timeout "$CI_TIMEOUT" \
            --json)
        CI_EXIT=$?
        set -e

        # Validate CI_RESULT is valid JSON before parsing
        if echo "$CI_RESULT" | jq empty 2>/dev/null; then
            CI_STATUS=$(echo "$CI_RESULT" | jq -r '.status // "unknown"')
            CI_SUMMARY=$(echo "$CI_RESULT" | jq -r '.summary // "No summary available"')
        else
            log_warn "CI status check returned non-JSON output (exit $CI_EXIT): ${CI_RESULT:0:200}"
            CI_STATUS="error"
            CI_SUMMARY="CI status check failed with non-JSON output"
            CI_EXIT=3
        fi

        case $CI_EXIT in
            0)
                log_info "CI Status: ${GREEN}MERGEABLE${NC} - $CI_SUMMARY"
                ;;
            1)
                log_error "CI Status: ${RED}NEEDS REVIEW${NC} - $CI_SUMMARY"
                # Show failed checks only if we have valid JSON
                if echo "$CI_RESULT" | jq empty 2>/dev/null; then
                    FAILED=$(echo "$CI_RESULT" | jq -r '.checks.failed_checks // ""')
                    if [ -n "$FAILED" ]; then
                        log_error "Failed checks: $FAILED"
                    fi
                fi
                ;;
            2)
                log_warn "CI Status: ${YELLOW}PENDING${NC} - $CI_SUMMARY"
                ;;
            *)
                log_warn "CI Status: Could not determine status"
                ;;
        esac
    else
        log_warn "CI check script not found at $SCRIPT_DIR/check-pr-ci-status.sh"
    fi
fi

if [ "$KEEP" = "true" ]; then
    log_info "Container marked for retention (--keep flag)"
    exit 0
fi

# Create marker file indicating container is ready for cleanup
# This file is checked by the cleanup script on the host
MARKER_FILE="/tmp/container-cleanup-ready"
cat > "$MARKER_FILE" << EOF
{
    "issue": $ISSUE,
    "pr": $PR,
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "status": "pr_created",
    "ci_status": "$CI_STATUS",
    "cleanup_requested": true
}
EOF

log_info "Container marked for cleanup"
log_info "Marker file: $MARKER_FILE"

# Print cleanup instructions for host
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}PR #$PR created successfully!${NC}"
echo ""

# Show CI status summary if checked
if [ "$CHECK_CI" = "true" ]; then
    case "$CI_STATUS" in
        mergeable)
            echo -e "CI Status: ${GREEN}MERGEABLE${NC} - Ready to merge"
            ;;
        needs_review)
            echo -e "CI Status: ${RED}NEEDS REVIEW${NC} - Check failed CI checks"
            echo ""
            echo "View checks: gh pr checks $PR"
            ;;
        pending)
            echo -e "CI Status: ${YELLOW}PENDING${NC} - Some checks still running"
            echo ""
            echo "Monitor: gh pr checks $PR --watch"
            ;;
        *)
            echo -e "CI Status: ${YELLOW}UNKNOWN${NC}"
            ;;
    esac
    echo ""
fi

echo "Container work is complete. To cleanup from HOST:"
echo ""
echo "  ./scripts/container-cleanup.sh --issue $ISSUE"
echo ""
echo "Or let the orphan detector handle it automatically."
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
