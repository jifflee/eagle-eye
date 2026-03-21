#!/usr/bin/env bash
set -euo pipefail

# Dispatch an eagle-eye issue to the Proxmox worker queue.
# Usage: ./scripts/dispatch-issue.sh <issue_number> [--dry-run]
#
# Requires:
#   WORKER_TOKEN  — Bearer token for worker-webhook API
#   Or: source proxmox-infra/scripts/export-env.sh

WORKER_HOST="${WORKER_HOST:-10.69.8.11}"
WORKER_PORT="${WORKER_PORT:-9080}"
WORKER_URL="http://${WORKER_HOST}:${WORKER_PORT}/dispatch"
REPO="jifflee/eagle-eye"
IMAGE="${WORKER_IMAGE:-eagle-eye-worker:latest}"

usage() {
  echo "Usage: $0 <issue_number> [--dry-run]"
  echo ""
  echo "Dispatches an issue to the Proxmox worker queue for autonomous processing."
  echo ""
  echo "Environment:"
  echo "  WORKER_TOKEN   Bearer token for worker-webhook API (required)"
  echo "  WORKER_HOST    Worker VM IP (default: 10.69.8.11)"
  echo "  WORKER_PORT    Worker API port (default: 9080)"
  echo "  WORKER_IMAGE   Docker image (default: eagle-eye-worker:latest)"
  exit 1
}

ISSUE="${1:-}"
DRY_RUN=false

[[ -z "${ISSUE}" ]] && usage
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

# Validate issue exists
if ! gh issue view "${ISSUE}" --repo "${REPO}" --json state -q '.state' >/dev/null 2>&1; then
  echo "Error: Issue #${ISSUE} not found in ${REPO}" >&2
  exit 1
fi

ISSUE_TITLE=$(gh issue view "${ISSUE}" --repo "${REPO}" --json title -q '.title')
echo "Dispatching: #${ISSUE} — ${ISSUE_TITLE}"

# Build dispatch payload
PAYLOAD=$(jq -n \
  --arg repo "${REPO}" \
  --arg issue "${ISSUE}" \
  --arg image "${IMAGE}" \
  '{
    repo: $repo,
    issue: ($issue | tonumber),
    image: $image,
    env: {
      ISSUE_NUMBER: $issue,
      REPO: $repo
    }
  }')

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "Dry run — would POST to ${WORKER_URL}:"
  echo "${PAYLOAD}" | jq .
  exit 0
fi

# Dispatch to worker queue
if [[ -z "${WORKER_TOKEN:-}" ]]; then
  echo "Error: WORKER_TOKEN not set. Source proxmox-infra/scripts/export-env.sh" >&2
  exit 1
fi

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${WORKER_URL}" \
  -H "Authorization: Bearer ${WORKER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | head -n -1)

if [[ "${HTTP_CODE}" -ge 200 && "${HTTP_CODE}" -lt 300 ]]; then
  JOB_ID=$(echo "${BODY}" | jq -r '.id // .job_id // "unknown"')
  echo "Dispatched successfully. Job ID: ${JOB_ID}"
  echo ""
  echo "Monitor:"
  echo "  make worker-queue-status id=${JOB_ID}    # from proxmox-infra"
  echo "  make worker-logs id=${JOB_ID}            # view container logs"
else
  echo "Dispatch failed (HTTP ${HTTP_CODE}):" >&2
  echo "${BODY}" | jq . 2>/dev/null || echo "${BODY}" >&2
  exit 1
fi
