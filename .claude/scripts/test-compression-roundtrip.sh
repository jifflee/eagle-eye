#!/usr/bin/env bash
# test-compression-roundtrip.sh
# Validates the framework compression standard (gzip+base64) round-trip.
# Usage: ./scripts/test-compression-roundtrip.sh
# Exit 0 = pass, Exit 1 = fail
# See: docs/COMPRESSION_STANDARD.md

set -euo pipefail

PASS=0
FAIL=0

run_test() {
    local name="$1"
    local input="$2"

    # Compress
    local compressed
    compressed=$(printf '%s' "$input" | gzip -9 | base64 -w 0 2>/dev/null \
        || printf '%s' "$input" | gzip -9 | base64)  # macOS fallback (no -w)

    # Decompress
    local restored
    restored=$(printf '%s' "$compressed" | base64 -d | gunzip 2>/dev/null \
        || printf '%s' "$compressed" | base64 --decode | gunzip)  # macOS fallback

    if [ "$input" = "$restored" ]; then
        echo "  PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name"
        echo "        Expected: $(printf '%s' "$input" | head -c 80)"
        echo "        Got:      $(printf '%s' "$restored" | head -c 80)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Compression Round-Trip Tests (gzip+base64) ==="
echo "    Standard: docs/COMPRESSION_STANDARD.md"
echo ""

# Test 1: simple string
run_test "simple string" "Hello, framework!"

# Test 2: markdown content
run_test "markdown" "# Report

| Col | Value |
|-----|-------|
| A   | 1     |
| B   | 2     |"

# Test 3: large payload (simulate ops:full report)
LARGE_PAYLOAD=$(printf '## Section %s\n\nContent for section %s.\n\n' \
    {1..500} {1..500})
run_test "large payload (>60K chars simulated)" "$LARGE_PAYLOAD"

# Test 4: special characters
run_test "special chars" 'Chars: \n \t `code` "quotes" & <html> 日本語'

# Test 5: empty-ish content
run_test "minimal content" "x"

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "FAILURE: $FAIL test(s) failed. Check gzip/base64 flags for your platform."
    exit 1
else
    echo "SUCCESS: All $PASS tests passed."
    exit 0
fi
