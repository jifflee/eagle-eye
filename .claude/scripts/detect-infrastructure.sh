#!/bin/bash
# detect-infrastructure.sh
# Detects available sprint-work infrastructure (container/worktree scripts)
# Returns JSON with infrastructure availability and recommended execution mode
#
# Path resolution order (supports both framework repo and consumer repos):
#   1. .claude/scripts/ — consumer repos deployed via manifest-sync
#   2. ./scripts/       — framework (source) repo at repo root

set -euo pipefail

# Resolve container script path: check consumer repo location first, then framework repo root
CONTAINER_SCRIPT=""
if [ -f ".claude/scripts/container/container-launch.sh" ]; then
    CONTAINER_SCRIPT=".claude/scripts/container/container-launch.sh"
elif [ -f "./scripts/container/container-launch.sh" ]; then
    CONTAINER_SCRIPT="./scripts/container/container-launch.sh"
else
    CONTAINER_SCRIPT=".claude/scripts/container/container-launch.sh"  # canonical path (not found)
fi

# Resolve worktree script path: check consumer repo location first, then framework repo root
WORKTREE_SCRIPT=""
if [ -f ".claude/scripts/sprint/sprint-work-preflight.sh" ]; then
    WORKTREE_SCRIPT=".claude/scripts/sprint/sprint-work-preflight.sh"
elif [ -f "./scripts/sprint/sprint-work-preflight.sh" ]; then
    WORKTREE_SCRIPT="./scripts/sprint/sprint-work-preflight.sh"
else
    WORKTREE_SCRIPT=".claude/scripts/sprint/sprint-work-preflight.sh"  # canonical path (not found)
fi

# Detect what's available
CONTAINER_AVAILABLE="false"
WORKTREE_AVAILABLE="false"
INFRASTRUCTURE_TYPE="none"

if [ -f "$CONTAINER_SCRIPT" ]; then
    CONTAINER_AVAILABLE="true"
fi

if [ -f "$WORKTREE_SCRIPT" ]; then
    WORKTREE_AVAILABLE="true"
fi

# Determine infrastructure type
if [ "$CONTAINER_AVAILABLE" = "true" ] && [ "$WORKTREE_AVAILABLE" = "true" ]; then
    INFRASTRUCTURE_TYPE="full"
elif [ "$CONTAINER_AVAILABLE" = "true" ]; then
    INFRASTRUCTURE_TYPE="container-only"
elif [ "$WORKTREE_AVAILABLE" = "true" ]; then
    INFRASTRUCTURE_TYPE="worktree-only"
else
    INFRASTRUCTURE_TYPE="none"
fi

# Determine recommended execution mode
RECOMMENDED_MODE="direct"
if [ "$INFRASTRUCTURE_TYPE" = "full" ] || [ "$INFRASTRUCTURE_TYPE" = "container-only" ]; then
    # Check if Docker is available
    if command -v docker &> /dev/null && docker info &> /dev/null 2>&1; then
        RECOMMENDED_MODE="container"
    elif [ "$WORKTREE_AVAILABLE" = "true" ]; then
        RECOMMENDED_MODE="worktree"
    else
        RECOMMENDED_MODE="direct"
    fi
elif [ "$INFRASTRUCTURE_TYPE" = "worktree-only" ]; then
    RECOMMENDED_MODE="worktree"
else
    RECOMMENDED_MODE="direct"
fi

# Output JSON
cat <<EOF
{
  "container_available": $CONTAINER_AVAILABLE,
  "worktree_available": $WORKTREE_AVAILABLE,
  "infrastructure_type": "$INFRASTRUCTURE_TYPE",
  "recommended_mode": "$RECOMMENDED_MODE",
  "container_script": "$CONTAINER_SCRIPT",
  "worktree_script": "$WORKTREE_SCRIPT"
}
EOF
