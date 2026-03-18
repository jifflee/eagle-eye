#!/usr/bin/env bash
#
# MCP Security Authorization Server launcher script
#
# Usage:
#   ./scripts/mcp-auth-server.sh [stdio|http] [OPTIONS]
#
# Examples:
#   ./scripts/mcp-auth-server.sh                    # Start with stdio
#   ./scripts/mcp-auth-server.sh http --port 8080   # Start HTTP server
#   ./scripts/mcp-auth-server.sh --log-level debug  # Debug mode

set -euo pipefail

# Get script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Change to repo root
cd "${REPO_ROOT}"

# Check if Python is available
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is not installed" >&2
    exit 1
fi

# Check if virtual environment exists, create if not
if [[ ! -d "${REPO_ROOT}/venv" ]]; then
    echo "Creating virtual environment..." >&2
    python3 -m venv venv
fi

# Activate virtual environment
# shellcheck disable=SC1091
source "${REPO_ROOT}/venv/bin/activate"

# Install dependencies if needed
if ! python3 -c "import yaml" &> /dev/null; then
    echo "Installing dependencies..." >&2
    pip install -q -r requirements.txt
fi

# Set default environment variables if not set
export MCP_TRANSPORT="${MCP_TRANSPORT:-stdio}"
export MCP_HOST="${MCP_HOST:-localhost}"
export MCP_PORT="${MCP_PORT:-8080}"
export MCP_POLICY_PATH="${MCP_POLICY_PATH:-${REPO_ROOT}/config/security-policy.yaml}"
export MCP_AUDIT_LOG_PATH="${MCP_AUDIT_LOG_PATH:-${HOME}/.claude-tastic/security-audit}"
export MCP_LOG_LEVEL="${MCP_LOG_LEVEL:-info}"

# Run the MCP server
exec python3 -m src.mcp.cli "$@"
