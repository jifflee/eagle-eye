#!/bin/bash
set -euo pipefail
# analyze-epic-work-mode.sh
# Analyze epic children to recommend parallel vs sequential work execution
# size-ok: dependency analysis and file overlap detection for epic children
#
# DESCRIPTION:
#   Analyzes child issues of an epic to determine if they should be worked
#   in parallel (multiple containers) or sequentially based on:
#   - Dependency relationships between children
#   - File overlap analysis (shared files = merge conflicts)
#   - Data dependencies (API changes, schema migrations, etc.)
#
# USAGE:
#   ./scripts/analyze-epic-work-mode.sh EPIC_NUMBER              # Analyze epic children
#   ./scripts/analyze-epic-work-mode.sh EPIC_NUMBER --json       # JSON output
#   ./scripts/analyze-epic-work-mode.sh EPIC_NUMBER --verbose    # Detailed analysis
#
# OUTPUT:
#   JSON with recommendation (parallel/sequential) and rationale

set -e

EPIC_NUMBER="${1:-}"
OUTPUT_FORMAT="human"
VERBOSE="false"

# Parse flags
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      OUTPUT_FORMAT="json"
      shift
      ;;
    --verbose)
      VERBOSE="true"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$EPIC_NUMBER" ]; then
  echo '{"error": "Epic number required"}' >&2
  exit 1
fi

# Verify epic exists
EPIC_STATE=$(gh issue view "$EPIC_NUMBER" --json state,labels --jq '.state' 2>/dev/null || echo "NOT_FOUND")
if [ "$EPIC_STATE" = "NOT_FOUND" ]; then
  echo "{\"error\": \"Epic #$EPIC_NUMBER not found\"}" >&2
  exit 1
fi

# Verify it's actually an epic
IS_EPIC=$(gh issue view "$EPIC_NUMBER" --json labels --jq '.labels[].name' 2>/dev/null | grep -q "^epic$" && echo "true" || echo "false")
if [ "$IS_EPIC" = "false" ]; then
  echo "{\"error\": \"Issue #$EPIC_NUMBER is not labeled as an epic\"}" >&2
  exit 1
fi

# Get open children
CHILDREN=$(gh issue list --label "parent:$EPIC_NUMBER" --state open --json number,title,body,labels 2>/dev/null)
CHILDREN_COUNT=$(echo "$CHILDREN" | jq 'length')

if [ "$CHILDREN_COUNT" -eq 0 ]; then
  echo "{\"recommendation\": \"none\", \"reason\": \"no_open_children\", \"children_count\": 0}" >&2
  exit 0
fi

# If only one child, no parallel/sequential decision needed
if [ "$CHILDREN_COUNT" -eq 1 ]; then
  CHILD_NUM=$(echo "$CHILDREN" | jq -r '.[0].number')
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    echo "{\"recommendation\": \"single\", \"reason\": \"only_one_child\", \"children_count\": 1, \"child\": $CHILD_NUM}"
  else
    echo "Only one open child issue (#$CHILD_NUM). No parallel/sequential decision needed."
  fi
  exit 0
fi

# Analyze dependencies between children
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_SCRIPT="$SCRIPT_DIR/issue-dependencies.sh"

if [ ! -x "$DEPS_SCRIPT" ]; then
  echo "{\"error\": \"Dependency analysis script not found: $DEPS_SCRIPT\"}" >&2
  exit 1
fi

# Build dependency graph for children
CHILD_NUMBERS=$(echo "$CHILDREN" | jq -r '.[].number' | tr '\n' ' ')
DEPENDENCY_EDGES="[]"
RELATED_EDGES="[]"

for child_num in $CHILD_NUMBERS; do
  # Get dependencies for this child
  child_deps=$("$DEPS_SCRIPT" "$child_num" 2>/dev/null || echo '{"dependencies": {"depends_on": [], "related_to": [], "blocks": []}}')

  # Extract depends_on relationships (within children only)
  depends_on=$(echo "$child_deps" | jq -r '.dependencies.depends_on[]?.number // empty' 2>/dev/null || echo "")
  for dep in $depends_on; do
    # Check if dependency is in our children list
    if echo "$CHILD_NUMBERS" | grep -qw "$dep"; then
      DEPENDENCY_EDGES=$(echo "$DEPENDENCY_EDGES" | jq --argjson from "$child_num" --argjson to "$dep" \
        '. + [{from: $from, to: $to, type: "depends_on"}]')
    fi
  done

  # Extract related_to relationships (file overlap hints)
  related_to=$(echo "$child_deps" | jq -r '.dependencies.related_to[]?.number // empty' 2>/dev/null || echo "")
  for rel in $related_to; do
    if echo "$CHILD_NUMBERS" | grep -qw "$rel"; then
      RELATED_EDGES=$(echo "$RELATED_EDGES" | jq --argjson from "$child_num" --argjson to "$rel" \
        '. + [{from: $from, to: $to, type: "related"}]')
    fi
  done
done

# Count dependency relationships
DEPENDENCY_COUNT=$(echo "$DEPENDENCY_EDGES" | jq 'length')
RELATED_COUNT=$(echo "$RELATED_EDGES" | jq 'length')

# Analyze file overlaps (estimate based on issue context)
# Look for common keywords in issue bodies/titles that suggest shared components
FILE_OVERLAP_SCORE=0
OVERLAP_REASONS=()

# Extract issue titles and bodies for keyword analysis
for i in $(seq 0 $((CHILDREN_COUNT - 1))); do
  for j in $(seq $((i + 1)) $((CHILDREN_COUNT - 1))); do
    if [ $j -lt $CHILDREN_COUNT ]; then
      title_i=$(echo "$CHILDREN" | jq -r ".[$i].title // \"\"" | tr '[:upper:]' '[:lower:]')
      title_j=$(echo "$CHILDREN" | jq -r ".[$j].title // \"\"" | tr '[:upper:]' '[:lower:]')
      body_i=$(echo "$CHILDREN" | jq -r ".[$i].body // \"\"" | tr '[:upper:]' '[:lower:]')
      body_j=$(echo "$CHILDREN" | jq -r ".[$j].body // \"\"" | tr '[:upper:]' '[:lower:]')

      num_i=$(echo "$CHILDREN" | jq -r ".[$i].number")
      num_j=$(echo "$CHILDREN" | jq -r ".[$j].number")

      # Check for common file/component indicators
      if echo "$title_i $body_i" | grep -qE "(api|endpoint|route)" && \
         echo "$title_j $body_j" | grep -qE "(api|endpoint|route)"; then
        FILE_OVERLAP_SCORE=$((FILE_OVERLAP_SCORE + 2))
        OVERLAP_REASONS+=("API/endpoint changes in #$num_i and #$num_j may conflict")
      fi

      if echo "$title_i $body_i" | grep -qE "(schema|migration|database|model)" && \
         echo "$title_j $body_j" | grep -qE "(schema|migration|database|model)"; then
        FILE_OVERLAP_SCORE=$((FILE_OVERLAP_SCORE + 3))
        OVERLAP_REASONS+=("Database schema changes in #$num_i and #$num_j will conflict")
      fi

      if echo "$title_i $body_i" | grep -qE "(config|settings)" && \
         echo "$title_j $body_j" | grep -qE "(config|settings)"; then
        FILE_OVERLAP_SCORE=$((FILE_OVERLAP_SCORE + 1))
        OVERLAP_REASONS+=("Config changes in #$num_i and #$num_j may overlap")
      fi

      # Check for same file mentions in body (exact file paths)
      shared_files=$(comm -12 \
        <(echo "$body_i" | grep -oE '\S+\.(sh|js|py|md|json|yaml|yml)' | sort -u) \
        <(echo "$body_j" | grep -oE '\S+\.(sh|js|py|md|json|yaml|yml)' | sort -u) 2>/dev/null | wc -l)
      if [ "$shared_files" -gt 0 ]; then
        FILE_OVERLAP_SCORE=$((FILE_OVERLAP_SCORE + shared_files * 2))
        OVERLAP_REASONS+=("Shared file references between #$num_i and #$num_j ($shared_files files)")
      fi
    fi
  done
done

# Determine recommendation
RECOMMENDATION="parallel"
CONFIDENCE="high"
REASONS=()

# Sequential is recommended if:
# 1. Any dependency edges exist (some children depend on others)
if [ "$DEPENDENCY_COUNT" -gt 0 ]; then
  RECOMMENDATION="sequential"
  REASONS+=("Dependency relationships exist between children ($DEPENDENCY_COUNT edges)")
  CONFIDENCE="high"
fi

# 2. High file overlap score (likely merge conflicts)
if [ "$FILE_OVERLAP_SCORE" -ge 4 ]; then
  RECOMMENDATION="sequential"
  REASONS+=("High file overlap detected (score: $FILE_OVERLAP_SCORE)")
  [ "$CONFIDENCE" = "medium" ] || CONFIDENCE="high"
elif [ "$FILE_OVERLAP_SCORE" -ge 2 ]; then
  if [ "$RECOMMENDATION" = "parallel" ]; then
    CONFIDENCE="medium"
  fi
  REASONS+=("Some file overlap detected (score: $FILE_OVERLAP_SCORE)")
fi

# 3. Many related edges (file overlap hints from issue authors)
if [ "$RELATED_COUNT" -ge 2 ]; then
  if [ "$RECOMMENDATION" = "parallel" ]; then
    RECOMMENDATION="sequential"
    CONFIDENCE="medium"
  fi
  REASONS+=("Multiple related-to relationships ($RELATED_COUNT pairs)")
fi

# Parallel is good when:
# - No dependencies, low file overlap, few related edges
if [ "$RECOMMENDATION" = "parallel" ]; then
  REASONS+=("No dependencies between children")
  REASONS+=("Low risk of merge conflicts")
  if [ "$RELATED_COUNT" -eq 0 ] && [ "$FILE_OVERLAP_SCORE" -eq 0 ]; then
    CONFIDENCE="high"
  fi
fi

# Build merge order for sequential mode (topological sort)
MERGE_ORDER="[]"
if [ "$RECOMMENDATION" = "sequential" ]; then
  # Simple topological sort: issues with no incoming edges first
  SORTED_CHILDREN=$(echo "$CHILDREN" | jq -r '.[].number')
  for child_num in $SORTED_CHILDREN; do
    has_incoming=$(echo "$DEPENDENCY_EDGES" | jq --argjson num "$child_num" \
      '[.[] | select(.from == $num)] | length')
    if [ "$has_incoming" -eq 0 ]; then
      MERGE_ORDER=$(echo "$MERGE_ORDER" | jq --argjson num "$child_num" '. + [$num]')
    fi
  done

  # Add remaining issues (those with dependencies) sorted by dependency count
  for child_num in $SORTED_CHILDREN; do
    already_added=$(echo "$MERGE_ORDER" | jq --argjson num "$child_num" 'any(. == $num)')
    if [ "$already_added" = "false" ]; then
      MERGE_ORDER=$(echo "$MERGE_ORDER" | jq --argjson num "$child_num" '. + [$num]')
    fi
  done
fi

# Format reasons array for JSON
REASONS_JSON=$(printf '%s\n' "${REASONS[@]}" | jq -R . | jq -s '.')
OVERLAP_REASONS_JSON=$(printf '%s\n' "${OVERLAP_REASONS[@]}" | jq -R . | jq -s '.')

# Build output
if [ "$OUTPUT_FORMAT" = "json" ]; then
  jq -n \
    --arg rec "$RECOMMENDATION" \
    --arg conf "$CONFIDENCE" \
    --argjson children "$CHILDREN_COUNT" \
    --argjson dep_count "$DEPENDENCY_COUNT" \
    --argjson related_count "$RELATED_COUNT" \
    --argjson overlap_score "$FILE_OVERLAP_SCORE" \
    --argjson reasons "$REASONS_JSON" \
    --argjson overlap_reasons "$OVERLAP_REASONS_JSON" \
    --argjson merge_order "$MERGE_ORDER" \
    --argjson dep_edges "$DEPENDENCY_EDGES" \
    --argjson related_edges "$RELATED_EDGES" \
    '{
      recommendation: $rec,
      confidence: $conf,
      children_count: $children,
      analysis: {
        dependency_edges: $dep_count,
        related_edges: $related_count,
        file_overlap_score: $overlap_score
      },
      reasons: $reasons,
      file_overlap_details: $overlap_reasons,
      merge_order: $merge_order,
      details: {
        dependency_edges: $dep_edges,
        related_edges: $related_edges
      }
    }'
else
  # Human-readable output
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  EPIC WORK MODE ANALYSIS: #$EPIC_NUMBER"
  echo "╠══════════════════════════════════════════════════════════════════╣"
  echo "║"
  echo "║  RECOMMENDATION: $RECOMMENDATION (confidence: $CONFIDENCE)"
  echo "║"
  echo "║  ANALYSIS SUMMARY:"
  echo "║    - Children count: $CHILDREN_COUNT"
  echo "║    - Dependency edges: $DEPENDENCY_COUNT"
  echo "║    - Related pairs: $RELATED_COUNT"
  echo "║    - File overlap score: $FILE_OVERLAP_SCORE"
  echo "║"
  echo "║  REASONING:"
  for reason in "${REASONS[@]}"; do
    echo "║    • $reason"
  done

  if [ ${#OVERLAP_REASONS[@]} -gt 0 ]; then
    echo "║"
    echo "║  FILE OVERLAP DETAILS:"
    for overlap in "${OVERLAP_REASONS[@]}"; do
      echo "║    • $overlap"
    done
  fi

  if [ "$RECOMMENDATION" = "sequential" ] && [ "$(echo "$MERGE_ORDER" | jq 'length')" -gt 0 ]; then
    echo "║"
    echo "║  RECOMMENDED MERGE ORDER:"
    order_nums=$(echo "$MERGE_ORDER" | jq -r '.[]' | tr '\n' ' ')
    for num in $order_nums; do
      title=$(echo "$CHILDREN" | jq -r ".[] | select(.number == $num) | .title")
      echo "║    1. #$num: $title"
    done
  fi

  if [ "$RECOMMENDATION" = "parallel" ]; then
    echo "║"
    echo "║  PARALLEL EXECUTION:"
    echo "║    Can spawn $CHILDREN_COUNT containers/worktrees simultaneously"
    echo "║    Merge in any order after completion"
  fi

  echo "║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
fi
