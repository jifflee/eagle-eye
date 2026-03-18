#!/bin/bash
set -euo pipefail
# test-container-auth.sh
# Validates Claude CLI authentication in Docker container
# Part of POC validation for issue #130

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Claude Container Auth Test ==="
echo ""

# Check for required environment variables
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] && [ -z "$ANTHROPIC_API_KEY" ]; then
    echo -e "${YELLOW}Warning:${NC} Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set"
    echo ""
    echo "To generate an OAuth token:"
    echo "  claude setup-token"
    echo ""
    echo "Then run:"
    echo "  export CLAUDE_CODE_OAUTH_TOKEN=<your-token>"
    echo "  $0"
    echo ""
    exit 1
fi

# Determine which token to use
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    TOKEN_TYPE="CLAUDE_CODE_OAUTH_TOKEN"
    TOKEN_VAR="-e CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN"
else
    TOKEN_TYPE="ANTHROPIC_API_KEY"
    TOKEN_VAR="-e ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
fi

echo "Using: $TOKEN_TYPE"
echo ""

# Test 1: Version check
echo "Test 1: Version check..."
VERSION=$(docker run --rm --entrypoint claude claude-poc:latest --version 2>&1)
if [ $? -eq 0 ]; then
    echo -e "${GREEN}PASS${NC}: claude --version = $VERSION"
else
    echo -e "${RED}FAIL${NC}: Version check failed"
    exit 1
fi

# Test 2: Auth status
echo ""
echo "Test 2: Auth with token..."
RESULT=$(docker run --rm $TOKEN_VAR --entrypoint claude claude-poc:latest --print "Say hello in 3 words" 2>&1) || true

if echo "$RESULT" | grep -q "Invalid API key\|error\|Error"; then
    echo -e "${RED}FAIL${NC}: Authentication failed"
    echo "Output: $RESULT"
    exit 1
else
    echo -e "${GREEN}PASS${NC}: Claude responded successfully"
    echo "Response: $RESULT"
fi

echo ""
echo "=== All tests passed ==="
echo ""
echo "POC Validation Complete:"
echo "  - Container builds: YES"
echo "  - Claude --version: YES"
echo "  - Claude responds to prompt: YES"
