#!/bin/bash
set -euo pipefail
# claude-model-review-data.sh
# Gathers agent configurations for model review
#
# Usage:
#   ./scripts/audit-model-configs-data.sh              # Analyze all agents
#   ./scripts/audit-model-configs-data.sh --summary    # Quick summary only
#
# Outputs structured JSON with agent model configurations and recommendations

set -e

SUMMARY_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --summary)
      SUMMARY_ONLY=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Create temp directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Agent directories to search
AGENT_DIRS=(
  "core/agents"
  "packs/*/agents"
  "domains/*/agents"
  ".claude/agents"
  ".claude-sync/agents"
)

# Find all agent files
find_agents() {
  for dir in "${AGENT_DIRS[@]}"; do
    find $dir -name "*.md" 2>/dev/null || true
  done
}

# Extract model from frontmatter
get_model() {
  local file="$1"
  # Look for model: in frontmatter
  grep -E '^model:' "$file" 2>/dev/null | head -1 | sed 's/model:\s*//' | tr -d ' ' || echo "unspecified"
}

# Determine appropriate model for an agent task
# Returns: haiku | sonnet | opus
classify_task() {
  local file="$1"
  local filename=$(basename "$file" .md)
  local content=$(cat "$file")

  # Intentional sonnet usage - security agents
  # These require deep security analysis and thoroughness
  if echo "$filename" | grep -qiE '(security-iam|pr-security)'; then
    echo "sonnet"
    return
  fi

  # Intentional sonnet usage - financial agents
  # These require precision in financial calculations and critical data handling
  if echo "$filename" | grep -qiE '(financial-security-auditor|options-strategy-analyst)'; then
    echo "sonnet"
    return
  fi

  # Explicitly haiku agents by name - performance and review agents
  # performance-engineering: haiku by default (sonnet only for deep/critical analysis)
  # These agents do reviews and analysis that haiku handles well
  if echo "$filename" | grep -qiE '^(performance-engineering|code-reviewer|pr-code-reviewer|guardrails-policy)$'; then
    echo "haiku"
    return
  fi

  # Haiku-appropriate patterns
  if echo "$content" | grep -qiE '(documentation|issue|pr|label|scaffold|config|simple|basic|straightforward)'; then
    echo "haiku"
    return
  fi

  # Sonnet-appropriate patterns (for other agents not caught above)
  if echo "$content" | grep -qiE '(deep analysis|complex algorithm|critical analysis)'; then
    echo "sonnet"
    return
  fi

  # Opus-appropriate patterns
  if echo "$content" | grep -qiE '(critical security|architecture decision|complex design)'; then
    echo "opus"
    return
  fi

  # Default to haiku
  echo "haiku"
}

# Initialize counters
total=0
haiku_count=0
sonnet_count=0
opus_count=0
unspecified_count=0
misconfigurations=0

# Results array
results="["
first=true

# Analyze each agent
while IFS= read -r file; do
  [ -z "$file" ] && continue
  [ ! -f "$file" ] && continue

  filename=$(basename "$file" .md)
  current_model=$(get_model "$file")
  recommended_model=$(classify_task "$file")

  # Count models
  total=$((total + 1))
  case "$current_model" in
    haiku) haiku_count=$((haiku_count + 1)) ;;
    sonnet) sonnet_count=$((sonnet_count + 1)) ;;
    opus) opus_count=$((opus_count + 1)) ;;
    *) unspecified_count=$((unspecified_count + 1)) ;;
  esac

  # Check for misconfiguration
  is_misconfigured=false
  reason=""

  if [ "$current_model" = "unspecified" ]; then
    is_misconfigured=true
    reason="no model specified"
    misconfigurations=$((misconfigurations + 1))
  elif [ "$current_model" != "$recommended_model" ]; then
    # Only flag if using more expensive model than needed
    if [ "$current_model" = "opus" ] && [ "$recommended_model" = "haiku" ]; then
      is_misconfigured=true
      reason="opus used for haiku-appropriate task"
      misconfigurations=$((misconfigurations + 1))
    elif [ "$current_model" = "sonnet" ] && [ "$recommended_model" = "haiku" ]; then
      is_misconfigured=true
      reason="sonnet used for haiku-appropriate task"
      misconfigurations=$((misconfigurations + 1))
    elif [ "$current_model" = "opus" ] && [ "$recommended_model" = "sonnet" ]; then
      is_misconfigured=true
      reason="opus used for sonnet-appropriate task"
      misconfigurations=$((misconfigurations + 1))
    fi
  fi

  if [ "$SUMMARY_ONLY" = false ]; then
    [ "$first" = true ] && first=false || results+=","
    results+="{\"name\":\"$filename\",\"path\":\"$file\",\"current_model\":\"$current_model\",\"recommended_model\":\"$recommended_model\",\"misconfigured\":$is_misconfigured,\"reason\":\"$reason\"}"
  fi

done < <(find_agents)

results+="]"

# Calculate percentages
haiku_pct=0
sonnet_pct=0
opus_pct=0

if [ "$total" -gt 0 ]; then
  haiku_pct=$((haiku_count * 100 / total))
  sonnet_pct=$((sonnet_count * 100 / total))
  opus_pct=$((opus_count * 100 / total))
fi

# Estimate cost impact
# Relative costs: haiku=1, sonnet=3, opus=15
base_cost=$((haiku_count * 1 + sonnet_count * 3 + opus_count * 15 + unspecified_count * 3))
optimal_cost=$((total * 1))  # If all were haiku
cost_impact="normal"
if [ "$base_cost" -gt $((optimal_cost * 3)) ]; then
  cost_impact="high"
elif [ "$base_cost" -gt $((optimal_cost * 2)) ]; then
  cost_impact="moderate"
fi

cat <<EOF
{
  "summary": {
    "total_agents": $total,
    "misconfigurations": $misconfigurations,
    "cost_impact": "$cost_impact"
  },
  "distribution": {
    "haiku": {"count": $haiku_count, "percent": $haiku_pct, "target": 90},
    "sonnet": {"count": $sonnet_count, "percent": $sonnet_pct, "target": 9},
    "opus": {"count": $opus_count, "percent": $opus_pct, "target": 1},
    "unspecified": {"count": $unspecified_count}
  },
  "agents": $results,
  "analyzed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
