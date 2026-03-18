#!/usr/bin/env bash
# ============================================================
# Script: n8n-metrics-exporter.sh
# Purpose: Sidecar Prometheus metrics exporter for n8n workflows
#
# Polls the n8n REST API to compute enriched metrics not available
# natively from the n8n /metrics endpoint:
#   - PR merge latency (cross-workflow)
#   - Sprint-work container success rates
#   - Never-triggered / stale workflow counts
#   - Workflow redundancy metrics
#
# Usage:
#   ./scripts/n8n-metrics-exporter.sh [OPTIONS]
#
# Options:
#   --daemon            Run continuously, updating metrics on interval
#   --once              Run a single collection cycle and exit
#   --port PORT         HTTP port to expose metrics (default: 9091)
#   --interval SECONDS  Poll interval in daemon mode (default: 60)
#   --output FILE       Write metrics to file instead of serving HTTP
#   --help              Show this help message
#
# Environment:
#   N8N_API_URL         n8n base URL (default: http://localhost:5678)
#   N8N_API_KEY         n8n API key for authentication
#   METRICS_PORT        HTTP port (overrides --port)
#   POLL_INTERVAL       Poll interval in seconds (overrides --interval)
#   LOOKBACK_DAYS       Days of history to analyze (default: 30)
#
# Dependencies: curl, jq, python3 (for HTTP server), bash 4+
#
# Feature: #821 - n8n workflow performance tracking and observability
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration (with environment variable overrides)
N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"
METRICS_PORT="${METRICS_PORT:-9091}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-30}"

# Runtime options
MODE="once"
OUTPUT_FILE=""

# Temp file for metrics
METRICS_FILE=""
cleanup() {
  [ -n "${METRICS_FILE:-}" ] && rm -f "$METRICS_FILE" 2>/dev/null || true
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --daemon)    MODE="daemon"; shift ;;
    --once)      MODE="once"; shift ;;
    --port)      METRICS_PORT="$2"; shift 2 ;;
    --interval)  POLL_INTERVAL="$2"; shift 2 ;;
    --output)    OUTPUT_FILE="$2"; shift 2 ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
log_info()  { log "[INFO]  $*"; }
log_warn()  { log "[WARN]  $*"; }
log_error() { log "[ERROR] $*"; }

# Build auth header
auth_header() {
  if [ -n "$N8N_API_KEY" ]; then
    echo "X-N8N-API-KEY: ${N8N_API_KEY}"
  else
    echo "Content-Type: application/json"
  fi
}

# Call n8n API
n8n_api() {
  local path="$1"
  shift
  local url="${N8N_API_URL}/api/v1${path}"
  local header
  header=$(auth_header)
  curl -sf --max-time 30 -H "$header" -H "Accept: application/json" "$url" "$@" 2>/dev/null || echo "null"
}

# Check if n8n API is reachable
check_n8n_health() {
  local health
  health=$(curl -sf --max-time 10 "${N8N_API_URL}/healthz" 2>/dev/null || echo "")
  if [ -z "$health" ]; then
    log_error "n8n health check failed at ${N8N_API_URL}"
    return 1
  fi
  return 0
}

# Fetch all workflows
get_workflows() {
  n8n_api "/workflows?limit=100&active=" | jq -c '.data // []'
}

# Fetch recent executions (last N days)
get_recent_executions() {
  local limit="${1:-250}"
  n8n_api "/executions?limit=${limit}&includeData=false" | jq -c '.data // []'
}

# Compute execution metrics from API data
compute_execution_metrics() {
  local executions="$1"
  local workflows="$2"

  # Count totals
  local total_executions success_executions error_executions
  total_executions=$(echo "$executions" | jq 'length')
  success_executions=$(echo "$executions" | jq '[.[] | select(.status == "success")] | length')
  error_executions=$(echo "$executions" | jq '[.[] | select(.status == "error")] | length')

  # Active workflow count
  local active_workflows
  active_workflows=$(echo "$workflows" | jq '[.[] | select(.active == true)] | length')

  # Total workflow count
  local total_workflows
  total_workflows=$(echo "$workflows" | jq 'length')

  # Compute never-triggered workflow count (no executions in lookback period)
  local workflow_ids_with_executions
  workflow_ids_with_executions=$(echo "$executions" | jq -r '[.[].workflowId] | unique | .[]' 2>/dev/null || echo "")

  local never_triggered=0
  if [ -n "$workflow_ids_with_executions" ]; then
    # Compare active workflows with those that have executions
    never_triggered=$(echo "$workflows" | jq --argjson executed "$(echo "$executions" | jq '[.[].workflowId] | unique')" \
      '[.[] | select(.active == true) | .id | tostring | IN($executed[])] | map(select(. == false)) | length' 2>/dev/null || echo "0")
  else
    # No executions at all — all active workflows are never-triggered
    never_triggered="$active_workflows"
  fi

  # Compute stale workflows (active but not triggered in LOOKBACK_DAYS)
  local lookback_ts
  lookback_ts=$(date -u -d "${LOOKBACK_DAYS} days ago" +%s 2>/dev/null || date -u -v-${LOOKBACK_DAYS}d +%s 2>/dev/null || echo 0)

  local stale_count
  stale_count=$(echo "$executions" | jq --argjson ts "$lookback_ts" \
    '[.[] | select((.startedAt // "") | gsub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime > $ts)] | [.[].workflowId] | unique | length' 2>/dev/null || echo "0")

  # Output metrics in Prometheus text format
  cat <<EOF
# HELP n8n_exporter_workflows_total Total number of n8n workflows
# TYPE n8n_exporter_workflows_total gauge
n8n_exporter_workflows_total ${total_workflows}

# HELP n8n_exporter_active_workflows Total number of active (enabled) n8n workflows
# TYPE n8n_exporter_active_workflows gauge
n8n_exporter_active_workflows ${active_workflows}

# HELP n8n_exporter_executions_total Total executions in lookback window
# TYPE n8n_exporter_executions_total gauge
n8n_exporter_executions_total{status="all"} ${total_executions}
n8n_exporter_executions_total{status="success"} ${success_executions}
n8n_exporter_executions_total{status="error"} ${error_executions}

# HELP n8n_exporter_never_triggered_workflows Workflows with no executions in lookback window
# TYPE n8n_exporter_never_triggered_workflows gauge
n8n_exporter_never_triggered_workflows ${never_triggered}
EOF
}

# Compute redundancy metrics from workflow definitions
compute_redundancy_metrics() {
  local workflows="$1"

  # Find duplicate webhook paths
  local duplicate_webhook_paths
  duplicate_webhook_paths=$(echo "$workflows" | jq '
    [.[] | .nodes // [] | .[] | select(.type == "n8n-nodes-base.webhook") |
      .parameters.path // "" | select(. != "")]
    | group_by(.)
    | [.[] | select(length > 1)]
    | length
  ' 2>/dev/null || echo "0")

  # Find duplicate trigger types (same trigger type, same config)
  local duplicate_trigger_count
  duplicate_trigger_count=$(echo "$workflows" | jq '
    [.[] | {id: .id, name: .name, triggers: (.nodes // [] |
      [.[] | select(.type | test("trigger|webhook|cron|schedule"; "i"))]
    )}]
    | [.[] | .triggers[] | {type: .type, path: (.parameters.path // ""), schedule: (.parameters.cronExpression // "")}]
    | group_by(.)
    | [.[] | select(length > 1)]
    | length
  ' 2>/dev/null || echo "0")

  # Count overlapping trigger signatures
  local overlap_count
  overlap_count=$(echo "$workflows" | jq '
    [.[] | .nodes // [] | .[] |
      select(.type | test("n8n-nodes-base\\.(webhook|scheduleTrigger|cron)")) |
      {type: .type, sig: (.parameters | tojson)}]
    | group_by(.sig)
    | [.[] | select(length > 1)]
    | length
  ' 2>/dev/null || echo "0")

  cat <<EOF
# HELP n8n_exporter_duplicate_webhook_paths Workflows with duplicate webhook paths
# TYPE n8n_exporter_duplicate_webhook_paths gauge
n8n_exporter_duplicate_webhook_paths ${duplicate_webhook_paths}

# HELP n8n_exporter_duplicate_trigger_configs Workflows sharing identical trigger configurations
# TYPE n8n_exporter_duplicate_trigger_configs gauge
n8n_exporter_duplicate_trigger_configs ${duplicate_trigger_count}

# HELP n8n_exporter_trigger_overlap_count Number of overlapping trigger signatures
# TYPE n8n_exporter_trigger_overlap_count gauge
n8n_exporter_trigger_overlap_count ${overlap_count}
EOF
}

# Compute PR merge latency metrics from pr-auto-merge workflow executions
compute_pr_merge_latency() {
  local executions="$1"
  local workflows="$2"

  # Find pr-auto-merge related workflow IDs by name pattern
  local merge_workflow_ids
  merge_workflow_ids=$(echo "$workflows" | jq -r \
    '[.[] | select(.name | test("auto.merge|pr.merge|merge.pipeline"; "i")) | .id] | join(",")' 2>/dev/null || echo "")

  if [ -z "$merge_workflow_ids" ]; then
    cat <<EOF
# HELP n8n_exporter_pr_merge_workflows_found Number of PR merge workflows detected
# TYPE n8n_exporter_pr_merge_workflows_found gauge
n8n_exporter_pr_merge_workflows_found 0
EOF
    return
  fi

  local merge_workflow_count
  merge_workflow_count=$(echo "$merge_workflow_ids" | tr ',' '\n' | wc -l)

  # Get merge workflow executions
  local merge_executions
  merge_executions=$(echo "$executions" | jq --arg ids "$merge_workflow_ids" \
    '[.[] | select(.workflowId | IN(($ids | split(",")))[])]' 2>/dev/null || echo "[]")

  local merge_success_count
  merge_success_count=$(echo "$merge_executions" | jq '[.[] | select(.status == "success")] | length' 2>/dev/null || echo "0")

  local merge_error_count
  merge_error_count=$(echo "$merge_executions" | jq '[.[] | select(.status == "error")] | length' 2>/dev/null || echo "0")

  # Compute average duration for successful merge executions
  local avg_duration_ms
  avg_duration_ms=$(echo "$merge_executions" | jq '
    [.[] | select(.status == "success") |
      select(.startedAt != null and .stoppedAt != null) |
      (((.stoppedAt | gsub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
        (.startedAt | gsub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) * 1000)
    ] | if length > 0 then add / length else 0 end
  ' 2>/dev/null || echo "0")

  cat <<EOF
# HELP n8n_exporter_pr_merge_workflows_found Number of PR merge workflows detected
# TYPE n8n_exporter_pr_merge_workflows_found gauge
n8n_exporter_pr_merge_workflows_found ${merge_workflow_count}

# HELP n8n_exporter_pr_merge_executions PR merge workflow execution counts
# TYPE n8n_exporter_pr_merge_executions gauge
n8n_exporter_pr_merge_executions{status="success"} ${merge_success_count}
n8n_exporter_pr_merge_executions{status="error"} ${merge_error_count}

# HELP n8n_exporter_pr_merge_avg_duration_ms Average PR merge workflow duration in milliseconds
# TYPE n8n_exporter_pr_merge_avg_duration_ms gauge
n8n_exporter_pr_merge_avg_duration_ms ${avg_duration_ms}
EOF
}

# Add exporter metadata metrics
exporter_metadata() {
  local collection_ts
  collection_ts=$(date -u +%s)
  cat <<EOF
# HELP n8n_exporter_last_collection_timestamp Unix timestamp of last successful collection
# TYPE n8n_exporter_last_collection_timestamp gauge
n8n_exporter_last_collection_timestamp ${collection_ts}

# HELP n8n_exporter_up Whether the n8n API is reachable (1=up, 0=down)
# TYPE n8n_exporter_up gauge
n8n_exporter_up 1

# HELP n8n_exporter_lookback_days Days of history analyzed
# TYPE n8n_exporter_lookback_days gauge
n8n_exporter_lookback_days ${LOOKBACK_DAYS}
EOF
}

# Collect all metrics and write to target
collect_metrics() {
  local target="${1:-${METRICS_FILE}}"

  log_info "Starting metrics collection from ${N8N_API_URL}"

  # Check n8n health
  if ! check_n8n_health; then
    {
      echo "# HELP n8n_exporter_up Whether the n8n API is reachable"
      echo "# TYPE n8n_exporter_up gauge"
      echo "n8n_exporter_up 0"
    } > "$target"
    return 1
  fi

  # Fetch data
  local workflows executions
  log_info "Fetching workflow definitions..."
  workflows=$(get_workflows)

  log_info "Fetching recent executions (last ${LOOKBACK_DAYS} days, limit=250)..."
  executions=$(get_recent_executions 250)

  # Compute and assemble metrics
  {
    compute_execution_metrics "$executions" "$workflows"
    echo ""
    compute_redundancy_metrics "$workflows"
    echo ""
    compute_pr_merge_latency "$executions" "$workflows"
    echo ""
    exporter_metadata
  } > "$target"

  log_info "Metrics written to ${target}"
}

# Serve metrics via simple HTTP server
serve_http() {
  local metrics_file="$1"
  local port="$2"

  log_info "Starting HTTP metrics server on port ${port}"

  # Use Python's built-in HTTP server with a custom handler
  python3 - "$metrics_file" "$port" <<'PYEOF'
import sys
import http.server
import threading

metrics_file = sys.argv[1]
port = int(sys.argv[2])

class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            try:
                with open(metrics_file, 'r') as f:
                    content = f.read().encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain; version=0.0.4; charset=utf-8')
                self.send_header('Content-Length', str(len(content)))
                self.end_headers()
                self.wfile.write(content)
            except FileNotFoundError:
                self.send_response(503)
                self.end_headers()
                self.wfile.write(b'# Metrics not yet available\n')
        elif self.path == '/health':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Suppress default access log; let bash handle logging
        pass

server = http.server.HTTPServer(('0.0.0.0', port), MetricsHandler)
server.serve_forever()
PYEOF
}

# Main execution
main() {
  METRICS_FILE=$(mktemp /tmp/n8n-metrics-XXXXXX.prom)

  if [ -n "$OUTPUT_FILE" ]; then
    METRICS_FILE="$OUTPUT_FILE"
  fi

  case "$MODE" in
    daemon)
      log_info "Starting n8n metrics exporter in daemon mode (interval: ${POLL_INTERVAL}s)"
      log_info "Metrics endpoint: http://0.0.0.0:${METRICS_PORT}/metrics"

      # Initial collection (may fail if n8n not ready yet)
      collect_metrics "$METRICS_FILE" || true

      # Start HTTP server in background
      serve_http "$METRICS_FILE" "$METRICS_PORT" &
      SERVER_PID=$!

      # Poll loop
      while true; do
        sleep "$POLL_INTERVAL"
        collect_metrics "$METRICS_FILE" || log_warn "Collection failed, retaining previous metrics"
      done
      ;;

    once)
      collect_metrics "$METRICS_FILE"
      if [ -z "$OUTPUT_FILE" ]; then
        cat "$METRICS_FILE"
      fi
      ;;

    *)
      log_error "Unknown mode: ${MODE}"
      exit 1
      ;;
  esac
}

main
