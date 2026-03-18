#!/bin/bash
set -euo pipefail
# detect-execution-mode.sh
# Determines whether an issue should be worked on via worktree or container
#
# Usage: ./scripts/detect-execution-mode.sh <issue_number>
#
# Output (JSON):
#   {
#     "issue": 123,
#     "mode": "container|worktree|n8n",
#     "reason": "explanation",
#     "labels": ["label1", "label2"]
#   }
#
# Detection Priority:
#   1. Explicit label: execution:container, execution:worktree, or execution:n8n
#   2. Issue body contains: ## Execution Mode: container|worktree|n8n
#   3. Project-level config (.claude-agents.config.yml)
#   4. User-level config (~/.claude-agents/config.json) - DEPRECATED
#   5. Fallback: container (default since #531), worktree if Docker unavailable

set -e

# Get script directory and source config utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/lib/config.sh" ]; then
    source "${SCRIPT_DIR}/lib/config.sh"
fi

ISSUE_NUMBER="$1"

if [ -z "$ISSUE_NUMBER" ]; then
    echo '{"error": "Usage: detect-execution-mode.sh <issue_number>"}' >&2
    exit 1
fi

# Get issue data
ISSUE_DATA=$(gh issue view "$ISSUE_NUMBER" --json labels,body 2>/dev/null)

if [ -z "$ISSUE_DATA" ] || [ "$ISSUE_DATA" = "null" ]; then
    echo '{"error": "Issue not found", "issue": '"$ISSUE_NUMBER"'}' >&2
    exit 1
fi

# Extract labels
LABELS=$(echo "$ISSUE_DATA" | jq -r '[.labels[].name] | join(",")')
BODY=$(echo "$ISSUE_DATA" | jq -r '.body // ""')

# Check for explicit execution:container label
if echo "$LABELS" | grep -q "execution:container"; then
    cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "container",
  "reason": "Label 'execution:container' present",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
    exit 0
fi

# Check for explicit execution:worktree label
if echo "$LABELS" | grep -q "execution:worktree"; then
    cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "worktree",
  "reason": "Label 'execution:worktree' present",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
    exit 0
fi

# Check for explicit execution:n8n label
if echo "$LABELS" | grep -q "execution:n8n"; then
    cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "n8n",
  "reason": "Label 'execution:n8n' present",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
    exit 0
fi

# Check issue body for execution mode directive
if echo "$BODY" | grep -qi "## Execution Mode:.*container"; then
    cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "container",
  "reason": "Issue body contains '## Execution Mode: container'",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
    exit 0
fi

if echo "$BODY" | grep -qi "## Execution Mode:.*worktree"; then
    cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "worktree",
  "reason": "Issue body contains '## Execution Mode: worktree'",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
    exit 0
fi

if echo "$BODY" | grep -qi "## Execution Mode:.*n8n"; then
    cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "n8n",
  "reason": "Issue body contains '## Execution Mode: n8n'",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
    exit 0
fi

# Check for repo-profile config preference (config/repo-profile.yaml)
REPO_PROFILE_CONFIG="config/repo-profile.yaml"
if [ -f "$REPO_PROFILE_CONFIG" ] && command -v yq &> /dev/null; then
    # Get execution mode from repo-profile.yaml
    EXEC_MODE=$(yq eval '.execution_mode.mode // ""' "$REPO_PROFILE_CONFIG" 2>/dev/null)

    if [ -n "$EXEC_MODE" ] && [ "$EXEC_MODE" != "null" ]; then
        case "$EXEC_MODE" in
            local)
                # Get local execution method
                LOCAL_METHOD=$(yq eval '.execution_mode.local.method // "worktree"' "$REPO_PROFILE_CONFIG" 2>/dev/null)
                if [ "$LOCAL_METHOD" = "docker" ]; then
                    DEFAULT_MODE="docker"
                    REASON="Repo profile (local mode: docker)"
                else
                    DEFAULT_MODE="worktree"
                    REASON="Repo profile (local mode: worktree)"
                fi
                ;;
            hosted)
                # Check if hosted is configured
                HOSTED_CONFIGURED=$(yq eval '.execution_mode.hosted.configured // false' "$REPO_PROFILE_CONFIG" 2>/dev/null)
                if [ "$HOSTED_CONFIGURED" = "true" ]; then
                    DEFAULT_MODE="container"
                    REASON="Repo profile (hosted mode - Proxmox containers)"
                else
                    # Hosted mode selected but not configured - fall back to local
                    DEFAULT_MODE="worktree"
                    REASON="Repo profile (hosted not configured - fallback to worktree)"
                fi
                ;;
            hybrid)
                # Hybrid mode - check preference order
                PREFERENCE=$(yq eval '.execution_mode.hybrid.preference_order[0] // "local"' "$REPO_PROFILE_CONFIG" 2>/dev/null)
                HOSTED_CONFIGURED=$(yq eval '.execution_mode.hosted.configured // false' "$REPO_PROFILE_CONFIG" 2>/dev/null)

                if [ "$PREFERENCE" = "hosted" ] && [ "$HOSTED_CONFIGURED" = "true" ]; then
                    DEFAULT_MODE="container"
                    REASON="Repo profile (hybrid mode - prefer hosted)"
                else
                    # Fall back to local
                    LOCAL_METHOD=$(yq eval '.execution_mode.local.method // "worktree"' "$REPO_PROFILE_CONFIG" 2>/dev/null)
                    if [ "$LOCAL_METHOD" = "docker" ]; then
                        DEFAULT_MODE="docker"
                        REASON="Repo profile (hybrid mode - local docker)"
                    else
                        DEFAULT_MODE="worktree"
                        REASON="Repo profile (hybrid mode - local worktree)"
                    fi
                fi
                ;;
            *)
                # Unknown mode - skip to next check
                DEFAULT_MODE=""
                ;;
        esac

        # Return if we found a valid mode
        if [ -n "$DEFAULT_MODE" ]; then
            cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "$DEFAULT_MODE",
  "reason": "$REASON",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
            exit 0
        fi
    fi
fi

# Check for project-level config preference (.claude-agents.config.yml)
PROJECT_CONFIG=".claude-agents.config.yml"
if [ -f "$PROJECT_CONFIG" ]; then
    # Try to get default mode using config library function
    if type get_execution_mode_default &>/dev/null; then
        DEFAULT_MODE=$(get_execution_mode_default)
    elif command -v yq &> /dev/null; then
        # Fallback to direct yq if function not available
        DEFAULT_MODE=$(yq eval '.execution_mode.default // "worktree"' "$PROJECT_CONFIG" 2>/dev/null)
    else
        DEFAULT_MODE="worktree"
    fi

    # Handle hybrid mode - resolve to actual mode
    if [ "$DEFAULT_MODE" = "hybrid" ]; then
        if type get_hybrid_mode &>/dev/null; then
            DEFAULT_MODE=$(get_hybrid_mode)
            REASON="Project config (hybrid auto-detected: $DEFAULT_MODE)"
        else
            # Simple fallback for hybrid without config library
            if command -v docker &> /dev/null && docker info &> /dev/null 2>&1; then
                DEFAULT_MODE="docker"
                REASON="Project config (hybrid -> docker available)"
            else
                DEFAULT_MODE="worktree"
                REASON="Project config (hybrid -> worktree fallback)"
            fi
        fi
    else
        REASON="Project config (.claude-agents.config.yml)"
    fi

    # Return the configured mode if it's not worktree (to distinguish from default)
    if [ "$DEFAULT_MODE" != "worktree" ]; then
        cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "$DEFAULT_MODE",
  "reason": "$REASON",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
        exit 0
    fi
fi

# Check for user-level config preference (DEPRECATED - for backward compatibility)
USER_CONFIG="${HOME}/.claude-agents/config.json"
if [ -f "$USER_CONFIG" ]; then
    DEPRECATED_MODE=$(jq -r '.default_execution_mode // ""' "$USER_CONFIG" 2>/dev/null)
    if [ -n "$DEPRECATED_MODE" ] && [ "$DEPRECATED_MODE" != "null" ]; then
        # Map old values to new values
        case "$DEPRECATED_MODE" in
            container)
                FINAL_MODE="docker"
                ;;
            *)
                FINAL_MODE="$DEPRECATED_MODE"
                ;;
        esac

        cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "$FINAL_MODE",
  "reason": "User config (DEPRECATED: migrate to .claude-agents.config.yml)",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
        exit 0
    fi
fi

# Default: container (since #531), fall back to worktree if Docker unavailable
if command -v docker &> /dev/null && docker info &> /dev/null 2>&1; then
    cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "container",
  "reason": "Default mode (container, Docker available)",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
else
    cat << EOF
{
  "issue": $ISSUE_NUMBER,
  "mode": "worktree",
  "reason": "Default mode (worktree fallback, Docker unavailable)",
  "labels": $(echo "$ISSUE_DATA" | jq '[.labels[].name]')
}
EOF
fi
