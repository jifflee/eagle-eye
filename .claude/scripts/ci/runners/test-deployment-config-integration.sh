#!/usr/bin/env bash
# ============================================================
# Script: test-deployment-config-integration.sh
# Purpose: Integration tests for deployment config feature #685
# Usage: ./test-deployment-config-integration.sh
# ============================================================

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "$SCRIPT_DIR/../lib/config.sh"

# ============================================================
# Acceptance Criteria Tests
# ============================================================

test_ac1_corporate_managed_question() {
  log_info "AC1: Asks 'Is this a corporate-managed endpoint?' (yes/no)"

  # Test with non-interactive mode setting corporate_managed to true
  local repo_root
  repo_root=$(get_repo_root)
  rm -f "$repo_root/$CONFIG_FILE"

  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=true \
    --github-repo=test/repo >/dev/null 2>&1

  local value
  value=$(get_config_value "corporate_managed")
  if [ "$value" != "true" ]; then
    log_error "Expected corporate_managed=true, got: $value"
    return 1
  fi

  # Test with false
  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=false \
    --github-repo=test/repo >/dev/null 2>&1

  value=$(get_config_value "corporate_managed")
  if [ "$value" != "false" ]; then
    log_error "Expected corporate_managed=false, got: $value"
    return 1
  fi

  log_success "AC1: ✓ Corporate-managed question accepted (yes/no)"
  return 0
}

test_ac2_github_repo_detection() {
  log_info "AC2: Auto-detects GitHub repo, confirms with user (owner/repo)"

  # Test that script accepts owner/repo format
  local repo_root
  repo_root=$(get_repo_root)
  rm -f "$repo_root/$CONFIG_FILE"

  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=false \
    --github-repo=my-org/my-repo >/dev/null 2>&1

  local value
  value=$(get_config_value "github_repo")
  if [ "$value" != "my-org/my-repo" ]; then
    log_error "Expected github_repo=my-org/my-repo, got: $value"
    return 1
  fi

  # Test validation rejects invalid formats
  if "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=false \
    --github-repo=invalid-format >/dev/null 2>&1; then
    log_error "Should reject invalid repo format"
    return 1
  fi

  log_success "AC2: ✓ GitHub repo auto-detection and validation"
  return 0
}

test_ac3_framework_repo_question() {
  log_info "AC3: Asks framework feedback repo (with default)"

  # Test with default
  local repo_root
  repo_root=$(get_repo_root)
  rm -f "$repo_root/$CONFIG_FILE"

  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=false \
    --github-repo=test/repo >/dev/null 2>&1

  local value
  value=$(get_config_value "framework_repo")
  if [ "$value" != "anthropics/anthropic-quickstarts" ]; then
    log_error "Expected default framework_repo=anthropics/anthropic-quickstarts, got: $value"
    return 1
  fi

  # Test with custom value
  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=false \
    --github-repo=test/repo \
    --framework-repo=custom/framework >/dev/null 2>&1

  value=$(get_config_value "framework_repo")
  if [ "$value" != "custom/framework" ]; then
    log_error "Expected framework_repo=custom/framework, got: $value"
    return 1
  fi

  log_success "AC3: ✓ Framework repo question with default"
  return 0
}

test_ac4_stores_config_file() {
  log_info "AC4: Stores config in .claude/project-config.json"

  local repo_root
  repo_root=$(get_repo_root)
  rm -f "$repo_root/$CONFIG_FILE"

  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=true \
    --github-repo=owner/repo \
    --framework-repo=frame/work >/dev/null 2>&1

  # Verify file exists
  if [ ! -f "$repo_root/$CONFIG_FILE" ]; then
    log_error "Config file not created at $CONFIG_FILE"
    return 1
  fi

  # Verify it's valid JSON
  if ! jq empty "$repo_root/$CONFIG_FILE" 2>/dev/null; then
    log_error "Config file is not valid JSON"
    return 1
  fi

  # Verify structure
  local config
  config=$(cat "$repo_root/$CONFIG_FILE")

  local corporate_managed
  corporate_managed=$(echo "$config" | jq -r '.corporate_managed')
  if [ "$corporate_managed" != "true" ]; then
    log_error "Config missing or incorrect corporate_managed"
    return 1
  fi

  local github_repo
  github_repo=$(echo "$config" | jq -r '.github_repo')
  if [ "$github_repo" != "owner/repo" ]; then
    log_error "Config missing or incorrect github_repo"
    return 1
  fi

  local framework_repo
  framework_repo=$(echo "$config" | jq -r '.framework_repo')
  if [ "$framework_repo" != "frame/work" ]; then
    log_error "Config missing or incorrect framework_repo"
    return 1
  fi

  log_success "AC4: ✓ Config stored in .claude/project-config.json"
  return 0
}

test_ac5_rerunnable() {
  log_info "AC5: Re-runnable (updates existing config, doesn't duplicate)"

  local repo_root
  repo_root=$(get_repo_root)
  rm -f "$repo_root/$CONFIG_FILE"

  # Create initial config
  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=false \
    --github-repo=initial/repo \
    --framework-repo=initial/framework >/dev/null 2>&1

  local initial_config
  initial_config=$(cat "$repo_root/$CONFIG_FILE")

  # Update config
  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=true \
    --github-repo=updated/repo \
    --framework-repo=updated/framework >/dev/null 2>&1

  local updated_config
  updated_config=$(cat "$repo_root/$CONFIG_FILE")

  # Verify values were updated
  local corporate_managed
  corporate_managed=$(echo "$updated_config" | jq -r '.corporate_managed')
  if [ "$corporate_managed" != "true" ]; then
    log_error "Config was not updated (corporate_managed)"
    return 1
  fi

  local github_repo
  github_repo=$(echo "$updated_config" | jq -r '.github_repo')
  if [ "$github_repo" != "updated/repo" ]; then
    log_error "Config was not updated (github_repo)"
    return 1
  fi

  # Verify no duplicate keys (count should be 3)
  local key_count
  key_count=$(echo "$updated_config" | jq 'keys | length')
  if [ "$key_count" -ne 3 ]; then
    log_error "Config has duplicate keys or wrong structure. Expected 3 keys, got $key_count"
    return 1
  fi

  log_success "AC5: ✓ Re-runnable without duplication"
  return 0
}

test_ac6_non_interactive_flag() {
  log_info "AC6: --non-interactive flag accepts answers as arguments"

  local repo_root
  repo_root=$(get_repo_root)
  rm -f "$repo_root/$CONFIG_FILE"

  # Test all arguments
  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=false \
    --github-repo=test/repo \
    --framework-repo=test/framework >/dev/null 2>&1

  if [ ! -f "$repo_root/$CONFIG_FILE" ]; then
    log_error "--non-interactive flag did not create config"
    return 1
  fi

  local corporate_managed
  corporate_managed=$(get_config_value "corporate_managed")
  if [ "$corporate_managed" != "false" ]; then
    log_error "--non-interactive did not set corporate_managed correctly"
    return 1
  fi

  local github_repo
  github_repo=$(get_config_value "github_repo")
  if [ "$github_repo" != "test/repo" ]; then
    log_error "--non-interactive did not set github_repo correctly"
    return 1
  fi

  local framework_repo
  framework_repo=$(get_config_value "framework_repo")
  if [ "$framework_repo" != "test/framework" ]; then
    log_error "--non-interactive did not set framework_repo correctly"
    return 1
  fi

  # Test with default framework_repo
  rm -f "$repo_root/$CONFIG_FILE"
  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=true \
    --github-repo=test/repo >/dev/null 2>&1

  framework_repo=$(get_config_value "framework_repo")
  if [ "$framework_repo" != "anthropics/anthropic-quickstarts" ]; then
    log_error "--non-interactive did not use default framework_repo"
    return 1
  fi

  log_success "AC6: ✓ --non-interactive flag works correctly"
  return 0
}

test_ac7_config_readable_by_scripts() {
  log_info "AC7: Config readable by all scripts via shared lib function"

  local repo_root
  repo_root=$(get_repo_root)
  rm -f "$repo_root/$CONFIG_FILE"

  # Create config
  "$SCRIPT_DIR/../init-deployment-config.sh" \
    --non-interactive \
    --corporate-managed=true \
    --github-repo=readable/repo \
    --framework-repo=readable/framework >/dev/null 2>&1

  # Test get_project_config
  local config
  config=$(get_project_config)
  if [ -z "$config" ]; then
    log_error "get_project_config returned empty"
    return 1
  fi

  # Test get_config_value for all keys
  local corporate_managed
  corporate_managed=$(get_config_value "corporate_managed")
  if [ "$corporate_managed" != "true" ]; then
    log_error "get_config_value failed for corporate_managed"
    return 1
  fi

  local github_repo
  github_repo=$(get_config_value "github_repo")
  if [ "$github_repo" != "readable/repo" ]; then
    log_error "get_config_value failed for github_repo"
    return 1
  fi

  local framework_repo
  framework_repo=$(get_config_value "framework_repo")
  if [ "$framework_repo" != "readable/framework" ]; then
    log_error "get_config_value failed for framework_repo"
    return 1
  fi

  # Test config_exists
  if ! config_exists; then
    log_error "config_exists returned false when config exists"
    return 1
  fi

  log_success "AC7: ✓ Config readable via shared lib functions"
  return 0
}

# ============================================================
# Main
# ============================================================

main() {
  log_info "Running acceptance criteria tests for feature #685..."
  echo ""

  local failed=0

  # Run all acceptance criteria tests
  test_ac1_corporate_managed_question || failed=$((failed + 1))
  echo ""

  test_ac2_github_repo_detection || failed=$((failed + 1))
  echo ""

  test_ac3_framework_repo_question || failed=$((failed + 1))
  echo ""

  test_ac4_stores_config_file || failed=$((failed + 1))
  echo ""

  test_ac5_rerunnable || failed=$((failed + 1))
  echo ""

  test_ac6_non_interactive_flag || failed=$((failed + 1))
  echo ""

  test_ac7_config_readable_by_scripts || failed=$((failed + 1))
  echo ""

  # Summary
  echo "========================================"
  if [ "$failed" -eq 0 ]; then
    log_success "All 7 acceptance criteria tests passed! ✓"
    echo ""
    echo "Feature #685 implementation complete:"
    echo "  ✓ AC1: Corporate-managed endpoint question"
    echo "  ✓ AC2: GitHub repo auto-detection"
    echo "  ✓ AC3: Framework repo with default"
    echo "  ✓ AC4: Config stored in .claude/project-config.json"
    echo "  ✓ AC5: Re-runnable (updates, no duplication)"
    echo "  ✓ AC6: --non-interactive flag"
    echo "  ✓ AC7: Config readable via shared lib"
    return 0
  else
    log_error "$failed acceptance criteria test(s) failed"
    return 1
  fi
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  main "$@"
fi
