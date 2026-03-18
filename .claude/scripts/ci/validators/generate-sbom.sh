#!/usr/bin/env bash
# ============================================================
# Script: generate-sbom.sh
# Purpose: Software Bill of Materials (SBOM) generation for builds
#
# Generates SBOM using syft in SPDX and CycloneDX formats for all
# npm and Python dependencies.
#
# Usage:
#   ./scripts/ci/validators/generate-sbom.sh [OPTIONS]
#
# Options:
#   --output-dir DIR    Output directory for SBOMs (default: .sbom/)
#   --formats FORMATS   Comma-separated formats: spdx-json,cyclonedx-json,spdx,cyclonedx (default: spdx-json,cyclonedx-json)
#   --package-dir DIR   Package directory to scan (default: repo root)
#   --ecosystems TYPES  Comma-separated: npm,python,all (default: all)
#   --validate          Validate generated SBOMs after creation
#   --upload            Upload SBOMs to .sbom/builds/ with timestamp
#   --verbose           Show detailed output
#   --quiet             Suppress non-essential output
#   --install-tools     Install syft and cyclonedx-cli if missing
#   --help              Show this help
#
# Exit codes:
#   0 - SBOM generation successful
#   1 - SBOM generation failed (missing dependencies, invalid output)
#   2 - Tool error (syft/cyclonedx not available, cannot install)
#
# Output:
#   - SBOM files written to output directory:
#     - sbom.spdx.json       (SPDX JSON format)
#     - sbom.cyclonedx.json  (CycloneDX JSON format)
#     - sbom.spdx            (SPDX tag-value format, optional)
#     - sbom.cyclonedx.xml   (CycloneDX XML format, optional)
#   - Build artifacts stored in .sbom/builds/{timestamp}/ if --upload enabled
#
# Integration:
#   - Pre-PR: Generate SBOM for PR review
#   - Pre-merge: Validate SBOM completeness
#   - Pre-release: Upload SBOM to artifact storage
#   - QA gate: Verify all dependencies covered
#
# Related:
#   - Issue #1038 - Add SBOM generation to CI builds
#   - Epic #1030 - CI/CD infrastructure improvements
#   - scripts/ci/validators/dep-audit.sh - Dependency vulnerability scanning
#   - scripts/ci/runners/run-pipeline.sh - CI orchestrator
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

OUTPUT_DIR="$REPO_ROOT/.sbom"
FORMATS="spdx-json,cyclonedx-json"
PACKAGE_DIR="$REPO_ROOT"
ECOSYSTEMS="all"
VALIDATE=false
UPLOAD=false
VERBOSE=false
QUIET=false
INSTALL_TOOLS=false

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
    --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
    --formats)        FORMATS="$2"; shift 2 ;;
    --package-dir)    PACKAGE_DIR="$2"; shift 2 ;;
    --ecosystems)     ECOSYSTEMS="$2"; shift 2 ;;
    --validate)       VALIDATE=true; shift ;;
    --upload)         UPLOAD=true; shift ;;
    --verbose)        VERBOSE=true; shift ;;
    --quiet)          QUIET=true; shift ;;
    --install-tools)  INSTALL_TOOLS=true; shift ;;
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

# ─── Tool Installation ────────────────────────────────────────────────────────

install_syft() {
  log_step "Installing syft..."

  local syft_version="v1.18.1"
  local install_dir="$HOME/.local/bin"
  mkdir -p "$install_dir"

  # Detect architecture
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      log_error "Unsupported architecture: $arch"
      return 1
      ;;
  esac

  local os
  os=$(uname -s | tr '[:upper:]' '[:lower:]')

  local download_url="https://github.com/anchore/syft/releases/download/${syft_version}/syft_${syft_version#v}_${os}_${arch}.tar.gz"

  log_verbose "Downloading syft from: $download_url"

  local tmp_dir
  tmp_dir=$(mktemp -d)

  if ! curl -fsSL "$download_url" -o "$tmp_dir/syft.tar.gz"; then
    log_error "Failed to download syft"
    rm -rf "$tmp_dir"
    return 1
  fi

  tar -xzf "$tmp_dir/syft.tar.gz" -C "$tmp_dir"
  mv "$tmp_dir/syft" "$install_dir/syft"
  chmod +x "$install_dir/syft"
  rm -rf "$tmp_dir"

  # Add to PATH if not already there
  if [[ ":$PATH:" != *":$install_dir:"* ]]; then
    export PATH="$install_dir:$PATH"
  fi

  log_info "syft installed successfully: $install_dir/syft"
  return 0
}

install_cyclonedx() {
  log_step "Installing cyclonedx-cli..."

  # cyclonedx-cli is a .NET tool, check if dotnet is available
  if ! command -v dotnet &>/dev/null; then
    log_warn "dotnet SDK not available, skipping cyclonedx-cli installation"
    log_warn "Install .NET SDK from: https://dotnet.microsoft.com/download"
    return 1
  fi

  if dotnet tool install --global CycloneDX &>/dev/null; then
    log_info "cyclonedx-cli installed successfully"
    return 0
  else
    log_warn "Failed to install cyclonedx-cli via dotnet tool"
    return 1
  fi
}

# ─── Tool Validation ──────────────────────────────────────────────────────────

check_tools() {
  local missing_tools=()

  # Check for jq (required for validation)
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    log_error "Install: apt-get install jq"
    exit 2
  fi

  # Check for syft
  if ! command -v syft &>/dev/null; then
    if [[ "$INSTALL_TOOLS" == "true" ]]; then
      if ! install_syft; then
        missing_tools+=("syft")
      fi
    else
      missing_tools+=("syft")
    fi
  fi

  # CycloneDX is optional - syft can generate CycloneDX format too
  if [[ "$FORMATS" == *"cyclonedx"* ]] && ! command -v cyclonedx &>/dev/null; then
    log_verbose "cyclonedx-cli not found, will use syft for CycloneDX generation"
  fi

  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing_tools[*]}"
    log_error "Install with: $0 --install-tools"
    log_error "Or manually:"
    for tool in "${missing_tools[@]}"; do
      case "$tool" in
        syft)
          log_error "  syft: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b ~/.local/bin"
          ;;
        cyclonedx)
          log_error "  cyclonedx-cli: dotnet tool install --global CycloneDX"
          ;;
      esac
    done
    exit 2
  fi

  log_verbose "All required tools available"
}

# ─── SBOM Generation ──────────────────────────────────────────────────────────

detect_package_ecosystems() {
  local detected=()

  # Check for npm
  if [[ -f "$PACKAGE_DIR/package.json" ]]; then
    detected+=("npm")
    log_verbose "Detected npm ecosystem: $PACKAGE_DIR/package.json"
  fi

  # Check for Python
  if [[ -f "$PACKAGE_DIR/requirements.txt" ]] || compgen -G "$PACKAGE_DIR/requirements*.txt" > /dev/null; then
    detected+=("python")
    log_verbose "Detected Python ecosystem: requirements*.txt"
  fi

  if [[ ${#detected[@]} -eq 0 ]]; then
    log_warn "No package ecosystems detected in $PACKAGE_DIR"
  fi

  echo "${detected[@]}"
}

generate_sbom_with_syft() {
  local format="$1"
  local output_file="$2"

  log_step "Generating SBOM with syft (format: $format)..."

  local syft_format=""
  case "$format" in
    spdx-json)
      syft_format="spdx-json"
      ;;
    cyclonedx-json)
      syft_format="cyclonedx-json"
      ;;
    spdx)
      syft_format="spdx-tag-value"
      ;;
    cyclonedx)
      syft_format="cyclonedx-xml"
      ;;
    *)
      log_error "Unknown format: $format"
      return 1
      ;;
  esac

  local syft_args=(
    "$PACKAGE_DIR"
    -o "$syft_format=$output_file"
  )

  # Add ecosystem filters if specified
  if [[ "$ECOSYSTEMS" != "all" ]]; then
    IFS=',' read -ra ecosystem_list <<< "$ECOSYSTEMS"
    for ecosystem in "${ecosystem_list[@]}"; do
      case "$ecosystem" in
        npm)
          syft_args+=(--catalogers "javascript-package-cataloger")
          ;;
        python)
          syft_args+=(--catalogers "python-package-cataloger")
          ;;
      esac
    done
  fi

  if [[ "$VERBOSE" == "true" ]]; then
    syft_args+=(-vv)
  else
    syft_args+=(-q)
  fi

  log_verbose "Running: syft ${syft_args[*]}"

  if syft "${syft_args[@]}" 2>&1 | ([ "$VERBOSE" == "true" ] && cat || grep -v "^"); then
    log_info "Generated SBOM: $output_file"
    return 0
  else
    log_error "Failed to generate SBOM with syft"
    return 1
  fi
}

# ─── SBOM Validation ──────────────────────────────────────────────────────────

validate_sbom() {
  local format="$1"
  local file="$2"

  log_step "Validating SBOM: $file"

  if [[ ! -f "$file" ]]; then
    log_error "SBOM file not found: $file"
    return 1
  fi

  local validation_failed=false

  # Basic validation: check file is valid JSON for JSON formats
  if [[ "$format" == *"json"* ]]; then
    if ! jq empty "$file" 2>/dev/null; then
      log_error "SBOM is not valid JSON: $file"
      validation_failed=true
    fi

    # Count packages in SBOM
    local package_count=0
    case "$format" in
      spdx-json)
        package_count=$(jq '.packages | length' "$file" 2>/dev/null || echo "0")
        log_verbose "SPDX SBOM contains $package_count packages"
        ;;
      cyclonedx-json)
        package_count=$(jq '.components | length' "$file" 2>/dev/null || echo "0")
        log_verbose "CycloneDX SBOM contains $package_count components"
        ;;
    esac

    if [[ $package_count -eq 0 ]]; then
      log_warn "SBOM contains no packages/components: $file"
      validation_failed=true
    else
      log_info "SBOM validation passed: $package_count packages/components"
    fi
  fi

  if [[ "$validation_failed" == "true" ]]; then
    return 1
  fi

  return 0
}

# ─── SBOM Upload ──────────────────────────────────────────────────────────────

upload_sbom_artifacts() {
  if [[ "$UPLOAD" != "true" ]]; then
    return 0
  fi

  log_step "Uploading SBOM artifacts..."

  local timestamp
  timestamp=$(date -u +"%Y%m%dT%H%M%SZ")

  local upload_dir="$OUTPUT_DIR/builds/$timestamp"
  mkdir -p "$upload_dir"

  # Copy all SBOM files to upload directory
  local copied_count=0
  for file in "$OUTPUT_DIR"/sbom.*; do
    if [[ -f "$file" ]]; then
      cp "$file" "$upload_dir/"
      copied_count=$((copied_count + 1))
      log_verbose "Uploaded: $(basename "$file")"
    fi
  done

  if [[ $copied_count -gt 0 ]]; then
    log_info "Uploaded $copied_count SBOM artifact(s) to: $upload_dir"

    # Create latest symlink
    local latest_link="$OUTPUT_DIR/builds/latest"
    rm -f "$latest_link"
    ln -s "$timestamp" "$latest_link"
    log_verbose "Updated latest symlink"
  else
    log_warn "No SBOM files found to upload"
  fi
}

# ─── Report Generation ────────────────────────────────────────────────────────

generate_summary() {
  local generated_files=("$@")

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  SBOM Generation Report${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  local ecosystems
  ecosystems=$(detect_package_ecosystems)

  echo "  Package Directory: $PACKAGE_DIR"
  echo "  Ecosystems:        ${ecosystems:-none detected}"
  echo "  Output Directory:  $OUTPUT_DIR"
  echo ""

  echo "  Generated SBOMs:"
  for file in "${generated_files[@]}"; do
    if [[ -f "$file" ]]; then
      local size
      size=$(du -h "$file" | cut -f1)
      echo -e "    ${GREEN}✓${NC} $(basename "$file") ($size)"
    else
      echo -e "    ${RED}✗${NC} $(basename "$file") (failed)"
    fi
  done

  echo ""

  if [[ "$VALIDATE" == "true" ]]; then
    echo "  Validation: Enabled"
  fi

  if [[ "$UPLOAD" == "true" ]]; then
    echo "  Upload:     Enabled (stored in $OUTPUT_DIR/builds/)"
  fi

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_tools

  log_info "Starting SBOM generation..."
  log_verbose "Package directory: $PACKAGE_DIR"
  log_verbose "Output directory: $OUTPUT_DIR"
  log_verbose "Formats: $FORMATS"
  log_verbose "Ecosystems: $ECOSYSTEMS"

  # Create output directory
  mkdir -p "$OUTPUT_DIR"

  # Parse format list
  IFS=',' read -ra format_list <<< "$FORMATS"

  local generated_files=()
  local failed=false

  # Generate SBOMs for each format
  for format in "${format_list[@]}"; do
    local output_file=""
    case "$format" in
      spdx-json)
        output_file="$OUTPUT_DIR/sbom.spdx.json"
        ;;
      cyclonedx-json)
        output_file="$OUTPUT_DIR/sbom.cyclonedx.json"
        ;;
      spdx)
        output_file="$OUTPUT_DIR/sbom.spdx"
        ;;
      cyclonedx)
        output_file="$OUTPUT_DIR/sbom.cyclonedx.xml"
        ;;
      *)
        log_error "Unknown format: $format"
        failed=true
        continue
        ;;
    esac

    if ! generate_sbom_with_syft "$format" "$output_file"; then
      failed=true
      continue
    fi

    generated_files+=("$output_file")

    # Validate if requested
    if [[ "$VALIDATE" == "true" ]]; then
      if ! validate_sbom "$format" "$output_file"; then
        log_error "SBOM validation failed: $output_file"
        failed=true
      fi
    fi
  done

  # Upload artifacts if requested
  upload_sbom_artifacts

  # Generate summary
  if [[ "$QUIET" != "true" ]]; then
    generate_summary "${generated_files[@]}"
  fi

  # Exit with appropriate code
  if [[ "$failed" == "true" ]]; then
    log_error "SBOM generation completed with errors"
    exit 1
  fi

  log_info "SBOM generation completed successfully"
  exit 0
}

main "$@"
