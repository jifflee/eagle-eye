#!/bin/bash
set -euo pipefail
# issue-dependencies.sh
# Parse and query issue dependencies from GitHub issues
# size-ok: dependency graph parser with multiple relationship types and parallel-candidate detection
#
# DESCRIPTION:
#   Parses issue bodies for dependency declarations and queries related issues.
#   Supports three relationship types:
#   - depends-on: This issue requires another issue to complete first
#   - related-to: This issue may overlap with another (informational)
#   - blocks: This issue must complete before another can start
#
# SYNTAX (in issue body):
#   Depends on: #15, #16
#   Related to: #21
#   Blocks: #30, #31
#
# USAGE:
#   ./scripts/issue-dependencies.sh ISSUE_NUMBER                  # Get dependencies for single issue
#   ./scripts/issue-dependencies.sh --active                      # Get all active issue dependencies
#   ./scripts/issue-dependencies.sh --graph [MILESTONE]           # Build dependency graph for milestone
#   ./scripts/issue-dependencies.sh --parallel-candidates [MILESTONE]  # Find issues that can run in parallel
#
# OUTPUT:
#   JSON with dependency information

set -e

ISSUE_NUMBER="${1:-}"
FLAG="${1:-}"
MILESTONE="${2:-}"

# Parse dependency declarations from issue body
# Returns JSON: {"depends_on": [15, 16], "related_to": [21], "blocks": [30]}
parse_dependencies() {
  local body="$1"

  # Extract issue numbers after each keyword
  # Case-insensitive matching, supports: #N, N, or comma-separated lists

  local depends_on=$(echo "$body" | grep -i "depends.on:" | head -1 | \
    grep -oE '#?[0-9]+' | sed 's/#//' | jq -R . | jq -s 'map(tonumber)')

  local related_to=$(echo "$body" | grep -i "related.to:" | head -1 | \
    grep -oE '#?[0-9]+' | sed 's/#//' | jq -R . | jq -s 'map(tonumber)')

  local blocks=$(echo "$body" | grep -i "blocks:" | head -1 | \
    grep -oE '#?[0-9]+' | sed 's/#//' | jq -R . | jq -s 'map(tonumber)')

  # Handle empty arrays
  [ -z "$depends_on" ] && depends_on="[]"
  [ -z "$related_to" ] && related_to="[]"
  [ -z "$blocks" ] && blocks="[]"

  jq -n \
    --argjson depends_on "$depends_on" \
    --argjson related_to "$related_to" \
    --argjson blocks "$blocks" \
    '{depends_on: $depends_on, related_to: $related_to, blocks: $blocks}'
}

# Get single issue dependencies
get_issue_dependencies() {
  local issue_num="$1"

  # Fetch issue details
  local issue_data=$(gh issue view "$issue_num" --json number,title,body,state,labels 2>/dev/null)
  if [ -z "$issue_data" ]; then
    echo "{\"error\": \"Issue #$issue_num not found\"}" >&2
    exit 1
  fi

  local body=$(echo "$issue_data" | jq -r '.body // ""')
  local deps=$(parse_dependencies "$body")

  # Enrich with issue status for each dependency
  local depends_on_enriched=$(echo "$deps" | jq -r '.depends_on[]' 2>/dev/null | while read dep_num; do
    if [ -n "$dep_num" ]; then
      local dep_state=$(gh issue view "$dep_num" --json state,title --jq '{number: '"$dep_num"', title: .title, state: .state}' 2>/dev/null)
      echo "$dep_state"
    fi
  done | jq -s '.' 2>/dev/null || echo "[]")

  local related_to_enriched=$(echo "$deps" | jq -r '.related_to[]' 2>/dev/null | while read rel_num; do
    if [ -n "$rel_num" ]; then
      local rel_state=$(gh issue view "$rel_num" --json state,title --jq '{number: '"$rel_num"', title: .title, state: .state}' 2>/dev/null)
      echo "$rel_state"
    fi
  done | jq -s '.' 2>/dev/null || echo "[]")

  local blocks_enriched=$(echo "$deps" | jq -r '.blocks[]' 2>/dev/null | while read blk_num; do
    if [ -n "$blk_num" ]; then
      local blk_state=$(gh issue view "$blk_num" --json state,title --jq '{number: '"$blk_num"', title: .title, state: .state}' 2>/dev/null)
      echo "$blk_state"
    fi
  done | jq -s '.' 2>/dev/null || echo "[]")

  # Check for blocking issues (issues that depend on this one)
  local blocked_by=$(get_issues_blocked_by "$issue_num")

  echo "$issue_data" | jq \
    --argjson depends_on "$depends_on_enriched" \
    --argjson related_to "$related_to_enriched" \
    --argjson blocks "$blocks_enriched" \
    --argjson blocked_by "$blocked_by" \
    '{
      issue: {number: .number, title: .title, state: .state},
      dependencies: {
        depends_on: $depends_on,
        related_to: $related_to,
        blocks: $blocks,
        blocked_by: $blocked_by
      },
      warnings: []
    } |
    # Add warnings for open dependencies
    if (.dependencies.depends_on | map(select(.state == "OPEN")) | length) > 0 then
      .warnings += ["Has open dependencies that should complete first"]
    else . end |
    if (.dependencies.blocked_by | length) > 0 then
      .warnings += ["Other issues are waiting on this one"]
    else . end'
}

# Get issues that are blocked by (depend on) a given issue
get_issues_blocked_by() {
  local issue_num="$1"

  # Search for issues that mention this issue in their dependencies
  # Note: This is an approximation - searches issue bodies
  gh issue list --state open --limit 100 --json number,title,body 2>/dev/null | jq --arg num "$issue_num" '
    [.[] | select(.body != null) |
      select(.body | test("(?i)depends.on:.*#?" + $num + "(?:[^0-9]|$)")) |
      {number: .number, title: .title, state: "OPEN"}
    ]'
}

# Get all dependencies for active (in-progress/checked-out) issues
get_active_dependencies() {
  # Get all in-progress or checked-out issues
  local active_issues=$(gh issue list --label "in-progress" --state open --json number 2>/dev/null | jq -r '.[].number')
  local checked_out=$(gh issue list --label "wip:checked-out" --state open --json number 2>/dev/null | jq -r '.[].number')

  # Combine and dedupe
  local all_active=$(echo -e "$active_issues\n$checked_out" | sort -u | grep -v '^$')

  if [ -z "$all_active" ]; then
    echo '{"active_issues": [], "dependency_conflicts": [], "file_overlaps": []}'
    exit 0
  fi

  # Build dependency info for each active issue
  local results=()
  for issue in $all_active; do
    local deps=$(get_issue_dependencies "$issue" 2>/dev/null)
    if [ -n "$deps" ]; then
      results+=("$deps")
    fi
  done

  if [ ${#results[@]} -eq 0 ]; then
    echo '{"active_issues": [], "dependency_conflicts": [], "file_overlaps": []}'
    exit 0
  fi

  # Combine results
  printf '%s\n' "${results[@]}" | jq -s '{
    active_issues: .,
    dependency_conflicts: [
      .[] | select(.dependencies.depends_on | map(select(.state == "OPEN")) | length > 0) |
      {issue: .issue.number, blocked_by: [.dependencies.depends_on[] | select(.state == "OPEN") | .number]}
    ],
    related_pairs: (
      [.[] | .issue.number as $num | .dependencies.related_to[] | {a: $num, b: .number}] |
      unique_by([.a, .b] | sort | join("-"))
    )
  }'
}

# Build dependency graph for a milestone
build_dependency_graph() {
  local milestone="${1:-}"

  # Get milestone if not specified
  if [ -z "$milestone" ]; then
    milestone=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty')
  fi

  if [ -z "$milestone" ]; then
    echo '{"error": "No open milestones found"}' >&2
    exit 1
  fi

  # Get all issues in milestone
  local issues=$(gh issue list --milestone "$milestone" --state all --json number,title,body,state 2>/dev/null)

  if [ -z "$issues" ] || [ "$issues" = "[]" ]; then
    echo '{"milestone": "'"$milestone"'", "issues": [], "edges": [], "merge_order": []}'
    exit 0
  fi

  # Parse dependencies for each issue
  local nodes=$(echo "$issues" | jq '[.[] | {number: .number, title: .title, state: .state}]')

  # Build edges (dependency relationships)
  # Use bash to parse dependencies since jq regex is limited
  local edges="[]"
  while IFS= read -r issue_json; do
    local issue_num=$(echo "$issue_json" | jq -r '.number')
    local body=$(echo "$issue_json" | jq -r '.body // ""')

    # Parse depends_on using grep
    local depends_on=$(echo "$body" | grep -i "depends.on:" | head -1 | \
      grep -oE '#?[0-9]+' | sed 's/#//' | jq -R . 2>/dev/null | jq -s 'map(tonumber)' 2>/dev/null || echo "[]")
    [ -z "$depends_on" ] && depends_on="[]"

    # Parse blocks using grep
    local blocks=$(echo "$body" | grep -i "blocks:" | head -1 | \
      grep -oE '#?[0-9]+' | sed 's/#//' | jq -R . 2>/dev/null | jq -s 'map(tonumber)' 2>/dev/null || echo "[]")
    [ -z "$blocks" ] && blocks="[]"

    # Parse related_to using grep
    local related=$(echo "$body" | grep -i "related.to:" | head -1 | \
      grep -oE '#?[0-9]+' | sed 's/#//' | jq -R . 2>/dev/null | jq -s 'map(tonumber)' 2>/dev/null || echo "[]")
    [ -z "$related" ] && related="[]"

    # Add depends_on edges (this issue depends on others)
    edges=$(echo "$edges" | jq --argjson from "$issue_num" --argjson deps "$depends_on" \
      '. + [$deps[] | {from: $from, to: ., type: "depends_on"}]')

    # Add blocks edges (other issues depend on this one)
    edges=$(echo "$edges" | jq --argjson from "$issue_num" --argjson blks "$blocks" \
      '. + [$blks[] | {from: ., to: $from, type: "depends_on"}]')

    # Add related edges
    edges=$(echo "$edges" | jq --argjson from "$issue_num" --argjson rels "$related" \
      '. + [$rels[] | {from: $from, to: ., type: "related"}]')
  done < <(echo "$issues" | jq -c '.[]')

  # Calculate merge order (topological sort based on dependencies)
  # Issues with no dependencies come first, then issues whose deps are satisfied
  local merge_order=$(echo "$issues" | jq --argjson edges "$edges" '
    # Get all depends_on edges
    ($edges | [.[] | select(.type == "depends_on")]) as $deps |

    # Calculate in-degree for each issue
    [.[] | .number] as $all_issues |

    # Issues with no incoming depends_on edges come first
    [$all_issues[] | . as $n |
      if ($deps | map(select(.from == $n)) | length) == 0 then $n else empty end
    ] as $no_deps |

    # Remaining issues sorted by number of dependencies
    [$all_issues[] | . as $n |
      if ($deps | map(select(.from == $n)) | length) > 0 then
        {number: $n, dep_count: ($deps | map(select(.from == $n)) | length)}
      else empty end
    ] | sort_by(.dep_count) | map(.number) as $with_deps |

    $no_deps + $with_deps')

  jq -n \
    --arg milestone "$milestone" \
    --argjson nodes "$nodes" \
    --argjson edges "$edges" \
    --argjson merge_order "$merge_order" \
    '{
      milestone: $milestone,
      issues: $nodes,
      edges: $edges,
      merge_order: $merge_order,
      summary: {
        total_issues: ($nodes | length),
        with_dependencies: ([$nodes[].number] | map(. as $n | if ($edges | map(select(.from == $n and .type == "depends_on")) | length) > 0 then 1 else 0 end) | add // 0),
        dependency_edges: ($edges | map(select(.type == "depends_on")) | length),
        related_edges: ($edges | map(select(.type == "related")) | length)
      }
    }'
}

# Find issues that can be worked on in parallel (no interdependencies)
find_parallel_candidates() {
  local milestone="${1:-}"

  # Get milestone if not specified
  if [ -z "$milestone" ]; then
    milestone=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty')
  fi

  if [ -z "$milestone" ]; then
    echo '{"error": "No open milestones found"}' >&2
    exit 1
  fi

  # Get backlog issues only (not in-progress, not blocked)
  local backlog_issues=$(gh issue list --milestone "$milestone" --label "backlog" --state open --json number,title,body,labels 2>/dev/null)

  if [ -z "$backlog_issues" ] || [ "$backlog_issues" = "[]" ]; then
    echo '{"milestone": "'"$milestone"'", "parallel_groups": [], "independent_issues": []}'
    exit 0
  fi

  # Build dependency map from backlog issues
  local issue_deps="{}"
  local all_deps="[]"

  while IFS= read -r issue_json; do
    local issue_num=$(echo "$issue_json" | jq -r '.number')
    local body=$(echo "$issue_json" | jq -r '.body // ""')

    # Parse depends_on
    local depends_on=$(echo "$body" | grep -i "depends.on:" | head -1 | \
      grep -oE '#?[0-9]+' | sed 's/#//' | jq -R . 2>/dev/null | jq -s 'map(tonumber)' 2>/dev/null || echo "[]")
    [ -z "$depends_on" ] && depends_on="[]"

    # Store issue -> dependencies mapping
    issue_deps=$(echo "$issue_deps" | jq --arg num "$issue_num" --argjson deps "$depends_on" \
      '. + {($num): $deps}')

    # Collect all dependency edges
    all_deps=$(echo "$all_deps" | jq --argjson from "$issue_num" --argjson deps "$depends_on" \
      '. + [$deps[] | {from: $from, to: .}]')
  done < <(echo "$backlog_issues" | jq -c '.[]')

  # Find issues with no dependencies on other backlog issues
  # (dependencies on closed issues are satisfied)
  local backlog_nums=$(echo "$backlog_issues" | jq '[.[].number]')

  # Group issues by independence
  # Independent = no deps on other backlog issues, and not depended on by other backlog issues
  local result=$(echo "$backlog_issues" | jq --argjson deps "$issue_deps" --argjson backlog "$backlog_nums" --argjson edges "$all_deps" '
    # Get issues that have no backlog dependencies
    [.[] | .number as $num |
      ($deps[($num | tostring)] // []) as $my_deps |
      # Check if any of my deps are in backlog
      ($my_deps | map(select(. as $d | $backlog | any(. == $d))) | length) as $backlog_deps |
      # Check if any backlog issue depends on me
      ([$edges[] | select(.to == $num and (.from as $f | $backlog | any(. == $f)))] | length) as $depended_on |
      select($backlog_deps == 0) |
      {
        number: .number,
        title: .title,
        labels: [.labels[].name],
        has_dependents: ($depended_on > 0),
        priority: (
          if ([.labels[].name] | any(. == "P0")) then 0
          elif ([.labels[].name] | any(. == "P1")) then 1
          elif ([.labels[].name] | any(. == "P2")) then 2
          elif ([.labels[].name] | any(. == "P3")) then 3
          else 2 end
        )
      }
    ] |
    sort_by(.priority, .number) |
    # Split into independent (no dependents) and foundational (has dependents)
    {
      independent: [.[] | select(.has_dependents == false)],
      foundational: [.[] | select(.has_dependents == true)]
    }
  ')

  # Build final output
  local independent=$(echo "$result" | jq '.independent')
  local foundational=$(echo "$result" | jq '.foundational')

  jq -n \
    --arg milestone "$milestone" \
    --argjson independent "$independent" \
    --argjson foundational "$foundational" \
    --argjson total_backlog "$(echo "$backlog_issues" | jq 'length')" \
    '{
      milestone: $milestone,
      summary: {
        total_backlog: $total_backlog,
        parallel_ready: ($independent | length),
        foundational: ($foundational | length)
      },
      parallel_candidates: $independent,
      foundational_first: $foundational,
      recommendation: (
        if ($foundational | length) > 0 then
          "Work on foundational issues first: " + ([$foundational[].number] | map("#" + tostring) | join(", "))
        elif ($independent | length) > 1 then
          "Can spawn " + ($independent | length | tostring) + " parallel worktrees"
        elif ($independent | length) == 1 then
          "Single issue ready: #" + ($independent[0].number | tostring)
        else
          "No issues ready for parallel execution"
        end
      )
    }'
}

# Main routing
case "$FLAG" in
  --active)
    get_active_dependencies
    ;;
  --graph)
    build_dependency_graph "$MILESTONE"
    ;;
  --parallel-candidates)
    find_parallel_candidates "$MILESTONE"
    ;;
  --help|-h)
    echo "Usage: $0 ISSUE_NUMBER                  # Get dependencies for single issue"
    echo "       $0 --active                      # Get all active issue dependencies"
    echo "       $0 --graph [MILESTONE]           # Build dependency graph for milestone"
    echo "       $0 --parallel-candidates [MILESTONE]  # Find issues that can run in parallel"
    exit 0
    ;;
  *)
    if [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
      get_issue_dependencies "$ISSUE_NUMBER"
    else
      echo "{\"error\": \"Invalid issue number: $ISSUE_NUMBER\"}" >&2
      exit 1
    fi
    ;;
esac
