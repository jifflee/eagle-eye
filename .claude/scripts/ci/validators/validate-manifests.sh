#!/usr/bin/env bash
# ============================================================
# Script: validate-manifests.sh
# Purpose: Validate skill and command manifests against schemas
# Usage: ./scripts/ci/validators/validate-manifests.sh [--verbose] [--fix]
# Exit codes: 0 = valid, 1 = validation errors, 2 = fatal error
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Defaults
VERBOSE=false
FIX_MODE=false
QUIET=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --fix) FIX_MODE=true; shift ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Logging
log_info() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${GREEN}[INFO]${NC} $*"
  fi
}

log_warn() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
  fi
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}[DEBUG]${NC} $*"
  fi
}

# Check prerequisites
check_prerequisites() {
  local missing=()

  for tool in jq find; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    exit 2
  fi
}

# Validate JSON against schema (basic check)
# Full JSON Schema validation requires additional tools like ajv-cli
validate_json_basic() {
  local json_file="$1"
  local schema_file="$2"
  local name="$3"

  log_verbose "Validating $name against schema..."

  # Check if JSON is valid
  if ! jq empty "$json_file" 2>/dev/null; then
    log_error "Invalid JSON: $json_file"
    return 1
  fi

  # Check required fields from schema
  local required_fields
  required_fields=$(jq -r '.required[]?' "$schema_file" 2>/dev/null || echo "")

  local missing_fields=()
  for field in $required_fields; do
    if ! jq -e ".$field" "$json_file" >/dev/null 2>&1; then
      missing_fields+=("$field")
    fi
  done

  if [[ ${#missing_fields[@]} -gt 0 ]]; then
    log_error "Missing required fields in $json_file: ${missing_fields[*]}"
    return 1
  fi

  log_verbose "✓ $name validated"
  return 0
}

# Scan for skill manifests
validate_skills() {
  log_info "Validating skill manifests..."

  local skill_schema="$REPO_ROOT/schemas/skill-manifest.schema.json"
  if [[ ! -f "$skill_schema" ]]; then
    log_warn "Skill schema not found: $skill_schema"
    return 0
  fi

  local errors=0
  local total=0

  # Look for skill manifest files
  while IFS= read -r manifest; do
    total=$((total + 1))
    local basename_manifest
    basename_manifest=$(basename "$manifest")

    if ! validate_json_basic "$manifest" "$skill_schema" "$basename_manifest"; then
      errors=$((errors + 1))
    fi
  done < <(find "$REPO_ROOT/skills" -name "*.manifest.json" -type f 2>/dev/null || true)

  if [[ $total -eq 0 ]]; then
    log_warn "No skill manifests found (*.manifest.json in skills/)"
    log_warn "Skill manifests are recommended but not yet required"
  else
    log_info "Validated $total skill manifest(s), $errors error(s)"
  fi

  return "$errors"
}

# Scan for command manifests
validate_commands() {
  log_info "Validating command manifests..."

  local command_schema="$REPO_ROOT/schemas/command-manifest.schema.json"
  if [[ ! -f "$command_schema" ]]; then
    log_warn "Command schema not found: $command_schema"
    return 0
  fi

  local errors=0
  local total=0

  # Look for command manifest files
  while IFS= read -r manifest; do
    total=$((total + 1))
    local basename_manifest
    basename_manifest=$(basename "$manifest")

    if ! validate_json_basic "$manifest" "$command_schema" "$basename_manifest"; then
      errors=$((errors + 1))
    fi
  done < <(find "$REPO_ROOT/scripts" -name "*.manifest.json" -type f 2>/dev/null || true)

  if [[ $total -eq 0 ]]; then
    log_warn "No command manifests found (*.manifest.json in scripts/)"
    log_warn "Command manifests are recommended but not yet required"
  else
    log_info "Validated $total command manifest(s), $errors error(s)"
  fi

  return "$errors"
}

# Validate agent manifests
validate_agents() {
  log_info "Validating agent manifests..."

  local agent_schema="$REPO_ROOT/schemas/agent-manifest.schema.json"
  if [[ ! -f "$agent_schema" ]]; then
    log_warn "Agent schema not found: $agent_schema"
    return 0
  fi

  local errors=0
  local total=0

  # Agent manifests are in .md files with YAML frontmatter
  # For now, just check they exist and are readable
  while IFS= read -r agent_file; do
    total=$((total + 1))
    local basename_agent
    basename_agent=$(basename "$agent_file")

    if [[ ! -r "$agent_file" ]]; then
      log_error "Cannot read agent file: $agent_file"
      errors=$((errors + 1))
    else
      log_verbose "✓ $basename_agent exists and is readable"
    fi
  done < <(find "$REPO_ROOT/.claude/agents" -name "*.md" -type f 2>/dev/null || true)

  log_info "Validated $total agent(s), $errors error(s)"

  return "$errors"
}

# Main execution
main() {
  cd "$REPO_ROOT"

  check_prerequisites

  log_info "Starting manifest validation..."
  echo ""

  local total_errors=0

  # Validate skills
  local skill_errors=0
  validate_skills || skill_errors=$?
  total_errors=$((total_errors + skill_errors))
  echo ""

  # Validate commands
  local command_errors=0
  validate_commands || command_errors=$?
  total_errors=$((total_errors + command_errors))
  echo ""

  # Validate agents
  local agent_errors=0
  validate_agents || agent_errors=$?
  total_errors=$((total_errors + agent_errors))
  echo ""

  # Summary
  if [[ $total_errors -eq 0 ]]; then
    log_info "✓ All manifests valid"
    exit 0
  else
    log_error "✗ $total_errors validation error(s) found"
    exit 1
  fi
}

main "$@"
