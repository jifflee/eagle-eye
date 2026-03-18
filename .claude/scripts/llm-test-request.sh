#!/bin/bash
#
# llm-test-request.sh - Test request/response for local LLM endpoints
#
# Usage:
#   ./scripts/llm-test-request.sh [--model codestral|llama|both] [--json]
#
# Options:
#   --model   Which model to test (default: both)
#   --json    Output in JSON format
#   --prompt  Custom prompt to send (default: test prompt)
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Script error
#
# Related: Issue #428

set -euo pipefail

# Configuration
CODESTRAL_PORT="${CODESTRAL_PORT:-8001}"
LLAMA_PORT="${LLAMA_PORT:-8002}"
CODESTRAL_URL="http://127.0.0.1:${CODESTRAL_PORT}/v1/chat/completions"
LLAMA_URL="http://127.0.0.1:${LLAMA_PORT}/v1/chat/completions"
TIMEOUT="${LLM_TEST_TIMEOUT:-30}"

# Default test prompts
CODESTRAL_PROMPT="Write a Python function that returns 'hello world'."
LLAMA_PROMPT="What is 2 + 2? Answer with just the number."

# Parse arguments
MODEL="both"
JSON_OUTPUT=false
CUSTOM_PROMPT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --model)
      MODEL="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --prompt)
      CUSTOM_PROMPT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--model codestral|llama|both] [--json] [--prompt \"...\"]"
      echo ""
      echo "Test request/response for local LLM endpoints."
      echo ""
      echo "Options:"
      echo "  --model    Which model to test (codestral, llama, or both)"
      echo "  --json     Output in JSON format"
      echo "  --prompt   Custom prompt to send"
      echo ""
      echo "Environment variables:"
      echo "  CODESTRAL_PORT       Codestral port (default: 8001)"
      echo "  LLAMA_PORT           Llama port (default: 8002)"
      echo "  LLM_TEST_TIMEOUT     Timeout in seconds (default: 30)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Test single endpoint
test_endpoint() {
  local name="$1"
  local url="$2"
  local model_name="$3"
  local prompt="$4"
  local start_time
  local end_time
  local duration
  local status="failed"
  local response=""
  local content=""
  local tokens=0

  # Use perl for milliseconds on macOS (date %N not supported)
  if command -v perl &>/dev/null; then
    start_time=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')
  else
    start_time=$(($(date +%s) * 1000))
  fi

  # Build request body
  local body
  body=$(cat <<EOF
{
  "model": "${model_name}",
  "messages": [{"role": "user", "content": "${prompt}"}],
  "temperature": 0.1,
  "max_tokens": 100
}
EOF
)

  # Make request
  if response=$(curl -sf --connect-timeout 5 --max-time "$TIMEOUT" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$url" 2>&1); then

    # Parse response
    if command -v jq &> /dev/null; then
      content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo "")
      tokens=$(echo "$response" | jq -r '.usage.total_tokens // 0' 2>/dev/null || echo "0")
    else
      # Fallback: basic grep
      content=$(echo "$response" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
    fi

    if [[ -n "$content" ]]; then
      status="passed"
    else
      status="failed"
      content="Empty or invalid response"
    fi
  else
    status="failed"
    content="Connection failed: ${response}"
  fi

  if command -v perl &>/dev/null; then
    end_time=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')
  else
    end_time=$(($(date +%s) * 1000))
  fi

  duration=$((end_time - start_time))

  # Output result
  echo "${name}|${status}|${duration}|${tokens}|${content}"
}

# Print test result
print_result() {
  local name="$1"
  local status="$2"
  local duration="$3"
  local tokens="$4"
  local content="$5"

  if [[ "$status" == "passed" ]]; then
    echo "  Status: PASSED"
    echo "  Latency: ${duration}ms"
    echo "  Tokens: ${tokens}"
    echo "  Response preview: ${content:0:100}..."
  else
    echo "  Status: FAILED"
    echo "  Error: ${content}"
  fi
}

# Main test function
main() {
  local codestral_result=""
  local llama_result=""
  local all_passed=true
  local results=()

  echo "LLM Request/Response Test"
  echo "========================="
  echo ""

  # Test Codestral
  if [[ "$MODEL" == "codestral" ]] || [[ "$MODEL" == "both" ]]; then
    local prompt="${CUSTOM_PROMPT:-$CODESTRAL_PROMPT}"
    echo "Testing Codestral (port ${CODESTRAL_PORT})..."
    echo "  Prompt: ${prompt:0:50}..."
    echo ""

    codestral_result=$(test_endpoint "codestral" "$CODESTRAL_URL" "codestral" "$prompt")

    IFS='|' read -r name status duration tokens content <<< "$codestral_result"

    if ! $JSON_OUTPUT; then
      print_result "$name" "$status" "$duration" "$tokens" "$content"
      echo ""
    fi

    if [[ "$status" != "passed" ]]; then
      all_passed=false
    fi

    results+=("$codestral_result")
  fi

  # Test Llama
  if [[ "$MODEL" == "llama" ]] || [[ "$MODEL" == "both" ]]; then
    local prompt="${CUSTOM_PROMPT:-$LLAMA_PROMPT}"
    echo "Testing Llama (port ${LLAMA_PORT})..."
    echo "  Prompt: ${prompt:0:50}..."
    echo ""

    llama_result=$(test_endpoint "llama" "$LLAMA_URL" "llama3.1" "$prompt")

    IFS='|' read -r name status duration tokens content <<< "$llama_result"

    if ! $JSON_OUTPUT; then
      print_result "$name" "$status" "$duration" "$tokens" "$content"
      echo ""
    fi

    if [[ "$status" != "passed" ]]; then
      all_passed=false
    fi

    results+=("$llama_result")
  fi

  # JSON output
  if $JSON_OUTPUT; then
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"all_passed\": $all_passed,"
    echo "  \"results\": ["

    local first=true
    for result in "${results[@]}"; do
      IFS='|' read -r name status duration tokens content <<< "$result"

      if ! $first; then
        echo ","
      fi
      first=false

      cat <<EOF
    {
      "model": "$name",
      "status": "$status",
      "latency_ms": $duration,
      "tokens": $tokens,
      "response_preview": "${content:0:100}"
    }
EOF
    done

    echo ""
    echo "  ]"
    echo "}"
  else
    # Summary
    echo "========================="
    if $all_passed; then
      echo "All tests PASSED"
    else
      echo "Some tests FAILED"
      echo ""
      echo "Troubleshooting:"
      echo "  1. Check tunnel: ./scripts/llm-tunnel.sh status"
      echo "  2. Check health: ./scripts/llm-health-check.sh"
      echo "  3. See docs: /docs/LOCAL_LLM_ENDPOINTS.md"
    fi
  fi

  # Exit code
  if $all_passed; then
    exit 0
  else
    exit 1
  fi
}

main
