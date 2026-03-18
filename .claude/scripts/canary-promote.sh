#!/usr/bin/env bash
# canary-promote.sh - Stage promotion for canary deployments
# Issue: #328 - Automated canary deployment pipeline
#
# Manages traffic routing between baseline and canary instances
# by updating Nginx upstream weights for each deployment stage.
#
# Usage:
#   ./scripts/canary-promote.sh --stage canary-10 --version v1.2.3
#   ./scripts/canary-promote.sh --stage canary-25 --version v1.2.3
#   ./scripts/canary-promote.sh --stage full-deploy --version v1.2.3
#   ./scripts/canary-promote.sh --status

set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-deploy/canary/docker-compose.canary.yml}"
NGINX_CONF="${NGINX_CONF:-deploy/canary/nginx.canary.conf}"
STATE_FILE="${CANARY_STATE_FILE:-/tmp/canary-deploy-state.json}"

# Validate version string (alphanumeric, dots, dashes, underscores, 'v' prefix)
validate_version() {
    local version="$1"
    if [ -z "$version" ]; then
        return 0  # Empty is ok (uses default)
    fi
    if ! echo "$version" | grep -qE '^v?[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$'; then
        echo "Error: Invalid version format '$version'. Must be alphanumeric with ._- (max 128 chars)" >&2
        exit 1
    fi
}

# Validate file path is safe (no traversal, within expected locations)
validate_path() {
    local path="$1" label="$2"
    # Reject paths with traversal sequences
    if echo "$path" | grep -qE '(^|/)\.\.(/|$)'; then
        echo "Error: Path traversal detected in $label: $path" >&2
        exit 1
    fi
    # Reject paths with shell metacharacters
    if echo "$path" | grep -qE '[;|&$`\\]'; then
        echo "Error: Invalid characters in $label path: $path" >&2
        exit 1
    fi
}

# Get canary weight for a given stage name
get_stage_weight() {
    local stage="$1"
    case "$stage" in
        canary-10)   echo 10 ;;
        canary-25)   echo 25 ;;
        canary-50)   echo 50 ;;
        full-deploy) echo 100 ;;
        *)           echo "" ;;
    esac
}

# Parse arguments
STAGE=""
VERSION=""
SHOW_STATUS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage)
            STAGE="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --status)
            SHOW_STATUS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "Usage: canary-promote.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --stage STAGE      Target stage (canary-10, canary-25, canary-50, full-deploy)"
            echo "  --version VERSION  Version being deployed"
            echo "  --status           Show current deployment state"
            echo "  --dry-run          Show what would happen"
            echo ""
            echo "Stages:"
            echo "  canary-10    10% canary, 90% baseline"
            echo "  canary-25    25% canary, 75% baseline"
            echo "  canary-50    50% canary, 50% baseline"
            echo "  full-deploy  100% canary (baseline swap)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
    echo "[$(timestamp)] $1"
}

# Get canary weight for a stage (wrapper with default)
get_canary_weight() {
    local stage="$1"
    local weight
    weight=$(get_stage_weight "$stage")
    echo "${weight:-0}"
}

# Update Nginx upstream weights
update_nginx_weights() {
    local canary_weight="$1"
    local baseline_weight=$((100 - canary_weight))

    log "Setting weights: baseline=$baseline_weight, canary=$canary_weight"

    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would update Nginx weights"
        return 0
    fi

    # Verify Nginx config exists
    if [ ! -f "$NGINX_CONF" ]; then
        log "ERROR: Nginx config not found: $NGINX_CONF"
        return 1
    fi

    # Generate updated Nginx config with new weights
    if [ "$canary_weight" -eq 100 ]; then
        sed -i.bak \
            -e "s/server app-baseline:8080 weight=[0-9]*.*/server app-baseline:8080 weight=0 backup;/" \
            -e "s/server app-canary:8080 weight=[0-9]*.*/server app-canary:8080 weight=100;/" \
            "$NGINX_CONF"
    elif [ "$canary_weight" -eq 0 ]; then
        sed -i.bak \
            -e "s/server app-baseline:8080 weight=[0-9]*.*/server app-baseline:8080 weight=100;/" \
            -e "s/server app-canary:8080 weight=[0-9]*.*/server app-canary:8080 weight=0 backup;/" \
            "$NGINX_CONF"
    else
        sed -i.bak \
            -e "s/server app-baseline:8080 weight=[0-9]*.*/server app-baseline:8080 weight=${baseline_weight};/" \
            -e "s/server app-canary:8080 weight=[0-9]*.*/server app-canary:8080 weight=${canary_weight};/" \
            "$NGINX_CONF"
    fi

    # Validate sed succeeded - verify weights are present in updated config
    if ! grep -q "weight=${canary_weight}" "$NGINX_CONF"; then
        log "ERROR: Nginx config update failed - expected weight not found"
        # Restore backup
        if [ -f "${NGINX_CONF}.bak" ]; then
            mv "${NGINX_CONF}.bak" "$NGINX_CONF"
            log "Restored Nginx config from backup"
        fi
        return 1
    fi

    rm -f "${NGINX_CONF}.bak"
    log "Nginx config updated"
}

# Reload Nginx configuration
reload_nginx() {
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would reload Nginx"
        return 0
    fi

    if command -v docker >/dev/null 2>&1 && [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" exec -T nginx-router nginx -t 2>/dev/null && \
        docker compose -f "$COMPOSE_FILE" exec -T nginx-router nginx -s reload 2>/dev/null || {
            log "WARNING: Nginx reload failed - config may need manual reload"
            return 1
        }
        log "Nginx reloaded successfully"
    else
        log "Docker not available - Nginx reload skipped (manual reload needed)"
    fi
}

# Ensure canary container is running
ensure_canary_running() {
    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would ensure canary container is running"
        return 0
    fi

    if command -v docker >/dev/null 2>&1 && [ -f "$COMPOSE_FILE" ]; then
        local canary_state
        canary_state=$(docker compose -f "$COMPOSE_FILE" ps --format json app-canary 2>/dev/null | \
            grep -o '"State":"[^"]*"' | head -1 || echo "")

        if [[ "$canary_state" != *"running"* ]]; then
            log "Starting canary container..."
            if ! CANARY_VERSION="${VERSION:-latest}" docker compose -f "$COMPOSE_FILE" up -d app-canary 2>&1; then
                log "ERROR: Failed to start canary container"
                return 1
            fi
            log "Canary container started"
        fi
    else
        log "Docker not available - skipping container check"
    fi
}

# Save deployment state
save_state() {
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi

    cat > "$STATE_FILE" << JSON
{
    "current_stage": "$STAGE",
    "version": "${VERSION:-unknown}",
    "canary_weight": $(get_canary_weight "$STAGE"),
    "promoted_at": "$(timestamp)",
    "previous_stage": "${PREVIOUS_STAGE:-none}"
}
JSON
    log "State saved to $STATE_FILE"
}

# Show current state
show_status() {
    echo "=== Canary Deployment Status ==="
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "No active deployment."
    fi

    echo ""
    echo "Nginx config:"
    if [ -f "$NGINX_CONF" ]; then
        grep -E "server (app-baseline|app-canary)" "$NGINX_CONF" | sed 's/^/  /'
    else
        echo "  Config file not found: $NGINX_CONF"
    fi
}

# Main promotion logic
main() {
    if [ "$SHOW_STATUS" = true ]; then
        show_status
        exit 0
    fi

    if [ -z "$STAGE" ]; then
        echo "Error: --stage required" >&2
        exit 1
    fi

    local valid_weight
    valid_weight=$(get_stage_weight "$STAGE")
    if [ -z "$valid_weight" ]; then
        echo "Error: Unknown stage '$STAGE'. Valid: canary-10, canary-25, canary-50, full-deploy" >&2
        exit 1
    fi

    # Validate inputs
    validate_version "$VERSION"
    validate_path "$NGINX_CONF" "NGINX_CONF"
    validate_path "$COMPOSE_FILE" "COMPOSE_FILE"

    # Get previous stage for state tracking
    PREVIOUS_STAGE=""
    if [ -f "$STATE_FILE" ]; then
        PREVIOUS_STAGE=$(grep -o '"current_stage": *"[^"]*"' "$STATE_FILE" | cut -d'"' -f4 || true)
    fi

    local canary_weight
    canary_weight=$(get_canary_weight "$STAGE")

    log "=========================================="
    log "CANARY PROMOTION: $STAGE"
    log "Version: ${VERSION:-unknown}"
    log "Traffic: ${canary_weight}% canary, $((100 - canary_weight))% baseline"
    log "Previous: ${PREVIOUS_STAGE:-none}"
    log "=========================================="

    # Step 1: Ensure canary is running
    ensure_canary_running

    # Step 2: Update traffic weights
    update_nginx_weights "$canary_weight"

    # Step 3: Reload Nginx
    reload_nginx

    # Step 4: Save state
    save_state

    log "=========================================="
    log "PROMOTION COMPLETE: $STAGE"
    log "=========================================="
}

main
