#!/usr/bin/env bash
# ============================================================
# Script: container-scan.sh
# Purpose: Container image vulnerability scanning with Trivy
#
# Scans Docker container images for CVEs in base images and
# installed packages. Blocks deployment on critical/high findings.
#
# Usage:
#   ./scripts/ci/validators/container-scan.sh [OPTIONS]
#
# Options:
#   --image IMAGE        Docker image to scan (required)
#   --severity LEVEL     Minimum severity: CRITICAL,HIGH,MEDIUM,LOW (default: MEDIUM)
#   --output FILE        Write JSON report to FILE (default: container-scan-report.json)
#   --no-fail            Exit 0 even if vulnerabilities found
#   --verbose            Show detailed scan output
#   --dry-run            Show what would be scanned
#   --install-trivy      Auto-install Trivy if not present
#   --help               Show this help
#
# Exit codes:
#   0  No vulnerabilities found (or --no-fail)
#   1  Medium/low vulnerabilities found
#   2  Critical/high vulnerabilities found (blocks deployment)
#   3  Scan error (Trivy failed or image not found)
#
# Integration:
#   This script is called by qa-gate.sh before deployment.
#   It scans images built by container-launch.sh and deployment images.
#
# Related:
#   - scripts/container/container-launch.sh    - Builds containers to scan
#   - scripts/qa-gate.sh              - Calls this script for validation
#   - docs/security/phase1-docker-security-review.md
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

IMAGE=""
SEVERITY="${CONTAINER_SCAN_SEVERITY:-MEDIUM}"
OUTPUT_FILE="${CONTAINER_SCAN_REPORT:-container-scan-report.json}"
NO_FAIL=false
VERBOSE=false
DRY_RUN=false
INSTALL_TRIVY=false

# Trivy configuration
TRIVY_CACHE_DIR="${HOME}/.cache/trivy"
TRIVY_TIMEOUT="5m"
TRIVY_VERSION="0.48.0"  # Known stable version

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --severity)
      SEVERITY="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --no-fail)
      NO_FAIL=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --install-trivy)
      INSTALL_TRIVY=true
      shift
      ;;
    --help|-h)
      show_help
      ;;
    *)
      echo -e "${RED}[ERROR]${NC} Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 3
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
    echo -e "${BLUE}[DEBUG]${NC} $*"
  fi
}

# ─── Validation ───────────────────────────────────────────────────────────────

validate_inputs() {
  if [[ -z "$IMAGE" ]]; then
    log_error "--image is required"
    echo "Run with --help for usage." >&2
    exit 3
  fi

  # Validate severity level
  case "$SEVERITY" in
    CRITICAL|HIGH|MEDIUM|LOW) ;;
    *)
      log_error "Invalid severity: $SEVERITY (must be CRITICAL, HIGH, MEDIUM, or LOW)"
      exit 3
      ;;
  esac
}

# ─── Trivy Installation ───────────────────────────────────────────────────────

check_trivy() {
  if command -v trivy &>/dev/null; then
    log_verbose "Trivy found: $(command -v trivy)"
    local version
    version=$(trivy --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    log_verbose "Trivy version: $version"
    return 0
  fi
  return 1
}

install_trivy() {
  log_info "Installing Trivy v${TRIVY_VERSION}..."

  local os arch install_dir
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  # Map architecture names
  case "$arch" in
    x86_64) arch="64bit" ;;
    aarch64|arm64) arch="ARM64" ;;
    *)
      log_error "Unsupported architecture: $arch"
      return 1
      ;;
  esac

  # Map OS names
  case "$os" in
    linux) os="Linux" ;;
    darwin) os="macOS" ;;
    *)
      log_error "Unsupported OS: $os"
      return 1
      ;;
  esac

  # Determine install directory
  if [[ -w "/usr/local/bin" ]]; then
    install_dir="/usr/local/bin"
  else
    install_dir="${HOME}/.local/bin"
    mkdir -p "$install_dir"
    log_verbose "Installing to user directory: $install_dir"
  fi

  local download_url="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${os}-${arch}.tar.gz"
  local temp_dir
  temp_dir=$(mktemp -d)

  log_verbose "Downloading from: $download_url"

  if ! curl -fsSL "$download_url" | tar -xz -C "$temp_dir" trivy 2>/dev/null; then
    log_error "Failed to download Trivy from $download_url"
    rm -rf "$temp_dir"
    return 1
  fi

  if ! mv "$temp_dir/trivy" "$install_dir/trivy" 2>/dev/null; then
    log_error "Failed to install Trivy to $install_dir (permission denied?)"
    log_error "Try running with sudo or install manually: https://aquasecurity.github.io/trivy/"
    rm -rf "$temp_dir"
    return 1
  fi

  chmod +x "$install_dir/trivy"
  rm -rf "$temp_dir"

  # Add to PATH if needed
  if [[ "$install_dir" == "${HOME}/.local/bin" ]] && [[ ":$PATH:" != *":$install_dir:"* ]]; then
    export PATH="$install_dir:$PATH"
    log_verbose "Added $install_dir to PATH"
  fi

  log_info "Trivy installed successfully: $(trivy --version 2>&1 | head -1)"
  return 0
}

ensure_trivy() {
  if check_trivy; then
    return 0
  fi

  log_warn "Trivy not found"

  if [[ "$INSTALL_TRIVY" == "true" ]]; then
    install_trivy || {
      log_error "Trivy installation failed"
      log_error "Install manually: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
      return 1
    }
  else
    log_error "Trivy is required for container scanning"
    log_error "Install with: --install-trivy flag or manually from https://aquasecurity.github.io/trivy/"
    return 1
  fi
}

# ─── Image Validation ─────────────────────────────────────────────────────────

check_image_exists() {
  local image="$1"

  log_verbose "Checking if image exists: $image"

  if docker image inspect "$image" &>/dev/null; then
    log_verbose "Image found in local registry"
    return 0
  else
    log_error "Image not found: $image"
    log_error "Build the image first or check the image name"
    return 1
  fi
}

# ─── Trivy Scan ───────────────────────────────────────────────────────────────

run_trivy_scan() {
  local image="$1"
  local severity="$2"
  local output_file="$3"

  log_info "Scanning image: $image"
  log_info "Severity threshold: $severity"

  # Create cache directory
  mkdir -p "$TRIVY_CACHE_DIR"

  # Build Trivy command
  local -a trivy_args=(
    "image"
    "--format" "json"
    "--output" "$output_file"
    "--severity" "$severity"
    "--timeout" "$TRIVY_TIMEOUT"
    "--cache-dir" "$TRIVY_CACHE_DIR"
    "--quiet"
  )

  if [[ "$VERBOSE" == "true" ]]; then
    trivy_args=("${trivy_args[@]/--quiet/}")
    trivy_args+=("--debug")
  fi

  trivy_args+=("$image")

  log_verbose "Running: trivy ${trivy_args[*]}"

  # Run scan
  local exit_code=0
  if [[ "$VERBOSE" == "true" ]]; then
    trivy "${trivy_args[@]}" || exit_code=$?
  else
    trivy "${trivy_args[@]}" 2>&1 | grep -v "^[0-9]" || exit_code=$?
  fi

  # Trivy exit codes:
  # 0 = no vulnerabilities found
  # 1 = vulnerabilities found (any severity)
  # Other = scan error

  if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 1 ]]; then
    log_error "Trivy scan failed with exit code: $exit_code"
    return 3
  fi

  return $exit_code
}

# ─── Report Analysis ──────────────────────────────────────────────────────────

analyze_report() {
  local report_file="$1"

  if [[ ! -f "$report_file" ]]; then
    log_error "Report file not found: $report_file"
    return 3
  fi

  # Parse Trivy JSON output
  # Trivy format: { "Results": [{ "Vulnerabilities": [...] }] }

  local total critical high medium low
  total=$(jq '[.Results[]?.Vulnerabilities[]? // empty] | length' "$report_file" 2>/dev/null || echo "0")
  critical=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "$report_file" 2>/dev/null || echo "0")
  high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' "$report_file" 2>/dev/null || echo "0")
  medium=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "MEDIUM")] | length' "$report_file" 2>/dev/null || echo "0")
  low=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "LOW")] | length' "$report_file" 2>/dev/null || echo "0")

  echo ""
  echo -e "${BLUE}Vulnerability Summary:${NC}"
  echo "  Total:    $total"
  echo -e "  Critical: ${RED}$critical${NC}"
  echo -e "  High:     ${YELLOW}$high${NC}"
  echo "  Medium:   $medium"
  echo "  Low:      $low"
  echo ""

  # Determine exit code based on findings
  if [[ "$total" -eq 0 ]]; then
    echo -e "${GREEN}✓ No vulnerabilities found${NC}"
    return 0
  fi

  # Critical or high = block deployment
  if [[ "$critical" -gt 0 ]] || [[ "$high" -gt 0 ]]; then
    echo -e "${RED}✗ CRITICAL/HIGH vulnerabilities found - deployment blocked${NC}"
    echo ""
    echo "  Critical and high severity vulnerabilities must be remediated before deployment."
    echo "  Review the full report: $report_file"
    return 2
  fi

  # Medium/low = warning
  if [[ "$medium" -gt 0 ]] || [[ "$low" -gt 0 ]]; then
    echo -e "${YELLOW}! Medium/low vulnerabilities found${NC}"
    echo ""
    echo "  These vulnerabilities should be addressed but don't block deployment."
    echo "  Review the full report: $report_file"
    return 1
  fi

  return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BLUE}Container Image Vulnerability Scanner${NC}"
  echo "────────────────────────────────────────"

  validate_inputs

  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would scan container image:"
    echo "  Image:    $IMAGE"
    echo "  Severity: $SEVERITY"
    echo "  Output:   $OUTPUT_FILE"
    echo ""
    exit 0
  fi

  # Ensure Trivy is available
  ensure_trivy || exit 3

  # Check image exists
  check_image_exists "$IMAGE" || exit 3

  # Run scan
  local scan_exit=0
  run_trivy_scan "$IMAGE" "$SEVERITY" "$OUTPUT_FILE" || scan_exit=$?

  if [[ $scan_exit -eq 3 ]]; then
    log_error "Scan failed - exiting"
    exit 3
  fi

  # Analyze results
  local analysis_exit=0
  analyze_report "$OUTPUT_FILE" || analysis_exit=$?

  # Apply --no-fail override
  if [[ "$NO_FAIL" == "true" ]]; then
    if [[ $analysis_exit -ne 0 ]]; then
      log_warn "--no-fail flag set, exiting 0 despite findings"
    fi
    exit 0
  fi

  exit $analysis_exit
}

main "$@"
