#!/usr/bin/env bash
# ============================================================
# Script: capture-api-fixture.sh
# Purpose: Capture API responses as test fixtures
# Usage: ./scripts/dev/capture-api-fixture.sh <endpoint> <output-file>
# Dependencies: curl, jq
# ============================================================

set -euo pipefail

ENDPOINT="${1:-}"
OUTPUT_FILE="${2:-}"
API_BASE="${API_BASE:-}"

if [ -z "$ENDPOINT" ] || [ -z "$OUTPUT_FILE" ]; then
  echo "Usage: $0 <endpoint> <output-file>"
  echo ""
  echo "Example:"
  echo "  API_BASE=https://api.example.com $0 /users/me tests/fixtures/api/users/me.json"
  echo ""
  echo "Environment variables:"
  echo "  API_BASE - Base URL for API (required)"
  echo "  API_TOKEN - Bearer token for authentication (optional)"
  exit 2
fi

if [ -z "$API_BASE" ]; then
  echo "ERROR: API_BASE environment variable is required"
  exit 2
fi

# Create output directory if needed
mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "Capturing: $API_BASE$ENDPOINT"

# Build curl command
CURL_ARGS=(-s "$API_BASE$ENDPOINT")

if [ -n "${API_TOKEN:-}" ]; then
  CURL_ARGS+=(-H "Authorization: Bearer $API_TOKEN")
fi

# Capture response
RESPONSE=$(curl "${CURL_ARGS[@]}")

# Validate JSON
if ! echo "$RESPONSE" | jq empty 2>/dev/null; then
  echo "ERROR: Response is not valid JSON"
  echo "$RESPONSE"
  exit 1
fi

# Add metadata and save
jq -n \
  --arg captured "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg source "$ENDPOINT" \
  --arg env "${API_ENV:-production}" \
  --argjson data "$RESPONSE" \
  '{
    _metadata: {
      capturedAt: $captured,
      source: $source,
      environment: $env,
      sanitized: false,
      notes: "Raw capture - needs sanitization before commit"
    },
    data: $data
  }' > "$OUTPUT_FILE"

echo "Saved to: $OUTPUT_FILE"
echo ""
echo "IMPORTANT: Run sanitization before committing:"
echo "  ./scripts/dev/sanitize-fixture.sh $OUTPUT_FILE > sanitized.json"
echo "  mv sanitized.json $OUTPUT_FILE"
