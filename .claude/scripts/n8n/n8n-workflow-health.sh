#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: n8n-workflow-health.sh
# Purpose: Continuous health monitoring for n8n workflows
# Usage: ./scripts/n8n-workflow-health.sh [--json] [--quiet]
#
# Options:
#   --json    Output JSON format (for programmatic consumption)
#   --quiet   Minimal output (exit code only)
#   --help    Show this help message
#
# Exit codes:
#   0 - All workflows healthy
#   1 - One or more workflows unhealthy
#   2 - n8n container not running
#   3 - Invalid arguments
#
# Dependencies: docker, curl, jq
# Issue: #724 - n8n continuous workflow health monitoring
# Parent: #720 - Network isolation and workflow automation
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  source "$SCRIPT_DIR/lib/common.sh"
else
  # Minimal fallback
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_success() { echo "[OK] $*" >&2; }
  timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fi

# Configuration
N8N_PORT="${N8N_PORT:-5678}"
N8N_URL="http://localhost:$N8N_PORT"
JSON_OUTPUT=false
QUIET=false

# Auto-detect repository name for per-repo container naming (matches n8n-start.sh)
if [ -z "$REPO_NAME" ]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  REPO_NAME=$(cd "$REPO_ROOT" && basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$REPO_ROOT")
fi
CONTAINER_NAME="n8n-${REPO_NAME:-local}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 3
      ;;
  esac
done

# Check if n8n container is running
check_container_running() {
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    return 0
  fi
  return 1
}

# Get n8n API key from .env.local
get_api_key() {
  local env_file="$SCRIPT_DIR/../.env.local"
  if [ -f "$env_file" ]; then
    grep '^N8N_API_KEY=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'"
  fi
}

# Get all workflows
get_workflows() {
  local api_key="$1"

  if [ -z "$api_key" ]; then
    echo "[]"
    return 1
  fi

  curl -sf "$N8N_URL/api/v1/workflows" \
    -H "X-N8N-API-KEY: $api_key" 2>/dev/null | jq -r '.data // []'
}

# Get workflow executions (last 10, within last hour)
get_workflow_executions() {
  local api_key="$1"
  local workflow_id="$2"

  if [ -z "$api_key" ] || [ -z "$workflow_id" ]; then
    echo "[]"
    return 1
  fi

  # Get executions for this workflow (last 10)
  curl -sf "$N8N_URL/api/v1/executions?workflowId=$workflow_id&limit=10" \
    -H "X-N8N-API-KEY: $api_key" 2>/dev/null | jq -r '.data // []'
}

# Calculate time since last execution in human-readable format
time_since() {
  local timestamp="$1"

  if [ -z "$timestamp" ] || [ "$timestamp" = "null" ]; then
    echo "Never"
    return
  fi

  # Parse timestamp to epoch (handle both GNU and BSD date)
  local exec_epoch
  if date --version >/dev/null 2>&1; then
    # GNU date
    exec_epoch=$(date -u -d "$timestamp" +%s 2>/dev/null || echo 0)
  else
    # BSD date (macOS)
    exec_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${timestamp%.*}" +%s 2>/dev/null || echo 0)
  fi

  local now_epoch=$(date -u +%s)
  local diff_seconds=$((now_epoch - exec_epoch))

  if [ $diff_seconds -lt 60 ]; then
    echo "${diff_seconds}s ago"
  elif [ $diff_seconds -lt 3600 ]; then
    echo "$((diff_seconds / 60))m ago"
  elif [ $diff_seconds -lt 86400 ]; then
    echo "$((diff_seconds / 3600))h ago"
  else
    echo "$((diff_seconds / 86400))d ago"
  fi
}

# Count errors in last hour
count_recent_errors() {
  local executions="$1"

  # Get current time - 1 hour (epoch)
  local one_hour_ago=$(($(date -u +%s) - 3600))

  # Count failed executions within last hour
  echo "$executions" | jq -r --arg threshold "$one_hour_ago" '
    [.[] | select(.finished == "true" and .stoppedAt != null)] |
    map(
      .stoppedAt |
      gsub("\\.[0-9]+Z$"; "Z") |
      fromdate
    ) as $timestamps |
    [.[] | select(.stoppedAt != null)] |
    map(
      select(
        (.finished == "true") and
        (.stoppedAt | gsub("\\.[0-9]+Z$"; "Z") | fromdate) > ($threshold | tonumber)
      )
    ) |
    map(select(.status == "error" or .status == "failed")) |
    length
  ' 2>/dev/null || echo "0"
}

# Get last execution status and error message
get_last_execution_info() {
  local executions="$1"

  echo "$executions" | jq -r '
    [.[] | select(.finished == "true" and .stoppedAt != null)] |
    sort_by(.stoppedAt) |
    reverse |
    .[0] // {} |
    {
      status: (.status // "unknown"),
      stopped_at: (.stoppedAt // null),
      error: (if .status == "error" or .status == "failed" then
        (.data?.resultData?.error?.message // .data?.resultData?.lastNodeExecuted // "Unknown error")
      else null end)
    }
  '
}

# Check if workflow has webhook trigger
has_webhook_trigger() {
  local workflow_data="$1"

  echo "$workflow_data" | jq -r '
    .nodes // [] |
    map(select(.type == "n8n-nodes-base.webhook" or .type == "n8n-nodes-base.formTrigger" or .type == "n8n-nodes-base.chatTrigger")) |
    length > 0
  '
}

# Get webhook path from workflow
get_webhook_path() {
  local workflow_data="$1"

  echo "$workflow_data" | jq -r '
    .nodes // [] |
    map(select(.type == "n8n-nodes-base.webhook" or .type == "n8n-nodes-base.formTrigger")) |
    .[0]?.parameters?.path // null
  '
}

# Test webhook reachability
test_webhook() {
  local webhook_path="$1"

  if [ -z "$webhook_path" ] || [ "$webhook_path" = "null" ]; then
    echo "false"
    return
  fi

  # Test webhook endpoint (GET request, don't care about response code, just reachability)
  if curl -sf -I "$N8N_URL/webhook/$webhook_path" &>/dev/null; then
    echo "true"
  else
    # Some webhooks only accept POST, try that
    if curl -sf -X POST "$N8N_URL/webhook/$webhook_path" -d '{}' &>/dev/null; then
      echo "true"
    else
      echo "false"
    fi
  fi
}

# Get remediation advice for failures
get_remediation() {
  local workflow_name="$1"
  local is_active="$2"
  local last_status="$3"
  local error_message="$4"

  if [ "$is_active" = "false" ]; then
    echo "Activate workflow in n8n UI: $N8N_URL"
    return
  fi

  if [ "$last_status" = "error" ] || [ "$last_status" = "failed" ]; then
    # Try to provide specific remediation based on error
    if echo "$error_message" | grep -qi "401\|unauthorized\|authentication"; then
      echo "Check GitHub token - 401 Unauthorized in last execution"
    elif echo "$error_message" | grep -qi "404\|not found"; then
      echo "Resource not found - verify webhook URLs and API endpoints"
    elif echo "$error_message" | grep -qi "timeout\|timed out"; then
      echo "Execution timeout - consider optimizing workflow or increasing timeout"
    elif echo "$error_message" | grep -qi "rate limit"; then
      echo "API rate limit exceeded - add delay nodes or retry logic"
    else
      echo "Check workflow logs: docker logs $CONTAINER_NAME"
    fi
  fi
}

# Main health check
main() {
  local all_healthy=true
  local workflows_data='[]'
  local container_running=false

  # Check if container is running
  if ! check_container_running; then
    if [ "$JSON_OUTPUT" = true ]; then
      jq -n '{
        healthy: false,
        container_running: false,
        error: "n8n container not running",
        workflows: [],
        checked_at: (now | todate)
      }'
    elif [ "$QUIET" = false ]; then
      log_error "n8n container not running"
      echo ""
      echo "Remediation: Start n8n with: ./scripts/n8n-start.sh"
      echo ""
    fi
    exit 2
  fi

  container_running=true

  # Get API key
  local api_key
  api_key=$(get_api_key)

  if [ -z "$api_key" ]; then
    if [ "$JSON_OUTPUT" = true ]; then
      jq -n '{
        healthy: false,
        container_running: true,
        error: "N8N_API_KEY not found in .env.local",
        workflows: [],
        checked_at: (now | todate)
      }'
    elif [ "$QUIET" = false ]; then
      log_error "N8N_API_KEY not found in .env.local"
      echo ""
      echo "Remediation: Run setup to generate API key: ./scripts/n8n-setup.sh"
      echo ""
    fi
    exit 1
  fi

  # Get all workflows
  local workflows
  workflows=$(get_workflows "$api_key")

  if [ "$workflows" = "[]" ] || [ -z "$workflows" ]; then
    if [ "$JSON_OUTPUT" = true ]; then
      jq -n '{
        healthy: true,
        container_running: true,
        workflows: [],
        summary: {
          total: 0,
          active: 0,
          inactive: 0,
          healthy: 0,
          unhealthy: 0
        },
        checked_at: (now | todate)
      }'
    elif [ "$QUIET" = false ]; then
      echo "n8n Workflow Health"
      echo "==================="
      echo ""
      log_warn "No workflows found"
      echo ""
    fi
    exit 0
  fi

  # Process each workflow
  local workflow_results=()
  local total=0
  local active=0
  local inactive=0
  local healthy=0
  local unhealthy=0

  while IFS= read -r workflow; do
    local workflow_id=$(echo "$workflow" | jq -r '.id')
    local workflow_name=$(echo "$workflow" | jq -r '.name')
    local is_active=$(echo "$workflow" | jq -r '.active')

    total=$((total + 1))

    if [ "$is_active" = "true" ]; then
      active=$((active + 1))
    else
      inactive=$((inactive + 1))
    fi

    # Get executions
    local executions
    executions=$(get_workflow_executions "$api_key" "$workflow_id")

    # Get last execution info
    local last_exec_info
    last_exec_info=$(get_last_execution_info "$executions")
    local last_status=$(echo "$last_exec_info" | jq -r '.status')
    local last_time=$(echo "$last_exec_info" | jq -r '.stopped_at')
    local error_message=$(echo "$last_exec_info" | jq -r '.error // ""')

    # Count recent errors
    local error_count
    error_count=$(count_recent_errors "$executions")

    # Format last run time
    local last_run_display
    last_run_display=$(time_since "$last_time")

    # Check webhook if applicable
    local webhook_check="N/A"
    local has_webhook=$(has_webhook_trigger "$workflow")

    if [ "$has_webhook" = "true" ]; then
      local webhook_path=$(get_webhook_path "$workflow")
      local webhook_reachable=$(test_webhook "$webhook_path")

      if [ "$webhook_reachable" = "true" ]; then
        webhook_check="✓"
      else
        webhook_check="✗"
      fi
    fi

    # Determine health status
    local status="✓"
    local status_text="healthy"
    local remediation=""

    if [ "$is_active" = "false" ]; then
      status="⚪"
      status_text="inactive"
      remediation=$(get_remediation "$workflow_name" "$is_active" "$last_status" "$error_message")
      unhealthy=$((unhealthy + 1))
      all_healthy=false
    elif [ "$last_status" = "error" ] || [ "$last_status" = "failed" ]; then
      status="✗"
      status_text="failed"
      remediation=$(get_remediation "$workflow_name" "$is_active" "$last_status" "$error_message")
      unhealthy=$((unhealthy + 1))
      all_healthy=false
    elif [ "$webhook_check" = "✗" ]; then
      status="✗"
      status_text="webhook_unreachable"
      remediation="Webhook endpoint not responding - check workflow configuration"
      unhealthy=$((unhealthy + 1))
      all_healthy=false
    else
      healthy=$((healthy + 1))
    fi

    # Build workflow result
    if [ "$JSON_OUTPUT" = true ]; then
      workflow_results+=("$(jq -n \
        --arg id "$workflow_id" \
        --arg name "$workflow_name" \
        --argjson active "$is_active" \
        --arg status "$status_text" \
        --arg last_run "$last_run_display" \
        --arg last_status "$last_status" \
        --argjson error_count "$error_count" \
        --arg webhook_check "$webhook_check" \
        --arg remediation "$remediation" \
        --arg error_message "$error_message" \
        '{
          id: $id,
          name: $name,
          active: $active,
          status: $status,
          last_run: $last_run,
          last_status: $last_status,
          errors_last_hour: $error_count,
          webhook_check: $webhook_check,
          remediation: (if $remediation != "" then $remediation else null end),
          error_message: (if $error_message != "" then $error_message else null end)
        }'
      )")
    elif [ "$QUIET" = false ]; then
      # Human-readable output
      printf "%s %-25s | " "$status" "$workflow_name"

      if [ "$is_active" = "true" ]; then
        printf "Active | "
      else
        printf "Inactive | "
      fi

      printf "Last run: %-12s " "$last_run_display"

      if [ "$last_status" = "success" ]; then
        printf "(success)"
      elif [ "$last_status" = "error" ] || [ "$last_status" = "failed" ]; then
        printf "(failed)"
      elif [ "$last_run_display" = "Never" ]; then
        printf ""
      else
        printf "(%s)" "$last_status"
      fi

      printf " | %s errors/1h" "$error_count"

      if [ "$has_webhook" = "true" ]; then
        printf " | webhook: %s" "$webhook_check"
      fi

      printf "\n"

      # Show remediation if needed
      if [ -n "$remediation" ]; then
        printf "  → Fix: %s\n" "$remediation"
      fi
    fi

  done < <(echo "$workflows" | jq -c '.[]')

  # Output results
  if [ "$JSON_OUTPUT" = true ]; then
    # Combine all workflow results into JSON array
    local workflows_json="[]"
    if [ ${#workflow_results[@]} -gt 0 ]; then
      workflows_json=$(printf '%s\n' "${workflow_results[@]}" | jq -s '.')
    fi

    jq -n \
      --argjson healthy "$all_healthy" \
      --argjson container_running "$container_running" \
      --argjson workflows "$workflows_json" \
      --argjson total "$total" \
      --argjson active "$active" \
      --argjson inactive "$inactive" \
      --argjson healthy_count "$healthy" \
      --argjson unhealthy_count "$unhealthy" \
      '{
        healthy: $healthy,
        container_running: $container_running,
        workflows: $workflows,
        summary: {
          total: $total,
          active: $active,
          inactive: $inactive,
          healthy: $healthy_count,
          unhealthy: $unhealthy_count
        },
        checked_at: (now | todate)
      }'
  elif [ "$QUIET" = false ]; then
    # Print header if not already done
    if [ $total -gt 0 ]; then
      # Already printed workflows above
      echo ""
      echo "Summary:"
      echo "  Total workflows: $total"
      echo "  Active: $active | Inactive: $inactive"
      echo "  Healthy: $healthy | Unhealthy: $unhealthy"
      echo ""
    else
      echo "n8n Workflow Health"
      echo "==================="
      echo ""
    fi
  fi

  # Exit code based on health
  if [ "$all_healthy" = true ]; then
    exit 0
  else
    exit 1
  fi
}

# Print header for human-readable output
if [ "$QUIET" = false ] && [ "$JSON_OUTPUT" = false ]; then
  echo "n8n Workflow Health"
  echo "==================="
  echo ""
fi

main
