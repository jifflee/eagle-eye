#!/usr/bin/env bash
# size-ok: permission graph builder parses all skill files and emits graph JSON; inline logic is intentional
# skill-permission-graph.sh
# Parses all skills in .claude/commands/ (or a provided commands dir) and builds a
# Neo4j-style permission graph: skills as nodes, capabilities as nodes, edges
# representing which skill is authorized for which capability.
#
# Usage:
#   ./scripts/graph/skill-permission-graph.sh [OPTIONS]
#
# Options:
#   --output FILE        Path to write JSON output (default: scripts/graph/skill-permission-graph-data.json)
#   --commands-dir DIR   Directory containing skill .md files (default: .claude/commands)
#   --help               Show this help
#
# Output:
#   JSON: { meta, nodes, edges } suitable for the bundled HTML viewer.
#   Nodes have type "skill" or "capability".
#   Edges connect skill → capability with relation "HAS_PERMISSION".
#   Escalation edges connect skill → skill with relation "INVOKES" where target tier > source tier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMANDS_DIR="${REPO_ROOT}/.claude/commands"
OUTPUT_FILE="${REPO_ROOT}/scripts/graph/skill-permission-graph-data.json"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --commands-dir)
      COMMANDS_DIR="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '/^# Usage:/,/^[^#]/p' "$0" | head -20
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed." >&2
  exit 1
fi

echo "Reading skills from: ${COMMANDS_DIR}" >&2

# ---------------------------------------------------------------------------
# Capability definitions
# Each capability has an id, label, category, and tier level.
# These are the "permission nodes" in the graph.
# ---------------------------------------------------------------------------
declare -A CAP_LABEL
declare -A CAP_TIER
declare -A CAP_CATEGORY

register_cap() {
  local id="$1" label="$2" tier="$3" category="$4"
  CAP_LABEL["$id"]="$label"
  CAP_TIER["$id"]="$tier"
  CAP_CATEGORY["$id"]="$category"
}

# T0 - Read-only capabilities
register_cap "file.read"        "File Read"          "T0" "filesystem"
register_cap "repo.read"        "Repo Read"          "T0" "github"
register_cap "issue.read"       "Issue Read"         "T0" "github"
register_cap "pr.read"          "PR Read"            "T0" "github"
register_cap "milestone.read"   "Milestone Read"     "T0" "github"
register_cap "ci.read"          "CI/CD Read"         "T0" "ci"
register_cap "audit.read"       "Audit Read"         "T0" "audit"

# T1 - Safe write capabilities
register_cap "issue.label"      "Issue Label"        "T1" "github"
register_cap "issue.comment"    "Issue Comment"      "T1" "github"
register_cap "issue.create"     "Issue Create"       "T1" "github"
register_cap "milestone.create" "Milestone Create"   "T1" "github"
register_cap "file.write"       "File Write"         "T1" "filesystem"
register_cap "git.commit"       "Git Commit"         "T1" "git"
register_cap "git.branch"       "Git Branch"         "T1" "git"

# T2 - Elevated/reversible capabilities
register_cap "pr.create"        "PR Create"          "T2" "github"
register_cap "pr.review"        "PR Review"          "T2" "github"
register_cap "git.push"         "Git Push"           "T2" "git"
register_cap "worktree.manage"  "Worktree Manage"    "T2" "git"
register_cap "container.run"    "Container Run"      "T2" "infrastructure"
register_cap "deploy.stage"     "Deploy (Staging)"   "T2" "deployment"

# T3 - Privileged capabilities
register_cap "pr.merge"         "PR Merge"           "T3" "github"
register_cap "issue.close"      "Issue Close"        "T3" "github"
register_cap "milestone.close"  "Milestone Close"    "T3" "github"
register_cap "release.tag"      "Release Tag"        "T3" "release"
register_cap "deploy.prod"      "Deploy (Prod)"      "T3" "deployment"
register_cap "secret.manage"    "Secret Manage"      "T3" "security"
register_cap "branch.delete"    "Branch Delete"      "T3" "git"

# ---------------------------------------------------------------------------
# Heuristics: map keyword patterns → capability ids
# Pattern format: "keyword_pattern:capability_id"
# ---------------------------------------------------------------------------
CAPABILITY_PATTERNS=(
  # T0 patterns
  "READ-ONLY:file.read"
  "read-only:file.read"
  "query only:file.read"
  "NEVER modif:file.read"
  "audit:audit.read"
  "analyze:file.read"
  "inspect:file.read"
  "report:file.read"
  "health check:file.read"
  "status:repo.read"
  "list.*issue:issue.read"
  "view.*issue:issue.read"
  "list.*milestone:milestone.read"
  "list.*pr:pr.read"
  "CI.*status:ci.read"
  "ci.*status:ci.read"

  # T1 patterns
  "label.*issue:issue.label"
  "apply.*label:issue.label"
  "remove.*label:issue.label"
  "triage:issue.label"
  "comment.*issue:issue.comment"
  "create.*issue:issue.create"
  "capture.*issue:issue.create"
  "create.*milestone:milestone.create"
  "new.*milestone:milestone.create"
  "scaffold:file.write"
  "initialize:file.write"
  "write.*file:file.write"
  "generate.*file:file.write"
  "commit:git.commit"
  "branch:git.branch"

  # T2 patterns
  "create.*PR:pr.create"
  "create.*pull request:pr.create"
  "open.*PR:pr.create"
  "review.*PR:pr.review"
  "PR.*review:pr.review"
  "push:git.push"
  "worktree:worktree.manage"
  "container:container.run"
  "deploy.*staging:deploy.stage"
  "promote.*qa:deploy.stage"

  # T3 patterns
  "merge.*PR:pr.merge"
  "PR.*merge:pr.merge"
  "merge.*pull request:pr.merge"
  "close.*issue:issue.close"
  "close.*milestone:milestone.close"
  "tag.*release:release.tag"
  "release.*tag:release.tag"
  "deploy.*prod:deploy.prod"
  "promote.*main:deploy.prod"
  "secret:secret.manage"
  "delete.*branch:branch.delete"
)

# ---------------------------------------------------------------------------
# Tier heuristics: infer a skill's tier from its description/body
# Returns T0, T1, T2, or T3
# ---------------------------------------------------------------------------
infer_tier() {
  local text="$1"
  local max_tier_explicit="$2"  # From frontmatter permissions.max_tier (may be empty)

  # Use explicit max_tier if present
  if [[ -n "$max_tier_explicit" && "$max_tier_explicit" != "null" && "$max_tier_explicit" != "none" ]]; then
    echo "$max_tier_explicit"
    return
  fi

  # Strong READ-ONLY overrides — skill explicitly declares read-only intent
  if echo "$text" | grep -qE "READ-ONLY OPERATION|NEVER modif(ies|y) (files|code|issues|PRs|milestones)|query only"; then
    echo "T0"; return
  fi

  # T3: intentional destructive/privileged operations (match action verbs, not mentions)
  # Use ^ in grep patterns to avoid matching "do NOT merge" / "avoid closing" etc.
  local desc
  desc=$(echo "$text" | grep -iE "^(Merge|Promote|Deploy|Close|Delete|Release|Tag).*to (main|prod|production)" | head -1 || true)
  if [[ -n "$desc" ]]; then
    echo "T3"; return
  fi
  if echo "$text" | grep -qiE "Merges.*PR|Batch merge|merge.*pull request.*to|promote.*to main|promote.*qa.*to main|tag.*release|deploy.*to.*prod|close.*milestone.*safely|delete.*branch.*after|manage.*secrets"; then
    echo "T3"; return
  fi

  # T2 signals — meaningful write actions
  if echo "$text" | grep -qiE "creates?.*pull request|opens?.*PR|push.*to.*remote|git.*push.*branch|worktree.*creat|launch.*container|promote.*to.*qa|deploy.*to.*staging"; then
    echo "T2"; return
  fi

  # T1 signals — lightweight write actions
  if echo "$text" | grep -qiE "creates?.*issue|captures?.*issue|apply.*labels?|scaffold.*new|initialize.*repo|git.*commit|creates?.*milestone"; then
    echo "T1"; return
  fi

  # Default T0 for read-only
  echo "T0"
}

# ---------------------------------------------------------------------------
# Extract capabilities from skill text
# Returns space-separated list of capability ids
# ---------------------------------------------------------------------------
extract_capabilities() {
  local text="$1"
  local tier="$2"
  local found_caps=()

  for pattern in "${CAPABILITY_PATTERNS[@]}"; do
    local keyword="${pattern%%:*}"
    local cap_id="${pattern##*:}"

    if echo "$text" | grep -qi "$keyword"; then
      # Only include capability if its tier <= skill's tier
      local cap_tier="${CAP_TIER[$cap_id]:-T0}"
      local skill_tier_num cap_tier_num
      skill_tier_num=$(echo "$tier" | tr -d 'T')
      cap_tier_num=$(echo "$cap_tier" | tr -d 'T')

      if (( cap_tier_num <= skill_tier_num )); then
        found_caps+=("$cap_id")
      fi
    fi
  done

  # Deduplicate
  if [[ ${#found_caps[@]} -gt 0 ]]; then
    printf '%s\n' "${found_caps[@]}" | sort -u | tr '\n' ' '
  fi

  # Always add file.read for any skill (all skills read something)
  echo -n "file.read "
}

# ---------------------------------------------------------------------------
# Parse skill frontmatter
# Returns: max_tier (or empty)
# ---------------------------------------------------------------------------
get_frontmatter_tier() {
  local file="$1"
  # Extract between first --- and second ---
  awk '
    BEGIN { in_fm=0; started=0 }
    /^---$/ { if(!started){started=1;in_fm=1;next}else if(in_fm){exit} }
    in_fm && /max_tier:/ { gsub(/.*max_tier:[[:space:]]*/,""); print; exit }
  ' "$file"
}

get_frontmatter_description() {
  local file="$1"
  awk '
    BEGIN { in_fm=0; started=0 }
    /^---$/ { if(!started){started=1;in_fm=1;next}else if(in_fm){exit} }
    in_fm && /^description:/ { gsub(/^description:[[:space:]]*/,""); print; exit }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Build graph nodes and edges
# ---------------------------------------------------------------------------
echo "Parsing skill files…" >&2

skill_nodes="[]"
cap_nodes="[]"
edges="[]"

# Track which capabilities have been referenced (so we only emit used cap nodes)
declare -A USED_CAPS

# Track invocation references (skill → skill with higher tier = escalation path)
# We'll infer these from skill bodies referencing other skill names
declare -A SKILL_TIER_MAP
declare -A SKILL_DESCRIPTION_MAP
declare -A SKILL_CAPS_MAP

# First pass: collect all skills
declare -a SKILL_IDS=()

for skill_file in "${COMMANDS_DIR}"/*.md; do
  [[ -f "$skill_file" ]] || continue

  skill_id=$(basename "$skill_file" .md)
  SKILL_IDS+=("$skill_id")

  description=$(get_frontmatter_description "$skill_file")
  [[ -z "$description" ]] && description="$skill_id"

  max_tier_explicit=$(get_frontmatter_tier "$skill_file")
  max_tier_explicit="${max_tier_explicit// /}"  # trim whitespace

  # Read full file text for heuristic analysis
  file_text=$(cat "$skill_file" 2>/dev/null || echo "")

  tier=$(infer_tier "$file_text" "$max_tier_explicit")

  SKILL_TIER_MAP["$skill_id"]="$tier"
  SKILL_DESCRIPTION_MAP["$skill_id"]="$description"

  # Extract capabilities
  caps=$(extract_capabilities "$file_text" "$tier")
  SKILL_CAPS_MAP["$skill_id"]="$caps"

  # Mark used capabilities
  for cap in $caps; do
    USED_CAPS["$cap"]=1
  done
done

# ---------------------------------------------------------------------------
# Build skill nodes JSON
# ---------------------------------------------------------------------------
for skill_id in "${SKILL_IDS[@]}"; do
  tier="${SKILL_TIER_MAP[$skill_id]}"
  description="${SKILL_DESCRIPTION_MAP[$skill_id]}"

  # Derive permission_level from tier
  case "$tier" in
    T0) perm_level="READ-ONLY" ;;
    T1) perm_level="WRITE-LIMITED" ;;
    T2) perm_level="WRITE-FULL" ;;
    T3) perm_level="PRIVILEGED" ;;
    *)  perm_level="READ-ONLY" ;;
  esac

  # Derive category from skill namespace
  category="${skill_id%%:*}"

  node=$(jq -n \
    --arg id "$skill_id" \
    --arg label "$skill_id" \
    --arg description "$description" \
    --arg tier "$tier" \
    --arg permission_level "$perm_level" \
    --arg category "$category" \
    --arg node_type "skill" \
    '{
      id: $id,
      label: $label,
      description: $description,
      tier: $tier,
      permission_level: $permission_level,
      category: $category,
      node_type: $node_type
    }')

  skill_nodes=$(echo "$skill_nodes" | jq --argjson node "$node" '. + [$node]')
done

# ---------------------------------------------------------------------------
# Build capability nodes JSON (only used ones)
# ---------------------------------------------------------------------------
for cap_id in "${!USED_CAPS[@]}"; do
  cap_label="${CAP_LABEL[$cap_id]:-$cap_id}"
  cap_tier="${CAP_TIER[$cap_id]:-T0}"
  cap_category="${CAP_CATEGORY[$cap_id]:-unknown}"

  node=$(jq -n \
    --arg id "cap:$cap_id" \
    --arg label "$cap_label" \
    --arg tier "$cap_tier" \
    --arg category "$cap_category" \
    --arg node_type "capability" \
    --arg cap_name "$cap_id" \
    '{
      id: $id,
      label: $label,
      tier: $tier,
      category: $category,
      node_type: $node_type,
      cap_name: $cap_name
    }')

  cap_nodes=$(echo "$cap_nodes" | jq --argjson node "$node" '. + [$node]')
done

# ---------------------------------------------------------------------------
# Build edges: skill → capability (HAS_PERMISSION)
# ---------------------------------------------------------------------------
for skill_id in "${SKILL_IDS[@]}"; do
  caps="${SKILL_CAPS_MAP[$skill_id]:-}"
  skill_tier="${SKILL_TIER_MAP[$skill_id]}"

  for cap in $caps; do
    [[ -z "$cap" ]] && continue
    [[ -z "${USED_CAPS[$cap]+x}" ]] && continue

    cap_tier="${CAP_TIER[$cap]:-T0}"

    edge=$(jq -n \
      --arg source "$skill_id" \
      --arg target "cap:$cap" \
      --arg type "HAS_PERMISSION" \
      --arg label "can $cap" \
      --arg cap_tier "$cap_tier" \
      '{
        source: $source,
        target: $target,
        type: $type,
        label: $label,
        cap_tier: $cap_tier
      }')

    edges=$(echo "$edges" | jq --argjson edge "$edge" '. + [$edge]')
  done
done

# ---------------------------------------------------------------------------
# Build escalation edges: skill → skill (INVOKES) where callee has higher tier
# Detect by scanning for other skill names in file body
# ---------------------------------------------------------------------------
for skill_id in "${SKILL_IDS[@]}"; do
  skill_file="${COMMANDS_DIR}/${skill_id}.md"
  [[ -f "$skill_file" ]] || continue

  skill_tier="${SKILL_TIER_MAP[$skill_id]}"
  skill_tier_num=$(echo "$skill_tier" | tr -d 'T')

  for other_id in "${SKILL_IDS[@]}"; do
    [[ "$other_id" == "$skill_id" ]] && continue

    other_tier="${SKILL_TIER_MAP[$other_id]:-T0}"
    other_tier_num=$(echo "$other_tier" | tr -d 'T')

    # Only emit escalation edge if other has higher tier
    if (( other_tier_num > skill_tier_num )); then
      # Check if skill body mentions other skill (by id or short name)
      short_other="${other_id##*:}"
      if grep -q "$other_id\|/$short_other\b" "$skill_file" 2>/dev/null; then
        edge=$(jq -n \
          --arg source "$skill_id" \
          --arg target "$other_id" \
          --arg type "INVOKES" \
          --arg label "invokes (escalates)" \
          '{
            source: $source,
            target: $target,
            type: $type,
            label: $label
          }')
        edges=$(echo "$edges" | jq --argjson edge "$edge" '. + [$edge]')
      fi
    fi
  done
done

# ---------------------------------------------------------------------------
# Combine nodes and write output
# ---------------------------------------------------------------------------
all_nodes=$(echo "$skill_nodes" | jq --argjson caps "$cap_nodes" '. + $caps')

skill_count=$(echo "$skill_nodes" | jq 'length')
cap_count=$(echo "$cap_nodes" | jq 'length')
edge_count=$(echo "$edges" | jq 'length')

output=$(jq -n \
  --argjson nodes "$all_nodes" \
  --argjson edges "$edges" \
  --argjson skill_count "$skill_count" \
  --argjson cap_count "$cap_count" \
  '{
    meta: {
      generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      skill_count: $skill_count,
      capability_count: $cap_count,
      node_count: ($nodes | length),
      edge_count: ($edges | length),
      description: "Skill permission graph: skills mapped to authorized capabilities"
    },
    nodes: $nodes,
    edges: $edges
  }')

echo "$output" > "$OUTPUT_FILE"

echo "Permission graph written to: ${OUTPUT_FILE}" >&2
echo "  Skills:       ${skill_count}" >&2
echo "  Capabilities: ${cap_count}" >&2
echo "  Edges:        ${edge_count}" >&2
echo "$output"
