#!/usr/bin/env bash
#
# assemble-worker-context.sh - Assemble a minimal CLAUDE.md from template fragments
#
# Usage:
#   ./scripts/assemble-worker-context.sh \
#     --issue 267 \
#     --agents bug,backend-developer,test-qa \
#     --output /tmp/worker-267/CLAUDE.md
#
# The script assembles context files in this order:
#   1. templates/base.md
#   2. templates/agents/{agent}.md for each specified agent
#   3. templates/awareness.md
#

set -euo pipefail

# Get script directory to find templates relative to repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/templates"

# Default values
ISSUE=""
AGENTS=""
OUTPUT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --issue)
      ISSUE="$2"
      shift 2
      ;;
    --agents)
      AGENTS="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 --issue N --agents agent1,agent2 --output /path/to/CLAUDE.md"
      echo ""
      echo "Options:"
      echo "  --issue N       Issue number for header comment"
      echo "  --agents LIST   Comma-separated list of agent names"
      echo "  --output PATH   Output file path for assembled CLAUDE.md"
      echo "  -h, --help      Show this help message"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$ISSUE" ]]; then
  echo "ERROR: --issue is required" >&2
  exit 1
fi

if [[ -z "$AGENTS" ]]; then
  echo "ERROR: --agents is required" >&2
  exit 1
fi

if [[ -z "$OUTPUT" ]]; then
  echo "ERROR: --output is required" >&2
  exit 1
fi

# Validate templates directory exists
if [[ ! -d "$TEMPLATES_DIR" ]]; then
  echo "ERROR: Templates directory not found: $TEMPLATES_DIR" >&2
  exit 1
fi

# Validate base.md exists
if [[ ! -f "$TEMPLATES_DIR/base.md" ]]; then
  echo "ERROR: Base template not found: $TEMPLATES_DIR/base.md" >&2
  exit 1
fi

# Validate awareness.md exists
if [[ ! -f "$TEMPLATES_DIR/awareness.md" ]]; then
  echo "ERROR: Awareness template not found: $TEMPLATES_DIR/awareness.md" >&2
  exit 1
fi

# Create output directory if needed
OUTPUT_DIR="$(dirname "$OUTPUT")"
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

# Convert comma-separated agents to array
IFS=',' read -ra AGENT_ARRAY <<< "$AGENTS"

# Validate each agent file exists (warn if not found)
MISSING_AGENTS=()
VALID_AGENTS=()
for agent in "${AGENT_ARRAY[@]}"; do
  # Trim whitespace
  agent=$(echo "$agent" | xargs)
  agent_file="$TEMPLATES_DIR/agents/${agent}.md"
  if [[ ! -f "$agent_file" ]]; then
    echo "WARNING: Agent template not found: $agent_file" >&2
    MISSING_AGENTS+=("$agent")
  else
    VALID_AGENTS+=("$agent")
  fi
done

# Build the assembled file
{
  # Header comment
  echo "# Worker Context (Auto-generated)"
  echo "# Issue: #$ISSUE"
  echo "# Agents: ${AGENTS}"
  echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo ""

  # Base context
  cat "$TEMPLATES_DIR/base.md"
  echo ""

  # Agent sections
  if [[ ${#VALID_AGENTS[@]} -gt 0 ]]; then
    echo "## Available Agents"
    echo ""
    for agent in "${VALID_AGENTS[@]}"; do
      agent_file="$TEMPLATES_DIR/agents/${agent}.md"
      cat "$agent_file"
      echo ""
    done
  fi

  # Awareness section
  echo "## Other Agents (Awareness)"
  echo ""
  cat "$TEMPLATES_DIR/awareness.md"

} > "$OUTPUT"

# Report result
echo "$OUTPUT"

# Exit with warning status if any agents were missing
if [[ ${#MISSING_AGENTS[@]} -gt 0 ]]; then
  exit 0  # Still success, but warnings were printed
fi

exit 0
