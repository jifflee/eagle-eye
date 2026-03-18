#!/usr/bin/env bash
# ============================================================
# Script: generate-route-tests.sh
# Purpose: Generate test stubs from route definitions using the route test template
# Usage: ./scripts/dev/generate-route-tests.sh [--dry-run|--audit] <path>
# Dependencies: grep, sed
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Invalid arguments
#   5 - Source path not found
# ============================================================
# size-ok: test generator with inline template rendering requires verbose output
# shellcheck disable=SC2250,SC2292,SC2312

set -euo pipefail

# --- Configuration ---
TEMPLATE_FILE="tests/templates/route-test.template.ts"
OUTPUT_DIR="tests/integration/routes"

# --- Parse arguments ---
DRY_RUN=false
AUDIT_MODE=false
SOURCE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --audit)
      AUDIT_MODE=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--dry-run|--audit] <source-path>"
      echo ""
      echo "Generate test stubs for API routes from source files."
      echo ""
      echo "Arguments:"
      echo "  <source-path>  Path to route file or directory (e.g., src/routes/api/v1/)"
      echo ""
      echo "Options:"
      echo "  --dry-run   Preview output without writing files"
      echo "  --audit     Show coverage report (routes with/without tests)"
      echo "  -h, --help  Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0 src/routes/api/v1/              # Generate for all routes in directory"
      echo "  $0 src/routes/api/v1/users.ts      # Generate for single file"
      echo "  $0 --dry-run src/routes/api/v1/    # Preview without writing"
      echo "  $0 --audit src/routes/             # Show coverage report"
      exit 0
      ;;
    *)
      SOURCE_PATH="$1"
      shift
      ;;
  esac
done

if [ -z "$SOURCE_PATH" ]; then
  echo "ERROR: Source path is required"
  echo "Usage: $0 [--dry-run|--audit] <source-path>"
  exit 2
fi

if [ ! -e "$SOURCE_PATH" ]; then
  echo "ERROR: Source path not found: $SOURCE_PATH"
  exit 5
fi

# --- Resolve paths relative to repo root ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TEMPLATE_PATH="${REPO_ROOT}/${TEMPLATE_FILE}"

if [ ! -f "$TEMPLATE_PATH" ]; then
  echo "ERROR: Template not found: $TEMPLATE_PATH"
  exit 5
fi

# --- Helper functions ---

# Extract route handlers from a TypeScript/JavaScript file
# Looks for patterns like: router.get('/path', ...) or app.post('/path', ...)
extract_routes() {
  local file="$1"
  grep -nEi "(router|app)\.(get|post|put|delete|patch)\s*\(" "$file" 2>/dev/null | while IFS= read -r line; do
    local method path
    method=$(echo "$line" | grep -oEi '\.(get|post|put|delete|patch)' | sed 's/\.//' | tr '[:upper:]' '[:lower:]')
    path=$(echo "$line" | grep -oE "'[^']+'" | head -1 | tr -d "'")
    if [ -z "$path" ]; then
      path=$(echo "$line" | grep -oE '"[^"]+"' | head -1 | tr -d '"')
    fi
    if [ -n "$method" ] && [ -n "$path" ]; then
      echo "${method}|${path}"
    fi
  done
}

# Determine expected success code for a method
get_success_code() {
  local method="$1"
  case "$method" in
    post) echo "201" ;;
    delete) echo "204" ;;
    *) echo "200" ;;
  esac
}

# Determine if route has an :id parameter
has_id_param() {
  local path="$1"
  echo "$path" | grep -qE ':[a-zA-Z]+' && echo "true" || echo "false"
}

# Convert string to uppercase
to_upper() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Generate test file path from source file path
get_test_path() {
  local source_file="$1"
  local relative
  # Get path relative to repo root, then strip src/ prefix
  relative=$(echo "$source_file" | sed "s|^${REPO_ROOT}/||" | sed 's|^src/||' | sed 's|^/.*||')
  # If the file is outside the repo, use just the basename
  if [ -z "$relative" ] || echo "$relative" | grep -q '^/'; then
    relative=$(basename "$source_file")
  fi
  local test_file="${REPO_ROOT}/${OUTPUT_DIR}/${relative}"
  # Change extension to .test.ts
  test_file=$(echo "$test_file" | sed -E 's/\.(ts|js)$/.test.ts/')
  echo "$test_file"
}

# Generate a test file from template for given routes
generate_test_file() {
  local source_file="$1"
  local test_file
  test_file=$(get_test_path "$source_file")
  local routes
  routes=$(extract_routes "$source_file")

  if [ -z "$routes" ]; then
    echo "  SKIP: No routes found in $(basename "$source_file")"
    return
  fi

  if [ -f "$test_file" ] && [ "$DRY_RUN" = "false" ]; then
    echo "  SKIP: Test already exists: $(basename "$test_file")"
    return
  fi

  local route_count
  route_count=$(echo "$routes" | wc -l | tr -d ' ')

  if [ "$DRY_RUN" = "true" ]; then
    echo "  WOULD CREATE: $test_file ($route_count routes)"
    echo "$routes" | while IFS='|' read -r method path; do
      echo "    - $(to_upper "$method") $path"
    done
    return
  fi

  # Create output directory
  mkdir -p "$(dirname "$test_file")"

  # Generate test content with all routes
  {
    echo "/**"
    echo " * Route Tests: $(basename "$source_file")"
    echo " *"
    echo " * Auto-generated by generate-route-tests.sh"
    echo " * Template: ${TEMPLATE_FILE}"
    echo " * Source: ${source_file#"$REPO_ROOT/"}"
    echo " *"
    echo " * Customize these stubs with actual test logic."
    echo " * See docs/standards/API_TESTING.md for requirements."
    echo " */"
    echo ""
    echo "import { describe, it, expect, beforeAll, beforeEach, afterAll } from '@jest/globals';"
    echo "// import request from 'supertest';"
    echo "// import { app } from '@/app';"
    echo "// import { db } from '@/database';"
    echo "// import { validateResponse } from '../../helpers/openapi-validator';"
    echo "// import { getValidToken, getTokenForRole } from '../../helpers/auth';"
    echo ""

    echo "$routes" | while IFS='|' read -r method path; do
      METHOD="$(to_upper "$method")"
      success_code=$(get_success_code "$method")
      has_id=$(has_id_param "$path")

      echo "describe('${METHOD} ${path}', () => {"
      echo "  // let token: string;"
      echo ""
      echo "  // beforeAll(async () => { token = await getValidToken(); });"
      echo ""
      echo "  // === SUCCESS CASES ==="
      echo "  describe('success', () => {"
      echo "    it('returns ${success_code} with valid request', async () => {"
      echo "      // const response = await request(app)"
      echo "      //   .${method}('${path}')"
      echo "      //   .set('Authorization', \`Bearer \${token}\`);"
      echo "      // expect(response.status).toBe(${success_code});"
      echo "    });"
      echo ""
      echo "    it('response matches OpenAPI schema', async () => {"
      echo "      // const response = await request(app).${method}('${path}');"
      echo "      // await validateResponse('${METHOD}', '${path}', response.status, response.body);"
      echo "    });"
      echo "  });"
      echo ""
      echo "  // === ERROR CASES ==="
      echo "  describe('errors', () => {"

      if [ "$method" = "post" ] || [ "$method" = "put" ] || [ "$method" = "patch" ]; then
        echo "    it('returns 400 for invalid input', async () => {"
        echo "      // const response = await request(app)"
        echo "      //   .${method}('${path}')"
        echo "      //   .send({});"
        echo "      // expect(response.status).toBe(400);"
        echo "    });"
        echo ""
        echo "    it('returns 400 for missing required field', async () => {"
        echo "      // const response = await request(app)"
        echo "      //   .${method}('${path}')"
        echo "      //   .send({});"
        echo "      // expect(response.status).toBe(400);"
        echo "      // expect(response.body.errors).toBeInstanceOf(Array);"
        echo "    });"
      fi

      echo ""
      echo "    it('returns 401 without auth token', async () => {"
      echo "      // const response = await request(app).${method}('${path}');"
      echo "      // expect(response.status).toBe(401);"
      echo "    });"

      if [ "$has_id" = "true" ]; then
        echo ""
        echo "    it('returns 404 for non-existent resource', async () => {"
        echo "      // const response = await request(app)"
        echo "      //   .${method}('${path}'.replace(/:([a-zA-Z]+)/, 'non-existent-id'))"
        echo "      //   .set('Authorization', \`Bearer \${token}\`);"
        echo "      // expect(response.status).toBe(404);"
        echo "    });"
      fi

      echo "  });"
      echo ""
      echo "  // === EDGE CASES ==="
      echo "  describe('edge cases', () => {"
      echo "    // Add edge case tests specific to this endpoint"
      echo "  });"
      echo "});"
      echo ""
    done
  } > "$test_file"

  echo "  CREATED: $test_file ($route_count routes)"
}

# Audit mode: show coverage report
run_audit() {
  echo "=== Route Test Coverage Audit ==="
  echo ""

  local total_routes=0
  local covered_routes=0
  local uncovered_routes=0

  local source_files
  if [ -d "$SOURCE_PATH" ]; then
    source_files=$(find "$SOURCE_PATH" -type f \( -name "*.ts" -o -name "*.js" \) ! -name "*.test.*" ! -name "*.spec.*" 2>/dev/null || true)
  else
    source_files="$SOURCE_PATH"
  fi

  if [ -z "$source_files" ]; then
    echo "No route files found in: $SOURCE_PATH"
    exit 0
  fi

  echo "| Status | Method | Path | Test File |"
  echo "|--------|--------|------|-----------|"

  echo "$source_files" | while IFS= read -r file; do
    [ -z "$file" ] && continue
    local routes
    routes=$(extract_routes "$file")
    [ -z "$routes" ] && continue

    local test_file
    test_file=$(get_test_path "$file")

    echo "$routes" | while IFS='|' read -r method path; do
      total_routes=$((total_routes + 1))
      if [ -f "$test_file" ]; then
        covered_routes=$((covered_routes + 1))
        echo "| COVERED | $(to_upper "$method") | $path | $(basename "$test_file") |"
      else
        uncovered_routes=$((uncovered_routes + 1))
        echo "| **GAP** | $(to_upper "$method") | $path | - |"
      fi
    done
  done

  echo ""
  echo "---"
  echo ""
  echo "To generate missing tests:"
  echo "  $0 $SOURCE_PATH"
}

# --- Main execution ---

if [ "$AUDIT_MODE" = "true" ]; then
  run_audit
  exit 0
fi

echo "=== Route Test Generator ==="
echo "Source: $SOURCE_PATH"
echo "Template: $TEMPLATE_FILE"
echo "Output: $OUTPUT_DIR/"
if [ "$DRY_RUN" = "true" ]; then
  echo "Mode: DRY RUN (no files written)"
fi
echo ""

# Collect source files
if [ -d "$SOURCE_PATH" ]; then
  find "$SOURCE_PATH" -type f \( -name "*.ts" -o -name "*.js" \) ! -name "*.test.*" ! -name "*.spec.*" | sort | while IFS= read -r file; do
    echo "Processing: $(basename "$file")"
    generate_test_file "$file"
  done
else
  echo "Processing: $(basename "$SOURCE_PATH")"
  generate_test_file "$SOURCE_PATH"
fi

echo ""
echo "Done. See docs/standards/API_TESTING.md for test requirements."
