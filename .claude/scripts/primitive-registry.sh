#!/usr/bin/env bash
# primitive-registry.sh - Query the primitive registry
# Part of Issue #222 - Primitive registry with tier metadata
#
# Usage:
#   primitive-registry.sh list [--tier T0|T1|T2|T3] [--category CATEGORY] [--tag TAG]
#   primitive-registry.sh info PRIMITIVE_NAME
#   primitive-registry.sh exists PRIMITIVE_NAME
#   primitive-registry.sh tier PRIMITIVE_NAME
#   primitive-registry.sh deps PRIMITIVE_NAME [--recursive]
#   primitive-registry.sh validate
#   primitive-registry.sh search PATTERN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PRIMITIVE_REGISTRY_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REGISTRY_FILE="${PRIMITIVE_REGISTRY_FILE:-${REPO_ROOT}/primitives/registry.yaml}"

# Check for yq (YAML parser)
check_yq() {
  if ! command -v yq &> /dev/null; then
    echo "ERROR: yq is required but not installed." >&2
    echo "Install with: brew install yq" >&2
    exit 1
  fi
}

# Validate registry file exists
check_registry() {
  if [[ ! -f "${REGISTRY_FILE}" ]]; then
    echo "ERROR: Registry file not found: ${REGISTRY_FILE}" >&2
    exit 1
  fi
}

# --- List Primitives ---
# List all primitives with optional filters
list_primitives() {
  local tier_filter=""
  local category_filter=""
  local tag_filter=""
  local output_format="table"

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --tier)
        tier_filter="${2}"
        shift 2
        ;;
      --category)
        category_filter="${2}"
        shift 2
        ;;
      --tag)
        tag_filter="${2}"
        shift 2
        ;;
      --json)
        output_format="json"
        shift
        ;;
      *)
        echo "ERROR: Unknown option for list: ${1}" >&2
        return 1
        ;;
    esac
  done

  # Build yq filter expression
  local filter=".primitives | to_entries"

  if [[ -n "${tier_filter}" ]]; then
    filter="${filter} | map(select(.value.tier == \"${tier_filter}\"))"
  fi

  if [[ -n "${category_filter}" ]]; then
    filter="${filter} | map(select(.value.category == \"${category_filter}\"))"
  fi

  if [[ -n "${tag_filter}" ]]; then
    filter="${filter} | map(select(.value.tags // [] | contains([\"${tag_filter}\"])))"
  fi

  case "${output_format}" in
    json)
      yq -o json "${filter} | from_entries" "${REGISTRY_FILE}"
      ;;
    table)
      echo "NAME                          TIER  CATEGORY    DESCRIPTION"
      echo "----------------------------  ----  ----------  -----------"
      yq -r "${filter}[] | [.key, .value.tier, .value.category, .value.description] | @tsv" "${REGISTRY_FILE}" | \
        while IFS=$'\t' read -r name tier category desc; do
          printf "%-30s %-4s %-10s %s\n" "${name}" "${tier}" "${category}" "${desc:0:50}"
        done
      ;;
  esac
}

# --- Get Primitive Info ---
# Get detailed information about a specific primitive
get_primitive_info() {
  local primitive_name="${1:-}"
  local output_format="${2:-yaml}"

  if [[ -z "${primitive_name}" ]]; then
    echo "ERROR: Primitive name required" >&2
    return 1
  fi

  local exists
  exists=$(yq ".primitives | has(\"${primitive_name}\")" "${REGISTRY_FILE}")

  if [[ "${exists}" != "true" ]]; then
    echo "ERROR: Primitive not found: ${primitive_name}" >&2
    return 1
  fi

  case "${output_format}" in
    json)
      yq -o json ".primitives.\"${primitive_name}\"" "${REGISTRY_FILE}"
      ;;
    yaml)
      echo "# ${primitive_name}"
      yq ".primitives.\"${primitive_name}\"" "${REGISTRY_FILE}"
      ;;
    verbose)
      echo "=== ${primitive_name} ==="
      echo ""
      local tier category desc path
      tier=$(yq -r ".primitives.\"${primitive_name}\".tier // \"unknown\"" "${REGISTRY_FILE}")
      category=$(yq -r ".primitives.\"${primitive_name}\".category // \"unknown\"" "${REGISTRY_FILE}")
      desc=$(yq -r ".primitives.\"${primitive_name}\".description // \"No description\"" "${REGISTRY_FILE}")
      path=$(yq -r ".primitives.\"${primitive_name}\".path // \"null\"" "${REGISTRY_FILE}")

      echo "Tier:        ${tier}"
      echo "Category:    ${category}"
      echo "Description: ${desc}"
      echo "Path:        ${path}"
      echo ""

      # Inputs
      echo "Inputs:"
      local has_inputs
      has_inputs=$(yq -r ".primitives.\"${primitive_name}\".inputs // {} | length" "${REGISTRY_FILE}")
      if [[ "${has_inputs}" == "0" || -z "${has_inputs}" ]]; then
        echo "  (none)"
      else
        yq -r ".primitives.\"${primitive_name}\".inputs | to_entries[] | \"  - \" + .key + \" (\" + (.value.type // \"any\") + \")\" + (select(.value.required == true) | \" [required]\" // \"\")" "${REGISTRY_FILE}" 2>/dev/null || \
        yq -r ".primitives.\"${primitive_name}\".inputs | to_entries[] | \"  - \" + .key + \" (\" + (.value.type // \"any\") + \")\"" "${REGISTRY_FILE}"
      fi
      echo ""

      # Outputs
      echo "Outputs:"
      yq -r ".primitives.\"${primitive_name}\".outputs.type // \"void\"" "${REGISTRY_FILE}"
      echo ""

      # Dependencies
      echo "Dependencies:"
      yq -r ".primitives.\"${primitive_name}\".dependencies // [] | .[] | \"  - \" + ." "${REGISTRY_FILE}" 2>/dev/null || echo "  (none)"
      echo ""

      # Reversibility
      local reversible
      reversible=$(yq ".primitives.\"${primitive_name}\" | has(\"reversibility\")" "${REGISTRY_FILE}")
      if [[ "${reversible}" == "true" ]]; then
        echo "Reversibility:"
        yq -r ".primitives.\"${primitive_name}\".reversibility | \"  Primitive: \" + (.primitive // \"N/A\") + \"\n  Note: \" + (.note // .description // \"N/A\")" "${REGISTRY_FILE}"
      fi
      ;;
  esac
}

# --- Check Primitive Exists ---
# Check if a primitive exists in the registry
check_primitive_exists() {
  local primitive_name="${1:-}"

  if [[ -z "${primitive_name}" ]]; then
    echo "ERROR: Primitive name required" >&2
    return 1
  fi

  local exists
  exists=$(yq ".primitives | has(\"${primitive_name}\")" "${REGISTRY_FILE}")

  if [[ "${exists}" == "true" ]]; then
    echo "true"
    return 0
  else
    echo "false"
    return 1
  fi
}

# --- Get Primitive Tier ---
# Get the tier classification of a primitive
get_primitive_tier() {
  local primitive_name="${1:-}"
  local output_format="${2:-simple}"

  if [[ -z "${primitive_name}" ]]; then
    echo "ERROR: Primitive name required" >&2
    return 1
  fi

  local exists
  exists=$(yq ".primitives | has(\"${primitive_name}\")" "${REGISTRY_FILE}")

  if [[ "${exists}" != "true" ]]; then
    echo "ERROR: Primitive not found: ${primitive_name}" >&2
    return 1
  fi

  local tier
  tier=$(yq -r ".primitives.\"${primitive_name}\".tier" "${REGISTRY_FILE}")

  case "${output_format}" in
    simple)
      echo "${tier}"
      ;;
    json)
      local category requires_approval
      category=$(yq -r ".primitives.\"${primitive_name}\".category // \"unknown\"" "${REGISTRY_FILE}")
      requires_approval=$(yq -r ".primitives.\"${primitive_name}\".requires_approval // \"false\"" "${REGISTRY_FILE}")

      jq -cn \
        --arg tier "${tier}" \
        --arg primitive "${primitive_name}" \
        --arg category "${category}" \
        --arg requires_approval "${requires_approval}" \
        '{
          primitive: $primitive,
          tier: $tier,
          category: $category,
          requires_approval: ($requires_approval == "always")
        }'
      ;;
    verbose)
      local tier_name tier_risk tier_approval
      tier_name=$(yq -r ".tier_definitions.${tier}.name // \"Unknown\"" "${REGISTRY_FILE}")
      tier_risk=$(yq -r ".tier_definitions.${tier}.risk // \"Unknown\"" "${REGISTRY_FILE}")
      tier_approval=$(yq -r ".tier_definitions.${tier}.approval // \"Unknown\"" "${REGISTRY_FILE}")

      echo "Primitive: ${primitive_name}"
      echo "Tier:      ${tier} - ${tier_name}"
      echo "Risk:      ${tier_risk}"
      echo "Approval:  ${tier_approval}"
      ;;
  esac
}

# --- Get Dependencies ---
# Get dependency tree for a primitive
get_dependencies() {
  local primitive_name="${1:-}"
  local recursive="${2:-false}"
  local output_format="${3:-list}"

  if [[ -z "${primitive_name}" ]]; then
    echo "ERROR: Primitive name required" >&2
    return 1
  fi

  local exists
  exists=$(yq ".primitives | has(\"${primitive_name}\")" "${REGISTRY_FILE}")

  if [[ "${exists}" != "true" ]]; then
    echo "ERROR: Primitive not found: ${primitive_name}" >&2
    return 1
  fi

  if [[ "${recursive}" == "true" ]]; then
    # Recursive dependency resolution
    get_deps_recursive "${primitive_name}" "" "${output_format}"
  else
    # Direct dependencies only
    case "${output_format}" in
      json)
        yq -o json ".primitives.\"${primitive_name}\".dependencies // []" "${REGISTRY_FILE}"
        ;;
      list)
        yq -r ".primitives.\"${primitive_name}\".dependencies // [] | .[]" "${REGISTRY_FILE}"
        ;;
    esac
  fi
}

# Recursive helper for dependency resolution
get_deps_recursive() {
  local primitive_name="${1}"
  local indent="${2:-}"
  local output_format="${3:-list}"
  local visited="${4:-}"

  # Check for circular dependency
  if [[ "${visited}" == *"|${primitive_name}|"* ]]; then
    echo "${indent}${primitive_name} (CIRCULAR DEPENDENCY)" >&2
    return 1
  fi
  visited="${visited}|${primitive_name}|"

  local deps
  deps=$(yq -r ".primitives.\"${primitive_name}\".dependencies // [] | .[]" "${REGISTRY_FILE}" 2>/dev/null)

  for dep in ${deps}; do
    local dep_tier
    dep_tier=$(yq -r ".primitives.\"${dep}\".tier // \"?\"" "${REGISTRY_FILE}")

    case "${output_format}" in
      tree)
        echo "${indent}${dep} (${dep_tier})"
        get_deps_recursive "${dep}" "${indent}  " "${output_format}" "${visited}"
        ;;
      list)
        echo "${dep}"
        get_deps_recursive "${dep}" "" "${output_format}" "${visited}"
        ;;
    esac
  done
}

# --- Validate Registry ---
# Validate registry integrity
validate_registry() {
  local errors=0
  local warnings=0

  echo "Validating registry: ${REGISTRY_FILE}"
  echo ""

  # Check schema version
  local schema_version
  schema_version=$(yq -r ".schema_version // \"missing\"" "${REGISTRY_FILE}")
  if [[ "${schema_version}" == "missing" ]]; then
    echo "ERROR: Missing schema_version" >&2
    ((errors++))
  fi

  # Validate each primitive
  local primitives
  primitives=$(yq -r ".primitives | keys | .[]" "${REGISTRY_FILE}")

  for primitive in ${primitives}; do
    # Required fields
    local tier category
    tier=$(yq -r ".primitives.\"${primitive}\".tier // \"missing\"" "${REGISTRY_FILE}")
    category=$(yq -r ".primitives.\"${primitive}\".category // \"missing\"" "${REGISTRY_FILE}")

    if [[ "${tier}" == "missing" ]]; then
      echo "ERROR: ${primitive}: missing tier" >&2
      ((errors++))
    elif [[ ! "${tier}" =~ ^T[0-3]$ ]]; then
      echo "ERROR: ${primitive}: invalid tier '${tier}' (expected T0-T3)" >&2
      ((errors++))
    fi

    if [[ "${category}" == "missing" ]]; then
      echo "ERROR: ${primitive}: missing category" >&2
      ((errors++))
    fi

    # Validate dependencies exist
    local deps
    deps=$(yq -r ".primitives.\"${primitive}\".dependencies // [] | .[]" "${REGISTRY_FILE}" 2>/dev/null)

    for dep in ${deps}; do
      local dep_exists
      dep_exists=$(yq ".primitives | has(\"${dep}\")" "${REGISTRY_FILE}")
      if [[ "${dep_exists}" != "true" ]]; then
        echo "ERROR: ${primitive}: dependency '${dep}' not found in registry" >&2
        ((errors++))
      fi
    done

    # Validate reversibility primitive exists
    local rev_primitive
    rev_primitive=$(yq -r ".primitives.\"${primitive}\".reversibility.primitive // \"\"" "${REGISTRY_FILE}")
    if [[ -n "${rev_primitive}" ]]; then
      local rev_exists
      rev_exists=$(yq ".primitives | has(\"${rev_primitive}\")" "${REGISTRY_FILE}")
      if [[ "${rev_exists}" != "true" ]]; then
        echo "WARNING: ${primitive}: reversibility primitive '${rev_primitive}' not found" >&2
        ((warnings++))
      fi
    fi

    # Check path exists (if specified and not null)
    local path
    path=$(yq -r ".primitives.\"${primitive}\".path // \"null\"" "${REGISTRY_FILE}")
    if [[ "${path}" != "null" && ! -f "${REPO_ROOT}/${path}" ]]; then
      echo "WARNING: ${primitive}: script path does not exist: ${path}" >&2
      ((warnings++))
    fi
  done

  # Check for circular dependencies
  for primitive in ${primitives}; do
    if ! get_deps_recursive "${primitive}" "" "list" "" >/dev/null 2>&1; then
      echo "ERROR: Circular dependency detected involving: ${primitive}" >&2
      ((errors++))
    fi
  done

  echo ""
  echo "Validation complete: ${errors} errors, ${warnings} warnings"

  if [[ ${errors} -gt 0 ]]; then
    return 1
  fi
  return 0
}

# --- Search Primitives ---
# Search primitives by pattern
search_primitives() {
  local pattern="${1:-}"

  if [[ -z "${pattern}" ]]; then
    echo "ERROR: Search pattern required" >&2
    return 1
  fi

  # Search in name and description (case-insensitive)
  yq -r ".primitives | to_entries[] | select(.key | test(\"(?i)${pattern}\") or (.value.description // \"\" | test(\"(?i)${pattern}\"))) | .key" "${REGISTRY_FILE}"
}

# --- Compute Effective Tier ---
# Compute the effective tier for a primitive including its dependencies
compute_effective_tier() {
  local primitive_name="${1:-}"

  if [[ -z "${primitive_name}" ]]; then
    echo "ERROR: Primitive name required" >&2
    return 1
  fi

  local exists
  exists=$(yq ".primitives | has(\"${primitive_name}\")" "${REGISTRY_FILE}")

  if [[ "${exists}" != "true" ]]; then
    echo "ERROR: Primitive not found: ${primitive_name}" >&2
    return 1
  fi

  # Get own tier
  local own_tier
  own_tier=$(yq -r ".primitives.\"${primitive_name}\".tier" "${REGISTRY_FILE}")

  # Get all dependencies recursively
  local all_deps
  all_deps=$(get_dependencies "${primitive_name}" "true" "list" 2>/dev/null | sort -u)

  local max_tier="${own_tier}"

  # Find maximum tier among dependencies
  for dep in ${all_deps}; do
    local dep_tier
    dep_tier=$(yq -r ".primitives.\"${dep}\".tier // \"T0\"" "${REGISTRY_FILE}")
    # Compare tiers (T3 > T2 > T1 > T0)
    if [[ "${dep_tier}" > "${max_tier}" ]]; then
      max_tier="${dep_tier}"
    fi
  done

  echo "${max_tier}"
}

# --- Export for Action Audit ---
# Export primitive registry to format compatible with action-log.sh
export_for_audit() {
  local output_format="${1:-json}"

  case "${output_format}" in
    json)
      # Export as categories/operations format for tier-registry.json
      yq -o json '
        {
          "schema_version": .schema_version,
          "description": "Auto-generated from primitives/registry.yaml",
          "primitives": (
            .primitives | to_entries | map({
              key: .key,
              value: {
                tier: .value.tier,
                category: .value.category,
                path: .value.path,
                requires_approval: (.value.requires_approval // false)
              }
            }) | from_entries
          ),
          "categories": (
            .primitives | to_entries | group_by(.value.category) |
            map({
              key: .[0].value.category,
              value: (map({key: .key, value: .value.tier}) | from_entries)
            }) | from_entries
          ),
          "tier_definitions": .tier_definitions
        }
      ' "${REGISTRY_FILE}"
      ;;
    summary)
      echo "Primitive Registry Summary for Action Audit"
      echo "==========================================="
      echo ""
      echo "Primitives by Tier:"
      for tier in T0 T1 T2 T3; do
        local count
        count=$(yq -r ".primitives | to_entries | map(select(.value.tier == \"${tier}\")) | length" "${REGISTRY_FILE}")
        echo "  ${tier}: ${count} primitives"
      done
      echo ""
      echo "Categories:"
      yq -r '.primitives | to_entries | group_by(.value.category) | .[] | "  " + .[0].value.category + ": " + (length | tostring) + " primitives"' "${REGISTRY_FILE}"
      ;;
  esac
}

# --- Lookup by Path ---
# Find primitive by script path (for action audit integration)
lookup_by_path() {
  local script_path="${1:-}"

  if [[ -z "${script_path}" ]]; then
    echo "ERROR: Script path required" >&2
    return 1
  fi

  # Normalize path (strip leading ./ or repo root)
  script_path="${script_path#./}"
  script_path="${script_path#${REPO_ROOT}/}"

  # Find primitive with matching path
  local result
  result=$(yq -r ".primitives | to_entries[] | select(.value.path == \"${script_path}\") | .key" "${REGISTRY_FILE}" 2>/dev/null)

  if [[ -n "${result}" ]]; then
    echo "${result}"
    return 0
  else
    echo ""
    return 1
  fi
}

# --- Usage ---
usage() {
  cat <<'EOF'
Usage: primitive-registry.sh COMMAND [OPTIONS]

Query and validate the primitive registry.

Commands:
  list [OPTIONS]              List all primitives
    --tier T0|T1|T2|T3        Filter by tier
    --category CATEGORY       Filter by category
    --tag TAG                 Filter by tag
    --json                    Output as JSON

  info PRIMITIVE              Get detailed primitive information
    --json                    Output as JSON
    --verbose                 Detailed formatted output

  exists PRIMITIVE            Check if primitive exists (returns true/false)

  tier PRIMITIVE              Get tier for primitive
    --json                    Include category and approval info
    --verbose                 Detailed tier information

  effective-tier PRIMITIVE    Get effective tier (including dependencies)

  deps PRIMITIVE              Get dependencies for primitive
    --recursive               Include transitive dependencies
    --tree                    Show as tree (with --recursive)

  validate                    Validate registry integrity

  search PATTERN              Search primitives by name/description

  lookup-path SCRIPT_PATH     Find primitive by script path

  export [--json|--summary]   Export registry for action audit integration

Examples:
  primitive-registry.sh list
  primitive-registry.sh list --tier T0
  primitive-registry.sh list --category github --json
  primitive-registry.sh info get-sprint-state
  primitive-registry.sh tier create-pr --verbose
  primitive-registry.sh effective-tier create-pr
  primitive-registry.sh deps create-pr --recursive --tree
  primitive-registry.sh validate
  primitive-registry.sh search issue
  primitive-registry.sh lookup-path scripts/sprint/generate-sprint-state.sh
  primitive-registry.sh export --json > .claude/primitive-tiers.json
EOF
}

# --- Main ---
main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  check_yq
  check_registry

  local command="${1}"
  shift

  case "${command}" in
    list)
      list_primitives "$@"
      ;;
    info)
      local name="${1:-}"
      shift || true
      local format="yaml"
      while [[ $# -gt 0 ]]; do
        case "${1}" in
          --json) format="json"; shift ;;
          --verbose) format="verbose"; shift ;;
          *) shift ;;
        esac
      done
      get_primitive_info "${name}" "${format}"
      ;;
    exists)
      check_primitive_exists "${1:-}"
      ;;
    tier)
      local name="${1:-}"
      shift || true
      local format="simple"
      while [[ $# -gt 0 ]]; do
        case "${1}" in
          --json) format="json"; shift ;;
          --verbose) format="verbose"; shift ;;
          *) shift ;;
        esac
      done
      get_primitive_tier "${name}" "${format}"
      ;;
    deps)
      local name="${1:-}"
      shift || true
      local recursive="false"
      local format="list"
      while [[ $# -gt 0 ]]; do
        case "${1}" in
          --recursive) recursive="true"; shift ;;
          --tree) format="tree"; shift ;;
          --json) format="json"; shift ;;
          *) shift ;;
        esac
      done
      get_dependencies "${name}" "${recursive}" "${format}"
      ;;
    validate)
      validate_registry
      ;;
    search)
      search_primitives "${1:-}"
      ;;
    effective-tier)
      compute_effective_tier "${1:-}"
      ;;
    lookup-path)
      lookup_by_path "${1:-}"
      ;;
    export)
      local format="json"
      while [[ $# -gt 0 ]]; do
        case "${1}" in
          --json) format="json"; shift ;;
          --summary) format="summary"; shift ;;
          *) shift ;;
        esac
      done
      export_for_audit "${format}"
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "ERROR: Unknown command: ${command}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
