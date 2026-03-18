#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: n8n-repo-commands.sh
# Purpose: Generate repo-specific n8n Docker commands
# Usage: ./scripts/n8n-repo-commands.sh [start|stop|logs|status|help]
#
# This script helps manage n8n instances with per-repository naming
# to avoid conflicts when running multiple n8n instances.
#
# Issue: #448 - Add unique per-repo container naming for n8n deployment
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source common utilities
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  source "$SCRIPT_DIR/lib/common.sh"
else
  # Minimal fallback
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_success() { echo "[OK] $*" >&2; }
  die() { log_error "$*"; exit 1; }
fi

# Get repository name
get_repo_name() {
  cd "$REPO_ROOT"
  basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$REPO_ROOT"
}

# Get container name
get_container_name() {
  local repo_name=$(get_repo_name)
  echo "n8n-${repo_name}"
}

# Get volume name
get_volume_path() {
  local repo_name=$(get_repo_name)
  echo "${HOME}/.n8n-${repo_name}"
}

# Get default port (can be overridden with N8N_PORT env var)
get_port() {
  echo "${N8N_PORT:-5678}"
}

# Display help
show_help() {
  cat <<EOF
n8n Repository-Specific Command Generator

USAGE:
  ./scripts/n8n-repo-commands.sh <command>

COMMANDS:
  start       Generate Docker command to start n8n for this repository
  stop        Generate Docker command to stop n8n for this repository
  logs        Generate Docker command to view n8n logs
  status      Check if n8n is running for this repository
  info        Show configuration information for this repository
  help        Show this help message

ENVIRONMENT VARIABLES:
  N8N_PORT    Port to expose n8n on (default: 5678)

EXAMPLES:
  # Get start command and execute it
  ./scripts/n8n-repo-commands.sh start | bash

  # Check if running
  ./scripts/n8n-repo-commands.sh status

  # Use custom port
  N8N_PORT=5679 ./scripts/n8n-repo-commands.sh start | bash

REPOSITORY NAMING CONVENTION:
  Container:  n8n-<repo-name>
  Volume:     ~/.n8n-<repo-name>/
  Port:       5678 (or custom via N8N_PORT)

Current Configuration:
  Repository:  $(get_repo_name)
  Container:   $(get_container_name)
  Volume:      $(get_volume_path)
  Port:        $(get_port)

EOF
}

# Generate start command
cmd_start() {
  local container_name=$(get_container_name)
  local volume_path=$(get_volume_path)
  local port=$(get_port)

  cat <<EOF
# Start n8n for repository: $(get_repo_name)
mkdir -p ${volume_path}
docker run -d \\
  --name ${container_name} \\
  --restart unless-stopped \\
  -p ${port}:5678 \\
  -v ${volume_path}:/home/node/.n8n \\
  -v ${REPO_ROOT}/n8n-workflows:/home/node/workflows:ro \\
  n8nio/n8n

# Verify it's running
docker ps | grep ${container_name}
EOF
}

# Generate stop command
cmd_stop() {
  local container_name=$(get_container_name)

  cat <<EOF
# Stop n8n for repository: $(get_repo_name)
docker stop ${container_name}
docker rm ${container_name}
EOF
}

# Generate logs command
cmd_logs() {
  local container_name=$(get_container_name)

  cat <<EOF
# View logs for n8n container: ${container_name}
docker logs -f ${container_name}
EOF
}

# Check status
cmd_status() {
  local container_name=$(get_container_name)
  local port=$(get_port)

  echo "Repository: $(get_repo_name)"
  echo "Container:  ${container_name}"
  echo "Port:       ${port}"
  echo "Volume:     $(get_volume_path)"
  echo ""

  if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    log_success "n8n is running for this repository"
    echo ""
    echo "Access UI:  http://localhost:${port}"
    echo "Health:     http://localhost:${port}/healthz"

    # Test health endpoint
    if curl -sf "http://localhost:${port}/healthz" &>/dev/null; then
      log_success "Health check: PASSED"
    else
      log_warn "Health check: FAILED (container may be starting)"
    fi
  else
    log_warn "n8n is NOT running for this repository"
    echo ""
    echo "To start: ./scripts/n8n-repo-commands.sh start | bash"
  fi
}

# Show configuration info
cmd_info() {
  cat <<EOF
Repository Configuration:
  Name:       $(get_repo_name)
  Path:       ${REPO_ROOT}

n8n Configuration:
  Container:  $(get_container_name)
  Volume:     $(get_volume_path)
  Port:       $(get_port)
  Workflows:  ${REPO_ROOT}/n8n-workflows

Docker Commands:
  Start:      ./scripts/n8n-repo-commands.sh start | bash
  Stop:       ./scripts/n8n-repo-commands.sh stop | bash
  Logs:       ./scripts/n8n-repo-commands.sh logs | bash
  Status:     ./scripts/n8n-repo-commands.sh status

Environment Variables:
  N8N_PORT=${N8N_PORT:-5678} (default: 5678)

EOF
}

# Main
main() {
  local command="${1:-help}"

  case "$command" in
    start)
      cmd_start
      ;;
    stop)
      cmd_stop
      ;;
    logs)
      cmd_logs
      ;;
    status)
      cmd_status
      ;;
    info)
      cmd_info
      ;;
    help|--help|-h)
      show_help
      ;;
    *)
      log_error "Unknown command: $command"
      echo ""
      show_help
      exit 1
      ;;
  esac
}

main "$@"
