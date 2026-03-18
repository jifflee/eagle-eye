#!/bin/bash
set -euo pipefail
# validate-phase1.sh
# Validates Phase 1 automation deployment readiness
# Epic #491 - Phase 1 Automation Deployment

set -e

SCRIPT_NAME="validate-phase1.sh"
VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASS=0
FAIL=0
WARN=0

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Print functions
pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}✗${NC} $1"; ((FAIL++)); }
warn() { echo -e "${YELLOW}⚠${NC} $1"; ((WARN++)); }
info() { echo -e "  $1"; }

usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Phase 1 Deployment Validation

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    --all           Run all validations
    --prerequisites Check software prerequisites
    --tokens        Validate token configuration
    --docker        Validate Docker setup
    --n8n           Validate n8n setup
    --e2e           Run end-to-end test
    --json          Output results as JSON
    --help          Show this help

EXAMPLES:
    $SCRIPT_NAME --all           # Full validation
    $SCRIPT_NAME --prerequisites # Just check software
    $SCRIPT_NAME --tokens        # Just check tokens

EOF
}

# Check software prerequisites
check_prerequisites() {
    echo ""
    echo "=== Prerequisites Check ==="
    echo ""

    # Docker
    if command -v docker &> /dev/null; then
        version=$(docker --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
        pass "Docker installed (v$version)"
    else
        fail "Docker not installed"
    fi

    # Docker daemon
    if docker info &> /dev/null 2>&1; then
        pass "Docker daemon running"
    else
        fail "Docker daemon not running"
        info "Try: open -a Docker (macOS) or systemctl start docker (Linux)"
    fi

    # GitHub CLI
    if command -v gh &> /dev/null; then
        version=$(gh --version | head -1 | grep -oE '[0-9]+\.[0-9]+')
        pass "GitHub CLI installed (v$version)"
    else
        fail "GitHub CLI not installed"
        info "Install: brew install gh"
    fi

    # gh auth status
    if gh auth status &> /dev/null 2>&1; then
        pass "GitHub CLI authenticated"
    else
        fail "GitHub CLI not authenticated"
        info "Run: gh auth login"
    fi

    # jq
    if command -v jq &> /dev/null; then
        version=$(jq --version | grep -oE '[0-9]+\.[0-9]+')
        pass "jq installed (v$version)"
    else
        fail "jq not installed"
        info "Install: brew install jq"
    fi

    # Docker Desktop (macOS)
    if [[ "$(uname)" == "Darwin" ]]; then
        if docker info &> /dev/null 2>&1; then
            pass "Docker Desktop running"
        else
            warn "Docker Desktop not running"
            info "Start Docker Desktop from Applications or run: open -a Docker"
        fi
    fi
}

# Check token configuration
check_tokens() {
    echo ""
    echo "=== Token Validation ==="
    echo ""

    # Check if load-container-tokens.sh exists
    if [ -f "${SCRIPT_DIR}/load-container-tokens.sh" ]; then
        pass "Token loader script exists"
    else
        fail "Token loader script missing"
        return
    fi

    # Check GitHub token in keychain
    if security find-generic-password -s "github-container-token" -w &> /dev/null 2>&1; then
        token=$(security find-generic-password -s "github-container-token" -w 2>/dev/null)
        if [[ "$token" == ghp_* ]] || [[ "$token" == github_pat_* ]]; then
            pass "GitHub token in keychain (valid format)"
        else
            warn "GitHub token format may be invalid"
        fi
    else
        fail "GitHub token not in keychain"
        info "Add: security add-generic-password -a \$USER -s github-container-token -w YOUR_TOKEN -U"
    fi

    # Check Claude token in keychain
    if security find-generic-password -s "claude-oauth-token" -w &> /dev/null 2>&1; then
        token=$(security find-generic-password -s "claude-oauth-token" -w 2>/dev/null)
        if [[ "$token" == sk-ant-oat01-* ]]; then
            pass "Claude OAuth token in keychain (correct type)"
        elif [[ "$token" == sk-ant-sid01-* ]]; then
            fail "Claude token is SESSION type (not OAuth)"
            info "Session tokens don't work in containers. Run: claude setup-token"
        elif [[ "$token" == sk-ant-api03-* ]]; then
            pass "Claude API key in keychain (acceptable)"
        else
            warn "Claude token format unknown"
        fi
    else
        fail "Claude token not in keychain"
        info "Add: security add-generic-password -a \$USER -s claude-oauth-token -w YOUR_TOKEN -U"
    fi

    # Test token loading
    if [ -f "${SCRIPT_DIR}/load-container-tokens.sh" ]; then
        if "${SCRIPT_DIR}/load-container-tokens.sh" check &> /dev/null; then
            pass "Token loading test passed"
        else
            warn "Token loading test had warnings"
        fi
    fi
}

# Check Docker setup
check_docker() {
    echo ""
    echo "=== Docker Validation ==="
    echo ""

    # Docker daemon (repeat check for standalone mode)
    if ! docker info &> /dev/null 2>&1; then
        fail "Docker daemon not running"
        return
    fi
    pass "Docker daemon accessible"

    # Check for Claude dev image
    if docker images | grep -q "claude-dev-env"; then
        version=$(docker images claude-dev-env --format "{{.Tag}}" | head -1)
        pass "claude-dev-env image exists (tag: $version)"
    else
        fail "claude-dev-env image not found"
        info "Build: docker build -t claude-dev-env:latest -f Dockerfile.claude ."
    fi

    # Test container can start
    if docker run --rm claude-dev-env:latest echo "test" &> /dev/null 2>&1; then
        pass "Container can start and run commands"
    else
        warn "Container start test failed"
    fi

    # Check Claude in container
    if docker run --rm claude-dev-env:latest which claude &> /dev/null 2>&1; then
        pass "Claude CLI available in container"
    else
        fail "Claude CLI not found in container"
    fi

    # Check gh in container
    if docker run --rm claude-dev-env:latest which gh &> /dev/null 2>&1; then
        pass "GitHub CLI available in container"
    else
        fail "GitHub CLI not found in container"
    fi

    # Check disk space
    available=$(docker system df --format "{{.Size}}" 2>/dev/null | head -1 || echo "unknown")
    info "Docker disk usage: $available"
}

# Check n8n setup
check_n8n() {
    echo ""
    echo "=== n8n Validation ==="
    echo ""

    # Check n8n container
    if docker ps | grep -q "n8n"; then
        pass "n8n container running"
    else
        fail "n8n container not running"
        info "Start: docker run -d --name n8n -p 5678:5678 n8nio/n8n"
        return
    fi

    # Check n8n health
    if curl -s http://localhost:5678/healthz &> /dev/null; then
        pass "n8n health endpoint responding"
    else
        fail "n8n health endpoint not responding"
    fi

    # Check workflow directory
    if [ -d "${SCRIPT_DIR}/../n8n-workflows" ]; then
        count=$(ls -1 "${SCRIPT_DIR}/../n8n-workflows"/*.json 2>/dev/null | wc -l | tr -d ' ')
        pass "n8n workflow templates found ($count files)"
    else
        warn "n8n-workflows directory not found"
    fi

    # Check webhook endpoints (basic connectivity)
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:5678/webhook/test 2>/dev/null | grep -qE "^[245]"; then
        pass "n8n webhook endpoint reachable"
    else
        warn "n8n webhook may not be configured"
    fi
}

# Run end-to-end test
run_e2e() {
    echo ""
    echo "=== End-to-End Test ==="
    echo ""

    warn "E2E test creates real GitHub issues/PRs"
    info "This test requires a working container environment"
    echo ""

    # Check if all prerequisites pass first
    if [ $FAIL -gt 0 ]; then
        fail "Cannot run E2E test - prerequisites not met ($FAIL failures above)"
        return
    fi

    # Check for existing test issue
    info "Checking for test infrastructure..."

    # For now, just verify the scripts exist
    if [ -f "${SCRIPT_DIR}/container-launch.sh" ]; then
        pass "Container launch script exists"
    else
        fail "Container launch script missing"
    fi

    if [ -f "${SCRIPT_DIR}/container-status.sh" ]; then
        pass "Container status script exists"
    else
        fail "Container status script missing"
    fi

    if [ -f "${SCRIPT_DIR}/container-sprint-workflow.sh" ]; then
        pass "Container workflow script exists"
    else
        fail "Container workflow script missing"
    fi

    info ""
    info "To run full E2E test manually:"
    info "  1. Create a test issue: gh issue create --title 'Test: Phase 1 validation'"
    info "  2. Run container: ./scripts/container-launch.sh --issue N --repo OWNER/REPO --sprint-work --sync"
    info "  3. Verify PR created: gh pr list --head feat/issue-N"
}

# Print summary
print_summary() {
    echo ""
    echo "=============================="
    echo "        VALIDATION SUMMARY"
    echo "=============================="
    echo ""
    echo -e "  ${GREEN}Passed:${NC}  $PASS"
    echo -e "  ${RED}Failed:${NC}  $FAIL"
    echo -e "  ${YELLOW}Warnings:${NC} $WARN"
    echo ""

    if [ $FAIL -eq 0 ]; then
        echo -e "${GREEN}Phase 1 validation PASSED${NC}"
        echo ""
        echo "Ready for deployment. Next steps:"
        echo "  1. Import n8n workflows"
        echo "  2. Run single container test"
        echo "  3. Enable automation"
        return 0
    else
        echo -e "${RED}Phase 1 validation FAILED${NC}"
        echo ""
        echo "Fix the failures above before deploying."
        return 1
    fi
}

# Output as JSON
output_json() {
    cat << EOF
{
  "validation": "phase1",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "results": {
    "passed": $PASS,
    "failed": $FAIL,
    "warnings": $WARN
  },
  "status": "$([ $FAIL -eq 0 ] && echo "PASSED" || echo "FAILED")"
}
EOF
}

# Main
main() {
    local run_all=false
    local run_prereq=false
    local run_tokens=false
    local run_docker=false
    local run_n8n=false
    local run_e2e=false
    local json_output=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                run_all=true
                shift
                ;;
            --prerequisites)
                run_prereq=true
                shift
                ;;
            --tokens)
                run_tokens=true
                shift
                ;;
            --docker)
                run_docker=true
                shift
                ;;
            --n8n)
                run_n8n=true
                shift
                ;;
            --e2e)
                run_e2e=true
                shift
                ;;
            --json)
                json_output=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Default to all if nothing specified
    if ! $run_prereq && ! $run_tokens && ! $run_docker && ! $run_n8n && ! $run_e2e; then
        run_all=true
    fi

    echo ""
    echo "╔════════════════════════════════════════════════════╗"
    echo "║   Phase 1 Automation Deployment Validation         ║"
    echo "║   Epic #491                                        ║"
    echo "╚════════════════════════════════════════════════════╝"

    # Run selected checks
    if $run_all || $run_prereq; then
        check_prerequisites
    fi

    if $run_all || $run_tokens; then
        check_tokens
    fi

    if $run_all || $run_docker; then
        check_docker
    fi

    if $run_all || $run_n8n; then
        check_n8n
    fi

    if $run_all || $run_e2e; then
        run_e2e
    fi

    # Output results
    if $json_output; then
        output_json
    else
        print_summary
    fi
}

main "$@"
