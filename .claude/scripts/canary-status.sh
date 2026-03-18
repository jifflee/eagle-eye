#!/usr/bin/env bash
# canary-status.sh - Deployment dashboard for canary deployments
# Issue: #328 - Automated canary deployment pipeline
#
# Displays real-time deployment status including current stage,
# health metrics, traffic distribution, and rollback history.
#
# Usage:
#   ./scripts/canary-status.sh                  # Full dashboard
#   ./scripts/canary-status.sh --json           # JSON output
#   ./scripts/canary-status.sh --watch          # Continuous refresh
#   ./scripts/canary-status.sh --history        # Deployment history

set -euo pipefail

STATE_FILE="${CANARY_STATE_FILE:-/tmp/canary-deploy-state.json}"
METRICS_DIR="${METRICS_DIR:-/tmp/canary-metrics}"
ROLLBACK_LOG="${ROLLBACK_LOG:-/tmp/canary-rollback.log}"
EVENTS_FILE="/tmp/canary-rollback-events.jsonl"

# Parse arguments
JSON_OUTPUT=false
WATCH_MODE=false
SHOW_HISTORY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --watch)
            WATCH_MODE=true
            shift
            ;;
        --history)
            SHOW_HISTORY=true
            shift
            ;;
        --help|-h)
            echo "Usage: canary-status.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --json       Output in JSON format"
            echo "  --watch      Refresh every 5 seconds"
            echo "  --history    Show deployment history"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Get current deployment state
get_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo '{"current_stage":"none","version":"none","canary_weight":0}'
    fi
}

# Get metrics summary
get_metrics_summary() {
    local role="$1"
    local metrics_file="$METRICS_DIR/${role}-metrics.jsonl"

    if [ ! -f "$metrics_file" ]; then
        echo "no_data"
        return
    fi

    local total errors avg_latency
    total=$(wc -l < "$metrics_file" | tr -d ' ')
    errors=$(grep -c '"healthy":false' "$metrics_file" || true)

    # Calculate average latency from last 10 checks
    avg_latency=$(tail -10 "$metrics_file" | \
        grep -o '"response_time_ms":[0-9]*' | \
        cut -d: -f2 | \
        awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')

    local error_rate="0"
    if [ "$total" -gt 0 ]; then
        error_rate=$(echo "$errors $total" | awk '{printf "%.1f", ($1/$2)*100}')
    fi

    echo "${total}|${errors}|${error_rate}|${avg_latency}"
}

# Get stage progress bar
stage_progress() {
    local weight="$1"
    local bar_len=20
    local filled=$((weight * bar_len / 100))
    local empty=$((bar_len - filled))

    printf "[%s%s] %d%%" \
        "$(printf '#%.0s' $(seq 1 "$filled" 2>/dev/null) || true)" \
        "$(printf '.%.0s' $(seq 1 "$empty" 2>/dev/null) || true)" \
        "$weight"
}

# Display dashboard
show_dashboard() {
    local state
    state=$(get_state)

    local current_stage version canary_weight promoted_at
    current_stage=$(echo "$state" | grep -o '"current_stage": *"[^"]*"' | cut -d'"' -f4 || echo "none")
    version=$(echo "$state" | grep -o '"version": *"[^"]*"' | cut -d'"' -f4 || echo "none")
    canary_weight=$(echo "$state" | grep -o '"canary_weight": *[0-9]*' | grep -o '[0-9]*$' || echo "0")
    promoted_at=$(echo "$state" | grep -o '"promoted_at": *"[^"]*"' | cut -d'"' -f4 || echo "unknown")

    echo "============================================"
    echo "  CANARY DEPLOYMENT DASHBOARD"
    echo "============================================"
    echo ""
    echo "  Stage:    $current_stage"
    echo "  Version:  $version"
    echo "  Traffic:  $(stage_progress "$canary_weight")"
    echo "  Since:    $promoted_at"
    echo ""
    echo "--------------------------------------------"
    echo "  HEALTH METRICS"
    echo "--------------------------------------------"

    # Canary metrics
    local canary_metrics
    canary_metrics=$(get_metrics_summary "canary")
    if [ "$canary_metrics" != "no_data" ]; then
        IFS='|' read -r c_total c_errors c_rate c_latency <<< "$canary_metrics"
        echo ""
        echo "  Canary:"
        echo "    Checks:     $c_total"
        echo "    Errors:     $c_errors (${c_rate}%)"
        echo "    Avg Latency: ${c_latency}ms"
    else
        echo ""
        echo "  Canary: No data"
    fi

    # Baseline metrics
    local baseline_metrics
    baseline_metrics=$(get_metrics_summary "baseline")
    if [ "$baseline_metrics" != "no_data" ]; then
        IFS='|' read -r b_total b_errors b_rate b_latency <<< "$baseline_metrics"
        echo ""
        echo "  Baseline:"
        echo "    Checks:     $b_total"
        echo "    Errors:     $b_errors (${b_rate}%)"
        echo "    Avg Latency: ${b_latency}ms"
    else
        echo ""
        echo "  Baseline: No data"
    fi

    echo ""
    echo "--------------------------------------------"
    echo "  STAGES"
    echo "--------------------------------------------"
    echo ""

    local stages=("canary-10" "canary-25" "canary-50" "full-deploy")
    for s in "${stages[@]}"; do
        local marker="  "
        if [ "$s" = "$current_stage" ]; then
            marker=">>"
        fi
        local pct="${s##*-}"
        if [ "$s" = "full-deploy" ]; then
            pct="100"
        fi
        echo "  $marker $s ($pct%)"
    done

    echo ""
    echo "--------------------------------------------"
    echo "  ROLLBACKS"
    echo "--------------------------------------------"

    if [ -f "$EVENTS_FILE" ]; then
        local rollback_count
        rollback_count=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
        echo ""
        echo "  Total rollbacks: $rollback_count"
        if [ "$rollback_count" -gt 0 ]; then
            echo "  Last rollback:"
            tail -1 "$EVENTS_FILE" | sed 's/^/    /'
        fi
    else
        echo ""
        echo "  No rollbacks recorded."
    fi

    echo ""
    echo "============================================"
}

# JSON output
show_json() {
    local state
    state=$(get_state)

    local canary_metrics baseline_metrics
    canary_metrics=$(get_metrics_summary "canary")
    baseline_metrics=$(get_metrics_summary "baseline")

    local c_total=0 c_errors=0 c_rate="0" c_latency=0
    if [ "$canary_metrics" != "no_data" ]; then
        IFS='|' read -r c_total c_errors c_rate c_latency <<< "$canary_metrics"
    fi

    local b_total=0 b_errors=0 b_rate="0" b_latency=0
    if [ "$baseline_metrics" != "no_data" ]; then
        IFS='|' read -r b_total b_errors b_rate b_latency <<< "$baseline_metrics"
    fi

    local rollback_count=0
    if [ -f "$EVENTS_FILE" ]; then
        rollback_count=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
    fi

    cat << JSON
{
    "deployment": $state,
    "metrics": {
        "canary": {
            "total_checks": $c_total,
            "errors": $c_errors,
            "error_rate_percent": $c_rate,
            "avg_latency_ms": $c_latency
        },
        "baseline": {
            "total_checks": $b_total,
            "errors": $b_errors,
            "error_rate_percent": $b_rate,
            "avg_latency_ms": $b_latency
        }
    },
    "rollbacks": {
        "total": $rollback_count
    }
}
JSON
}

# Show deployment history
show_history() {
    echo "=== Deployment History ==="
    echo ""

    if [ -f "$EVENTS_FILE" ]; then
        echo "Rollback Events:"
        cat "$EVENTS_FILE" | while IFS= read -r line; do
            echo "  $line"
        done
        echo ""
    fi

    if [ -f "$ROLLBACK_LOG" ]; then
        echo "Recent Rollback Log:"
        tail -20 "$ROLLBACK_LOG" | sed 's/^/  /'
    fi
}

# Main execution
main() {
    if [ "$SHOW_HISTORY" = true ]; then
        show_history
        exit 0
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        show_json
        exit 0
    fi

    if [ "$WATCH_MODE" = true ]; then
        while true; do
            clear 2>/dev/null || true
            show_dashboard
            echo ""
            echo "  (Refreshing every 5s, Ctrl+C to stop)"
            sleep 5
        done
    else
        show_dashboard
    fi
}

main
