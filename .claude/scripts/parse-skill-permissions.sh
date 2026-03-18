#!/usr/bin/env bash
# parse-skill-permissions.sh - Parse permissions block from skill files
# Part of Issue #203 - Automatic script permission pre-approval for skills
#
# Skills can declare required scripts in their YAML frontmatter:
#
# ---
# description: My skill
# permissions:
#   max_tier: T1
#   scripts:
#     - name: list-issues.sh
#       tier: T0
#     - name: add-label.sh
#       tier: T1
# ---
#
# Usage:
#   parse-skill-permissions.sh --skill-file /path/to/skill.md
#   parse-skill-permissions.sh --skill-file /path/to/skill.md --format json
#   parse-skill-permissions.sh --skill-file /path/to/skill.md --check-script "list-issues.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- YAML Parsing Functions ---

# Extract YAML frontmatter from a markdown file
extract_frontmatter() {
  local file="${1}"

  if [[ ! -f "${file}" ]]; then
    echo "ERROR: File not found: ${file}" >&2
    return 1
  fi

  # Extract content between first --- and second ---
  awk '
    BEGIN { in_frontmatter = 0; started = 0 }
    /^---$/ {
      if (!started) { started = 1; in_frontmatter = 1; next }
      else if (in_frontmatter) { exit }
    }
    in_frontmatter { print }
  ' "${file}"
}

# Parse permissions block from YAML frontmatter
# Uses yq if available, falls back to simple parsing
parse_permissions() {
  local frontmatter="${1}"

  # Check if yq is available
  if command -v yq &> /dev/null; then
    echo "${frontmatter}" | yq -o=json '.permissions // {}' 2>/dev/null || echo '{}'
  else
    # Fallback: simple grep-based parsing for the most common cases
    parse_permissions_simple "${frontmatter}"
  fi
}

# Simple permissions parser without yq dependency
parse_permissions_simple() {
  local frontmatter="${1}"
  local max_tier=""
  local scripts=()
  local in_scripts=false
  local current_script_name=""
  local current_script_tier=""

  while IFS= read -r line; do
    # Match max_tier
    if [[ "${line}" =~ ^[[:space:]]*max_tier:[[:space:]]*([A-Z0-9]+) ]]; then
      max_tier="${BASH_REMATCH[1]}"
    fi

    # Match scripts: array start
    if [[ "${line}" =~ ^[[:space:]]*scripts:[[:space:]]*$ ]]; then
      in_scripts=true
      continue
    fi

    # If in scripts section
    if [[ "${in_scripts}" == "true" ]]; then
      # Exit if we hit a non-indented line (new top-level key)
      if [[ "${line}" =~ ^[a-z] ]]; then
        in_scripts=false
        continue
      fi

      # Match - name: value
      if [[ "${line}" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*\"?([^\"]+)\"?$ ]]; then
        # Save previous script if exists
        if [[ -n "${current_script_name}" ]]; then
          scripts+=("{\"name\":\"${current_script_name}\",\"tier\":\"${current_script_tier:-T2}\"}")
        fi
        current_script_name="${BASH_REMATCH[1]}"
        current_script_tier=""
      fi

      # Match tier: value (continuation of script entry)
      if [[ "${line}" =~ ^[[:space:]]*tier:[[:space:]]*([A-Z0-9]+) ]]; then
        current_script_tier="${BASH_REMATCH[1]}"
      fi
    fi
  done <<< "${frontmatter}"

  # Don't forget the last script
  if [[ -n "${current_script_name}" ]]; then
    scripts+=("{\"name\":\"${current_script_name}\",\"tier\":\"${current_script_tier:-T2}\"}")
  fi

  # Build JSON output
  local scripts_json="[]"
  if [[ ${#scripts[@]} -gt 0 ]]; then
    scripts_json="[$(IFS=,; echo "${scripts[*]}")]"
  fi

  if [[ -z "${max_tier}" && "${#scripts[@]}" -eq 0 ]]; then
    # No permissions found
    echo '{}'
  else
    jq -cn \
      --arg max_tier "${max_tier}" \
      --argjson scripts "${scripts_json}" \
      '{
        max_tier: (if $max_tier == "" then null else $max_tier end),
        scripts: (if ($scripts | length) == 0 then null else $scripts end)
      } | with_entries(select(.value != null))'
  fi
}

# Check if a specific script is declared in skill permissions
check_script_in_permissions() {
  local permissions_json="${1}"
  local script_name="${2}"

  if [[ -z "${permissions_json}" || "${permissions_json}" == "{}" ]]; then
    echo '{"declared":false}'
    return
  fi

  # Extract script info from permissions
  local result
  result=$(echo "${permissions_json}" | jq -c --arg name "${script_name}" '
    .scripts // [] |
    map(select(.name == $name or (.name | endswith("/" + $name)))) |
    first // null |
    if . then {declared: true, tier: .tier} else {declared: false} end
  ')

  echo "${result}"
}

# Get effective tier for a script considering skill context
get_effective_tier() {
  local permissions_json="${1}"
  local script_name="${2}"
  local actual_tier="${3:-T2}"  # Tier from tier-registry

  local script_info
  script_info=$(check_script_in_permissions "${permissions_json}" "${script_name}")

  local declared
  declared=$(echo "${script_info}" | jq -r '.declared')

  if [[ "${declared}" != "true" ]]; then
    # Script not declared - use actual tier
    jq -cn \
      --arg tier "${actual_tier}" \
      '{
        effective_tier: $tier,
        auto_approved: false,
        reason: "script_not_declared"
      }'
    return
  fi

  local declared_tier
  declared_tier=$(echo "${script_info}" | jq -r '.tier')

  # Check max_tier constraint
  local max_tier
  max_tier=$(echo "${permissions_json}" | jq -r '.max_tier // "T1"')

  # T3 always prompts regardless of declaration
  if [[ "${declared_tier}" == "T3" || "${actual_tier}" == "T3" ]]; then
    jq -cn \
      --arg tier "T3" \
      '{
        effective_tier: "T3",
        auto_approved: false,
        reason: "t3_always_prompts"
      }'
    return
  fi

  # Convert tiers to numbers for comparison
  tier_to_num() {
    case "${1}" in
      T0) echo 0 ;;
      T1) echo 1 ;;
      T2) echo 2 ;;
      T3) echo 3 ;;
      *) echo 2 ;;  # Default to T2
    esac
  }

  local declared_num max_num
  declared_num=$(tier_to_num "${declared_tier}")
  max_num=$(tier_to_num "${max_tier}")

  # Auto-approve if declared tier <= max_tier and declared tier < T3
  if (( declared_num <= max_num )); then
    jq -cn \
      --arg tier "${declared_tier}" \
      '{
        effective_tier: $tier,
        auto_approved: true,
        reason: "declared_within_max_tier"
      }'
  else
    # Declared tier exceeds max_tier - prompt
    jq -cn \
      --arg tier "${declared_tier}" \
      '{
        effective_tier: $tier,
        auto_approved: false,
        reason: "exceeds_max_tier"
      }'
  fi
}

# --- Usage ---

usage() {
  cat <<'EOF'
Usage: parse-skill-permissions.sh [OPTIONS]

Parse permissions block from skill files for auto-approval of declared scripts.

Options:
  --skill-file FILE      Path to skill markdown file (required)
  --format FORMAT        Output format: json (default), simple
  --check-script NAME    Check if specific script is declared (returns tier info)
  --effective-tier NAME  Get effective tier for script (with --actual-tier)
  --actual-tier TIER     Actual tier from tier-registry (used with --effective-tier)
  -h, --help             Show this help

Output (--format json):
  {
    "max_tier": "T1",
    "scripts": [
      {"name": "list-issues.sh", "tier": "T0"},
      {"name": "add-label.sh", "tier": "T1"}
    ]
  }

Output (--check-script):
  {"declared": true, "tier": "T0"}
  {"declared": false}

Examples:
  # Parse permissions from a skill
  parse-skill-permissions.sh --skill-file core/commands/sprint-work.md

  # Check if a script is declared
  parse-skill-permissions.sh --skill-file skill.md --check-script "read-sprint-state.sh"

  # Get effective tier with auto-approval logic
  parse-skill-permissions.sh --skill-file skill.md --effective-tier "my-script.sh" --actual-tier T1
EOF
}

# --- Main ---

main() {
  local skill_file=""
  local format="json"
  local check_script=""
  local effective_tier_script=""
  local actual_tier="T2"

  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --skill-file)
        skill_file="${2}"
        shift 2
        ;;
      --format)
        format="${2}"
        shift 2
        ;;
      --check-script)
        check_script="${2}"
        shift 2
        ;;
      --effective-tier)
        effective_tier_script="${2}"
        shift 2
        ;;
      --actual-tier)
        actual_tier="${2}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: Unknown option '${1}'" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  # Validate required argument
  if [[ -z "${skill_file}" ]]; then
    echo "ERROR: --skill-file is required" >&2
    exit 1
  fi

  if [[ ! -f "${skill_file}" ]]; then
    echo "ERROR: Skill file not found: ${skill_file}" >&2
    exit 1
  fi

  # Extract frontmatter and parse permissions
  local frontmatter
  frontmatter=$(extract_frontmatter "${skill_file}")

  local permissions
  permissions=$(parse_permissions "${frontmatter}")

  # Handle different output modes
  if [[ -n "${effective_tier_script}" ]]; then
    get_effective_tier "${permissions}" "${effective_tier_script}" "${actual_tier}"
  elif [[ -n "${check_script}" ]]; then
    check_script_in_permissions "${permissions}" "${check_script}"
  else
    case "${format}" in
      json)
        echo "${permissions}"
        ;;
      simple)
        local max_tier
        max_tier=$(echo "${permissions}" | jq -r '.max_tier // "none"')
        echo "max_tier: ${max_tier}"
        echo "scripts:"
        echo "${permissions}" | jq -r '.scripts // [] | .[] | "  - \(.name): \(.tier)"'
        ;;
      *)
        echo "ERROR: Unknown format '${format}'" >&2
        exit 1
        ;;
    esac
  fi
}

main "$@"
