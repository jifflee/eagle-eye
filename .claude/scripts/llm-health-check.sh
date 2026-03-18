#!/bin/bash
#
# llm-health-check.sh - Check health of local LLM endpoints
#
# Usage:
#   ./scripts/llm-health-check.sh [--json] [--quiet]
#
# Options:
#   --json    Output in JSON format
#   --quiet   Only output on failure (exit code indicates status)
#
# Exit codes:
#   0 - All endpoints healthy
#   1 - One or more endpoints unhealthy
#   2 - Script error
#
# Related: Issue #428

set -euo pipefail

# Configuration
CODESTRAL_PORT="${CODESTRAL_PORT:-8001}"
LLAMA_PORT="${LLAMA_PORT:-8002}"
CODESTRAL_URL="http://127.0.0.1:${CODESTRAL_PORT}"
LLAMA_URL="http://127.0.0.1:${LLAMA_PORT}"
TIMEOUT="${LLM_HEALTH_TIMEOUT:-5}"

# Parse arguments
JSON_OUTPUT=false
QUIET=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--json] [--quiet]"
      echo ""
      echo "Check health of local LLM endpoints (Codestral and Llama)."
      echo ""
      echo "Options:"
      echo "  --json    Output in JSON format"
      echo "  --quiet   Only output on failure"
      echo ""
      echo "Environment variables:"
      echo "  CODESTRAL_PORT    Codestral port (default: 8001)"
      echo "  LLAMA_PORT        Llama port (default: 8002)"
      echo "  LLM_HEALTH_TIMEOUT  Timeout in seconds (default: 5)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Check single endpoint health
check_endpoint() {
  local name="$1"
  local url="$2"
  local start_time
  local end_time
  local duration
  local status
  local response

  # Use perl for milliseconds on macOS (date %N not supported)
  if command -v perl &>/dev/null; then
    start_time=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')
  else
    start_time=$(($(date +%s) * 1000))
  fi

  # Try health endpoint first, then root
  if response=$(curl -sf --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" "${url}/health" 2>&1); then
    status="healthy"
  elif response=$(curl -sf --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" "${url}/" 2>&1); then
    status="healthy"
  else
    status="unhealthy"
    response="Connection failed or timed out"
  fi

  if command -v perl &>/dev/null; then
    end_time=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')
  else
    end_time=$(($(date +%s) * 1000))
  fi

  duration=$((end_time - start_time))

  echo "${name}|${status}|${duration}|${response}"
}

# Main health check
main() {
  local codestral_result
  local llama_result
  local codestral_status
  local llama_status
  local codestral_latency
  local llama_latency
  local all_healthy=true

  # Check both endpoints
  codestral_result=$(check_endpoint "codestral" "$CODESTRAL_URL")
  llama_result=$(check_endpoint "llama" "$LLAMA_URL")

  # Parse results
  IFS='|' read -r _ codestral_status codestral_latency codestral_response <<< "$codestral_result"
  IFS='|' read -r _ llama_status llama_latency llama_response <<< "$llama_result"

  # Determine overall health
  if [[ "$codestral_status" != "healthy" ]] || [[ "$llama_status" != "healthy" ]]; then
    all_healthy=false
  fi

  # Output results
  if $JSON_OUTPUT; then
    cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "all_healthy": $all_healthy,
  "endpoints": {
    "codestral": {
      "url": "${CODESTRAL_URL}",
      "port": ${CODESTRAL_PORT},
      "status": "${codestral_status}",
      "latency_ms": ${codestral_latency:-0}
    },
    "llama": {
      "url": "${LLAMA_URL}",
      "port": ${LLAMA_PORT},
      "status": "${llama_status}",
      "latency_ms": ${llama_latency:-0}
    }
  }
}
EOF
  elif ! $QUIET || ! $all_healthy; then
    echo "LLM Health Check"
    echo "================"
    echo ""
    if [[ "$codestral_status" == "healthy" ]]; then
      echo "Codestral (${CODESTRAL_PORT})... OK (${codestral_latency}ms)"
    else
      echo "Codestral (${CODESTRAL_PORT})... FAILED"
      echo "  Error: ${codestral_response}"
    fi

    if [[ "$llama_status" == "healthy" ]]; then
      echo "Llama (${LLAMA_PORT})... OK (${llama_latency}ms)"
    else
      echo "Llama (${LLAMA_PORT})... FAILED"
      echo "  Error: ${llama_response}"
    fi

    echo ""
    if $all_healthy; then
      echo "All LLM endpoints healthy"
    else
      echo "WARNING: One or more LLM endpoints unhealthy"
      echo ""
      echo "Troubleshooting:"
      echo "  1. Check SSH tunnel: ./scripts/llm-tunnel.sh status"
      echo "  2. Start SSH tunnel: ./scripts/llm-tunnel.sh start"
      echo "  3. See docs: /docs/LOCAL_LLM_ENDPOINTS.md"
    fi
  fi

  # Exit with appropriate code
  if $all_healthy; then
    exit 0
  else
    exit 1
  fi
}

main
