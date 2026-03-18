#!/usr/bin/env bash
# Purpose: Validate n8n workflow JSON files for structural correctness
# size-ok: multi-check validator for connections, credentials, data flow, and version compatibility
# Usage: ./scripts/validate-n8n-workflows.sh [OPTIONS] [FILES...]
#
# Options:
#   --check-connections    Validate node connections reference valid nodes
#   --check-credentials   Validate credential references are not hardcoded
#   --check-data-flow     Alias for --check-connections (validates data flow)
#   --check-version       Check workflow version compatibility
#   --all                 Run all validation checks (default behavior)
#   --schema PATH         Path to JSON schema file (default: schemas/n8n-workflow.schema.json)
#   --report              Generate summary report to stdout
#   --quiet               Suppress non-error output
#   --exclude PATTERN     Exclude files matching pattern (e.g., 'test-fixtures')
#   --help                Show this help message
#
# If no files specified, validates all JSON files in n8n-workflows/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Defaults
CHECK_CONNECTIONS=false
CHECK_CREDENTIALS=false
CHECK_VERSION=false
SCHEMA_PATH="$REPO_ROOT/schemas/n8n-workflow.schema.json"
EXCLUDE_PATTERN=""
REPORT=false
QUIET=false
FILES=()
ERRORS=0
WARNINGS=0

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
  exit 0
}

# Override log functions to track counts
log_error() {
  echo -e "${RED:-}ERROR:${NC:-} $1" >&2
  ERRORS=$((ERRORS + 1))
}

log_warn() {
  if [ "$QUIET" = false ]; then
    echo -e "${YELLOW:-}WARN:${NC:-} $1" >&2
  fi
  WARNINGS=$((WARNINGS + 1))
}

log_info() {
  if [ "$QUIET" = false ]; then
    echo -e "${GREEN:-}OK:${NC:-} $1"
  fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-connections|--check-data-flow) CHECK_CONNECTIONS=true; shift ;;
    --check-credentials) CHECK_CREDENTIALS=true; shift ;;
    --check-version) CHECK_VERSION=true; shift ;;
    --all) CHECK_CONNECTIONS=true; CHECK_CREDENTIALS=true; CHECK_VERSION=true; shift ;;
    --schema) SCHEMA_PATH="$2"; shift 2 ;;
    --exclude) EXCLUDE_PATTERN="$2"; shift 2 ;;
    --report) REPORT=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --help|-h) usage ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

# If no files specified, find all workflow files
if [ ${#FILES[@]} -eq 0 ]; then
  if [ -d "$REPO_ROOT/n8n-workflows" ]; then
    while IFS= read -r -d '' f; do
      # Apply exclude pattern if specified
      if [ -n "$EXCLUDE_PATTERN" ] && echo "$f" | grep -q "$EXCLUDE_PATTERN"; then
        continue
      fi
      FILES+=("$f")
    done < <(find "$REPO_ROOT/n8n-workflows" -name "*.json" -type f -not -path "*/test-fixtures/*" -print0)
  fi
fi

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No workflow files found to validate."
  exit 0
fi

# Check for required tools
check_tool() {
  if ! command -v "$1" &>/dev/null; then
    echo "Required tool not found: $1" >&2
    return 1
  fi
}

check_tool jq || exit 1

# ============================================================
# Validation 1: JSON Syntax
# ============================================================
validate_json_syntax() {
  local file="$1"
  if ! jq empty "$file" 2>/dev/null; then
    log_error "$file: Invalid JSON syntax"
    return 1
  fi
  log_info "$file: Valid JSON syntax"
  return 0
}

# ============================================================
# Validation 2: Schema Structure (basic checks without ajv)
# ============================================================
validate_schema_structure() {
  local file="$1"
  local has_errors=0

  # Check required top-level fields
  local name
  name=$(jq -r '.name // empty' "$file")
  if [ -z "$name" ]; then
    log_error "$file: Missing required field 'name'"
    has_errors=1
  fi

  local nodes_count
  nodes_count=$(jq '.nodes | length' "$file" 2>/dev/null || echo 0)
  if [ "$nodes_count" -eq 0 ]; then
    log_error "$file: 'nodes' array is empty or missing"
    has_errors=1
  fi

  local has_connections
  has_connections=$(jq 'has("connections")' "$file" 2>/dev/null || echo false)
  if [ "$has_connections" != "true" ]; then
    log_error "$file: Missing required field 'connections'"
    has_errors=1
  fi

  # Validate each node has required fields
  local invalid_nodes
  invalid_nodes=$(jq '[.nodes[] | select(.name == null or .type == null or .position == null or .parameters == null)] | length' "$file" 2>/dev/null || echo 0)
  if [ "$invalid_nodes" -gt 0 ]; then
    log_error "$file: $invalid_nodes node(s) missing required fields (name, type, position, parameters)"
    has_errors=1
  fi

  # Validate node type prefix
  local bad_types
  bad_types=$(jq '[.nodes[] | select(.type != null and (.type | startswith("n8n-nodes-") | not))] | length' "$file" 2>/dev/null || echo 0)
  if [ "$bad_types" -gt 0 ]; then
    log_warn "$file: $bad_types node(s) have non-standard type prefix (expected 'n8n-nodes-*')"
  fi

  # Validate node names are unique
  local total_names
  total_names=$(jq '[.nodes[].name] | length' "$file" 2>/dev/null || echo 0)
  local unique_names
  unique_names=$(jq '[.nodes[].name] | unique | length' "$file" 2>/dev/null || echo 0)
  if [ "$total_names" -ne "$unique_names" ]; then
    log_error "$file: Duplicate node names detected ($total_names total, $unique_names unique)"
    has_errors=1
  fi

  if [ "$has_errors" -eq 0 ]; then
    log_info "$file: Schema structure valid"
  fi
  return $has_errors
}

# ============================================================
# Validation 3: Node Connections
# ============================================================
validate_connections() {
  local file="$1"
  local has_errors=0

  # Get list of node names
  local node_names
  node_names=$(jq -r '[.nodes[].name] | .[]' "$file" 2>/dev/null)

  # Check that connection source nodes exist
  local connection_sources
  connection_sources=$(jq -r '.connections | keys[]' "$file" 2>/dev/null)

  while IFS= read -r source; do
    [ -z "$source" ] && continue
    if ! echo "$node_names" | grep -qF "$source"; then
      log_error "$file: Connection source '$source' is not a valid node name"
      has_errors=1
    fi
  done <<< "$connection_sources"

  # Check that connection target nodes exist
  local target_nodes
  target_nodes=$(jq -r '[.connections | to_entries[].value | to_entries[].value[][] | .node] | unique | .[]' "$file" 2>/dev/null)

  while IFS= read -r target; do
    [ -z "$target" ] && continue
    if ! echo "$node_names" | grep -qF "$target"; then
      log_error "$file: Connection target '$target' is not a valid node name"
      has_errors=1
    fi
  done <<< "$target_nodes"

  # Check for orphaned nodes (no connections in or out, except triggers)
  local trigger_count
  trigger_count=$(jq '[.nodes[] | select(.type | test("trigger|webhook|schedule|cron"; "i"))] | length' "$file" 2>/dev/null || echo 0)

  local connected_nodes
  connected_nodes=$(jq -r '([.connections | keys[]] + [.connections | to_entries[].value | to_entries[].value[][] | .node]) | unique | .[]' "$file" 2>/dev/null)

  while IFS= read -r node_name; do
    [ -z "$node_name" ] && continue
    local node_type
    node_type=$(jq -r --arg name "$node_name" '.nodes[] | select(.name == $name) | .type' "$file" 2>/dev/null)

    # Skip trigger nodes (they start flows, no incoming connections expected)
    if echo "$node_type" | grep -qi "trigger\|webhook\|schedule\|cron"; then
      continue
    fi

    if ! echo "$connected_nodes" | grep -qF "$node_name"; then
      log_warn "$file: Node '$node_name' appears orphaned (no connections)"
    fi
  done <<< "$(jq -r '.nodes[].name' "$file" 2>/dev/null)"

  if [ "$has_errors" -eq 0 ]; then
    log_info "$file: Node connections valid"
  fi
  return $has_errors
}

# ============================================================
# Validation 4: Credential References
# ============================================================
validate_credentials() {
  local file="$1"
  local has_errors=0

  # Check for hardcoded credentials in parameters
  local hardcoded
  hardcoded=$(jq -r '
    [.nodes[].parameters | objects | to_entries[] |
      select(.key | test("password|secret|token|apiKey|api_key|apiSecret|api_secret"; "i")) |
      select(.value | type == "string" and length > 0 and (startswith("={{") | not))
    ] | length
  ' "$file" 2>/dev/null || echo 0)

  if [ "$hardcoded" -gt 0 ]; then
    log_error "$file: $hardcoded potential hardcoded credential(s) found in node parameters"
    has_errors=1
  fi

  # Check credential references have both id and name
  local invalid_creds
  invalid_creds=$(jq '
    [.nodes[] | select(.credentials != null) | .credentials | to_entries[] |
      select(.value.id == null or .value.name == null)
    ] | length
  ' "$file" 2>/dev/null || echo 0)

  if [ "$invalid_creds" -gt 0 ]; then
    log_error "$file: $invalid_creds credential reference(s) missing 'id' or 'name'"
    has_errors=1
  fi

  # Check for empty credential IDs
  local empty_cred_ids
  empty_cred_ids=$(jq '
    [.nodes[] | select(.credentials != null) | .credentials | to_entries[] |
      select(.value.id == "" or .value.id == "0")
    ] | length
  ' "$file" 2>/dev/null || echo 0)

  if [ "$empty_cred_ids" -gt 0 ]; then
    log_warn "$file: $empty_cred_ids credential reference(s) with empty/zero ID (may be placeholder)"
  fi

  if [ "$has_errors" -eq 0 ]; then
    log_info "$file: Credential references valid"
  fi
  return $has_errors
}

# ============================================================
# Validation 5: Version Compatibility
# ============================================================
validate_version() {
  local file="$1"

  # Check for deprecated node types
  local deprecated_nodes
  deprecated_nodes=$(jq -r '
    [.nodes[] | select(.type |
      test("n8n-nodes-base\\.function$|n8n-nodes-base\\.merge$"; "")
    )] | length
  ' "$file" 2>/dev/null || echo 0)

  if [ "$deprecated_nodes" -gt 0 ]; then
    log_warn "$file: $deprecated_nodes deprecated node type(s) found (consider upgrading)"
  fi

  # Check execution order version
  local exec_order
  exec_order=$(jq -r '.settings.executionOrder // "v1"' "$file" 2>/dev/null)
  if [ "$exec_order" = "v0" ]; then
    log_warn "$file: Uses legacy execution order (v0). Consider upgrading to v1."
  fi

  # Check for nodes with very old typeVersion
  local old_versions
  old_versions=$(jq '
    [.nodes[] | select(.typeVersion != null and .typeVersion < 1)] | length
  ' "$file" 2>/dev/null || echo 0)

  if [ "$old_versions" -gt 0 ]; then
    log_warn "$file: $old_versions node(s) with typeVersion < 1 (may need upgrade)"
  fi

  log_info "$file: Version compatibility check complete"
  return 0
}

# ============================================================
# Main validation loop
# ============================================================
VALIDATED=0
FAILED=0

for file in "${FILES[@]}"; do
  if [ ! -f "$file" ]; then
    log_error "File not found: $file"
    FAILED=$((FAILED + 1))
    continue
  fi

  file_errors=0

  # Always run JSON syntax check
  validate_json_syntax "$file" || { FAILED=$((FAILED + 1)); continue; }

  # Always run schema structure check
  validate_schema_structure "$file" || file_errors=1

  # Connection validation (always runs unless specific checks requested)
  if [ "$CHECK_CONNECTIONS" = true ] || { [ "$CHECK_CREDENTIALS" = false ] && [ "$CHECK_VERSION" = false ]; }; then
    validate_connections "$file" || file_errors=1
  fi

  # Credential validation (always runs unless specific checks requested)
  if [ "$CHECK_CREDENTIALS" = true ] || { [ "$CHECK_CONNECTIONS" = false ] && [ "$CHECK_VERSION" = false ]; }; then
    validate_credentials "$file" || file_errors=1
  fi

  # Version compatibility (always runs unless specific checks requested)
  if [ "$CHECK_VERSION" = true ] || { [ "$CHECK_CONNECTIONS" = false ] && [ "$CHECK_CREDENTIALS" = false ]; }; then
    validate_version "$file" || file_errors=1
  fi

  if [ "$file_errors" -eq 0 ]; then
    VALIDATED=$((VALIDATED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done

# ============================================================
# Report
# ============================================================
if [ "$REPORT" = true ] || [ "$QUIET" = false ]; then
  echo ""
  echo "=== n8n Workflow Validation Summary ==="
  echo "Files checked: ${#FILES[@]}"
  echo "Passed: $VALIDATED"
  echo "Failed: $FAILED"
  echo "Errors: $ERRORS"
  echo "Warnings: $WARNINGS"
  echo "======================================="
fi

if [ "$FAILED" -gt 0 ] || [ "$ERRORS" -gt 0 ]; then
  exit 1
fi

exit 0
