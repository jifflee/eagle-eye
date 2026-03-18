#!/usr/bin/env bash
# ============================================================
# Script: n8n-redundancy-check.sh
# Purpose: Detect redundant, overlapping, and never-triggered n8n workflows
#
# Analyzes n8n workflow definitions and execution history to identify:
#   - Workflows with duplicate/overlapping trigger conditions
#   - Workflows never triggered in the lookback window
#   - Stale active workflows (no recent executions)
#   - Duplicate webhook paths across workflows
#
# Usage:
#   ./scripts/n8n-redundancy-check.sh [OPTIONS]
#
# Options:
#   --json              Output JSON report (default: human-readable)
#   --lookback-days N   Days of history to analyze (default: 30)
#   --output FILE       Write report to file
#   --ci                Exit 1 if redundancies found (for CI gates)
#   --help              Show this help message
#
# Environment:
#   N8N_API_URL         n8n base URL (default: http://localhost:5678)
#   N8N_API_KEY         n8n API key for authentication
#   LOOKBACK_DAYS       Days of history (overrides --lookback-days)
#
# Exit codes:
#   0  - Success (no critical redundancies found, or --ci not set)
#   1  - Critical redundancies found (only when --ci flag is set)
#   2  - Error (n8n unreachable, API error)
#
# Feature: #821 - n8n workflow performance tracking and observability
# ============================================================

set -euo pipefail

# Configuration
N8N_API_URL="${N8N_API_URL:-http://localhost:5678}"
N8N_API_KEY="${N8N_API_KEY:-}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-30}"

# Options
JSON_OUTPUT=false
OUTPUT_FILE=""
CI_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)           JSON_OUTPUT=true; shift ;;
    --lookback-days)  LOOKBACK_DAYS="$2"; shift 2 ;;
    --output)         OUTPUT_FILE="$2"; shift 2 ;;
    --ci)             CI_MODE=true; shift ;;
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

log()       { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
log_info()  { log "[INFO]  $*"; }
log_warn()  { log "[WARN]  $*"; }
log_error() { log "[ERROR] $*"; }

# Build auth header for n8n API calls
n8n_api() {
  local path="$1"
  local auth_header
  if [ -n "$N8N_API_KEY" ]; then
    auth_header="X-N8N-API-KEY: ${N8N_API_KEY}"
  else
    auth_header="Accept: application/json"
  fi
  curl -sf --max-time 30 \
    -H "$auth_header" \
    -H "Accept: application/json" \
    "${N8N_API_URL}/api/v1${path}" 2>/dev/null || echo "null"
}

# Check n8n availability
check_n8n() {
  local health
  health=$(curl -sf --max-time 10 "${N8N_API_URL}/healthz" 2>/dev/null || echo "")
  if [ -z "$health" ]; then
    log_error "Cannot reach n8n at ${N8N_API_URL}"
    exit 2
  fi
  log_info "n8n is reachable at ${N8N_API_URL}"
}

# Fetch all workflows
fetch_workflows() {
  local raw
  raw=$(n8n_api "/workflows?limit=100")
  if [ "$raw" = "null" ] || [ -z "$raw" ]; then
    log_error "Failed to fetch workflows from n8n API"
    exit 2
  fi
  echo "$raw" | jq -c '.data // []'
}

# Fetch recent executions
fetch_executions() {
  local raw
  raw=$(n8n_api "/executions?limit=500&includeData=false")
  if [ "$raw" = "null" ] || [ -z "$raw" ]; then
    log_warn "Failed to fetch executions (may be empty)"
    echo "[]"
    return
  fi
  echo "$raw" | jq -c '.data // []'
}

# Detect never-triggered workflows
detect_never_triggered() {
  local workflows="$1"
  local executions="$2"

  jq -n \
    --argjson wf "$workflows" \
    --argjson ex "$executions" \
    '
    # Get all workflow IDs that have executions
    ($ex | map(.workflowId) | unique) as $triggered_ids |

    # Find active workflows not in triggered list
    [$wf[] |
      select(.active == true) |
      select((.id | tostring) | IN($triggered_ids[]) | not) |
      {
        id: (.id | tostring),
        name: .name,
        active: .active,
        created_at: .createdAt,
        updated_at: .updatedAt
      }
    ]
    '
}

# Detect stale workflows (active but last execution > LOOKBACK_DAYS ago)
detect_stale_workflows() {
  local workflows="$1"
  local executions="$2"
  local cutoff_days="$3"

  jq -n \
    --argjson wf "$workflows" \
    --argjson ex "$executions" \
    --argjson days "$cutoff_days" \
    '
    # Compute cutoff timestamp
    (now - ($days * 86400)) as $cutoff_ts |

    # Get last execution per workflow
    ($ex | group_by(.workflowId) | map({
      workflow_id: (.[0].workflowId | tostring),
      last_execution: (map(.startedAt) | sort | last),
      last_execution_ts: (map(
        .startedAt | gsub("\\\\.[0-9]+Z$"; "Z") |
        strptime("%Y-%m-%dT%H:%M:%SZ") | mktime
      ) | max)
    }) | INDEX(.workflow_id)) as $last_exec |

    # Find active workflows where last execution is before cutoff
    [$wf[] |
      select(.active == true) |
      (.id | tostring) as $wid |
      select($last_exec[$wid] != null) |
      select($last_exec[$wid].last_execution_ts < $cutoff_ts) |
      {
        id: $wid,
        name: .name,
        active: .active,
        last_execution: $last_exec[$wid].last_execution,
        days_since_execution: ((now - $last_exec[$wid].last_execution_ts) / 86400 | floor)
      }
    ]
    '
}

# Detect duplicate webhook paths
detect_duplicate_webhooks() {
  local workflows="$1"

  jq -n \
    --argjson wf "$workflows" \
    '
    # Extract webhook paths per workflow
    [$wf[] | {
      workflow_id: (.id | tostring),
      workflow_name: .name,
      webhook_paths: (
        [.nodes[]? |
          select(.type == "n8n-nodes-base.webhook" or .type == "n8n-nodes-base.formTrigger") |
          .parameters.path // ""
        ] | map(select(. != ""))
      )
    } | select(.webhook_paths | length > 0)] as $wf_webhooks |

    # Find duplicate paths
    [$wf_webhooks[].webhook_paths[]] |
    group_by(.) |
    map(select(length > 1)) |
    map({
      path: .[0],
      count: length
    }) as $dup_paths |

    # Find which workflows share each duplicate path
    [$dup_paths[] | . as $dp |
      {
        path: $dp.path,
        workflow_count: $dp.count,
        workflows: [$wf_webhooks[] |
          select(.webhook_paths | map(. == $dp.path) | any) |
          {id: .workflow_id, name: .workflow_name}
        ]
      }
    ]
    '
}

# Detect overlapping trigger configurations
detect_overlapping_triggers() {
  local workflows="$1"

  jq -n \
    --argjson wf "$workflows" \
    '
    # Extract triggers per workflow
    [$wf[] | {
      workflow_id: (.id | tostring),
      workflow_name: .name,
      triggers: [
        .nodes[]? |
        select(.type | test("trigger|Trigger|webhook|Webhook|cron|Cron|schedule|Schedule")) |
        {
          type: .type,
          config_signature: (.parameters | del(.path) | tojson)
        }
      ]
    } | select(.triggers | length > 0)] as $wf_triggers |

    # Group by trigger type + config signature
    [$wf_triggers[].triggers[] |
      . as $trigger |
      $wf_triggers[] |
      select(.triggers | map(. == $trigger) | any) |
      {trigger: $trigger, workflow_id: .workflow_id, workflow_name: .workflow_name}
    ] |
    group_by(.trigger.type + "::" + .trigger.config_signature) |
    map(select(length > 1)) |
    map({
      trigger_type: .[0].trigger.type,
      config_summary: .[0].trigger.config_signature,
      workflow_count: length,
      workflows: map({id: .workflow_id, name: .workflow_name}) | unique_by(.id)
    }) |
    # Only include groups with 2+ distinct workflows
    map(select(.workflows | length > 1))
    '
}

# Format human-readable output
format_human_output() {
  local report="$1"

  echo "n8n Workflow Redundancy Analysis"
  echo "================================="
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "n8n URL:   ${N8N_API_URL}"
  echo "Lookback:  ${LOOKBACK_DAYS} days"
  echo ""

  # Summary
  local total active never_triggered stale dup_webhooks dup_triggers
  total=$(echo "$report" | jq '.summary.total_workflows')
  active=$(echo "$report" | jq '.summary.active_workflows')
  never_triggered=$(echo "$report" | jq '.summary.never_triggered')
  stale=$(echo "$report" | jq '.summary.stale_workflows')
  dup_webhooks=$(echo "$report" | jq '.summary.duplicate_webhook_paths')
  dup_triggers=$(echo "$report" | jq '.summary.duplicate_trigger_configs')

  echo "Summary"
  echo "-------"
  echo "  Total workflows:           ${total}"
  echo "  Active workflows:          ${active}"
  echo "  Never triggered (${LOOKBACK_DAYS}d):    ${never_triggered}"
  echo "  Stale (${LOOKBACK_DAYS}d no activity):  ${stale}"
  echo "  Duplicate webhook paths:   ${dup_webhooks}"
  echo "  Duplicate trigger configs: ${dup_triggers}"
  echo ""

  # Never triggered
  if [ "$never_triggered" -gt 0 ]; then
    echo "⚠️  Never-Triggered Workflows (active but zero executions in ${LOOKBACK_DAYS}d)"
    echo "-------------------------------------------------------------"
    echo "$report" | jq -r '.never_triggered[] | "  - [\(.id)] \(.name) (created: \(.created_at // "unknown"))"'
    echo ""
  fi

  # Stale workflows
  if [ "$stale" -gt 0 ]; then
    echo "⏰  Stale Active Workflows (no executions in ${LOOKBACK_DAYS}+ days)"
    echo "----------------------------------------------------------"
    echo "$report" | jq -r '.stale_workflows[] | "  - [\(.id)] \(.name) (last run: \(.last_execution // "unknown"), \(.days_since_execution // "?") days ago)"'
    echo ""
  fi

  # Duplicate webhooks
  if [ "$dup_webhooks" -gt 0 ]; then
    echo "🔁  Duplicate Webhook Paths"
    echo "--------------------------"
    echo "$report" | jq -r '.duplicate_webhook_paths[] | "  Path: \(.path)\n    Workflows: \(.workflows | map("[\(.id)] \(.name)") | join(", "))"'
    echo ""
  fi

  # Overlapping triggers
  if [ "$dup_triggers" -gt 0 ]; then
    echo "⚡  Overlapping Trigger Configurations"
    echo "--------------------------------------"
    echo "$report" | jq -r '.overlapping_triggers[] | "  Type: \(.trigger_type) (\(.workflow_count) workflows)\n    Workflows: \(.workflows | map("[\(.id)] \(.name)") | join(", "))"'
    echo ""
  fi

  # Clean bill of health
  if [ "$never_triggered" -eq 0 ] && [ "$stale" -eq 0 ] && [ "$dup_webhooks" -eq 0 ] && [ "$dup_triggers" -eq 0 ]; then
    echo "✅  No redundancies detected. All workflows appear healthy."
  fi
}

# Main
main() {
  log_info "n8n Redundancy Check — n8n URL: ${N8N_API_URL}, Lookback: ${LOOKBACK_DAYS} days"

  # Verify n8n is reachable
  check_n8n

  # Fetch data
  log_info "Fetching workflow definitions..."
  local workflows
  workflows=$(fetch_workflows)
  local workflow_count
  workflow_count=$(echo "$workflows" | jq 'length')
  log_info "Found ${workflow_count} workflows"

  log_info "Fetching execution history..."
  local executions
  executions=$(fetch_executions)
  local execution_count
  execution_count=$(echo "$executions" | jq 'length')
  log_info "Found ${execution_count} recent executions"

  # Run analysis
  log_info "Analyzing workflow redundancy..."

  local never_triggered stale_workflows dup_webhooks overlapping_triggers

  never_triggered=$(detect_never_triggered "$workflows" "$executions")
  stale_workflows=$(detect_stale_workflows "$workflows" "$executions" "$LOOKBACK_DAYS")
  dup_webhooks=$(detect_duplicate_webhooks "$workflows")
  overlapping_triggers=$(detect_overlapping_triggers "$workflows")

  # Build report
  local report
  report=$(jq -n \
    --arg url "$N8N_API_URL" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson lookback_days "$LOOKBACK_DAYS" \
    --argjson total_workflows "$workflow_count" \
    --argjson active_workflows "$(echo "$workflows" | jq '[.[] | select(.active == true)] | length')" \
    --argjson never_triggered "$never_triggered" \
    --argjson stale_workflows "$stale_workflows" \
    --argjson dup_webhooks "$dup_webhooks" \
    --argjson overlapping_triggers "$overlapping_triggers" \
    '{
      generated_at: $generated_at,
      n8n_url: $url,
      lookback_days: $lookback_days,
      summary: {
        total_workflows: $total_workflows,
        active_workflows: $active_workflows,
        never_triggered: ($never_triggered | length),
        stale_workflows: ($stale_workflows | length),
        duplicate_webhook_paths: ($dup_webhooks | length),
        duplicate_trigger_configs: ($overlapping_triggers | length)
      },
      never_triggered: $never_triggered,
      stale_workflows: $stale_workflows,
      duplicate_webhook_paths: $dup_webhooks,
      overlapping_triggers: $overlapping_triggers
    }')

  # Output report
  local output
  if [ "$JSON_OUTPUT" = true ]; then
    output=$(echo "$report" | jq .)
  else
    output=$(format_human_output "$report")
  fi

  if [ -n "$OUTPUT_FILE" ]; then
    echo "$output" > "$OUTPUT_FILE"
    log_info "Report written to ${OUTPUT_FILE}"
  else
    echo "$output"
  fi

  # CI mode: exit 1 if critical redundancies found
  if [ "$CI_MODE" = true ]; then
    local dup_count
    dup_count=$(echo "$report" | jq '.summary.duplicate_webhook_paths + .summary.duplicate_trigger_configs')
    if [ "$dup_count" -gt 0 ]; then
      log_warn "CI mode: ${dup_count} critical redundancies detected"
      exit 1
    fi
    log_info "CI mode: No critical redundancies detected"
  fi

  exit 0
}

main
