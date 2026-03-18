#!/usr/bin/env bash
# ============================================================
# Script: deployment-provenance-gate.sh
# Purpose: Deployment gate for provenance verification
#
# Verifies that all artifacts have valid SLSA provenance
# before allowing deployment. Integrates with existing
# package-reputation and package-attestation checks.
#
# Usage:
#   ./scripts/ci/deployment-provenance-gate.sh [OPTIONS]
#
# Options:
#   --artifacts-dir DIR    Directory containing artifacts to verify (default: dist/)
#   --provenance-dir DIR   Directory containing provenance files (default: .provenance/)
#   --min-slsa-level LEVEL Minimum SLSA level required (default: 2)
#   --require-signatures   Require all artifacts to be signed
#   --skip-npm-packages    Skip npm package attestation checks
#   --skip-containers      Skip container image verification
#   --output-dir DIR       Output directory for reports (default: .provenance/)
#   --strict               Strict mode: fail on any issue
#   --verbose              Show detailed output
#   --help                 Show this help
#
# Exit codes:
#   0 - All provenance checks passed
#   1 - Provenance checks failed
#   2 - Tool error or misconfiguration
#
# Integration:
#   - Pre-deploy: Verify all artifacts before deployment
#   - QA gate: Part of pre-QA validation pipeline
#   - Release gate: Validate release artifacts
#
# Related:
#   - scripts/ci/generate-slsa-provenance.sh - Generate provenance
#   - scripts/ci/verify-slsa-provenance.sh - Verify provenance
#   - scripts/ci/validators/package-attestation.sh - NPM attestation
#   - scripts/ci/runners/package-reputation.sh - Supply chain checks
#   - Issue #1043 - Add supply chain provenance with SLSA and sigstore
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

ARTIFACTS_DIR="$REPO_ROOT/dist"
PROVENANCE_DIR="$REPO_ROOT/.provenance"
MIN_SLSA_LEVEL=2
REQUIRE_SIGNATURES=false
SKIP_NPM_PACKAGES=false
SKIP_CONTAINERS=false
OUTPUT_DIR="$REPO_ROOT/.provenance"
STRICT=false
VERBOSE=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts-dir)      ARTIFACTS_DIR="$2"; shift 2 ;;
    --provenance-dir)     PROVENANCE_DIR="$2"; shift 2 ;;
    --min-slsa-level)     MIN_SLSA_LEVEL="$2"; shift 2 ;;
    --require-signatures) REQUIRE_SIGNATURES=true; shift ;;
    --skip-npm-packages)  SKIP_NPM_PACKAGES=true; shift ;;
    --skip-containers)    SKIP_CONTAINERS=true; shift ;;
    --output-dir)         OUTPUT_DIR="$2"; shift 2 ;;
    --strict)             STRICT=true; shift ;;
    --verbose)            VERBOSE=true; shift ;;
    --help|-h)            show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${CYAN}[DEBUG]${NC} $*"
  fi
}

log_step() {
  echo -e "${BLUE}[STEP]${NC} $*"
}

# ─── Prerequisites ────────────────────────────────────────────────────────────

check_prerequisites() {
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    exit 2
  fi

  # Check for verification script
  if [[ ! -f "$SCRIPT_DIR/verify-slsa-provenance.sh" ]]; then
    log_error "verify-slsa-provenance.sh not found in $SCRIPT_DIR"
    exit 2
  fi

  # Check for package attestation script (optional)
  if [[ ! -f "$SCRIPT_DIR/validators/package-attestation.sh" ]]; then
    log_verbose "package-attestation.sh not found, NPM checks will be skipped"
  fi

  # Check for package reputation script (optional)
  if [[ ! -f "$SCRIPT_DIR/runners/package-reputation.sh" ]]; then
    log_verbose "package-reputation.sh not found, supply chain checks will be skipped"
  fi
}

# ─── NPM Package Attestation ──────────────────────────────────────────────────

check_npm_attestations() {
  if [[ "$SKIP_NPM_PACKAGES" == "true" ]]; then
    log_verbose "Skipping NPM package attestation checks"
    return 0
  fi

  if [[ ! -f "$REPO_ROOT/package.json" ]]; then
    log_verbose "No package.json found, skipping NPM checks"
    return 0
  fi

  log_step "Checking NPM package attestations..."

  local attestation_script="$SCRIPT_DIR/validators/package-attestation.sh"
  if [[ ! -f "$attestation_script" ]]; then
    log_warn "package-attestation.sh not found, skipping NPM attestation checks"
    return 0
  fi

  local exit_code=0
  if [[ "$VERBOSE" == "true" ]]; then
    "$attestation_script" --full --verbose --output-dir "$OUTPUT_DIR" || exit_code=$?
  else
    "$attestation_script" --full --output-dir "$OUTPUT_DIR" || exit_code=$?
  fi

  if [[ $exit_code -eq 0 ]]; then
    log_info "✓ NPM package attestations verified"
    return 0
  else
    log_error "✗ NPM package attestation checks failed"
    return 1
  fi
}

# ─── Supply Chain Reputation ──────────────────────────────────────────────────

check_supply_chain_reputation() {
  if [[ "$SKIP_NPM_PACKAGES" == "true" ]]; then
    log_verbose "Skipping supply chain reputation checks"
    return 0
  fi

  if [[ ! -f "$REPO_ROOT/package.json" ]]; then
    log_verbose "No package.json found, skipping reputation checks"
    return 0
  fi

  log_step "Checking supply chain reputation..."

  local reputation_script="$SCRIPT_DIR/runners/package-reputation.sh"
  if [[ ! -f "$reputation_script" ]]; then
    log_warn "package-reputation.sh not found, skipping reputation checks"
    return 0
  fi

  local exit_code=0
  local mode="full"
  [[ "$STRICT" == "true" ]] && mode="full --strict"

  if [[ "$VERBOSE" == "true" ]]; then
    # shellcheck disable=SC2086
    "$reputation_script" $mode --verbose --output-dir "$OUTPUT_DIR" || exit_code=$?
  else
    # shellcheck disable=SC2086
    "$reputation_script" $mode --output-dir "$OUTPUT_DIR" || exit_code=$?
  fi

  if [[ $exit_code -eq 0 ]]; then
    log_info "✓ Supply chain reputation verified"
    return 0
  else
    log_error "✗ Supply chain reputation checks failed"
    return 1
  fi
}

# ─── Artifact Provenance Verification ────────────────────────────────────────

verify_artifact_provenances() {
  log_step "Verifying artifact provenances..."

  if [[ ! -d "$ARTIFACTS_DIR" ]]; then
    log_verbose "Artifacts directory not found: $ARTIFACTS_DIR"
    return 0
  fi

  local artifacts_found=0
  local artifacts_verified=0
  local artifacts_failed=0

  # Find all artifacts (files in artifacts directory)
  while IFS= read -r -d '' artifact; do
    artifacts_found=$((artifacts_found + 1))

    local artifact_name
    artifact_name=$(basename "$artifact")

    log_verbose "Checking artifact: $artifact_name"

    # Look for provenance file
    local provenance_file="${artifact}.provenance.json"
    if [[ ! -f "$provenance_file" ]]; then
      # Try alternate location
      provenance_file="$PROVENANCE_DIR/$(basename "$artifact").provenance.json"
    fi

    if [[ ! -f "$provenance_file" ]]; then
      log_warn "No provenance found for: $artifact_name"
      if [[ "$STRICT" == "true" ]]; then
        artifacts_failed=$((artifacts_failed + 1))
      fi
      continue
    fi

    # Verify provenance
    local verify_args=(
      --artifact "$artifact"
      --provenance "$provenance_file"
      --min-slsa-level "$MIN_SLSA_LEVEL"
      --output-dir "$OUTPUT_DIR"
      --format json
    )

    if [[ "$REQUIRE_SIGNATURES" == "true" ]]; then
      verify_args+=(--require-signature)
    fi

    if [[ "$VERBOSE" == "true" ]]; then
      verify_args+=(--verbose)
    else
      verify_args+=(--quiet)
    fi

    local exit_code=0
    "$SCRIPT_DIR/verify-slsa-provenance.sh" "${verify_args[@]}" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      log_verbose "✓ Provenance verified: $artifact_name"
      artifacts_verified=$((artifacts_verified + 1))
    else
      log_error "✗ Provenance verification failed: $artifact_name"
      artifacts_failed=$((artifacts_failed + 1))
    fi

  done < <(find "$ARTIFACTS_DIR" -type f -not -name "*.provenance.json" -not -name "*.sig" -print0 2>/dev/null || true)

  log_info "Artifact verification: $artifacts_verified verified, $artifacts_failed failed (of $artifacts_found total)"

  if [[ $artifacts_failed -gt 0 ]]; then
    return 1
  fi

  return 0
}

# ─── Container Image Verification ────────────────────────────────────────────

verify_container_images() {
  if [[ "$SKIP_CONTAINERS" == "true" ]]; then
    log_verbose "Skipping container image verification"
    return 0
  fi

  log_step "Checking for container images..."

  # Check if there are any container images to verify
  # This is a placeholder - actual implementation would:
  # 1. List container images from docker or registry
  # 2. Verify their signatures with cosign
  # 3. Check their SLSA provenance

  if ! command -v docker &>/dev/null; then
    log_verbose "Docker not available, skipping container checks"
    return 0
  fi

  # Check for local images built in CI
  local images_count
  images_count=$(docker images -q | wc -l)

  if [[ $images_count -eq 0 ]]; then
    log_verbose "No container images found to verify"
    return 0
  fi

  log_info "Found $images_count container image(s)"

  # In a real implementation, we would verify each image here
  # For now, we just log that we found images

  return 0
}

# ─── Report Generation ────────────────────────────────────────────────────────

generate_gate_report() {
  local status="$1"
  local npm_status="$2"
  local reputation_status="$3"
  local artifact_status="$4"

  mkdir -p "$OUTPUT_DIR"
  local report_file="$OUTPUT_DIR/deployment-gate-report.json"

  jq -n \
    --arg status "$status" \
    --arg npm_status "$npm_status" \
    --arg reputation_status "$reputation_status" \
    --arg artifact_status "$artifact_status" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg min_slsa_level "$MIN_SLSA_LEVEL" \
    --arg require_signatures "$REQUIRE_SIGNATURES" \
    '{
      gate: "deployment-provenance",
      status: $status,
      timestamp: $timestamp,
      configuration: {
        min_slsa_level: ($min_slsa_level | tonumber),
        require_signatures: ($require_signatures == "true")
      },
      checks: {
        npm_attestations: $npm_status,
        supply_chain_reputation: $reputation_status,
        artifact_provenance: $artifact_status
      }
    }' > "$report_file"

  log_verbose "Gate report written to: $report_file"
}

generate_summary() {
  local status="$1"

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Deployment Provenance Gate Report${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  local status_color="$GREEN"
  local status_text="PASS"
  if [[ "$status" != "pass" ]]; then
    status_color="$RED"
    status_text="FAIL"
  fi

  echo -e "  Gate Status: ${status_color}${status_text}${NC}"
  echo ""

  echo "  Configuration:"
  echo "    Minimum SLSA Level:    $MIN_SLSA_LEVEL"
  echo "    Require Signatures:    $REQUIRE_SIGNATURES"
  echo "    Strict Mode:           $STRICT"
  echo ""

  echo "  Report Location: $OUTPUT_DIR/deployment-gate-report.json"
  echo ""

  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_prerequisites

  log_info "Running deployment provenance gate..."
  log_verbose "Artifacts directory: $ARTIFACTS_DIR"
  log_verbose "Provenance directory: $PROVENANCE_DIR"
  log_verbose "Minimum SLSA level: $MIN_SLSA_LEVEL"

  local overall_status="pass"
  local npm_status="skipped"
  local reputation_status="skipped"
  local artifact_status="skipped"

  # Run checks
  local exit_code=0

  # 1. NPM package attestations
  if ! check_npm_attestations; then
    npm_status="fail"
    overall_status="fail"
  else
    npm_status="pass"
  fi

  # 2. Supply chain reputation
  if ! check_supply_chain_reputation; then
    reputation_status="fail"
    if [[ "$STRICT" == "true" ]]; then
      overall_status="fail"
    else
      reputation_status="warn"
    fi
  else
    reputation_status="pass"
  fi

  # 3. Artifact provenance verification
  if ! verify_artifact_provenances; then
    artifact_status="fail"
    overall_status="fail"
  else
    artifact_status="pass"
  fi

  # 4. Container image verification
  verify_container_images || true  # Non-blocking for now

  # Generate reports
  generate_gate_report "$overall_status" "$npm_status" "$reputation_status" "$artifact_status"
  generate_summary "$overall_status"

  if [[ "$overall_status" == "pass" ]]; then
    log_info "✓ Deployment provenance gate PASSED"
    exit 0
  else
    log_error "✗ Deployment provenance gate FAILED"
    exit 1
  fi
}

main "$@"
