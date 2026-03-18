#!/usr/bin/env bash
# ============================================================
# Script: test-deployment-config.sh
# Purpose: Test deployment configuration functionality
# Usage: ./test-deployment-config.sh
# ============================================================

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "$SCRIPT_DIR/../lib/config.sh"

# ============================================================
# Test Functions
# ============================================================

test_non_interactive_config() {
  log_info "Test 1: Non-interactive configuration creation"

  # Remove existing config if present
  local repo_root
  repo_root=$(get_repo_root)
  rm -f "$repo_root/$CONFIG_FILE"

  # Run non-interactive config
  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=false \
    --github-repo=test-owner/test-repo \
    --framework-repo=anthropics/anthropic-quickstarts

  # Verify config was created
  if ! config_exists; then
    log_error "Config file was not created"
    return 1
  fi

  # Verify values
  local corporate_managed
  corporate_managed=$(get_config_value "corporate_managed")
  if [ "$corporate_managed" != "false" ]; then
    log_error "Expected corporate_managed=false, got: $corporate_managed"
    return 1
  fi

  local github_repo
  github_repo=$(get_config_value "github_repo")
  if [ "$github_repo" != "test-owner/test-repo" ]; then
    log_error "Expected github_repo=test-owner/test-repo, got: $github_repo"
    return 1
  fi

  local framework_repo
  framework_repo=$(get_config_value "framework_repo")
  if [ "$framework_repo" != "anthropics/anthropic-quickstarts" ]; then
    log_error "Expected framework_repo=anthropics/anthropic-quickstarts, got: $framework_repo"
    return 1
  fi

  log_success "Test 1 passed"
  return 0
}

test_config_update() {
  log_info "Test 2: Configuration update (re-runnable)"

  # Update configuration with different values
  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=true \
    --github-repo=updated-owner/updated-repo \
    --framework-repo=custom-owner/custom-framework

  # Verify updated values
  local corporate_managed
  corporate_managed=$(get_config_value "corporate_managed")
  if [ "$corporate_managed" != "true" ]; then
    log_error "Expected corporate_managed=true, got: $corporate_managed"
    return 1
  fi

  local github_repo
  github_repo=$(get_config_value "github_repo")
  if [ "$github_repo" != "updated-owner/updated-repo" ]; then
    log_error "Expected github_repo=updated-owner/updated-repo, got: $github_repo"
    return 1
  fi

  local framework_repo
  framework_repo=$(get_config_value "framework_repo")
  if [ "$framework_repo" != "custom-owner/custom-framework" ]; then
    log_error "Expected framework_repo=custom-owner/custom-framework, got: $framework_repo"
    return 1
  fi

  log_success "Test 2 passed"
  return 0
}

test_config_read_functions() {
  log_info "Test 3: Config read functions"

  # Test get_project_config
  local config
  config=$(get_project_config)
  if [ -z "$config" ]; then
    log_error "get_project_config returned empty"
    return 1
  fi

  # Verify it's valid JSON
  if ! echo "$config" | jq empty 2>/dev/null; then
    log_error "get_project_config returned invalid JSON"
    return 1
  fi

  # Test get_config_value for non-existent key
  local non_existent
  non_existent=$(get_config_value "non_existent_key")
  if [ -n "$non_existent" ]; then
    log_error "Expected empty string for non-existent key, got: $non_existent"
    return 1
  fi

  log_success "Test 3 passed"
  return 0
}

test_validation_functions() {
  log_info "Test 4: Validation functions"

  # Test valid repo formats
  if ! validate_github_repo "owner/repo"; then
    log_error "validate_github_repo failed for valid format: owner/repo"
    return 1
  fi

  if ! validate_github_repo "my-org/my-repo"; then
    log_error "validate_github_repo failed for valid format: my-org/my-repo"
    return 1
  fi

  if ! validate_github_repo "org_name/repo.name"; then
    log_error "validate_github_repo failed for valid format: org_name/repo.name"
    return 1
  fi

  # Test invalid repo formats
  if validate_github_repo "invalid"; then
    log_error "validate_github_repo passed for invalid format: invalid"
    return 1
  fi

  if validate_github_repo "invalid/repo/path"; then
    log_error "validate_github_repo passed for invalid format: invalid/repo/path"
    return 1
  fi

  # Test boolean validation
  if ! validate_boolean "true"; then
    log_error "validate_boolean failed for: true"
    return 1
  fi

  if ! validate_boolean "false"; then
    log_error "validate_boolean failed for: false"
    return 1
  fi

  if validate_boolean "yes"; then
    log_error "validate_boolean passed for invalid value: yes"
    return 1
  fi

  log_success "Test 4 passed"
  return 0
}

test_invalid_arguments() {
  log_info "Test 5: Invalid argument handling"

  # Test missing corporate-managed
  if "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --github-repo=owner/repo 2>/dev/null; then
    log_error "Script should fail with missing --corporate-managed"
    return 1
  fi

  # Test missing github-repo
  if "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=true 2>/dev/null; then
    log_error "Script should fail with missing --github-repo"
    return 1
  fi

  # Test invalid corporate-managed value
  if "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=maybe \
    --github-repo=owner/repo 2>/dev/null; then
    log_error "Script should fail with invalid --corporate-managed value"
    return 1
  fi

  # Test invalid github-repo format
  if "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=true \
    --github-repo=invalid-format 2>/dev/null; then
    log_error "Script should fail with invalid --github-repo format"
    return 1
  fi

  log_success "Test 5 passed"
  return 0
}

# ============================================================
# Main
# ============================================================

main() {
  log_info "Running deployment configuration tests..."
  echo ""

  local failed=0

  # Run tests
  test_non_interactive_config || failed=$((failed + 1))
  echo ""

  test_config_update || failed=$((failed + 1))
  echo ""

  test_config_read_functions || failed=$((failed + 1))
  echo ""

  test_validation_functions || failed=$((failed + 1))
  echo ""

  test_invalid_arguments || failed=$((failed + 1))
  echo ""

  # Summary
  if [ "$failed" -eq 0 ]; then
    log_success "All tests passed!"
    return 0
  else
    log_error "$failed test(s) failed"
    return 1
  fi
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  main "$@"
fi
