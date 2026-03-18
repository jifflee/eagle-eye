#!/usr/bin/env bash
# ============================================================
# Script: sanitize-fixture.sh
# Purpose: Sanitize test fixtures to remove PII and sensitive data
# Usage: ./scripts/dev/sanitize-fixture.sh <input-file> [> output-file]
# Dependencies: jq
# ============================================================

set -euo pipefail

INPUT_FILE="${1:-}"

if [ -z "$INPUT_FILE" ]; then
  echo "Usage: $0 <input-file> [> output-file]" >&2
  echo "" >&2
  echo "Example:" >&2
  echo "  $0 tests/fixtures/api/users.json > sanitized.json" >&2
  exit 2
fi

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: File not found: $INPUT_FILE" >&2
  exit 1
fi

# Sanitization rules using jq
jq '
  # Update metadata
  (._metadata // {}) |= . + {
    sanitized: true,
    sanitizedAt: (now | todate)
  } |

  # Walk through all values and sanitize
  walk(
    if type == "object" then
      # Remove sensitive fields entirely
      del(.password, .passwordHash, .token, .apiKey, .secret, .ssn, .taxId,
          .accessToken, .refreshToken, .privateKey, .secretKey) |

      # Sanitize email fields
      if .email then .email = "test@example.com" else . end |
      if .userEmail then .userEmail = "test@example.com" else . end |

      # Sanitize phone fields
      if .phone then .phone = "+1-555-000-0000" else . end |
      if .phoneNumber then .phoneNumber = "+1-555-000-0000" else . end |

      # Sanitize address fields
      if .address then .address = "123 Test Street" else . end |
      if .streetAddress then .streetAddress = "123 Test Street" else . end |
      if .city then .city = "Test City" else . end |
      if .zipCode then .zipCode = "00000" else . end |
      if .postalCode then .postalCode = "00000" else . end |

      # Sanitize personal info
      if .firstName then .firstName = "Test" else . end |
      if .lastName then .lastName = "User" else . end |
      if .fullName then .fullName = "Test User" else . end |
      if .name and (.name | type) == "string" and (.name | test("@") | not) then
        .name = "Test User"
      else . end |

      # Sanitize financial info
      if .creditCard then .creditCard = "4111111111111111" else . end |
      if .cardNumber then .cardNumber = "4111111111111111" else . end |
      if .accountNumber then .accountNumber = "000000000" else . end |
      if .routingNumber then .routingNumber = "000000000" else . end
    elif type == "string" then
      # Sanitize email patterns in strings
      if test("[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}") then
        gsub("[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"; "test@example.com")
      # Sanitize phone patterns
      elif test("^\\+?[0-9]{1,3}[-. ]?\\(?[0-9]{3}\\)?[-. ]?[0-9]{3}[-. ]?[0-9]{4}$") then
        "+1-555-000-0000"
      # Sanitize SSN patterns
      elif test("^[0-9]{3}-[0-9]{2}-[0-9]{4}$") then
        "000-00-0000"
      else
        .
      end
    else
      .
    end
  )
' "$INPUT_FILE"
