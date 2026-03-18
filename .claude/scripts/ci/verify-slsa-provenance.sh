#!/usr/bin/env bash
# ============================================================
# Script: verify-slsa-provenance.sh
# Purpose: Verify SLSA provenance for artifacts
#
# Verifies SLSA provenance attestations to ensure artifacts
# were built by trusted systems from declared sources.
#
# Usage:
#   ./scripts/ci/verify-slsa-provenance.sh [OPTIONS]
#
# Options:
#   --artifact PATH       Path to artifact to verify (required)
#   --provenance PATH     Path to provenance file (default: <artifact>.provenance.json)
#   --min-slsa-level LEVEL Minimum SLSA level required (default: 1)
#   --require-signature    Require cosign signature verification
#   --trusted-builders FILE File with trusted builder IDs (one per line)
#   --trusted-repos FILE   File with trusted source repos (one per line)
#   --output-dir DIR       Output directory for reports (default: .provenance/)
#   --format FORMAT        Output format: json|summary (default: summary)
#   --verbose              Show detailed output
#   --quiet                Suppress non-essential output
#   --help                 Show this help
#
# Exit codes:
#   0 - Provenance verification successful
#   1 - Provenance verification failed
#   2 - Tool error (missing dependencies, invalid configuration)
#
# Output:
#   - Verification report in JSON format
#   - Summary printed to stdout
#
# Integration:
#   - Deployment gate: Verify provenance before deploying
#   - QA gate: Ensure all artifacts have valid provenance
#   - Security review: Audit provenance for compliance
#
# Related:
#   - scripts/ci/generate-slsa-provenance.sh - Generate SLSA provenance
#   - scripts/ci/validators/package-attestation.sh - Package attestation
#   - Issue #1043 - Add supply chain provenance with SLSA and sigstore
#   - Epic #1030 - CI/CD infrastructure improvements
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

ARTIFACT_PATH=""
PROVENANCE_PATH=""
MIN_SLSA_LEVEL=1
REQUIRE_SIGNATURE=false
TRUSTED_BUILDERS_FILE=""
TRUSTED_REPOS_FILE=""
OUTPUT_DIR="$REPO_ROOT/.provenance"
OUTPUT_FORMAT="summary"
VERBOSE=false
QUIET=false

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
    --artifact)          ARTIFACT_PATH="$2"; shift 2 ;;
    --provenance)        PROVENANCE_PATH="$2"; shift 2 ;;
    --min-slsa-level)    MIN_SLSA_LEVEL="$2"; shift 2 ;;
    --require-signature) REQUIRE_SIGNATURE=true; shift ;;
    --trusted-builders)  TRUSTED_BUILDERS_FILE="$2"; shift 2 ;;
    --trusted-repos)     TRUSTED_REPOS_FILE="$2"; shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2"; shift 2 ;;
    --format)            OUTPUT_FORMAT="$2"; shift 2 ;;
    --verbose)           VERBOSE=true; shift ;;
    --quiet)             QUIET=true; shift ;;
    --help|-h)           show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Logging ──────────────────────────────────────────────────────────────────

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
    echo -e "${CYAN}[DEBUG]${NC} $*"
  fi
}

log_step() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${BLUE}[STEP]${NC} $*"
  fi
}

# ─── Validation ───────────────────────────────────────────────────────────────

validate_prerequisites() {
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    log_error "Install: apt-get install jq"
    exit 2
  fi

  if ! command -v sha256sum &>/dev/null; then
    log_error "sha256sum is required but not installed"
    exit 2
  fi

  if [[ "$REQUIRE_SIGNATURE" == "true" ]] && ! command -v cosign &>/dev/null; then
    log_error "cosign is required for signature verification but not installed"
    log_error "Install: https://docs.sigstore.dev/cosign/installation/"
    exit 2
  fi

  log_verbose "All required tools available"
}

validate_arguments() {
  if [[ -z "$ARTIFACT_PATH" ]]; then
    log_error "Artifact path is required (--artifact)"
    exit 2
  fi

  if [[ ! -f "$ARTIFACT_PATH" ]] && [[ ! -d "$ARTIFACT_PATH" ]]; then
    log_error "Artifact not found: $ARTIFACT_PATH"
    exit 2
  fi

  if [[ -z "$PROVENANCE_PATH" ]]; then
    PROVENANCE_PATH="${ARTIFACT_PATH}.provenance.json"
  fi

  if [[ ! -f "$PROVENANCE_PATH" ]]; then
    log_error "Provenance file not found: $PROVENANCE_PATH"
    exit 2
  fi

  if [[ ! "$MIN_SLSA_LEVEL" =~ ^[1-4]$ ]]; then
    log_error "Invalid minimum SLSA level: $MIN_SLSA_LEVEL (must be 1, 2, 3, or 4)"
    exit 2
  fi

  log_verbose "Arguments validated"
}

# ─── Artifact Verification ───────────────────────────────────────────────────

compute_artifact_digest() {
  local artifact="$1"

  log_verbose "Computing artifact digest..."

  if [[ -f "$artifact" ]]; then
    sha256sum "$artifact" | awk '{print $1}'
  elif [[ -d "$artifact" ]]; then
    find "$artifact" -type f -print0 | \
      sort -z | \
      xargs -0 sha256sum | \
      sha256sum | \
      awk '{print $1}'
  else
    log_error "Artifact is neither file nor directory: $artifact"
    return 1
  fi
}

verify_artifact_digest() {
  local computed_digest="$1"
  local provenance_file="$2"

  log_step "Verifying artifact digest..."

  local provenance_digest
  provenance_digest=$(jq -r '.subject[0].digest.sha256' "$provenance_file" 2>/dev/null || echo "")

  if [[ -z "$provenance_digest" ]]; then
    log_error "Failed to extract digest from provenance"
    return 1
  fi

  log_verbose "Computed digest:   sha256:$computed_digest"
  log_verbose "Provenance digest: sha256:$provenance_digest"

  if [[ "$computed_digest" == "$provenance_digest" ]]; then
    log_info "✓ Artifact digest matches provenance"
    return 0
  else
    log_error "✗ Artifact digest mismatch!"
    log_error "  Expected: sha256:$provenance_digest"
    log_error "  Computed: sha256:$computed_digest"
    return 1
  fi
}

# ─── SLSA Level Verification ──────────────────────────────────────────────────

verify_slsa_level() {
  local provenance_file="$1"

  log_step "Verifying SLSA level..."

  local slsa_level
  slsa_level=$(jq -r '.slsaLevel // "0"' "$provenance_file" 2>/dev/null || echo "0")

  log_verbose "Provenance SLSA level: $slsa_level"
  log_verbose "Required minimum: $MIN_SLSA_LEVEL"

  if [[ "$slsa_level" -ge "$MIN_SLSA_LEVEL" ]]; then
    log_info "✓ SLSA level $slsa_level meets minimum requirement ($MIN_SLSA_LEVEL)"
    return 0
  else
    log_error "✗ SLSA level $slsa_level below minimum requirement ($MIN_SLSA_LEVEL)"
    return 1
  fi
}

# ─── Builder Trust Verification ──────────────────────────────────────────────

verify_builder_trust() {
  local provenance_file="$1"

  if [[ -z "$TRUSTED_BUILDERS_FILE" ]]; then
    log_verbose "No trusted builders file specified, skipping builder verification"
    return 0
  fi

  if [[ ! -f "$TRUSTED_BUILDERS_FILE" ]]; then
    log_warn "Trusted builders file not found: $TRUSTED_BUILDERS_FILE"
    return 0
  fi

  log_step "Verifying builder trust..."

  local builder_id
  builder_id=$(jq -r '.predicate.builder.id' "$provenance_file" 2>/dev/null || echo "")

  if [[ -z "$builder_id" ]]; then
    log_error "Failed to extract builder ID from provenance"
    return 1
  fi

  log_verbose "Builder ID: $builder_id"

  # Check if builder is in trusted list
  if grep -qFx "$builder_id" "$TRUSTED_BUILDERS_FILE"; then
    log_info "✓ Builder is trusted: $builder_id"
    return 0
  else
    log_error "✗ Builder not in trusted list: $builder_id"
    return 1
  fi
}

# ─── Source Repository Verification ──────────────────────────────────────────

verify_source_repo() {
  local provenance_file="$1"

  if [[ -z "$TRUSTED_REPOS_FILE" ]]; then
    log_verbose "No trusted repos file specified, skipping source verification"
    return 0
  fi

  if [[ ! -f "$TRUSTED_REPOS_FILE" ]]; then
    log_warn "Trusted repos file not found: $TRUSTED_REPOS_FILE"
    return 0
  fi

  log_step "Verifying source repository..."

  local source_repo
  source_repo=$(jq -r '.predicate.materials[0].uri' "$provenance_file" 2>/dev/null || echo "")

  if [[ -z "$source_repo" ]]; then
    log_error "Failed to extract source repo from provenance"
    return 1
  fi

  log_verbose "Source repository: $source_repo"

  # Check if repo is in trusted list
  if grep -qFx "$source_repo" "$TRUSTED_REPOS_FILE"; then
    log_info "✓ Source repository is trusted: $source_repo"
    return 0
  else
    log_error "✗ Source repository not in trusted list: $source_repo"
    return 1
  fi
}

# ─── Signature Verification ──────────────────────────────────────────────────

verify_signature() {
  local provenance_file="$1"

  if [[ "$REQUIRE_SIGNATURE" != "true" ]]; then
    log_verbose "Signature verification not required"
    return 0
  fi

  log_step "Verifying signature..."

  local signature_file="${provenance_file}.sig"

  if [[ ! -f "$signature_file" ]]; then
    log_error "Signature file not found: $signature_file"
    return 1
  fi

  if ! command -v cosign &>/dev/null; then
    log_error "cosign not available for signature verification"
    return 1
  fi

  # Verify with cosign
  if cosign verify-blob --signature "$signature_file" "$provenance_file" 2>&1 | \
     ([ "$VERBOSE" == "true" ] && cat || grep -v "^"); then
    log_info "✓ Signature verified successfully"
    return 0
  else
    log_error "✗ Signature verification failed"
    return 1
  fi
}

# ─── Provenance Structure Validation ──────────────────────────────────────────

validate_provenance_structure() {
  local provenance_file="$1"

  log_step "Validating provenance structure..."

  # Check if file is valid JSON
  if ! jq empty "$provenance_file" 2>/dev/null; then
    log_error "Provenance file is not valid JSON"
    return 1
  fi

  # Check for required fields
  local required_fields=(
    "._type"
    ".subject"
    ".predicateType"
    ".predicate.builder.id"
  )

  local missing_fields=()

  for field in "${required_fields[@]}"; do
    local value
    value=$(jq -r "$field // empty" "$provenance_file" 2>/dev/null || echo "")
    if [[ -z "$value" ]]; then
      missing_fields+=("$field")
    fi
  done

  if [[ ${#missing_fields[@]} -gt 0 ]]; then
    log_error "Provenance missing required fields:"
    for field in "${missing_fields[@]}"; do
      log_error "  - $field"
    done
    return 1
  fi

  log_info "✓ Provenance structure is valid"
  return 0
}

# ─── Report Generation ────────────────────────────────────────────────────────

generate_verification_report() {
  local artifact_path="$1"
  local provenance_path="$2"
  local verification_status="$3"
  local checks_passed="$4"
  local checks_failed="$5"

  mkdir -p "$OUTPUT_DIR"
  local report_file="$OUTPUT_DIR/verification-report.json"

  local builder_id source_repo slsa_level
  builder_id=$(jq -r '.predicate.builder.id' "$provenance_path" 2>/dev/null || echo "unknown")
  source_repo=$(jq -r '.predicate.materials[0].uri' "$provenance_path" 2>/dev/null || echo "unknown")
  slsa_level=$(jq -r '.slsaLevel // "0"' "$provenance_path" 2>/dev/null || echo "0")

  jq -n \
    --arg artifact "$artifact_path" \
    --arg provenance "$provenance_path" \
    --arg status "$verification_status" \
    --arg builder_id "$builder_id" \
    --arg source_repo "$source_repo" \
    --arg slsa_level "$slsa_level" \
    --argjson checks_passed "$checks_passed" \
    --argjson checks_failed "$checks_failed" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{
      artifact: $artifact,
      provenance: $provenance,
      verification: {
        status: $status,
        timestamp: $timestamp,
        checks_passed: $checks_passed,
        checks_failed: $checks_failed
      },
      metadata: {
        builder_id: $builder_id,
        source_repo: $source_repo,
        slsa_level: ($slsa_level | tonumber)
      }
    }' > "$report_file"

  log_verbose "Report written to: $report_file"
}

generate_summary() {
  local verification_status="$1"
  local checks_passed="$2"
  local checks_failed="$3"

  if [[ "$QUIET" == "true" ]] || [[ "$OUTPUT_FORMAT" != "summary" ]]; then
    return 0
  fi

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  SLSA Provenance Verification Report${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  echo "  Artifact:    $ARTIFACT_PATH"
  echo "  Provenance:  $PROVENANCE_PATH"
  echo ""

  local status_color="$GREEN"
  local status_text="PASS"
  if [[ "$verification_status" != "pass" ]]; then
    status_color="$RED"
    status_text="FAIL"
  fi

  echo -e "  Status:      ${status_color}${status_text}${NC}"
  echo "  Checks Passed: $checks_passed"
  echo "  Checks Failed: $checks_failed"
  echo ""

  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_prerequisites
  validate_arguments

  log_info "Verifying SLSA provenance for: $ARTIFACT_PATH"
  log_verbose "Provenance file: $PROVENANCE_PATH"

  local checks_passed=0
  local checks_failed=0
  local overall_status="pass"

  # 1. Validate provenance structure
  if validate_provenance_structure "$PROVENANCE_PATH"; then
    checks_passed=$((checks_passed + 1))
  else
    checks_failed=$((checks_failed + 1))
    overall_status="fail"
  fi

  # 2. Verify artifact digest
  local artifact_digest
  artifact_digest=$(compute_artifact_digest "$ARTIFACT_PATH")

  if [[ -n "$artifact_digest" ]] && verify_artifact_digest "$artifact_digest" "$PROVENANCE_PATH"; then
    checks_passed=$((checks_passed + 1))
  else
    checks_failed=$((checks_failed + 1))
    overall_status="fail"
  fi

  # 3. Verify SLSA level
  if verify_slsa_level "$PROVENANCE_PATH"; then
    checks_passed=$((checks_passed + 1))
  else
    checks_failed=$((checks_failed + 1))
    overall_status="fail"
  fi

  # 4. Verify builder trust (optional)
  if verify_builder_trust "$PROVENANCE_PATH"; then
    checks_passed=$((checks_passed + 1))
  else
    if [[ -n "$TRUSTED_BUILDERS_FILE" ]]; then
      checks_failed=$((checks_failed + 1))
      overall_status="fail"
    fi
  fi

  # 5. Verify source repository (optional)
  if verify_source_repo "$PROVENANCE_PATH"; then
    checks_passed=$((checks_passed + 1))
  else
    if [[ -n "$TRUSTED_REPOS_FILE" ]]; then
      checks_failed=$((checks_failed + 1))
      overall_status="fail"
    fi
  fi

  # 6. Verify signature (optional)
  if verify_signature "$PROVENANCE_PATH"; then
    checks_passed=$((checks_passed + 1))
  else
    if [[ "$REQUIRE_SIGNATURE" == "true" ]]; then
      checks_failed=$((checks_failed + 1))
      overall_status="fail"
    fi
  fi

  # Generate reports
  generate_verification_report "$ARTIFACT_PATH" "$PROVENANCE_PATH" "$overall_status" "$checks_passed" "$checks_failed"
  generate_summary "$overall_status" "$checks_passed" "$checks_failed"

  if [[ "$overall_status" == "pass" ]]; then
    log_info "SLSA provenance verification passed"
    exit 0
  else
    log_error "SLSA provenance verification failed"
    exit 1
  fi
}

main "$@"
