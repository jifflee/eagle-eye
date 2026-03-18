#!/usr/bin/env bash
# canary-health-check.sh - Health monitoring for canary deployments
# Issue: #328 - Automated canary deployment pipeline
#
# Monitors canary instance health and compares against baseline.
# Triggers rollback when thresholds are breached.
#
# Usage:
#   ./scripts/canary-health-check.sh --check --stage canary-10
#   ./scripts/canary-health-check.sh --duration 900 --interval 10 --stage canary-10
#   ./scripts/canary-health-check.sh --status

set -euo pipefail

# Configuration defaults (can be overridden by deploy/canary/config.yml)
CANARY_HOST="${CANARY_HOST:-localhost}"
CANARY_PORT="${CANARY_PORT:-8080}"
BASELINE_HOST="${BASELINE_HOST:-localhost}"
BASELINE_PORT="${BASELINE_PORT:-8081}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/health}"
METRICS_ENDPOINT="${METRICS_ENDPOINT:-/metrics}"

# Rollback thresholds
ERROR_RATE_THRESHOLD="${ERROR_RATE_THRESHOLD:-5}"
LATENCY_MULTIPLIER="${LATENCY_MULTIPLIER:-2.0}"
CONSECUTIVE_FAILURES="${CONSECUTIVE_FAILURES:-3}"

# State
METRICS_DIR="${METRICS_DIR:-/tmp/canary-metrics}"
FAILURE_COUNT=0

# Parse arguments
DURATION=0
INTERVAL=10
STAGE=""
CHECK_ONLY=false
SHOW_STATUS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --stage)
            STAGE="$2"
            shift 2
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --status)
            SHOW_STATUS=true
            shift
            ;;
        --help|-h)
            echo "Usage: canary-health-check.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --check              Single health check (exit 0=healthy, 1=unhealthy)"
            echo "  --duration SECONDS   Monitor for specified duration"
            echo "  --interval SECONDS   Check interval (default: 10)"
            echo "  --stage STAGE        Current deployment stage"
            echo "  --status             Show current health status"
            echo ""
            echo "Environment:"
            echo "  CANARY_HOST          Canary host (default: localhost)"
            echo "  CANARY_PORT          Canary port (default: 8080)"
            echo "  ERROR_RATE_THRESHOLD Error rate % threshold (default: 5)"
            echo "  LATENCY_MULTIPLIER   Max latency vs baseline (default: 2.0)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Initialize metrics directory
mkdir -p "$METRICS_DIR"

# Get timestamp
timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Check a single endpoint health
check_endpoint_health() {
    local host="$1"
    local port="$2"
    local role="$3"

    local start_time
    start_time=$(date +%s%N 2>/dev/null || date +%s)

    local http_code
    local response_time

    # Make health check request
    if http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        "http://${host}:${port}${HEALTH_ENDPOINT}" 2>/dev/null); then

        local end_time
        end_time=$(date +%s%N 2>/dev/null || date +%s)

        # Calculate response time in milliseconds
        if [[ "$start_time" =~ [0-9]{10,} ]]; then
            response_time=$(( (end_time - start_time) / 1000000 ))
        else
            response_time=$(( (end_time - start_time) * 1000 ))
        fi
    else
        http_code="000"
        response_time=0
    fi

    # Determine if healthy
    local healthy=false
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        healthy=true
    fi

    # Record metric
    echo "{\"timestamp\":\"$(timestamp)\",\"role\":\"$role\",\"http_code\":$http_code,\"response_time_ms\":$response_time,\"healthy\":$healthy}" \
        >> "$METRICS_DIR/${role}-metrics.jsonl"

    # Return result
    if [ "$healthy" = true ]; then
        echo "$response_time"
        return 0
    else
        echo "0"
        return 1
    fi
}

# Compare canary vs baseline metrics
compare_metrics() {
    local canary_time="$1"
    local baseline_time="$2"

    # Check latency threshold
    if [ "$baseline_time" -gt 0 ] && [ "$canary_time" -gt 0 ]; then
        local ratio
        ratio=$(echo "$canary_time $baseline_time" | awk '{printf "%.1f", $1/$2}')
        local threshold_exceeded
        threshold_exceeded=$(echo "$ratio $LATENCY_MULTIPLIER" | awk '{print ($1 > $2) ? "true" : "false"}')

        if [ "$threshold_exceeded" = "true" ]; then
            echo "WARN: Canary latency ${canary_time}ms is ${ratio}x baseline ${baseline_time}ms (threshold: ${LATENCY_MULTIPLIER}x)"
            return 1
        fi
    fi

    return 0
}

# Calculate error rate from recent metrics (last 100 checks)
get_error_rate() {
    local role="$1"

    local metrics_file="$METRICS_DIR/${role}-metrics.jsonl"
    if [ ! -f "$metrics_file" ]; then
        echo "0"
        return
    fi

    # Count total and errors in recent window
    local total errors
    total=$(tail -n 100 "$metrics_file" | wc -l | tr -d ' ')
    errors=$(tail -n 100 "$metrics_file" | grep -c '"healthy":false' || true)

    if [ "$total" -eq 0 ]; then
        echo "0"
        return
    fi

    echo "$errors $total" | awk '{printf "%.1f", ($1/$2)*100}'
}

# Single health check
do_single_check() {
    local canary_healthy=true
    local baseline_healthy=true
    local canary_time=0
    local baseline_time=0

    # Check canary
    if canary_time=$(check_endpoint_health "$CANARY_HOST" "$CANARY_PORT" "canary"); then
        canary_healthy=true
    else
        canary_healthy=false
    fi

    # Check baseline (for comparison only - baseline failure does not trigger rollback)
    if baseline_time=$(check_endpoint_health "$BASELINE_HOST" "$BASELINE_PORT" "baseline"); then
        baseline_healthy=true
    else
        baseline_healthy=false
        baseline_time=0
    fi

    # Evaluate health
    if [ "$canary_healthy" = false ]; then
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        echo "[$(timestamp)] UNHEALTHY: Canary health check failed (failures: $FAILURE_COUNT/$CONSECUTIVE_FAILURES)"

        if [ "$FAILURE_COUNT" -ge "$CONSECUTIVE_FAILURES" ]; then
            echo "[$(timestamp)] CRITICAL: $CONSECUTIVE_FAILURES consecutive failures - triggering rollback"
            return 2 # Rollback signal
        fi
        return 1
    fi

    # Reset failure count on success
    FAILURE_COUNT=0

    # Compare metrics (only when baseline is available)
    if [ "$baseline_healthy" = true ] && [ "$baseline_time" -gt 0 ]; then
        if ! compare_metrics "$canary_time" "$baseline_time"; then
            return 1
        fi
    fi

    # Check error rate
    local canary_error_rate
    canary_error_rate=$(get_error_rate "canary")
    local threshold_exceeded
    threshold_exceeded=$(echo "$canary_error_rate $ERROR_RATE_THRESHOLD" | awk '{print ($1 > $2) ? "true" : "false"}')

    if [ "$threshold_exceeded" = "true" ]; then
        echo "[$(timestamp)] WARN: Canary error rate ${canary_error_rate}% exceeds threshold ${ERROR_RATE_THRESHOLD}%"
        return 1
    fi

    echo "[$(timestamp)] HEALTHY: canary=${canary_time}ms baseline=${baseline_time}ms error_rate=${canary_error_rate}%"
    return 0
}

# Show status
show_status() {
    echo "=== Canary Health Status ==="
    echo "Stage: ${STAGE:-unknown}"
    echo "Canary: ${CANARY_HOST}:${CANARY_PORT}"
    echo "Baseline: ${BASELINE_HOST}:${BASELINE_PORT}"
    echo ""

    if [ -f "$METRICS_DIR/canary-metrics.jsonl" ]; then
        local total errors rate
        total=$(wc -l < "$METRICS_DIR/canary-metrics.jsonl" | tr -d ' ')
        errors=$(grep -c '"healthy":false' "$METRICS_DIR/canary-metrics.jsonl" || true)
        rate=$(get_error_rate "canary")
        echo "Canary Metrics:"
        echo "  Total checks: $total"
        echo "  Failures: $errors"
        echo "  Error rate: ${rate}%"
        echo "  Last check: $(tail -1 "$METRICS_DIR/canary-metrics.jsonl" 2>/dev/null || echo "none")"
    else
        echo "No metrics collected yet."
    fi
}

# Main execution
main() {
    if [ "$SHOW_STATUS" = true ]; then
        show_status
        exit 0
    fi

    if [ "$CHECK_ONLY" = true ]; then
        if do_single_check; then
            exit 0
        else
            exit 1
        fi
    fi

    # Continuous monitoring mode
    if [ "$DURATION" -le 0 ]; then
        echo "Error: --duration required for monitoring mode" >&2
        exit 1
    fi

    echo "[$(timestamp)] Starting health monitoring for ${DURATION}s at stage: ${STAGE:-unknown}"
    echo "[$(timestamp)] Thresholds: error_rate=${ERROR_RATE_THRESHOLD}% latency=${LATENCY_MULTIPLIER}x failures=${CONSECUTIVE_FAILURES}"

    local elapsed=0
    local check_count=0
    local healthy_count=0

    while [ "$elapsed" -lt "$DURATION" ]; do
        check_count=$((check_count + 1))

        local check_result=0
        do_single_check || check_result=$?

        if [ "$check_result" -eq 2 ]; then
            echo "[$(timestamp)] ROLLBACK TRIGGERED after $check_count checks ($elapsed/${DURATION}s)"
            exit 2
        elif [ "$check_result" -eq 0 ]; then
            healthy_count=$((healthy_count + 1))
        fi

        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
    done

    echo "[$(timestamp)] Monitoring complete: $healthy_count/$check_count healthy checks"

    # Final verdict
    local health_pct
    health_pct=$(echo "$healthy_count $check_count" | awk '{printf "%.0f", ($1/$2)*100}')

    if [ "$health_pct" -lt 95 ]; then
        echo "[$(timestamp)] VERDICT: UNHEALTHY (${health_pct}% healthy, need 95%+)"
        exit 1
    fi

    echo "[$(timestamp)] VERDICT: HEALTHY (${health_pct}% healthy)"
    exit 0
}

main
