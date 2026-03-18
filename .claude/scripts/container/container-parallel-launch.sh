#!/bin/bash
set -euo pipefail
# container-parallel-launch.sh
# Launch multiple containers in parallel for independent epic children
# size-ok: parallel container orchestration with dependency checks and epic coordination
#
# PURPOSE:
#   Enables parallel work on independent issues (no dependencies between them).
#   Useful for epics with multiple children that can be worked simultaneously.
#
# USAGE:
#   ./scripts/container-parallel-launch.sh --epic <N> --issues <N1,N2,N3> --repo <owner/repo>
#   ./scripts/container-parallel-launch.sh --epic <N> --all-independent --repo <owner/repo>
#
# OPTIONS:
#   --epic <N>           Epic number (for context injection)
#   --issues <N1,N2,..>  Comma-separated list of issue numbers to launch
#   --all-independent    Auto-detect and launch all independent children
#   --repo <owner/repo>  Repository to clone (required)
#   --branch <branch>    Branch to checkout (default: auto-detected from repo's default branch)
#   --image <image>      Docker image to use
#   --max-parallel <N>   Maximum concurrent containers (default: 3)
#   --dry-run            Show what would be launched
#   --json               Output JSON status
#
# DEPENDENCIES:
#   - container-launch.sh
#   - issue-dependencies.sh
#   - detect-epic-children.sh

set -e

# Script metadata
SCRIPT_NAME="container-parallel-launch.sh"
VERSION="1.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    cat << EOF >&2
$SCRIPT_NAME v$VERSION - Launch parallel containers for independent epic children

USAGE:
    $SCRIPT_NAME --epic <N> --issues <N1,N2,N3> --repo <owner/repo>
    $SCRIPT_NAME --epic <N> --all-independent --repo <owner/repo>

OPTIONS:
    --epic <N>           Epic number (for context injection)
    --issues <N1,N2,..>  Comma-separated list of issue numbers
    --all-independent    Auto-detect and launch all independent children
    --repo <owner/repo>  Repository to clone (required)
    --branch <branch>    Branch to checkout (default: auto-detected from repo's default branch)
    --image <image>      Docker image to use
    --max-parallel <N>   Maximum concurrent containers (default: 3)
    --dry-run            Show what would be launched
    --json               Output JSON status

EXAMPLES:
    # Launch specific issues in parallel
    $SCRIPT_NAME --epic 128 --issues 132,133,134 --repo owner/repo

    # Auto-detect and launch all independent children
    $SCRIPT_NAME --epic 128 --all-independent --repo owner/repo

    # Dry run to see what would be launched
    $SCRIPT_NAME --epic 128 --all-independent --repo owner/repo --dry-run
EOF
    exit 2
}

# Parse arguments
EPIC=""
ISSUES=""
ALL_INDEPENDENT=false
REPO=""
BRANCH=""  # Auto-detected from repo's default branch if not specified
IMAGE="claude-dev-env:latest"
MAX_PARALLEL=""  # Auto-detect from environment (feature #775)
DRY_RUN=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --epic)
            EPIC="$2"
            shift 2
            ;;
        --issues)
            ISSUES="$2"
            shift 2
            ;;
        --all-independent)
            ALL_INDEPENDENT=true
            shift
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --image)
            IMAGE="$2"
            shift 2
            ;;
        --max-parallel)
            MAX_PARALLEL="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate arguments
if [[ -z "$EPIC" ]]; then
    log_error "--epic is required"
    usage
fi

if [[ -z "$REPO" ]]; then
    log_error "--repo is required"
    usage
fi

if [[ -z "$ISSUES" ]] && [[ "$ALL_INDEPENDENT" != "true" ]]; then
    log_error "Either --issues or --all-independent is required"
    usage
fi

# ============================================================================
# STEP 0: DETECT MAX PARALLEL FROM ENVIRONMENT (Feature #775)
# ============================================================================

if [[ -z "$MAX_PARALLEL" ]]; then
    log_info "Auto-detecting max parallel containers from environment..."

    RESOURCE_CHECK_SCRIPT="${SCRIPT_DIR}/check-resource-capacity.sh"
    if [[ -x "$RESOURCE_CHECK_SCRIPT" ]]; then
        RESOURCE_DATA=$("$RESOURCE_CHECK_SCRIPT" 2>/dev/null) || {
            log_warn "Resource capacity check failed, defaulting to 2 containers"
            MAX_PARALLEL=2
        }

        if [[ -n "$RESOURCE_DATA" ]]; then
            MAX_PARALLEL=$(echo "$RESOURCE_DATA" | jq -r '.scaling.max_containers // 2')
            ENVIRONMENT=$(echo "$RESOURCE_DATA" | jq -r '.scaling.environment // "local"')
            log_info "Environment: $ENVIRONMENT, Max parallel: $MAX_PARALLEL"
        else
            MAX_PARALLEL=2
        fi
    else
        log_warn "check-resource-capacity.sh not found, defaulting to 2 containers"
        MAX_PARALLEL=2
    fi
fi

# ============================================================================
# STEP 1: GET EPIC DATA
# ============================================================================

log_info "Getting epic #$EPIC children..."

EPIC_SCRIPT="${SCRIPT_DIR}/detect-epic-children.sh"
if [[ ! -x "$EPIC_SCRIPT" ]]; then
    log_error "detect-epic-children.sh not found"
    exit 1
fi

EPIC_DATA=$("$EPIC_SCRIPT" "$EPIC" 2>/dev/null) || {
    log_error "Failed to get epic data"
    exit 1
}

IS_EPIC=$(echo "$EPIC_DATA" | jq -r '.is_epic')
if [[ "$IS_EPIC" != "true" ]]; then
    log_error "Issue #$EPIC is not an epic"
    exit 1
fi

# ============================================================================
# STEP 2: DETERMINE ISSUES TO LAUNCH
# ============================================================================

ISSUE_LIST=()

if [[ "$ALL_INDEPENDENT" == "true" ]]; then
    log_info "Detecting independent children..."

    # Get all open children
    OPEN_CHILDREN=$(echo "$EPIC_DATA" | jq -r '.children.items | map(select(.state == "OPEN")) | .[].number')

    if [[ -z "$OPEN_CHILDREN" ]]; then
        log_info "No open children to process"
        exit 0
    fi

    # Check dependencies between children
    DEPS_SCRIPT="${SCRIPT_DIR}/issue-dependencies.sh"
    if [[ ! -x "$DEPS_SCRIPT" ]]; then
        log_warn "issue-dependencies.sh not found, cannot check dependencies"
        # Use all open children without dependency check
        ISSUE_LIST=($OPEN_CHILDREN)
    else
        # For each child, check if it has dependencies on other children
        for child in $OPEN_CHILDREN; do
            CHILD_DEPS=$("$DEPS_SCRIPT" "$child" 2>/dev/null | jq -r '.dependencies.depends_on // [] | map(select(.state == "OPEN")) | .[].number' 2>/dev/null || echo "")

            # Check if any dependencies are other children of this epic
            HAS_SIBLING_DEP=false
            for dep in $CHILD_DEPS; do
                if echo "$OPEN_CHILDREN" | grep -qw "$dep"; then
                    log_warn "Issue #$child depends on sibling #$dep, excluding from parallel"
                    HAS_SIBLING_DEP=true
                    break
                fi
            done

            if [[ "$HAS_SIBLING_DEP" != "true" ]]; then
                ISSUE_LIST+=("$child")
            fi
        done
    fi
else
    # Use provided list
    IFS=',' read -ra ISSUE_LIST <<< "$ISSUES"
fi

if [[ ${#ISSUE_LIST[@]} -eq 0 ]]; then
    log_info "No independent issues to launch"
    exit 0
fi

log_info "Found ${#ISSUE_LIST[@]} independent issue(s): ${ISSUE_LIST[*]}"

# ============================================================================
# STEP 3: DRY RUN CHECK
# ============================================================================

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo -e "${BLUE}=== DRY RUN ===${NC}"
    echo "Would launch containers for:"
    echo ""
    for issue in "${ISSUE_LIST[@]}"; do
        TITLE=$(echo "$EPIC_DATA" | jq -r --arg n "$issue" '.children.items[] | select(.number == ($n | tonumber)) | .title // "Unknown"')
        echo "  #$issue: $TITLE"
    done
    echo ""
    echo "Max parallel: $MAX_PARALLEL"
    echo "Repository: $REPO"
    echo "Branch: $BRANCH"

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        jq -n \
            --arg epic "$EPIC" \
            --argjson issues "$(printf '%s\n' "${ISSUE_LIST[@]}" | jq -R . | jq -s 'map(tonumber)')" \
            --arg repo "$REPO" \
            --arg branch "$BRANCH" \
            --argjson max_parallel "$MAX_PARALLEL" \
            '{
                dry_run: true,
                epic: ($epic | tonumber),
                issues: $issues,
                repo: $repo,
                branch: $branch,
                max_parallel: $max_parallel
            }'
    fi
    exit 0
fi

# ============================================================================
# STEP 4: LAUNCH CONTAINERS
# ============================================================================

LAUNCH_SCRIPT="${SCRIPT_DIR}/container-launch.sh"
if [[ ! -x "$LAUNCH_SCRIPT" ]]; then
    log_error "container-launch.sh not found"
    exit 1
fi

# Track launched containers
LAUNCHED=()
FAILED=()
PIDS=()

# Launch in batches respecting max parallel
log_info "Launching containers (max parallel: $MAX_PARALLEL)..."
echo ""

batch_count=0
for issue in "${ISSUE_LIST[@]}"; do
    # Wait if we've hit max parallel
    while [[ ${#PIDS[@]} -ge $MAX_PARALLEL ]]; do
        # Wait for any background job to finish
        for i in "${!PIDS[@]}"; do
            pid="${PIDS[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null || true
                unset "PIDS[$i]"
            fi
        done
        # Compact array
        PIDS=("${PIDS[@]}")
        sleep 1
    done

    # Check resource capacity before launching (feature #775)
    RESOURCE_CHECK_SCRIPT="${SCRIPT_DIR}/check-resource-capacity.sh"
    if [[ -x "$RESOURCE_CHECK_SCRIPT" ]]; then
        RESOURCE_CHECK=$("$RESOURCE_CHECK_SCRIPT" 2>/dev/null) || true
        if [[ -n "$RESOURCE_CHECK" ]]; then
            HAS_CAPACITY=$(echo "$RESOURCE_CHECK" | jq -r '.has_capacity // false')
            if [[ "$HAS_CAPACITY" != "true" ]]; then
                REASON=$(echo "$RESOURCE_CHECK" | jq -r '.reason // "Resource capacity unavailable"')
                log_warn "Skipping launch for #$issue: $REASON"
                log_warn "Waiting for capacity to become available..."
                sleep 5
                continue
            fi
        fi
    fi

    log_info "Launching container for issue #$issue..."

    # Launch in background with detach mode
    # Only pass --branch if explicitly specified; otherwise container-launch.sh detects it
    BRANCH_ARGS=()
    if [[ -n "$BRANCH" ]]; then
        BRANCH_ARGS=("--branch" "$BRANCH")
    fi
    "$LAUNCH_SCRIPT" \
        --issue "$issue" \
        --repo "$REPO" \
        "${BRANCH_ARGS[@]}" \
        --image "$IMAGE" \
        --detach \
        --skip-preflight \
        >/dev/null 2>&1 &

    PIDS+=($!)
    LAUNCHED+=("$issue")
    ((batch_count++))

    # Small delay between launches to avoid race conditions
    sleep 2
done

# Wait for remaining launches
for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# ============================================================================
# STEP 5: REPORT STATUS
# ============================================================================

echo ""
log_info "Launch complete!"
echo ""

# Check container status
echo "Container status:"
for issue in "${LAUNCHED[@]}"; do
    CONTAINER_NAME="claude-tastic-issue-${issue}"
    if docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then
        echo -e "  ${GREEN}✓${NC} #$issue: running"
    else
        echo -e "  ${RED}✗${NC} #$issue: not running (may have failed)"
        FAILED+=("$issue")
    fi
done

echo ""
echo "View logs: docker logs -f claude-tastic-issue-<N>"
echo "Stop all: ${SCRIPT_DIR}/container-launch.sh --cleanup"

if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n \
        --arg epic "$EPIC" \
        --argjson launched "$(printf '%s\n' "${LAUNCHED[@]}" | jq -R . | jq -s 'map(tonumber)')" \
        --argjson failed "$(printf '%s\n' "${FAILED[@]}" | jq -R . | jq -s 'map(tonumber)')" \
        '{
            epic: ($epic | tonumber),
            launched: $launched,
            failed: $failed,
            success: (($failed | length) == 0)
        }'
fi

# Exit with error if any failed
[[ ${#FAILED[@]} -eq 0 ]]
