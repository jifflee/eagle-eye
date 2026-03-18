#!/usr/bin/env bash
# Lint script to detect unwrapped direct network calls in codebase
# Ensures all network operations go through net-gateway.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Network tools that should be wrapped
NETWORK_TOOLS=(
    "gh "
    "curl "
    "wget "
    "git push"
    "git pull"
    "git fetch"
    "git clone"
    "docker pull"
    "docker push"
)

# Patterns that indicate proper gateway usage
GATEWAY_PATTERNS=(
    "net_call"
    "source.*net-gateway.sh"
    "\. .*net-gateway.sh"
)

echo "Scanning for unwrapped network calls..."
echo ""

violations_found=0
files_checked=0

# Find all shell scripts
while IFS= read -r -d '' script_file; do
    ((files_checked++))

    # Skip the gateway itself
    if [[ "$script_file" == *"net-gateway.sh" ]]; then
        continue
    fi

    # Skip this lint script
    if [[ "$script_file" == *"lint-network-calls.sh" ]]; then
        continue
    fi

    # Check if file sources the gateway
    sources_gateway=false
    for pattern in "${GATEWAY_PATTERNS[@]}"; do
        if grep -q "$pattern" "$script_file"; then
            sources_gateway=true
            break
        fi
    done

    # Scan for direct network tool usage
    for tool in "${NETWORK_TOOLS[@]}"; do
        # Look for the tool being called directly (not via net_call)
        if grep -n "$tool" "$script_file" | grep -v "net_call" | grep -v "^[[:space:]]*#" > /dev/null; then
            # Found potential violation
            violations=$(grep -n "$tool" "$script_file" | grep -v "net_call" | grep -v "^[[:space:]]*#" || true)

            if [[ -n "$violations" ]]; then
                if [[ $violations_found -eq 0 ]]; then
                    echo -e "${RED}Violations found:${NC}"
                    echo ""
                fi

                ((violations_found++))

                echo -e "${YELLOW}File: $script_file${NC}"
                if [[ "$sources_gateway" == "false" ]]; then
                    echo -e "${RED}  ✗ Does not source net-gateway.sh${NC}"
                fi
                echo -e "${RED}  ✗ Direct call to '$tool' (should use net_call):${NC}"
                echo "$violations" | while IFS= read -r line; do
                    echo "    $line"
                done
                echo ""
            fi
        fi
    done

done < <(find "$PROJECT_ROOT/scripts" -type f -name "*.sh" -print0)

echo "Checked $files_checked script files"
echo ""

if [[ $violations_found -eq 0 ]]; then
    echo -e "${GREEN}✓ No unwrapped network calls found${NC}"
    exit 0
else
    echo -e "${RED}✗ Found $violations_found file(s) with unwrapped network calls${NC}"
    echo ""
    echo "To fix:"
    echo "  1. Add 'source \"\$(dirname \"\${BASH_SOURCE[0]}\")/lib/net-gateway.sh\"' at the top"
    echo "  2. Replace direct calls with: net_call <tool> <args>"
    echo "  Example: 'gh issue list' → 'net_call gh issue list'"
    echo ""
    exit 1
fi
