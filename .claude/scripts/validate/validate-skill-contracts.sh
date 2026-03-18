#!/usr/bin/env bash
# validate-skill-contracts.sh - Validate skill contract definitions
# Part of #220 - Skill Contract Schema
#
# Usage:
#   ./scripts/validate-skill-contracts.sh <contract.yaml>           # Validate single contract
#   ./scripts/validate-skill-contracts.sh --all                     # Validate all contracts
#   ./scripts/validate-skill-contracts.sh --chain <chain.yaml>      # Validate chain compatibility
#   ./scripts/validate-skill-contracts.sh --validate-output <skill> # Validate runtime output
#
# Exit codes:
#   0 - Validation passed
#   1 - Validation failed
#   2 - Usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACTS_DIR="$REPO_ROOT/contracts"
TYPES_DIR="$CONTRACTS_DIR/types"
SKILLS_DIR="$CONTRACTS_DIR/skills"
SCHEMA_FILE="$CONTRACTS_DIR/schema.json"

# Track validation results
ERRORS=0
WARNINGS=0

log_error() {
  echo -e "${RED}ERROR:${NC} $1" >&2
  echo "error" >> /tmp/validate-errors-$$
}

log_warning() {
  echo -e "${YELLOW}WARNING:${NC} $1" >&2
  echo "warning" >> /tmp/validate-warnings-$$
}

cleanup_counts() {
  rm -f /tmp/validate-errors-$$ /tmp/validate-warnings-$$
}

get_error_count() {
  if [[ -f /tmp/validate-errors-$$ ]]; then
    wc -l < /tmp/validate-errors-$$ | tr -d ' '
  else
    echo "0"
  fi
}

get_warning_count() {
  if [[ -f /tmp/validate-warnings-$$ ]]; then
    wc -l < /tmp/validate-warnings-$$ | tr -d ' '
  else
    echo "0"
  fi
}

log_success() {
  echo -e "${GREEN}✓${NC} $1"
}

log_info() {
  echo -e "  $1"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [CONTRACT_FILE]

Validate skill contract definitions against the schema.

Options:
  -h, --help            Show this help message
  --all                 Validate all contracts in contracts/skills/
  --chain FILE          Validate chain definition for compatibility
  --validate-output SKILL  Validate piped JSON against skill's output contract
  --types               Validate only type definitions
  --verbose             Show detailed validation info

Examples:
  $(basename "$0") contracts/skills/sprint-status.contract.yaml
  $(basename "$0") --all
  $(basename "$0") --chain contracts/chains/sprint-workflow.chain.yaml
  cat output.json | $(basename "$0") --validate-output pm-triage
EOF
  exit 2
}

# Check if required tools are available
check_dependencies() {
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed. Install with: brew install jq"
    exit 2
  fi

  # yq is optional - we can use Python as fallback
  if command -v yq &>/dev/null; then
    YAML_PARSER="yq"
  elif command -v python3 &>/dev/null; then
    # Check if PyYAML is available
    if python3 -c "import yaml" 2>/dev/null; then
      YAML_PARSER="python"
    else
      YAML_PARSER="basic"
      log_warning "yq not installed and PyYAML not available. Using basic validation only."
      log_info "Install yq for full validation: brew install yq"
    fi
  else
    YAML_PARSER="basic"
    log_warning "yq not installed. Using basic validation only."
    log_info "Install yq for full validation: brew install yq"
  fi
}

# Parse YAML to JSON using available parser
yaml_to_json() {
  local file="$1"
  case "$YAML_PARSER" in
    yq)
      yq -o=json '.' "$file"
      ;;
    python)
      python3 -c "
import yaml
import json
import sys
with open('$file', 'r') as f:
    data = yaml.safe_load(f)
    print(json.dumps(data))
"
      ;;
    basic)
      # Basic fallback - just check file is readable
      echo "{}"
      ;;
  esac
}

# Get YAML value using available parser
yaml_get() {
  local file="$1"
  local path="$2"
  case "$YAML_PARSER" in
    yq)
      yq -r "$path // empty" "$file" 2>/dev/null || echo ""
      ;;
    python)
      python3 -c "
import yaml
import sys
with open('$file', 'r') as f:
    data = yaml.safe_load(f)
    # Simple path parsing (supports .key syntax)
    path = '$path'.lstrip('.')
    keys = path.split('.')
    val = data
    try:
        for key in keys:
            if key and val:
                val = val.get(key)
        print(val if val else '')
    except:
        print('')
" 2>/dev/null || echo ""
      ;;
    basic)
      # Basic grep-based extraction for simple keys
      grep -E "^${path#.}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*: *//' | tr -d '"' || echo ""
      ;;
  esac
}

# Validate YAML syntax
validate_yaml_syntax() {
  local file="$1"
  case "$YAML_PARSER" in
    yq)
      if ! yq '.' "$file" >/dev/null 2>&1; then
        log_error "Invalid YAML syntax in $file"
        return 1
      fi
      ;;
    python)
      if ! python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
        log_error "Invalid YAML syntax in $file"
        return 1
      fi
      ;;
    basic)
      # Basic check - file is readable and has content
      if [[ ! -s "$file" ]]; then
        log_error "Empty or unreadable file: $file"
        return 1
      fi
      ;;
  esac
  return 0
}

# Check required fields exist
validate_required_fields() {
  local file="$1"
  local skill version

  skill=$(yaml_get "$file" ".skill")
  version=$(yaml_get "$file" ".version")

  if [[ -z "$skill" ]]; then
    log_error "Missing required field 'skill' in $file"
    return 1
  fi

  if [[ -z "$version" ]]; then
    log_error "Missing required field 'version' in $file"
    return 1
  fi

  # Validate version format (semver)
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]]; then
    log_error "Invalid version format '$version' in $file (expected semver)"
    return 1
  fi

  return 0
}

# Validate type references
validate_type_references() {
  local file="$1"
  local imports types_used

  # Skip detailed validation in basic mode
  if [[ "$YAML_PARSER" == "basic" ]]; then
    log_info "Skipping type reference validation (requires yq or PyYAML)"
    return 0
  fi

  # Get imported namespaces
  if [[ "$YAML_PARSER" == "yq" ]]; then
    imports=$(yq -r '.imports // [] | .[]' "$file" 2>/dev/null || echo "")
  else
    imports=$(python3 -c "
import yaml
with open('$file') as f:
    data = yaml.safe_load(f)
    for i in (data.get('imports') or []):
        print(i)
" 2>/dev/null || echo "")
  fi

  # Extract all type references from inputs, outputs, and custom types
  if [[ "$YAML_PARSER" == "yq" ]]; then
    types_used=$(yq -r '
      [
        (.inputs // {} | .. | select(type == "string") | select(test("\\."))) // [],
        (.outputs // {} | .. | select(type == "string") | select(test("\\."))) // [],
        (.types // {} | .. | select(type == "string") | select(test("\\."))) // []
      ] | flatten | unique | .[]
    ' "$file" 2>/dev/null || echo "")
  else
    # Python fallback - simpler extraction
    types_used=$(python3 -c "
import yaml
import re
with open('$file') as f:
    content = f.read()
    # Find patterns like 'namespace.TypeName'
    matches = re.findall(r'\\b(common|github|git)\\.\\w+', content)
    for m in set(matches):
        print(m)
" 2>/dev/null || echo "")
  fi

  # Check each namespaced type reference
  for type_ref in $types_used; do
    namespace=$(echo "$type_ref" | cut -d. -f1)

    # Skip if it's a primitive type pattern (not a namespace)
    if [[ "$namespace" =~ ^(string|number|integer|boolean|null|object|array|map)$ ]]; then
      continue
    fi

    # Check if namespace is imported
    if ! echo "$imports" | grep -q "^${namespace}$"; then
      log_warning "Type '$type_ref' uses namespace '$namespace' which is not imported in $file"
    fi

    # Check if type definition file exists
    type_file="$TYPES_DIR/${namespace}.yaml"
    if [[ ! -f "$type_file" ]]; then
      log_error "Type namespace '$namespace' referenced but $type_file not found"
    fi
  done

  return 0
}

# Validate input parameters
validate_inputs() {
  local file="$1"
  local input_count

  # Skip detailed validation in basic mode
  if [[ "$YAML_PARSER" == "basic" ]]; then
    log_info "Skipping input validation (requires yq or PyYAML)"
    return 0
  fi

  if [[ "$YAML_PARSER" == "yq" ]]; then
    input_count=$(yq '.inputs | length' "$file" 2>/dev/null || echo "0")
  else
    input_count=$(python3 -c "
import yaml
with open('$file') as f:
    data = yaml.safe_load(f)
    print(len(data.get('inputs') or {}))
" 2>/dev/null || echo "0")
  fi

  if [[ "$input_count" -eq 0 ]]; then
    log_info "No inputs defined (this may be intentional)"
    return 0
  fi

  # Check each input has required fields
  local inputs_json
  inputs_json=$(yaml_to_json "$file" | jq '.inputs // {}')

  echo "$inputs_json" | jq -r 'keys[]' | while read -r param_name; do
    local param_type param_required param_desc

    param_type=$(echo "$inputs_json" | jq -r ".\"$param_name\".type // empty")
    param_required=$(echo "$inputs_json" | jq -r ".\"$param_name\".required // empty")
    param_desc=$(echo "$inputs_json" | jq -r ".\"$param_name\".description // empty")

    if [[ -z "$param_type" ]]; then
      log_error "Input '$param_name' missing 'type' in $file"
    fi

    if [[ -z "$param_required" ]]; then
      log_warning "Input '$param_name' missing 'required' field in $file"
    fi

    if [[ -z "$param_desc" ]]; then
      log_warning "Input '$param_name' missing 'description' in $file"
    fi
  done

  return 0
}

# Validate output fields
validate_outputs() {
  local file="$1"
  local output_count

  # Skip detailed validation in basic mode
  if [[ "$YAML_PARSER" == "basic" ]]; then
    log_info "Skipping output validation (requires yq or PyYAML)"
    return 0
  fi

  if [[ "$YAML_PARSER" == "yq" ]]; then
    output_count=$(yq '.outputs | length' "$file" 2>/dev/null || echo "0")
  else
    output_count=$(python3 -c "
import yaml
with open('$file') as f:
    data = yaml.safe_load(f)
    print(len(data.get('outputs') or {}))
" 2>/dev/null || echo "0")
  fi

  if [[ "$output_count" -eq 0 ]]; then
    log_warning "No outputs defined in $file"
    return 0
  fi

  # Check each output has required fields
  local outputs_json
  outputs_json=$(yaml_to_json "$file" | jq '.outputs // {}')

  echo "$outputs_json" | jq -r 'keys[]' | while read -r field_name; do
    local field_type field_desc

    field_type=$(echo "$outputs_json" | jq -r ".\"$field_name\".type // empty")
    field_desc=$(echo "$outputs_json" | jq -r ".\"$field_name\".description // empty")

    if [[ -z "$field_type" ]]; then
      log_error "Output '$field_name' missing 'type' in $file"
    fi

    if [[ -z "$field_desc" ]]; then
      log_warning "Output '$field_name' missing 'description' in $file"
    fi
  done

  return 0
}

# Validate a single contract file
validate_contract() {
  local file="$1"
  local filename
  filename=$(basename "$file")

  echo "Validating: $filename"

  # Check file exists
  if [[ ! -f "$file" ]]; then
    log_error "File not found: $file"
    return 1
  fi

  # Validate YAML syntax
  validate_yaml_syntax "$file" || return 1

  # Validate required fields
  validate_required_fields "$file"

  # Validate type references
  validate_type_references "$file"

  # Validate inputs
  validate_inputs "$file"

  # Validate outputs
  validate_outputs "$file"

  # Summary for this file
  local err_count
  err_count=$(get_error_count)
  if [[ "$err_count" -eq 0 ]]; then
    log_success "$filename passed validation"
  fi
}

# Validate all contracts
validate_all() {
  echo "Validating all contracts in $SKILLS_DIR..."
  echo ""

  if [[ ! -d "$SKILLS_DIR" ]]; then
    log_error "Skills directory not found: $SKILLS_DIR"
    return 1
  fi

  local contract_files
  contract_files=$(find "$SKILLS_DIR" -name "*.contract.yaml" 2>/dev/null || true)

  if [[ -z "$contract_files" ]]; then
    log_warning "No contract files found in $SKILLS_DIR"
    return 0
  fi

  for file in $contract_files; do
    validate_contract "$file"
    echo ""
  done

  # Also validate type definitions
  echo "Validating type definitions in $TYPES_DIR..."
  for type_file in "$TYPES_DIR"/*.yaml; do
    if [[ -f "$type_file" ]]; then
      echo "Validating: $(basename "$type_file")"
      validate_yaml_syntax "$type_file"
      log_success "$(basename "$type_file") passed syntax check"
    fi
  done
}

# Validate chain compatibility
validate_chain() {
  local chain_file="$1"

  echo "Validating chain: $(basename "$chain_file")"

  if [[ ! -f "$chain_file" ]]; then
    log_error "Chain file not found: $chain_file"
    return 1
  fi

  # Validate YAML syntax
  validate_yaml_syntax "$chain_file" || return 1

  # Get chain metadata
  local chain_name
  chain_name=$(yaml_get "$chain_file" ".chain")

  if [[ -z "$chain_name" ]]; then
    log_error "Missing 'chain' field in chain definition"
    return 1
  fi

  # Validate each step
  local steps_count
  if [[ "$YAML_PARSER" == "yq" ]]; then
    steps_count=$(yq '.steps | length' "$chain_file")
  elif [[ "$YAML_PARSER" == "python" ]]; then
    steps_count=$(python3 -c "
import yaml
with open('$chain_file') as f:
    data = yaml.safe_load(f)
    print(len(data.get('steps') or []))
" 2>/dev/null || echo "0")
  else
    steps_count=$(grep -c "^  - id:" "$chain_file" 2>/dev/null || echo "0")
  fi

  if [[ "$steps_count" -eq 0 ]]; then
    log_error "Chain has no steps defined"
    return 1
  fi

  echo "  Chain: $chain_name ($steps_count steps)"

  # Skip detailed step validation in basic mode
  if [[ "$YAML_PARSER" == "basic" ]]; then
    log_info "Skipping detailed step validation (requires yq or PyYAML)"
    return 0
  fi

  # Check each step references a valid skill
  local steps_json
  steps_json=$(yaml_to_json "$chain_file" | jq '.steps')

  echo "$steps_json" | jq -c '.[]' | while read -r step; do
    local step_id skill_name contract_file

    step_id=$(echo "$step" | jq -r '.id')
    skill_name=$(echo "$step" | jq -r '.skill')

    # Check skill contract exists
    contract_file="$SKILLS_DIR/${skill_name}.contract.yaml"
    if [[ ! -f "$contract_file" ]]; then
      log_error "Step '$step_id' references skill '$skill_name' but contract not found: $contract_file"
      continue
    fi

    log_info "Step '$step_id': skill '$skill_name' ✓"

    # TODO: Validate input/output bindings are type-compatible
    # This would require parsing JSONPath expressions and matching types
    # For now, just verify the contract exists
  done

  local err_count
  err_count=$(get_error_count)
  if [[ "$err_count" -eq 0 ]]; then
    log_success "Chain '$chain_name' passed compatibility check"
  fi
}

# Validate runtime output against contract
validate_output() {
  local skill_name="$1"
  local contract_file="$SKILLS_DIR/${skill_name}.contract.yaml"

  if [[ ! -f "$contract_file" ]]; then
    log_error "Contract not found for skill '$skill_name': $contract_file"
    return 1
  fi

  # Read JSON from stdin
  local output_json
  if ! output_json=$(cat); then
    log_error "Failed to read JSON from stdin"
    return 1
  fi

  # Validate JSON syntax
  if ! echo "$output_json" | jq '.' >/dev/null 2>&1; then
    log_error "Invalid JSON provided"
    return 1
  fi

  echo "Validating output against $skill_name contract..."

  # Get expected output fields
  local expected_outputs
  expected_outputs=$(yaml_to_json "$contract_file" | jq '.outputs // {}')

  # Check each expected field exists in output
  echo "$expected_outputs" | jq -r 'keys[]' | while read -r field_name; do
    local field_nullable
    field_nullable=$(echo "$expected_outputs" | jq -r ".\"$field_name\".nullable // false")

    # Check if field exists in output
    if echo "$output_json" | jq -e ".\"$field_name\"" >/dev/null 2>&1; then
      local field_value
      field_value=$(echo "$output_json" | jq -r ".\"$field_name\"")

      if [[ "$field_value" == "null" ]] && [[ "$field_nullable" == "false" ]]; then
        log_warning "Field '$field_name' is null but not marked nullable"
      else
        log_info "Field '$field_name': present ✓"
      fi
    else
      if [[ "$field_nullable" == "true" ]]; then
        log_info "Field '$field_name': absent (nullable) ✓"
      else
        log_error "Required field '$field_name' missing from output"
      fi
    fi
  done

  local err_count
  err_count=$(get_error_count)
  if [[ "$err_count" -eq 0 ]]; then
    log_success "Output matches $skill_name contract"
  fi
}

# Main
main() {
  cleanup_counts
  trap cleanup_counts EXIT

  check_dependencies

  if [[ $# -eq 0 ]]; then
    usage
  fi

  case "$1" in
    -h|--help)
      usage
      ;;
    --all)
      validate_all
      ;;
    --chain)
      if [[ -z "${2:-}" ]]; then
        log_error "Missing chain file argument"
        usage
      fi
      validate_chain "$2"
      ;;
    --validate-output)
      if [[ -z "${2:-}" ]]; then
        log_error "Missing skill name argument"
        usage
      fi
      validate_output "$2"
      ;;
    --types)
      echo "Validating type definitions..."
      for type_file in "$TYPES_DIR"/*.yaml; do
        if [[ -f "$type_file" ]]; then
          validate_yaml_syntax "$type_file"
          log_success "$(basename "$type_file") passed"
        fi
      done
      ;;
    *)
      validate_contract "$1"
      ;;
  esac

  # Final summary
  echo ""
  local final_errors final_warnings
  final_errors=$(get_error_count)
  final_warnings=$(get_warning_count)

  if [[ "$final_errors" -gt 0 ]]; then
    echo -e "${RED}Validation failed: $final_errors error(s), $final_warnings warning(s)${NC}"
    exit 1
  elif [[ "$final_warnings" -gt 0 ]]; then
    echo -e "${YELLOW}Validation passed with $final_warnings warning(s)${NC}"
    exit 0
  else
    echo -e "${GREEN}Validation passed${NC}"
    exit 0
  fi
}

main "$@"
