#!/usr/bin/env bash
#
# Run E2E tests in containerized browsers with network isolation
#
# This script runs Playwright tests in Docker containers,
# ensuring browsers can ONLY access the specified test target URL and port.
#
# Security Features:
# - Network isolation: Browsers cannot access external resources
# - Container isolation: No host filesystem access
# - Port restriction: Only specified ports are accessible
# - DNS blocking: External domain resolution is blocked
#
# Prerequisites:
# - Docker Desktop installed and running
#
# Usage:
#   ./scripts/run-e2e-containerized.sh [options]
#
# Options:
#   --url URL       Base URL to test (default: http://localhost:3000)
#   --port PORT     Port to expose (default: 3000)
#   --browser NAME  Browser to test (chromium, firefox, webkit)
#   --smoke         Run only smoke tests
#   --headed        Run with visible browser (for debugging)
#   --no-cleanup    Keep containers after tests
#   --help          Show this help message

set -euo pipefail

# Configuration
DEFAULT_URL="http://localhost:3000"
DEFAULT_PORT="3000"
DEFAULT_BROWSER="chromium"
COMPOSE_FILE="tests/e2e/docker/docker-compose.e2e.yml"
NETWORK_NAME="e2e-isolated"

# Parse arguments
URL="${E2E_BASE_URL:-$DEFAULT_URL}"
PORT="$DEFAULT_PORT"
BROWSER="$DEFAULT_BROWSER"
SMOKE_ONLY=false
HEADED=false
CLEANUP=true

while [[ $# -gt 0 ]]; do
  case $1 in
    --url)
      URL="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --browser)
      BROWSER="$2"
      shift 2
      ;;
    --smoke)
      SMOKE_ONLY=true
      shift
      ;;
    --headed)
      HEADED=true
      shift
      ;;
    --no-cleanup)
      CLEANUP=false
      shift
      ;;
    --help)
      head -30 "$0" | tail -25
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
  log_info "Checking prerequisites..."

  # Check Docker CLI
  if ! command -v docker &> /dev/null; then
    log_error "Docker not found. Install Docker Desktop: brew install --cask docker"
    exit 1
  fi

  # Verify Docker is accessible
  if ! docker info &> /dev/null; then
    log_error "Cannot connect to Docker. Is Docker Desktop running?"
    exit 1
  fi

  log_info "Prerequisites OK"
}

# Create isolated network
create_network() {
  log_info "Creating isolated network: $NETWORK_NAME"

  # Remove existing network if present
  docker network rm "$NETWORK_NAME" 2>/dev/null || true

  # Create new isolated network with specific subnet
  docker network create \
    --driver bridge \
    --subnet=172.28.0.0/16 \
    --opt com.docker.network.bridge.enable_ip_masquerade=false \
    "$NETWORK_NAME"

  log_info "Network created with IP masquerade disabled (no external access)"
}

# Build test container
build_container() {
  log_info "Building Playwright test container..."

  docker build \
    -f tests/e2e/docker/Dockerfile.playwright \
    -t playwright-e2e \
    .

  log_info "Container built successfully"
}

# Run tests
run_tests() {
  log_info "Running E2E tests..."
  log_info "Target URL: $URL"
  log_info "Browser: $BROWSER"
  log_info "Smoke only: $SMOKE_ONLY"

  # Determine test command
  TEST_CMD="npx playwright test --project=$BROWSER"
  if [ "$SMOKE_ONLY" = true ]; then
    TEST_CMD="$TEST_CMD tests/e2e/smoke"
  fi

  # Extract host and port from URL
  # shellcheck disable=SC2001
  TARGET_HOST=$(echo "$URL" | sed 's|http[s]*://||' | cut -d: -f1 | cut -d/ -f1)
  TARGET_PORT=$(echo "$URL" | sed 's|http[s]*://||' | cut -d: -f2 | cut -d/ -f1)
  TARGET_PORT="${TARGET_PORT:-80}"

  log_info "Resolved target: $TARGET_HOST:$TARGET_PORT"

  # Run with docker-compose for proper isolation
  export E2E_BASE_URL="$URL"

  docker-compose \
    -f "$COMPOSE_FILE" \
    up \
    --abort-on-container-exit \
    --exit-code-from playwright

  local exit_code=$?

  return $exit_code
}

# Cleanup
cleanup() {
  if [ "$CLEANUP" = true ]; then
    log_info "Cleaning up containers and network..."

    docker-compose -f "$COMPOSE_FILE" down --volumes --remove-orphans 2>/dev/null || true
    docker network rm "$NETWORK_NAME" 2>/dev/null || true

    log_info "Cleanup complete"
  else
    log_warn "Skipping cleanup (--no-cleanup specified)"
  fi
}

# Main execution
main() {
  log_info "=========================================="
  log_info "Containerized E2E Testing with Docker"
  log_info "=========================================="

  check_prerequisites

  # Setup cleanup trap
  trap cleanup EXIT

  create_network
  build_container
  run_tests

  log_info "=========================================="
  log_info "E2E Tests Complete"
  log_info "=========================================="
}

main "$@"
