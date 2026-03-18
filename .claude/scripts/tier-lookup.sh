#!/usr/bin/env bash
# tier-lookup.sh - Look up permission tier for commands/operations
# Part of Issue #225 - Tier-based auto-approval mechanism
#
# Usage:
#   tier-lookup.sh --command "gh issue close 123"
#   tier-lookup.sh --category github --operation issue.close
#   tier-lookup.sh --list-categories
#   tier-lookup.sh --list-patterns

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${TIER_LOOKUP_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REGISTRY_FILE="${TIER_REGISTRY_FILE:-${REPO_ROOT}/.claude/tier-registry.json}"

# --- Tier Lookup Functions ---

# Lookup tier by category and operation (e.g., github/issue.close)
lookup_by_category() {
  local category="${1}"
  local operation="${2}"

  if [[ ! -f "${REGISTRY_FILE}" ]]; then
    echo ""
    return
  fi

  jq -r --arg cat "${category}" --arg op "${operation}" \
    '.categories[$cat][$op] // empty' "${REGISTRY_FILE}" 2>/dev/null
}

# Lookup tier by matching command against patterns
lookup_by_command() {
  local command="${1}"

  if [[ ! -f "${REGISTRY_FILE}" ]]; then
    echo ""
    return
  fi

  # Match against command_patterns with safe regex handling
  jq -r --arg cmd "${command}" '
    [.command_patterns[] | . as $p |
      try (if ($cmd | test($p.pattern)) then
        {tier: $p.tier, category: $p.category, operation: $p.operation}
      else empty end)
      catch empty
    ] | first // empty
  ' "${REGISTRY_FILE}" 2>/dev/null
}

# Main lookup function - tries patterns first, then returns default
tier_lookup() {
  local command="${1:-}"
  local category="${2:-}"
  local operation="${3:-}"
  local output_format="${4:-simple}"  # simple, json, verbose

  local tier=""
  local source="unknown"
  local matched_category=""
  local matched_operation=""

  # 1. If command provided, try pattern matching first
  if [[ -n "${command}" ]]; then
    local pattern_result
    pattern_result=$(lookup_by_command "${command}")
    if [[ -n "${pattern_result}" && "${pattern_result}" != "null" ]]; then
      tier=$(echo "${pattern_result}" | jq -r '.tier // empty')
      matched_category=$(echo "${pattern_result}" | jq -r '.category // empty')
      matched_operation=$(echo "${pattern_result}" | jq -r '.operation // empty')
      source="pattern"
    fi
  fi

  # 2. If category+operation provided or derived from pattern, do registry lookup
  if [[ -z "${tier}" ]]; then
    local lookup_cat="${category:-${matched_category}}"
    local lookup_op="${operation:-${matched_operation}}"

    if [[ -n "${lookup_cat}" && -n "${lookup_op}" ]]; then
      tier=$(lookup_by_category "${lookup_cat}" "${lookup_op}")
      if [[ -n "${tier}" ]]; then
        source="registry"
        matched_category="${lookup_cat}"
        matched_operation="${lookup_op}"
      fi
    fi
  fi

  # 3. Default to T2 if not found (safe default - requires session-once approval)
  if [[ -z "${tier}" ]]; then
    tier="T2"
    source="default"
  fi

  # Output based on format
  case "${output_format}" in
    simple)
      echo "${tier}"
      ;;
    json)
      jq -cn \
        --arg tier "${tier}" \
        --arg source "${source}" \
        --arg category "${matched_category:-${category}}" \
        --arg operation "${matched_operation:-${operation}}" \
        --arg command "${command}" \
        '{
          tier: $tier,
          source: $source,
          category: (if $category == "" then null else $category end),
          operation: (if $operation == "" then null else $operation end),
          command: (if $command == "" then null else $command end)
        }'
      ;;
    verbose)
      echo "Tier: ${tier}"
      echo "Source: ${source}"
      [[ -n "${matched_category:-${category}}" ]] && echo "Category: ${matched_category:-${category}}"
      [[ -n "${matched_operation:-${operation}}" ]] && echo "Operation: ${matched_operation:-${operation}}"
      ;;
    *)
      echo "ERROR: Unknown format '${output_format}'" >&2
      return 1
      ;;
  esac
}

# List all categories in the registry
list_categories() {
  if [[ ! -f "${REGISTRY_FILE}" ]]; then
    echo "Registry file not found: ${REGISTRY_FILE}" >&2
    return 1
  fi

  jq -r '.categories | keys[]' "${REGISTRY_FILE}"
}

# List all operations in a category
list_operations() {
  local category="${1}"

  if [[ ! -f "${REGISTRY_FILE}" ]]; then
    echo "Registry file not found: ${REGISTRY_FILE}" >&2
    return 1
  fi

  jq -r --arg cat "${category}" \
    '.categories[$cat] | to_entries[] | "\(.key): \(.value)"' "${REGISTRY_FILE}"
}

# List all command patterns
list_patterns() {
  if [[ ! -f "${REGISTRY_FILE}" ]]; then
    echo "Registry file not found: ${REGISTRY_FILE}" >&2
    return 1
  fi

  jq -r '.command_patterns[] | "\(.tier) \(.category)/\(.operation): \(.pattern)"' "${REGISTRY_FILE}"
}

# Get tier description
get_tier_info() {
  local tier="${1}"

  case "${tier}" in
    T0) echo "T0 - Read-Only (No Risk): Auto-approve" ;;
    T1) echo "T1 - Safe Write (Low Risk): Auto-approve" ;;
    T2) echo "T2 - Reversible Write (Medium Risk): Session-once prompt" ;;
    T3) echo "T3 - Destructive (High Risk): Always prompt" ;;
    *) echo "Unknown tier: ${tier}" >&2; return 1 ;;
  esac
}

# --- Usage ---

usage() {
  cat <<'EOF'
Usage: tier-lookup.sh [OPTIONS]

Look up permission tier for commands/operations.

Lookup modes:
  --command CMD          Look up tier by matching command pattern
  --category CAT         Category for registry lookup (with --operation)
  --operation OP         Operation for registry lookup (with --category)

Output formats:
  --format FORMAT        Output format: simple (default), json, verbose

List operations:
  --list-categories      List all categories in the registry
  --list-ops CATEGORY    List all operations in a category
  --list-patterns        List all command patterns

Info:
  --tier-info TIER       Get description for a tier (T0|T1|T2|T3)
  --registry-file        Print registry file path
  -h, --help             Show this help

Examples:
  tier-lookup.sh --command "gh issue close 123"
  tier-lookup.sh --command "git push" --format json
  tier-lookup.sh --category github --operation issue.close
  tier-lookup.sh --list-categories
  tier-lookup.sh --tier-info T2

Return codes:
  0 - Success
  1 - Error (missing file, invalid input)
EOF
}

# --- Main ---

main() {
  local command="" category="" operation=""
  local format="simple"
  local mode="lookup"

  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --command)
        command="${2}"
        shift 2
        ;;
      --category)
        category="${2}"
        shift 2
        ;;
      --operation)
        operation="${2}"
        shift 2
        ;;
      --format)
        format="${2}"
        shift 2
        ;;
      --list-categories)
        mode="list-categories"
        shift
        ;;
      --list-ops)
        mode="list-ops"
        category="${2}"
        shift 2
        ;;
      --list-patterns)
        mode="list-patterns"
        shift
        ;;
      --tier-info)
        get_tier_info "${2}"
        exit $?
        ;;
      --registry-file)
        echo "${REGISTRY_FILE}"
        exit 0
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

  case "${mode}" in
    lookup)
      if [[ -z "${command}" && ( -z "${category}" || -z "${operation}" ) ]]; then
        echo "ERROR: Provide --command or both --category and --operation" >&2
        exit 1
      fi
      tier_lookup "${command}" "${category}" "${operation}" "${format}"
      ;;
    list-categories)
      list_categories
      ;;
    list-ops)
      if [[ -z "${category}" ]]; then
        echo "ERROR: --list-ops requires a category" >&2
        exit 1
      fi
      list_operations "${category}"
      ;;
    list-patterns)
      list_patterns
      ;;
    *)
      echo "ERROR: Unknown mode '${mode}'" >&2
      exit 1
      ;;
  esac
}

main "$@"
