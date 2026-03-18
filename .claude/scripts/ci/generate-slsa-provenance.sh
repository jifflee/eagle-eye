#!/usr/bin/env bash
# ============================================================
# Script: generate-slsa-provenance.sh
# Purpose: Generate SLSA provenance metadata for builds
#
# Generates SLSA-compatible provenance attestations for build
# artifacts including container images and release packages.
#
# SLSA Levels:
#   - L1: Source + build metadata documented
#   - L2: Authenticated build service
#   - L3: Hardened build platform, non-falsifiable provenance
#   - L4: Two-party review + hermetic builds
#
# Usage:
#   ./scripts/ci/generate-slsa-provenance.sh [OPTIONS]
#
# Options:
#   --artifact PATH     Path to artifact to attest (required)
#   --artifact-type TYPE Artifact type: container|package|binary (required)
#   --output PATH       Output path for provenance file (default: <artifact>.provenance.json)
#   --slsa-level LEVEL  Target SLSA level: 1|2|3 (default: 2)
#   --builder-id ID     Builder identity (default: detected from CI env)
#   --source-repo REPO  Source repository (default: detected from git)
#   --source-commit SHA Source commit SHA (default: detected from git)
#   --sign              Sign provenance with cosign (requires cosign)
#   --upload            Upload provenance to .provenance/builds/
#   --verbose           Show detailed output
#   --quiet             Suppress non-essential output
#   --help              Show this help
#
# Exit codes:
#   0 - Provenance generation successful
#   1 - Provenance generation failed
#   2 - Tool error (missing dependencies, invalid configuration)
#
# Output:
#   - Provenance JSON file in SLSA format
#   - Optional: Signed provenance with cosign
#   - Optional: Uploaded to .provenance/builds/{timestamp}/
#
# Integration:
#   - Pre-release: Generate provenance for all release artifacts
#   - Container builds: Generate provenance for Docker images
#   - Package builds: Generate provenance for npm packages
#   - QA gate: Verify provenance exists and is valid
#
# Related:
#   - scripts/ci/verify-slsa-provenance.sh - Verify SLSA provenance
#   - scripts/ci/validators/package-attestation.sh - Package attestation
#   - scripts/ci/validators/generate-sbom.sh - SBOM generation
#   - Issue #1043 - Add supply chain provenance with SLSA and sigstore
#   - Epic #1030 - CI/CD infrastructure improvements
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

ARTIFACT_PATH=""
ARTIFACT_TYPE=""
OUTPUT_PATH=""
SLSA_LEVEL=2
BUILDER_ID=""
SOURCE_REPO=""
SOURCE_COMMIT=""
SIGN=false
UPLOAD=false
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
    --artifact)       ARTIFACT_PATH="$2"; shift 2 ;;
    --artifact-type)  ARTIFACT_TYPE="$2"; shift 2 ;;
    --output)         OUTPUT_PATH="$2"; shift 2 ;;
    --slsa-level)     SLSA_LEVEL="$2"; shift 2 ;;
    --builder-id)     BUILDER_ID="$2"; shift 2 ;;
    --source-repo)    SOURCE_REPO="$2"; shift 2 ;;
    --source-commit)  SOURCE_COMMIT="$2"; shift 2 ;;
    --sign)           SIGN=true; shift ;;
    --upload)         UPLOAD=true; shift ;;
    --verbose)        VERBOSE=true; shift ;;
    --quiet)          QUIET=true; shift ;;
    --help|-h)        show_help ;;
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
  # Check for jq (required)
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    log_error "Install: apt-get install jq"
    exit 2
  fi

  # Check for git (required for source metadata)
  if ! command -v git &>/dev/null; then
    log_error "git is required but not installed"
    exit 2
  fi

  # Check for sha256sum (for artifact hashing)
  if ! command -v sha256sum &>/dev/null; then
    log_error "sha256sum is required but not installed"
    exit 2
  fi

  # Check for cosign if signing is requested
  if [[ "$SIGN" == "true" ]] && ! command -v cosign &>/dev/null; then
    log_error "cosign is required for signing but not installed"
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

  if [[ -z "$ARTIFACT_TYPE" ]]; then
    log_error "Artifact type is required (--artifact-type container|package|binary)"
    exit 2
  fi

  if [[ ! "$ARTIFACT_TYPE" =~ ^(container|package|binary)$ ]]; then
    log_error "Invalid artifact type: $ARTIFACT_TYPE (must be container|package|binary)"
    exit 2
  fi

  if [[ ! "$SLSA_LEVEL" =~ ^[1-3]$ ]]; then
    log_error "Invalid SLSA level: $SLSA_LEVEL (must be 1, 2, or 3)"
    exit 2
  fi

  log_verbose "Arguments validated"
}

# ─── Environment Detection ────────────────────────────────────────────────────

detect_builder_id() {
  if [[ -n "$BUILDER_ID" ]]; then
    echo "$BUILDER_ID"
    return
  fi

  # Detect from CI environment
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "https://github.com/actions/runner"
  elif [[ -n "${GITLAB_CI:-}" ]]; then
    echo "https://gitlab.com/gitlab-ci"
  elif [[ -n "${CIRCLECI:-}" ]]; then
    echo "https://circleci.com"
  elif [[ -n "${JENKINS_URL:-}" ]]; then
    echo "${JENKINS_URL}"
  else
    echo "local-build@$(hostname)"
  fi
}

detect_source_repo() {
  if [[ -n "$SOURCE_REPO" ]]; then
    echo "$SOURCE_REPO"
    return
  fi

  # Try git remote
  local remote_url
  remote_url=$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || echo "")

  if [[ -n "$remote_url" ]]; then
    # Normalize GitHub URLs
    remote_url=$(echo "$remote_url" | sed -e 's|git@github.com:|https://github.com/|' -e 's|\.git$||')
    echo "$remote_url"
  else
    echo "unknown"
  fi
}

detect_source_commit() {
  if [[ -n "$SOURCE_COMMIT" ]]; then
    echo "$SOURCE_COMMIT"
    return
  fi

  git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown"
}

detect_build_invocation_id() {
  # Use CI-specific build ID if available
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    echo "github-actions-${GITHUB_RUN_ID}"
  elif [[ -n "${CI_PIPELINE_ID:-}" ]]; then
    echo "gitlab-ci-${CI_PIPELINE_ID}"
  elif [[ -n "${CIRCLE_BUILD_NUM:-}" ]]; then
    echo "circleci-${CIRCLE_BUILD_NUM}"
  elif [[ -n "${BUILD_ID:-}" ]]; then
    echo "jenkins-${BUILD_ID}"
  else
    echo "local-$(date +%s)"
  fi
}

# ─── Artifact Hashing ─────────────────────────────────────────────────────────

compute_artifact_digest() {
  local artifact="$1"

  log_verbose "Computing artifact digest..."

  if [[ -f "$artifact" ]]; then
    # Single file
    sha256sum "$artifact" | awk '{print $1}'
  elif [[ -d "$artifact" ]]; then
    # Directory - hash all files and combine
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

# ─── Provenance Generation ────────────────────────────────────────────────────

generate_provenance_statement() {
  local artifact="$1"
  local artifact_digest="$2"

  log_step "Generating SLSA provenance statement..."

  local builder_id
  builder_id=$(detect_builder_id)

  local source_repo
  source_repo=$(detect_source_repo)

  local source_commit
  source_commit=$(detect_source_commit)

  local build_invocation_id
  build_invocation_id=$(detect_build_invocation_id)

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Generate subject
  local artifact_name
  artifact_name=$(basename "$artifact")

  local subject
  subject=$(jq -n \
    --arg name "$artifact_name" \
    --arg digest "sha256:$artifact_digest" \
    '{
      name: $name,
      digest: {
        "sha256": ($digest | sub("sha256:"; ""))
      }
    }')

  # Generate build metadata
  local build_metadata
  build_metadata=$(jq -n \
    --arg builder_id "$builder_id" \
    --arg invocation_id "$build_invocation_id" \
    --arg timestamp "$timestamp" \
    '{
      invocationId: $invocation_id,
      startedOn: $timestamp,
      finishedOn: $timestamp
    }')

  # Generate materials (source)
  local materials
  materials=$(jq -n \
    --arg repo "$source_repo" \
    --arg commit "$source_commit" \
    '[
      {
        uri: $repo,
        digest: {
          "sha1": $commit
        }
      }
    ]')

  # Generate recipe (build steps)
  local recipe
  recipe=$(jq -n \
    --arg artifact_type "$ARTIFACT_TYPE" \
    '{
      type: ("build-\($artifact_type)"),
      definedInMaterial: 0,
      entryPoint: "build"
    }')

  # Construct full SLSA provenance
  local provenance
  provenance=$(jq -n \
    --argjson subject "[$subject]" \
    --arg builder_id "$builder_id" \
    --argjson build_metadata "$build_metadata" \
    --argjson materials "$materials" \
    --argjson recipe "$recipe" \
    --arg slsa_level "$SLSA_LEVEL" \
    '{
      "_type": "https://in-toto.io/Statement/v0.1",
      "subject": $subject,
      "predicateType": "https://slsa.dev/provenance/v0.2",
      "predicate": {
        "builder": {
          "id": $builder_id
        },
        "buildType": "https://github.com/slsa-framework/slsa/blob/main/buildTypes/generic.md",
        "invocation": $build_metadata,
        "metadata": {
          "buildInvocationId": $build_metadata.invocationId,
          "buildStartedOn": $build_metadata.startedOn,
          "buildFinishedOn": $build_metadata.finishedOn,
          "completeness": {
            "parameters": true,
            "environment": false,
            "materials": true
          },
          "reproducible": false
        },
        "materials": $materials,
        "recipe": $recipe
      },
      "slsaLevel": $slsa_level
    }')

  echo "$provenance"
}

# ─── Signing ──────────────────────────────────────────────────────────────────

sign_provenance() {
  local provenance_file="$1"

  if [[ "$SIGN" != "true" ]]; then
    return 0
  fi

  log_step "Signing provenance with cosign..."

  if ! command -v cosign &>/dev/null; then
    log_warn "cosign not available, skipping signing"
    return 0
  fi

  local signature_file="${provenance_file}.sig"

  # Sign with cosign (keyless mode using Fulcio)
  if cosign sign-blob --yes "$provenance_file" --output-signature "$signature_file" 2>&1 | \
     ([ "$VERBOSE" == "true" ] && cat || grep -v "^" ); then
    log_info "Provenance signed: $signature_file"
  else
    log_warn "Failed to sign provenance (continuing without signature)"
  fi
}

# ─── Upload ───────────────────────────────────────────────────────────────────

upload_provenance() {
  local provenance_file="$1"

  if [[ "$UPLOAD" != "true" ]]; then
    return 0
  fi

  log_step "Uploading provenance artifacts..."

  local timestamp
  timestamp=$(date -u +"%Y%m%dT%H%M%SZ")

  local upload_dir="$REPO_ROOT/.provenance/builds/$timestamp"
  mkdir -p "$upload_dir"

  # Copy provenance file
  cp "$provenance_file" "$upload_dir/"
  log_verbose "Uploaded: $(basename "$provenance_file")"

  # Copy signature if exists
  if [[ -f "${provenance_file}.sig" ]]; then
    cp "${provenance_file}.sig" "$upload_dir/"
    log_verbose "Uploaded: $(basename "${provenance_file}.sig")"
  fi

  log_info "Uploaded provenance to: $upload_dir"

  # Create latest symlink
  local latest_link="$REPO_ROOT/.provenance/builds/latest"
  rm -f "$latest_link"
  ln -s "$timestamp" "$latest_link"
  log_verbose "Updated latest symlink"
}

# ─── Report ───────────────────────────────────────────────────────────────────

generate_summary() {
  local provenance_file="$1"
  local artifact_digest="$2"

  if [[ "$QUIET" == "true" ]]; then
    return 0
  fi

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  SLSA Provenance Generation Report${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  echo "  Artifact:        $ARTIFACT_PATH"
  echo "  Artifact Type:   $ARTIFACT_TYPE"
  echo "  Artifact Digest: sha256:${artifact_digest:0:16}..."
  echo "  SLSA Level:      $SLSA_LEVEL"
  echo ""

  echo "  Source:"
  echo "    Repository:    $(detect_source_repo)"
  echo "    Commit:        $(detect_source_commit)"
  echo ""

  echo "  Builder:"
  echo "    Builder ID:    $(detect_builder_id)"
  echo "    Build ID:      $(detect_build_invocation_id)"
  echo ""

  echo "  Provenance:"
  echo -e "    File:          ${GREEN}$provenance_file${NC}"

  if [[ -f "${provenance_file}.sig" ]]; then
    echo -e "    Signature:     ${GREEN}${provenance_file}.sig${NC}"
  else
    echo "    Signature:     Not signed"
  fi

  if [[ "$UPLOAD" == "true" ]]; then
    echo "    Uploaded:      Yes (.provenance/builds/)"
  fi

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_prerequisites
  validate_arguments

  log_info "Generating SLSA provenance for: $ARTIFACT_PATH"
  log_verbose "Artifact type: $ARTIFACT_TYPE"
  log_verbose "SLSA level: $SLSA_LEVEL"

  # Compute artifact digest
  local artifact_digest
  artifact_digest=$(compute_artifact_digest "$ARTIFACT_PATH")

  if [[ -z "$artifact_digest" ]]; then
    log_error "Failed to compute artifact digest"
    exit 1
  fi

  log_verbose "Artifact digest: sha256:$artifact_digest"

  # Determine output path
  if [[ -z "$OUTPUT_PATH" ]]; then
    OUTPUT_PATH="${ARTIFACT_PATH}.provenance.json"
  fi

  # Generate provenance statement
  local provenance
  provenance=$(generate_provenance_statement "$ARTIFACT_PATH" "$artifact_digest")

  if [[ -z "$provenance" ]]; then
    log_error "Failed to generate provenance statement"
    exit 1
  fi

  # Write provenance to file
  echo "$provenance" | jq '.' > "$OUTPUT_PATH"
  log_info "Provenance generated: $OUTPUT_PATH"

  # Sign provenance if requested
  sign_provenance "$OUTPUT_PATH"

  # Upload if requested
  upload_provenance "$OUTPUT_PATH"

  # Generate summary
  generate_summary "$OUTPUT_PATH" "$artifact_digest"

  log_info "SLSA provenance generation completed successfully"
  exit 0
}

main "$@"
