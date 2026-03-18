#!/bin/bash
set -euo pipefail
# skill-deps-data.sh
# Analyzes skill dependencies, primitive usage, and permission tier inheritance
# Part of Issue #226 - Skill Dependency Visualization
#
# Usage:
#   ./scripts/skill-deps-data.sh                    # All skills overview
#   ./scripts/skill-deps-data.sh "sprint-work"      # Single skill deep dive
#   ./scripts/skill-deps-data.sh --tier T3          # Filter by tier
#   ./scripts/skill-deps-data.sh --unused           # Primitives not used by any skill
#   ./scripts/skill-deps-data.sh --json             # Force JSON output (default)
#
# Outputs structured JSON with dependency analysis

set -e

# Paths
REGISTRY_FILE="primitives/registry.yaml"
CONTRACTS_DIR="contracts/skills"
COMMANDS_DIR="core/commands"

# Arguments
SKILL_NAME=""
TIER_FILTER=""
SHOW_UNUSED=false
OUTPUT_FORMAT="json"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --tier)
      TIER_FILTER="$2"
      shift 2
      ;;
    --unused)
      SHOW_UNUSED=true
      shift
      ;;
    --json)
      OUTPUT_FORMAT="json"
      shift
      ;;
    --graph)
      OUTPUT_FORMAT="graph"
      shift
      ;;
    *)
      SKILL_NAME="$1"
      shift
      ;;
  esac
done

# Check dependencies
if ! command -v yq &> /dev/null; then
  echo '{"error": "yq is required but not installed. Install with: brew install yq"}' >&2
  exit 1
fi

# Create temp directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ============================================================================
# Parse Primitive Registry
# ============================================================================

parse_primitives() {
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo '[]'
    return
  fi

  yq -o=json '.primitives | to_entries | map({
    "name": .key,
    "tier": .value.tier,
    "category": .value.category,
    "description": .value.description,
    "path": .value.path,
    "dependencies": (.value.dependencies // []),
    "tags": (.value.tags // [])
  })' "$REGISTRY_FILE"
}

# ============================================================================
# Parse Skill Contracts
# ============================================================================

parse_skill_contracts() {
  if [[ ! -d "$CONTRACTS_DIR" ]]; then
    echo '[]'
    return
  fi

  # Collect all contract files
  local files=("$CONTRACTS_DIR"/*.yaml)
  [[ -f "${files[0]}" ]] || { echo '[]'; return; }

  # Process each contract file and collect into array
  {
    for contract_file in "${files[@]}"; do
      [[ -f "$contract_file" ]] || continue
      yq -o=json '{
        "name": .skill,
        "version": .version,
        "description": .description,
        "dependencies": (.dependencies // []),
        "source_file": "'"$contract_file"'"
      }' "$contract_file" 2>/dev/null || echo '{}'
    done
  } | jq -s '[.[] | select(.name != null)]'
}

# ============================================================================
# Parse Command Files for Script References
# ============================================================================

parse_command_scripts() {
  if [[ ! -d "$COMMANDS_DIR" ]]; then
    echo '[]'
    return
  fi

  # Build JSON for each command file
  for cmd_file in "$COMMANDS_DIR"/*.md; do
    [[ -f "$cmd_file" ]] || continue

    local name=$(basename "$cmd_file" .md)

    # Extract script references from command file (as JSON array)
    local scripts_raw=$(grep -oE '\./scripts/[a-zA-Z0-9_-]+\.sh' "$cmd_file" 2>/dev/null | sort -u | tr '\n' '|' | sed 's/|$//')
    local scripts='[]'
    if [[ -n "$scripts_raw" ]]; then
      scripts=$(echo "$scripts_raw" | tr '|' '\n' | jq -R -s 'split("\n") | map(select(length > 0))')
    fi

    # Detect tier from permissions block if present
    local tier=$(grep -A5 '^permissions:' "$cmd_file" 2>/dev/null | grep 'max_tier:' | head -1 | sed 's/.*max_tier: *//' | tr -d ' \n\r' || echo "")

    # Count gh commands (ensure single numeric value)
    local gh_count=$(grep -c 'gh ' "$cmd_file" 2>/dev/null | head -1 | tr -d ' \n\r' || echo "0")
    [[ -z "$gh_count" ]] && gh_count="0"

    # Output compact JSON (single line)
    jq -n -c \
      --arg name "$name" \
      --argjson scripts "$scripts" \
      --arg tier "$tier" \
      --argjson gh "$gh_count" \
      '{name: $name, scripts: $scripts, tier: $tier, gh_commands: $gh}'
  done | jq -s '.'
}

# ============================================================================
# Calculate Tier Inheritance
# ============================================================================

calculate_tier_inheritance() {
  local skill_deps="$1"
  local primitives="$2"

  # For each skill, trace through dependencies to find highest tier
  echo "$skill_deps" | jq --argjson prims "$primitives" '
    def get_prim_tier(name):
      ($prims | map(select(.name == name)) | .[0].tier) // "T0";

    def tier_order:
      {"T0": 0, "T1": 1, "T2": 2, "T3": 3};

    def max_tier(a; b):
      if (tier_order[a] // 0) > (tier_order[b] // 0) then a else b end;

    . | map(
      . as $skill |
      {
        "skill": .name,
        "dependencies": .dependencies,
        "tier_sources": (
          if .dependencies then
            .dependencies | map(
              if .type == "primitive" then
                {"name": .name, "tier": get_prim_tier(.name), "type": "primitive"}
              else
                {"name": .name, "tier": (.tier // "T0"), "type": "skill"}
              end
            )
          else
            []
          end
        ),
        "effective_tier": (
          if .dependencies then
            .dependencies | map(
              if .type == "primitive" then get_prim_tier(.name) else (.tier // "T0") end
            ) | if length > 0 then reduce .[] as $t ("T0"; max_tier(.; $t)) else "T0" end
          else
            "T0"
          end
        )
      }
    )
  '
}

# ============================================================================
# Find Unused Primitives
# ============================================================================

find_unused_primitives() {
  local primitives="$1"
  local skill_deps="$2"
  local commands="$3"

  # Get all primitive names
  local all_prims=$(echo "$primitives" | jq -r '.[].name')

  # Get primitives referenced in skill contracts
  local used_in_contracts=$(echo "$skill_deps" | jq -r '.[].dependencies[]? | select(.type == "primitive") | .name' 2>/dev/null | sort -u)

  # Get primitives referenced via scripts in commands
  local used_scripts=$(echo "$commands" | jq -r '.[].scripts[]?' | sort -u)

  # Build list of used primitives
  local all_used=$(echo -e "$used_in_contracts\n$used_scripts" | sort -u)

  # Find unused
  echo "$primitives" | jq --arg used "$all_used" '
    ($used | split("\n") | map(select(length > 0))) as $used_list |
    map(select(.name as $n | ($used_list | index($n) | not)))
  '
}

# ============================================================================
# Generate Dependency Graph Data
# ============================================================================

generate_graph_data() {
  local skill_name="$1"
  local primitives="$2"
  local skill_deps="$3"

  if [[ -z "$skill_name" ]]; then
    # Full graph for all skills
    echo "$skill_deps" | jq --argjson prims "$primitives" '
      {
        "nodes": (
          [.[] | {"id": .skill, "type": "skill", "tier": .effective_tier}] +
          [$prims[] | {"id": .name, "type": "primitive", "tier": .tier}]
        ),
        "edges": [
          .[] | .skill as $from | .dependencies[]? | {
            "from": $from,
            "to": .name,
            "type": .type
          }
        ]
      }
    '
  else
    # Single skill graph
    echo "$skill_deps" | jq --arg name "$skill_name" --argjson prims "$primitives" '
      def get_prim(name): $prims | map(select(.name == name)) | .[0];

      (.[] | select(.skill == $name)) as $skill |
      if $skill then
        {
          "root": $skill.skill,
          "tier": $skill.effective_tier,
          "nodes": (
            [{"id": $skill.skill, "type": "skill", "tier": $skill.effective_tier}] +
            [$skill.tier_sources[]? | {"id": .name, "type": .type, "tier": .tier}]
          ),
          "edges": [
            $skill.tier_sources[]? | {
              "from": $skill.skill,
              "to": .name,
              "tier": .tier
            }
          ],
          "tier_source": (
            $skill.tier_sources | map(select(.tier == $skill.effective_tier)) | .[0].name
          )
        }
      else
        {"error": "Skill not found", "name": $name}
      end
    '
  fi
}

# ============================================================================
# Tier Distribution Summary
# ============================================================================

tier_distribution() {
  local primitives="$1"
  local skill_deps="$2"

  jq -n --argjson prims "$primitives" --argjson skills "$skill_deps" '
    {
      "primitives": {
        "T0": ($prims | map(select(.tier == "T0")) | length),
        "T1": ($prims | map(select(.tier == "T1")) | length),
        "T2": ($prims | map(select(.tier == "T2")) | length),
        "T3": ($prims | map(select(.tier == "T3")) | length)
      },
      "skills": {
        "T0": ($skills | map(select(.effective_tier == "T0")) | length),
        "T1": ($skills | map(select(.effective_tier == "T1")) | length),
        "T2": ($skills | map(select(.effective_tier == "T2")) | length),
        "T3": ($skills | map(select(.effective_tier == "T3")) | length)
      }
    }
  '
}

# ============================================================================
# Main Execution
# ============================================================================

# Gather data
primitives=$(parse_primitives)
skill_contracts=$(parse_skill_contracts)
commands=$(parse_command_scripts)

# Calculate tier inheritance
tier_info=$(calculate_tier_inheritance "$skill_contracts" "$primitives")

# Filter by tier if specified
if [[ -n "$TIER_FILTER" ]]; then
  tier_info=$(echo "$tier_info" | jq --arg tier "$TIER_FILTER" '[.[] | select(.effective_tier == $tier)]')
  primitives=$(echo "$primitives" | jq --arg tier "$TIER_FILTER" '[.[] | select(.tier == $tier)]')
fi

# Handle different modes
if [[ "$SHOW_UNUSED" == "true" ]]; then
  # Unused primitives mode
  unused=$(find_unused_primitives "$primitives" "$skill_contracts" "$commands")
  jq -n --argjson unused "$unused" '{
    "mode": "unused_primitives",
    "count": ($unused | length),
    "primitives": $unused
  }'
elif [[ -n "$SKILL_NAME" ]]; then
  # Single skill deep dive
  graph=$(generate_graph_data "$SKILL_NAME" "$primitives" "$tier_info")
  skill_info=$(echo "$tier_info" | jq --arg name "$SKILL_NAME" '.[] | select(.skill == $name)')

  if [[ -z "$skill_info" || "$skill_info" == "null" ]]; then
    # Try to find in commands
    cmd_info=$(echo "$commands" | jq --arg name "$SKILL_NAME" '.[] | select(.name == $name)')
    if [[ -n "$cmd_info" && "$cmd_info" != "null" ]]; then
      jq -n --argjson cmd "$cmd_info" --argjson graph "$graph" '{
        "mode": "single_skill",
        "skill": $cmd.name,
        "source": "command",
        "tier": ($cmd.tier // "unknown"),
        "scripts": $cmd.scripts,
        "gh_commands": $cmd.gh_commands,
        "graph": $graph
      }'
    else
      jq -n --arg name "$SKILL_NAME" '{"error": "Skill not found", "name": $name}'
    fi
  else
    jq -n --argjson skill "$skill_info" --argjson graph "$graph" '{
      "mode": "single_skill",
      "skill": $skill.skill,
      "source": "contract",
      "effective_tier": $skill.effective_tier,
      "dependencies": $skill.dependencies,
      "tier_sources": $skill.tier_sources,
      "graph": $graph
    }'
  fi
else
  # Overview mode
  distribution=$(tier_distribution "$primitives" "$tier_info")

  jq -n \
    --argjson primitives "$primitives" \
    --argjson skills "$tier_info" \
    --argjson commands "$commands" \
    --argjson distribution "$distribution" \
    '{
      "mode": "overview",
      "summary": {
        "primitives_count": ($primitives | length),
        "skills_count": ($skills | length),
        "commands_count": ($commands | length)
      },
      "tier_distribution": $distribution,
      "skills": $skills,
      "primitives": ($primitives | map({name, tier, category, description})),
      "commands": ($commands | map({name, tier, scripts, gh_commands}))
    }'
fi
