#!/bin/bash
#
# llm-tunnel.sh - Manage SSH tunnel to llm-node for local LLM access
#
# Usage:
#   ./scripts/llm-tunnel.sh <command>
#
# Commands:
#   start   - Start the SSH tunnel
#   stop    - Stop the SSH tunnel
#   status  - Check tunnel status
#   restart - Restart the tunnel
#
# Configuration:
#   Set LLM_NODE_HOST environment variable or configure SSH host "llm-node"
#
# Related: Issue #428, /docs/LOCAL_LLM_ENDPOINTS.md

set -euo pipefail

# Configuration
LLM_NODE="${LLM_NODE_HOST:-llm-node}"
CODESTRAL_PORT="${CODESTRAL_PORT:-8001}"
LLAMA_PORT="${LLAMA_PORT:-8002}"
PID_FILE="${HOME}/.llm-tunnel.pid"
LOG_FILE="${HOME}/.llm-tunnel.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Print colored message
print_status() {
  local color="$1"
  local message="$2"
  echo -e "${color}${message}${NC}"
}

# Check if tunnel is running
is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if ps -p "$pid" > /dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# Get tunnel PID
get_pid() {
  if [[ -f "$PID_FILE" ]]; then
    cat "$PID_FILE"
  fi
}

# Check if ports are listening
check_ports() {
  local codestral_ok=false
  local llama_ok=false

  if lsof -i ":${CODESTRAL_PORT}" > /dev/null 2>&1; then
    codestral_ok=true
  fi

  if lsof -i ":${LLAMA_PORT}" > /dev/null 2>&1; then
    llama_ok=true
  fi

  if $codestral_ok && $llama_ok; then
    return 0
  fi
  return 1
}

# Start the tunnel
cmd_start() {
  if is_running; then
    print_status "$YELLOW" "Tunnel already running (PID: $(get_pid))"
    exit 0
  fi

  echo "Starting SSH tunnel to ${LLM_NODE}..."
  echo "  Forwarding port ${CODESTRAL_PORT} (Codestral)"
  echo "  Forwarding port ${LLAMA_PORT} (Llama)"

  # Start SSH tunnel in background
  ssh -f -N \
    -o "ServerAliveInterval=60" \
    -o "ServerAliveCountMax=3" \
    -o "ExitOnForwardFailure=yes" \
    -L "${CODESTRAL_PORT}:127.0.0.1:${CODESTRAL_PORT}" \
    -L "${LLAMA_PORT}:127.0.0.1:${LLAMA_PORT}" \
    "${LLM_NODE}" \
    > "$LOG_FILE" 2>&1

  # Find and save the PID (most recent ssh process to our host)
  sleep 1
  local pid
  pid=$(pgrep -f "ssh.*${LLM_NODE}.*${CODESTRAL_PORT}" | tail -1 || true)

  if [[ -n "$pid" ]]; then
    echo "$pid" > "$PID_FILE"
    print_status "$GREEN" "Tunnel started (PID: ${pid})"

    # Verify ports are listening
    sleep 1
    if check_ports; then
      print_status "$GREEN" "Ports ${CODESTRAL_PORT} and ${LLAMA_PORT} are now listening"
    else
      print_status "$YELLOW" "Warning: Ports may not be ready yet. Check with 'status' command."
    fi
  else
    print_status "$RED" "Failed to start tunnel. Check ${LOG_FILE} for errors."
    exit 1
  fi
}

# Stop the tunnel
cmd_stop() {
  if ! is_running; then
    print_status "$YELLOW" "Tunnel is not running"
    rm -f "$PID_FILE"
    exit 0
  fi

  local pid
  pid=$(get_pid)
  echo "Stopping tunnel (PID: ${pid})..."

  kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"

  # Wait for process to terminate
  local count=0
  while ps -p "$pid" > /dev/null 2>&1 && [[ $count -lt 10 ]]; do
    sleep 0.5
    ((count++))
  done

  if ps -p "$pid" > /dev/null 2>&1; then
    print_status "$YELLOW" "Process still running, sending SIGKILL..."
    kill -9 "$pid" 2>/dev/null || true
  fi

  print_status "$GREEN" "Tunnel stopped"
}

# Check tunnel status
cmd_status() {
  echo "LLM Tunnel Status"
  echo "================="
  echo ""

  # Check if process is running
  if is_running; then
    local pid
    pid=$(get_pid)
    print_status "$GREEN" "Tunnel process: Running (PID: ${pid})"
  else
    print_status "$RED" "Tunnel process: Not running"
    rm -f "$PID_FILE" 2>/dev/null || true
  fi

  # Check if ports are listening
  echo ""
  echo "Port Status:"
  if lsof -i ":${CODESTRAL_PORT}" > /dev/null 2>&1; then
    print_status "$GREEN" "  Port ${CODESTRAL_PORT} (Codestral): Listening"
  else
    print_status "$RED" "  Port ${CODESTRAL_PORT} (Codestral): Not listening"
  fi

  if lsof -i ":${LLAMA_PORT}" > /dev/null 2>&1; then
    print_status "$GREEN" "  Port ${LLAMA_PORT} (Llama): Listening"
  else
    print_status "$RED" "  Port ${LLAMA_PORT} (Llama): Not listening"
  fi

  # Quick health check
  echo ""
  echo "Endpoint Health:"
  if curl -sf --connect-timeout 2 "http://127.0.0.1:${CODESTRAL_PORT}/health" > /dev/null 2>&1; then
    print_status "$GREEN" "  Codestral: Healthy"
  else
    print_status "$RED" "  Codestral: Unreachable"
  fi

  if curl -sf --connect-timeout 2 "http://127.0.0.1:${LLAMA_PORT}/health" > /dev/null 2>&1; then
    print_status "$GREEN" "  Llama: Healthy"
  else
    print_status "$RED" "  Llama: Unreachable"
  fi

  echo ""
  echo "Configuration:"
  echo "  LLM Node: ${LLM_NODE}"
  echo "  Codestral Port: ${CODESTRAL_PORT}"
  echo "  Llama Port: ${LLAMA_PORT}"
  echo "  PID File: ${PID_FILE}"
}

# Restart the tunnel
cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

# Show help
cmd_help() {
  cat <<EOF
LLM Tunnel Manager

Usage: $0 <command>

Commands:
  start   - Start the SSH tunnel to llm-node
  stop    - Stop the SSH tunnel
  status  - Check tunnel and endpoint status
  restart - Restart the tunnel
  help    - Show this help message

Environment Variables:
  LLM_NODE_HOST    SSH host for llm-node (default: llm-node)
  CODESTRAL_PORT   Local port for Codestral (default: 8001)
  LLAMA_PORT       Local port for Llama (default: 8002)

SSH Configuration:
  Add to ~/.ssh/config:

    Host llm-node
        HostName <your-llm-node-ip>
        User <username>
        IdentityFile ~/.ssh/id_rsa
        LocalForward 8001 127.0.0.1:8001
        LocalForward 8002 127.0.0.1:8002

Examples:
  $0 start              # Start tunnel
  $0 status             # Check status
  LLM_NODE_HOST=myserver $0 start  # Use custom host

Related:
  /docs/LOCAL_LLM_ENDPOINTS.md
  ./scripts/llm-health-check.sh
EOF
}

# Main entry point
main() {
  local command="${1:-help}"

  case "$command" in
    start)
      cmd_start
      ;;
    stop)
      cmd_stop
      ;;
    status)
      cmd_status
      ;;
    restart)
      cmd_restart
      ;;
    help|--help|-h)
      cmd_help
      ;;
    *)
      echo "Unknown command: $command"
      echo "Run '$0 help' for usage"
      exit 1
      ;;
  esac
}

main "$@"
