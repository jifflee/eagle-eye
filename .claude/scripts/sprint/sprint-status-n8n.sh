#!/bin/bash
set -euo pipefail
# sprint-status-n8n.sh
# Gather n8n workflow health data for sprint-status integration
# Part of feature #724: n8n continuous workflow health monitoring
#
# Output: JSON object with n8n health suitable for sprint-status display
#
# Usage:
#   ./scripts/sprint-status-n8n.sh

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if n8n health script exists
N8N_HEALTH_SCRIPT="${SCRIPT_DIR}/n8n-health.sh"
if [ ! -x "$N8N_HEALTH_SCRIPT" ]; then
    echo '{"available": false, "error": "n8n-health.sh not found"}'
    exit 0
fi

# Run n8n health check with workflow monitoring
N8N_HEALTH=$("$N8N_HEALTH_SCRIPT" --include-workflows --json 2>/dev/null || echo '{"healthy": false, "error": "health check failed"}')

# Check if n8n is available
CONTAINER_RUNNING=$(echo "$N8N_HEALTH" | jq -r '.container.container_running // .container_running // false')

if [ "$CONTAINER_RUNNING" = "false" ]; then
    echo '{"available": false, "container_running": false}'
    exit 0
fi

# Extract workflow health data
WORKFLOWS=$(echo "$N8N_HEALTH" | jq -r '.workflows.workflows // []')
SUMMARY=$(echo "$N8N_HEALTH" | jq -r '.workflows.summary // {}')

# Format for sprint-status display
# Transform workflow data into display-friendly format
FORMATTED_WORKFLOWS=$(echo "$WORKFLOWS" | jq -r '
  map({
    name: .name,
    active: .active,
    status: .status,
    last_run: .last_run,
    errors: .errors_last_hour,
    remediation: .remediation
  })
')

# Build final output
jq -n \
  --argjson available "true" \
  --argjson container_running "$CONTAINER_RUNNING" \
  --argjson healthy "$(echo "$N8N_HEALTH" | jq -r '.healthy // false')" \
  --argjson workflows "$FORMATTED_WORKFLOWS" \
  --argjson summary "$SUMMARY" \
  --arg url "$(echo "$N8N_HEALTH" | jq -r '.container.url // "http://localhost:5678"')" \
  --arg uptime "$(echo "$N8N_HEALTH" | jq -r '.container.uptime // "N/A"')" \
  '{
    available: $available,
    container_running: $container_running,
    healthy: $healthy,
    url: $url,
    uptime: $uptime,
    workflows: $workflows,
    summary: $summary
  }'
