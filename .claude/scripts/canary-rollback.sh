#!/usr/bin/env bash
# canary-rollback.sh - Automated rollback for canary deployments
# Issue: #328 - Automated canary deployment pipeline
#
# Reverts traffic routing to baseline and stops canary instance.
# Called automatically by health check on threshold breach,
# or manually by operators.
#
# Usage:
#   ./scripts/canary-rollback.sh --stage canary-10 --reason "health_check_failure"
#   ./scripts/canary-rollback.sh --immediate
#   ./scripts/canary-rollback.sh --status

set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-deploy/canary/docker-compose.canary.yml}"
NGINX_CONF="${NGINX_CONF:-deploy/canary/nginx.canary.conf}"
ROLLBACK_LOG="${ROLLBACK_LOG:-/tmp/canary-rollback.log}"

# Validate file path is safe (no traversal, no metacharacters)
validate_path() {
    local path="$1" label="$2"
    if echo "$path" | grep -qE '(^|/)\.\.(/|$)'; then
        echo "Error: Path traversal detected in $label: $path" >&2
        exit 1
    fi
    if echo "$path" | grep -qE '[;|&$`\\]'; then
        echo "Error: Invalid characters in $label path: $path" >&2
        exit 1
    fi
}

# Parse arguments
STAGE=""
REASON=""
IMMEDIATE=false
SHOW_STATUS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage)
            STAGE="$2"
            shift 2
            ;;
        --reason)
            REASON="$2"
            shift 2
            ;;
        --immediate)
            IMMEDIATE=true
            shift
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
            echo "Usage: canary-rollback.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --stage STAGE     Stage being rolled back"
            echo "  --reason REASON   Reason for rollback"
            echo "  --immediate       Skip graceful drain, rollback now"
            echo "  --status          Show rollback history"
            echo "  --dry-run         Show what would happen"
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
    local msg="[$(timestamp)] $1"
    echo "$msg"
    echo "$msg" >> "$ROLLBACK_LOG"
}

# Record rollback event
record_rollback() {
    local event_file="/tmp/canary-rollback-events.jsonl"
    echo "{\"timestamp\":\"$(timestamp)\",\"stage\":\"$STAGE\",\"reason\":\"$REASON\",\"immediate\":$IMMEDIATE}" \
        >> "$event_file"
}

# Revert Nginx config to send all traffic to baseline
revert_traffic() {
    log "Reverting traffic to 100% baseline..."

    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would update Nginx config to weight baseline=100, canary=0"
        return 0
    fi

    # Generate baseline-only Nginx config
    local temp_conf="/tmp/nginx-rollback.conf"

    sed -e 's/server app-canary:8080 weight=[0-9]*/server app-canary:8080 weight=0 backup/' \
        -e 's/server app-baseline:8080 weight=[0-9]*/server app-baseline:8080 weight=100/' \
        "$NGINX_CONF" > "$temp_conf"

    # Apply config
    if [ -f "$COMPOSE_FILE" ] && command -v docker >/dev/null 2>&1; then
        cp "$temp_conf" "$NGINX_CONF"
        docker compose -f "$COMPOSE_FILE" exec -T nginx-router nginx -s reload 2>/dev/null || true
        log "Nginx config reverted and reloaded"
    else
        cp "$temp_conf" "$NGINX_CONF"
        log "Nginx config reverted (reload manually if needed)"
    fi

    rm -f "$temp_conf"
}

# Stop canary instance
stop_canary() {
    log "Stopping canary instance..."

    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would stop canary container"
        return 0
    fi

    if [ -f "$COMPOSE_FILE" ] && command -v docker >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" stop app-canary 2>/dev/null || true
        log "Canary container stopped"
    else
        log "Docker not available - canary stop skipped"
    fi
}

# Preserve deployment artifacts for investigation
preserve_artifacts() {
    local artifact_dir="/tmp/canary-rollback-artifacts-$(date +%s)"
    mkdir -p "$artifact_dir"
    chmod 700 "$artifact_dir"

    log "Preserving rollback artifacts to $artifact_dir"

    if [ "$DRY_RUN" = true ]; then
        log "DRY RUN: Would preserve metrics and logs"
        return 0
    fi

    # Copy metrics
    if [ -d /tmp/canary-metrics ]; then
        cp -r /tmp/canary-metrics "$artifact_dir/" 2>/dev/null || true
    fi

    # Get canary logs if available
    if command -v docker >/dev/null 2>&1; then
        docker logs canary-instance > "$artifact_dir/canary.log" 2>&1 || true
    fi

    # Record rollback metadata
    cat > "$artifact_dir/rollback-info.json" << JSON
{
    "timestamp": "$(timestamp)",
    "stage": "$STAGE",
    "reason": "$REASON",
    "immediate": $IMMEDIATE,
    "canary_version": "${CANARY_VERSION:-unknown}",
    "baseline_version": "${BASELINE_VERSION:-unknown}"
}
JSON

    log "Artifacts preserved at $artifact_dir"
}

# Show rollback history
show_status() {
    echo "=== Canary Rollback History ==="
    if [ -f /tmp/canary-rollback-events.jsonl ]; then
        echo ""
        echo "Recent rollbacks:"
        tail -10 /tmp/canary-rollback-events.jsonl | while IFS= read -r line; do
            echo "  $line"
        done
    else
        echo "No rollback events recorded."
    fi

    if [ -f "$ROLLBACK_LOG" ]; then
        echo ""
        echo "Recent log:"
        tail -5 "$ROLLBACK_LOG"
    fi
}

# Main rollback procedure
main() {
    if [ "$SHOW_STATUS" = true ]; then
        show_status
        exit 0
    fi

    # Validate paths before use
    validate_path "$NGINX_CONF" "NGINX_CONF"
    validate_path "$COMPOSE_FILE" "COMPOSE_FILE"

    log "=========================================="
    log "CANARY ROLLBACK INITIATED"
    log "Stage: ${STAGE:-unknown}"
    log "Reason: ${REASON:-manual}"
    log "Immediate: $IMMEDIATE"
    log "=========================================="

    # Record the event
    record_rollback

    # Step 1: Revert traffic immediately
    revert_traffic

    # Step 2: Grace period (unless immediate)
    if [ "$IMMEDIATE" = false ] && [ "$DRY_RUN" = false ]; then
        log "Waiting 5s for in-flight requests to complete..."
        sleep 5
    fi

    # Step 3: Stop canary
    stop_canary

    # Step 4: Preserve artifacts
    preserve_artifacts

    # Step 5: Final verification
    if [ "$DRY_RUN" = false ]; then
        log "Verifying baseline health after rollback..."
        if command -v curl >/dev/null 2>&1; then
            local baseline_status
            baseline_status=$(curl -s -o /dev/null -w "%{http_code}" \
                "http://${BASELINE_HOST:-localhost}:${BASELINE_PORT:-8081}/health" 2>/dev/null || echo "000")
            if [[ "$baseline_status" =~ ^2[0-9][0-9]$ ]]; then
                log "Baseline healthy after rollback (HTTP $baseline_status)"
            else
                log "WARNING: Baseline health check returned HTTP $baseline_status"
            fi
        fi
    fi

    log "=========================================="
    log "ROLLBACK COMPLETE"
    log "=========================================="

    exit 0
}

main
