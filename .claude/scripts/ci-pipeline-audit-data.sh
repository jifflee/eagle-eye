#!/usr/bin/env bash
# ci-pipeline-audit-data.sh
# Pre-process CI pipeline audit metrics for /performance:ci-pipeline skill
# Returns JSON with parallelization gaps, caching gaps, redundant steps, and Docker issues
#
# Usage: ./scripts/ci-pipeline-audit-data.sh
# Output: JSON object with CI pipeline findings, scores, and metadata
#
# Supports: GitHub Actions (.github/workflows/), local CI scripts (scripts/ci/)
#
# size-ok: data-gathering script, not a skill file

set -euo pipefail

# ── Helper: grep that never fails on no-match ─────────────────────────────────
safe_grep_count() {
  { grep "$@" 2>/dev/null || :; } | wc -l | tr -d ' '
}

safe_grep_lines() {
  { grep "$@" 2>/dev/null || :; } | head -10
}

# ── Detect CI system and workflow files ───────────────────────────────────────
CI_SYSTEM="none"
WORKFLOW_FILES=()
WORKFLOW_COUNT=0

if [[ -d ".github/workflows" ]]; then
  CI_SYSTEM="github-actions"
  while IFS= read -r -d '' f; do
    WORKFLOW_FILES+=("$f")
  done < <(find .github/workflows -name "*.yml" -o -name "*.yaml" 2>/dev/null | sort -z 2>/dev/null || true)
  WORKFLOW_COUNT=${#WORKFLOW_FILES[@]}
fi

# Also detect local CI scripts
LOCAL_CI_DIR=""
if [[ -d "scripts/ci" ]]; then
  LOCAL_CI_DIR="scripts/ci"
  [[ "$CI_SYSTEM" == "none" ]] && CI_SYSTEM="local-scripts"
  [[ "$CI_SYSTEM" == "github-actions" ]] && CI_SYSTEM="github-actions+local"
fi

WORKFLOW_COUNT_JSON=$WORKFLOW_COUNT

# ── Combine all workflow content for analysis ─────────────────────────────────
ALL_WORKFLOW_CONTENT=""
if [[ ${#WORKFLOW_FILES[@]} -gt 0 ]]; then
  for f in "${WORKFLOW_FILES[@]}"; do
    ALL_WORKFLOW_CONTENT+=$'\n'"$(cat "$f" 2>/dev/null || true)"
  done
fi

# ══════════════════════════════════════════════════════════════════════════════
# A. CACHING ANALYSIS
# ══════════════════════════════════════════════════════════════════════════════

HAS_CACHE_ACTION=false
MISSING_NODE_CACHE=false
MISSING_PIP_CACHE=false
MISSING_DOCKER_CACHE=false
MISSING_BUILD_CACHE=false

# Check for any cache action
CACHE_ACTION_COUNT=$(safe_grep_count -r "actions/cache\|cache-dependency-path\|cache: 'npm'\|cache: 'pip'\|cache: 'yarn'\|cache: 'pnpm'" \
  .github/workflows/ 2>/dev/null || echo "0")
[[ $CACHE_ACTION_COUNT -gt 0 ]] && HAS_CACHE_ACTION=true

# Node.js cache detection
NODE_INSTALL_COUNT=$(safe_grep_count -r "npm install\|npm ci\|yarn install\|pnpm install" \
  .github/workflows/ 2>/dev/null || echo "0")
NODE_CACHE_COUNT=$(safe_grep_count -r "actions/cache.*node\|cache: 'npm'\|cache: 'yarn'\|cache: 'pnpm'\|node-modules" \
  .github/workflows/ 2>/dev/null || echo "0")
if [[ $NODE_INSTALL_COUNT -gt 0 && $NODE_CACHE_COUNT -eq 0 ]]; then
  MISSING_NODE_CACHE=true
fi

# Pip cache detection
PIP_INSTALL_COUNT=$(safe_grep_count -r "pip install\|pip3 install\|poetry install\|uv sync" \
  .github/workflows/ 2>/dev/null || echo "0")
PIP_CACHE_COUNT=$(safe_grep_count -r "actions/cache.*pip\|cache: 'pip'\|pip-cache\|\.pip\|site-packages" \
  .github/workflows/ 2>/dev/null || echo "0")
if [[ $PIP_INSTALL_COUNT -gt 0 && $PIP_CACHE_COUNT -eq 0 ]]; then
  MISSING_PIP_CACHE=true
fi

# Docker cache detection
DOCKER_BUILD_COUNT=$(safe_grep_count -r "docker build\|docker buildx build\|uses: docker/build-push-action" \
  .github/workflows/ 2>/dev/null || echo "0")
DOCKER_CACHE_COUNT=$(safe_grep_count -r "cache-from\|cache-to\|buildx.*cache\|type=gha\|type=registry" \
  .github/workflows/ 2>/dev/null || echo "0")
if [[ $DOCKER_BUILD_COUNT -gt 0 && $DOCKER_CACHE_COUNT -eq 0 ]]; then
  MISSING_DOCKER_CACHE=true
fi

# Build output cache detection
BUILD_STEP_COUNT=$(safe_grep_count -r "npm run build\|next build\|tsc \|webpack\|vite build" \
  .github/workflows/ 2>/dev/null || echo "0")
BUILD_CACHE_COUNT=$(safe_grep_count -r "actions/cache.*dist\|actions/cache.*\.next\|actions/cache.*build" \
  .github/workflows/ 2>/dev/null || echo "0")
if [[ $BUILD_STEP_COUNT -gt 0 && $BUILD_CACHE_COUNT -eq 0 ]]; then
  MISSING_BUILD_CACHE=true
fi

# ── Assemble caching findings ──────────────────────────────────────────────────
CACHING=$(jq -n \
  --argjson has_cache "$HAS_CACHE_ACTION" \
  --argjson missing_node "$MISSING_NODE_CACHE" \
  --argjson missing_pip "$MISSING_PIP_CACHE" \
  --argjson missing_docker "$MISSING_DOCKER_CACHE" \
  --argjson missing_build "$MISSING_BUILD_CACHE" \
  --argjson node_installs "$NODE_INSTALL_COUNT" \
  --argjson pip_installs "$PIP_INSTALL_COUNT" \
  --argjson docker_builds "$DOCKER_BUILD_COUNT" \
  '{
    has_cache_action: $has_cache,
    missing_node_cache: $missing_node,
    missing_pip_cache: $missing_pip,
    missing_docker_cache: $missing_docker,
    missing_build_cache: $missing_build,
    node_install_count: $node_installs,
    pip_install_count: $pip_installs,
    docker_build_count: $docker_builds
  }')

# ══════════════════════════════════════════════════════════════════════════════
# B. PARALLELIZATION ANALYSIS
# ══════════════════════════════════════════════════════════════════════════════

# Count jobs with 'needs:' (sequential dependency)
JOBS_WITH_NEEDS=$(safe_grep_count -r "^    needs:" .github/workflows/ 2>/dev/null || echo "0")

# Count total job definitions
TOTAL_JOBS=$(safe_grep_count -r "^  [a-zA-Z_-]*:$\|^  [a-zA-Z_-]*: *$" .github/workflows/ 2>/dev/null || echo "0")

# Heuristic: workflows where lint/test/typecheck are sequential but could parallel
LINT_JOBS=$(safe_grep_count -r "lint\|eslint\|flake8\|ruff" .github/workflows/ 2>/dev/null || echo "0")
TEST_JOBS=$(safe_grep_count -r "npm test\|pytest\|jest\|vitest\|run: test" .github/workflows/ 2>/dev/null || echo "0")
TYPECHECK_JOBS=$(safe_grep_count -r "tsc \|typecheck\|mypy\|pyright" .github/workflows/ 2>/dev/null || echo "0")

# Detect matrix strategy usage (good pattern)
MATRIX_COUNT=$(safe_grep_count -r "strategy:.*matrix\|matrix:" .github/workflows/ 2>/dev/null || echo "0")
HAS_MATRIX_STRATEGY=false
[[ $MATRIX_COUNT -gt 0 ]] && HAS_MATRIX_STRATEGY=true

# Sequential lint→test→typecheck without needs: structure is a heuristic
CAN_PARALLELIZE_COUNT=0
if [[ $LINT_JOBS -gt 0 && $TEST_JOBS -gt 0 && $JOBS_WITH_NEEDS -gt 2 ]]; then
  CAN_PARALLELIZE_COUNT=1
fi

SEQUENTIAL_JOBS_JSON="[]"
if [[ $CAN_PARALLELIZE_COUNT -gt 0 ]]; then
  SEQUENTIAL_JOBS_JSON='[{"jobs": "lint → test → typecheck", "reason": "No inter-dependency detected — these can run in parallel using separate jobs"}]'
fi

PARALLELIZATION=$(jq -n \
  --argjson sequential "$SEQUENTIAL_JOBS_JSON" \
  --argjson no_matrix "$HAS_MATRIX_STRATEGY" \
  --argjson can_parallelize "$CAN_PARALLELIZE_COUNT" \
  --argjson jobs_with_needs "$JOBS_WITH_NEEDS" \
  --argjson total_jobs "$TOTAL_JOBS" \
  '{
    sequential_jobs: $sequential,
    has_matrix_strategy: $no_matrix,
    can_parallelize_count: $can_parallelize,
    jobs_with_needs: $jobs_with_needs,
    total_jobs: $total_jobs
  }')

# ══════════════════════════════════════════════════════════════════════════════
# C. REDUNDANT STEPS ANALYSIS
# ══════════════════════════════════════════════════════════════════════════════

# Duplicate install detection (npm install appearing more than once across steps in same workflow)
DUPLICATE_INSTALLS=false
for wf in "${WORKFLOW_FILES[@]:-}"; do
  [[ -z "$wf" ]] && continue
  INSTALL_COUNT_IN_FILE=$(safe_grep_count "npm install\|npm ci\|pip install" "$wf" 2>/dev/null || echo "0")
  if [[ $INSTALL_COUNT_IN_FILE -gt 1 ]]; then
    DUPLICATE_INSTALLS=true
    break
  fi
done

# Install without cache restore immediately before
INSTALL_WITHOUT_CACHE=$(safe_grep_count -r "npm ci\|npm install" .github/workflows/ 2>/dev/null || echo "0")
HAS_RESTORE_CACHE_BEFORE_INSTALL=$(safe_grep_count -r "restore-keys\|actions/cache" .github/workflows/ 2>/dev/null || echo "0")
INSTALL_WITHOUT_CACHE_BOOL=false
if [[ $INSTALL_WITHOUT_CACHE -gt 0 && $HAS_RESTORE_CACHE_BEFORE_INSTALL -eq 0 ]]; then
  INSTALL_WITHOUT_CACHE_BOOL=true
fi

# Repeated checkout action
REPEATED_CHECKOUT=false
for wf in "${WORKFLOW_FILES[@]:-}"; do
  [[ -z "$wf" ]] && continue
  CHECKOUT_COUNT=$(safe_grep_count "actions/checkout" "$wf" 2>/dev/null || echo "0")
  if [[ $CHECKOUT_COUNT -gt 1 ]]; then
    REPEATED_CHECKOUT=true
    break
  fi
done

# Duplicate linters (both eslint + tsc commonly overlap)
ESLINT_COUNT=$(safe_grep_count -r "eslint" .github/workflows/ 2>/dev/null || echo "0")
TSC_COUNT=$(safe_grep_count -r "tsc \|tsc$\|typecheck" .github/workflows/ 2>/dev/null || echo "0")
DUPLICATE_LINTERS_JSON="[]"
if [[ $ESLINT_COUNT -gt 0 && $TSC_COUNT -gt 0 ]]; then
  DUPLICATE_LINTERS_JSON='[{"tools": "eslint + tsc", "overlap": "Both can catch type-related import errors — consider relying on tsc for type checking only"}]'
fi

REDUNDANT=$(jq -n \
  --argjson dup_installs "$DUPLICATE_INSTALLS" \
  --argjson install_no_cache "$INSTALL_WITHOUT_CACHE_BOOL" \
  --argjson repeated_checkout "$REPEATED_CHECKOUT" \
  --argjson dup_linters "$DUPLICATE_LINTERS_JSON" \
  '{
    duplicate_installs: $dup_installs,
    install_without_cache: $install_no_cache,
    repeated_checkout: $repeated_checkout,
    duplicate_linters: $dup_linters
  }')

# ══════════════════════════════════════════════════════════════════════════════
# D. SLOW TEST SUITES ANALYSIS
# ══════════════════════════════════════════════════════════════════════════════

# e2e tests triggered on all pushes (not filtered to PRs/main)
E2E_COUNT=$(safe_grep_count -r "e2e\|playwright\|cypress\|selenium" .github/workflows/ 2>/dev/null || echo "0")
E2E_PUSH_COUNT=$(safe_grep_count -r -A5 "e2e\|playwright\|cypress" .github/workflows/ 2>/dev/null | safe_grep_count "push" || echo "0")
E2E_ON_EVERY_PUSH=false
[[ $E2E_COUNT -gt 0 && $E2E_PUSH_COUNT -gt 0 ]] && E2E_ON_EVERY_PUSH=true

# Test sharding
SHARD_COUNT=$(safe_grep_count -r "\-\-shard\|shard:\|split.*test\|test.*split" .github/workflows/ 2>/dev/null || echo "0")
NO_TEST_SHARDING=false
[[ $TEST_JOBS -gt 0 && $SHARD_COUNT -eq 0 && $MATRIX_COUNT -eq 0 ]] && NO_TEST_SHARDING=true

# Changed-file test filtering
CHANGED_FILE_FILTER=$(safe_grep_count -r "changedSince\|changed-files\|affected\|--only-changed" \
  .github/workflows/ 2>/dev/null || echo "0")
NO_TEST_FILTERING=false
[[ $TEST_JOBS -gt 0 && $CHANGED_FILE_FILTER -eq 0 ]] && NO_TEST_FILTERING=true

TEST_SUITES=$(jq -n \
  --argjson e2e_push "$E2E_ON_EVERY_PUSH" \
  --argjson no_sharding "$NO_TEST_SHARDING" \
  --argjson no_filtering "$NO_TEST_FILTERING" \
  --argjson e2e_count "$E2E_COUNT" \
  --argjson shard_count "$SHARD_COUNT" \
  '{
    e2e_on_every_push: $e2e_push,
    no_test_sharding: $no_sharding,
    no_test_filtering: $no_filtering,
    e2e_count: $e2e_count,
    shard_count: $shard_count
  }')

# ══════════════════════════════════════════════════════════════════════════════
# E. CHECKOUT ANALYSIS (shallow clone)
# ══════════════════════════════════════════════════════════════════════════════

CHECKOUT_COUNT=$(safe_grep_count -r "actions/checkout" .github/workflows/ 2>/dev/null || echo "0")
SHALLOW_COUNT=$(safe_grep_count -r "fetch-depth: 1\|fetch-depth:1" .github/workflows/ 2>/dev/null || echo "0")
FULL_CLONE_COUNT=$(( CHECKOUT_COUNT - SHALLOW_COUNT ))
[[ $FULL_CLONE_COUNT -lt 0 ]] && FULL_CLONE_COUNT=0
NO_SHALLOW_CLONE=false
[[ $CHECKOUT_COUNT -gt 0 && $SHALLOW_COUNT -eq 0 ]] && NO_SHALLOW_CLONE=true

LFS_COUNT=$(safe_grep_count -r "lfs: true\|git-lfs" .github/workflows/ 2>/dev/null || echo "0")
LFS_ENABLED_GLOBALLY=false
[[ $LFS_COUNT -gt 1 ]] && LFS_ENABLED_GLOBALLY=true

CHECKOUT=$(jq -n \
  --argjson total "$CHECKOUT_COUNT" \
  --argjson shallow "$SHALLOW_COUNT" \
  --argjson full_clone "$FULL_CLONE_COUNT" \
  --argjson no_shallow "$NO_SHALLOW_CLONE" \
  --argjson lfs "$LFS_ENABLED_GLOBALLY" \
  '{
    total_checkouts: $total,
    shallow_count: $shallow,
    full_clone_count: $full_clone,
    no_shallow_clone: $no_shallow,
    lfs_enabled_globally: $lfs
  }')

# ══════════════════════════════════════════════════════════════════════════════
# F. DOCKER BUILD ANALYSIS
# ══════════════════════════════════════════════════════════════════════════════

NO_LAYER_CACHE=false
COPY_BEFORE_INSTALL=false
NO_MULTI_STAGE=false
LARGE_BASE_IMAGE_JSON="[]"

DOCKERFILES=()
while IFS= read -r -d '' f; do
  DOCKERFILES+=("$f")
done < <(find . -name "Dockerfile" -o -name "Dockerfile.*" 2>/dev/null \
  | grep -v "node_modules\|\.git\|\.venv\|venv\|dist\|build" \
  | sort -z 2>/dev/null || true)

if [[ ${#DOCKERFILES[@]} -gt 0 ]]; then
  # Layer cache check (via workflow - already done above)
  [[ "$MISSING_DOCKER_CACHE" == "true" ]] && NO_LAYER_CACHE=true

  for df in "${DOCKERFILES[@]:-}"; do
    [[ -z "$df" ]] && continue

    # COPY . . before RUN npm install / pip install
    COPY_LINE=$(grep -n "^COPY \." "$df" 2>/dev/null | head -1 || true)
    INSTALL_LINE=$(grep -n "RUN.*npm install\|RUN.*pip install\|RUN.*yarn\|RUN.*pnpm" "$df" 2>/dev/null | head -1 || true)
    if [[ -n "$COPY_LINE" && -n "$INSTALL_LINE" ]]; then
      COPY_NUM=$(echo "$COPY_LINE" | cut -d: -f1)
      INSTALL_NUM=$(echo "$INSTALL_LINE" | cut -d: -f1)
      if [[ $COPY_NUM -lt $INSTALL_NUM ]]; then
        COPY_BEFORE_INSTALL=true
      fi
    fi

    # Multi-stage build detection
    FROM_COUNT=$(grep -c "^FROM " "$df" 2>/dev/null || echo "0")
    [[ $FROM_COUNT -lt 2 ]] && NO_MULTI_STAGE=true

    # Large base images
    BASE_IMAGE=$(grep "^FROM " "$df" 2>/dev/null | head -1 | awk '{print $2}' || true)
    if echo "$BASE_IMAGE" | grep -qE "^node:[0-9]+-?$|^node:latest|^python:[0-9]+\.[0-9]+$|^ubuntu:|^debian:" 2>/dev/null; then
      SLIM_VARIANT=""
      case "$BASE_IMAGE" in
        node:*) [[ ! "$BASE_IMAGE" =~ slim|alpine ]] && SLIM_VARIANT="${BASE_IMAGE%:*}:$(echo "${BASE_IMAGE##*:}" | sed 's/-.*$//')-slim" ;;
        python:*) [[ ! "$BASE_IMAGE" =~ slim|alpine ]] && SLIM_VARIANT="${BASE_IMAGE}-slim" ;;
        ubuntu:*|debian:*) SLIM_VARIANT="debian:slim or alpine equivalent" ;;
      esac
      if [[ -n "$SLIM_VARIANT" ]]; then
        LARGE_BASE_IMAGE_JSON=$(echo "$LARGE_BASE_IMAGE_JSON" | jq \
          --arg img "$BASE_IMAGE" --arg alt "$SLIM_VARIANT" --arg file "$df" \
          '. + [{"base_image": $img, "alternative": $alt, "dockerfile": $file, "severity": "low"}]')
      fi
    fi
  done
fi

DOCKER=$(jq -n \
  --argjson no_cache "$NO_LAYER_CACHE" \
  --argjson copy_before "$COPY_BEFORE_INSTALL" \
  --argjson no_multi_stage "$NO_MULTI_STAGE" \
  --argjson large_images "$LARGE_BASE_IMAGE_JSON" \
  --argjson build_count "$DOCKER_BUILD_COUNT" \
  '{
    no_layer_cache: $no_cache,
    copy_before_install: $copy_before,
    no_multi_stage: $no_multi_stage,
    large_base_images: $large_images,
    docker_build_count: $build_count
  }')

# ══════════════════════════════════════════════════════════════════════════════
# G. TRIGGER OPTIMIZATION ANALYSIS
# ══════════════════════════════════════════════════════════════════════════════

# Concurrency group usage
CONCURRENCY_COUNT=$(safe_grep_count -r "^concurrency:\|  concurrency:" .github/workflows/ 2>/dev/null || echo "0")
MISSING_CONCURRENCY=false
[[ $WORKFLOW_COUNT -gt 0 && $CONCURRENCY_COUNT -eq 0 ]] && MISSING_CONCURRENCY=true

# Path filters
PATH_FILTER_COUNT=$(safe_grep_count -r "paths:\|paths-ignore:" .github/workflows/ 2>/dev/null || echo "0")
NO_PATH_FILTERS=false
[[ $WORKFLOW_COUNT -gt 0 && $PATH_FILTER_COUNT -eq 0 ]] && NO_PATH_FILTERS=true

# Runs on all branches (push: with no branches filter)
PUSH_ALL_BRANCHES=$(safe_grep_count -r -A2 "^on:$\|^on: " .github/workflows/ 2>/dev/null | \
  safe_grep_count "push:" || echo "0")
BRANCH_FILTER_COUNT=$(safe_grep_count -r "branches:\|branches-ignore:" .github/workflows/ 2>/dev/null || echo "0")
RUNS_ON_ALL_BRANCHES=false
[[ $PUSH_ALL_BRANCHES -gt 0 && $BRANCH_FILTER_COUNT -eq 0 ]] && RUNS_ON_ALL_BRANCHES=true

TRIGGERS=$(jq -n \
  --argjson missing_concurrency "$MISSING_CONCURRENCY" \
  --argjson no_path_filters "$NO_PATH_FILTERS" \
  --argjson runs_all_branches "$RUNS_ON_ALL_BRANCHES" \
  --argjson concurrency_count "$CONCURRENCY_COUNT" \
  --argjson path_filter_count "$PATH_FILTER_COUNT" \
  '{
    missing_concurrency: $missing_concurrency,
    no_path_filters: $no_path_filters,
    runs_on_all_branches: $runs_all_branches,
    concurrency_count: $concurrency_count,
    path_filter_count: $path_filter_count
  }')

# ══════════════════════════════════════════════════════════════════════════════
# SCORING
# ══════════════════════════════════════════════════════════════════════════════

SCORE=100

# No caching at all: -20
if [[ "$HAS_CACHE_ACTION" == "false" && $WORKFLOW_COUNT -gt 0 && \
      ( $NODE_INSTALL_COUNT -gt 0 || $PIP_INSTALL_COUNT -gt 0 || $DOCKER_BUILD_COUNT -gt 0 ) ]]; then
  SCORE=$(( SCORE - 20 ))
fi

# Missing node cache: -10 (max -20 covered by above)
if [[ "$HAS_CACHE_ACTION" == "true" && "$MISSING_NODE_CACHE" == "true" ]]; then
  SCORE=$(( SCORE - 10 ))
fi

# Missing pip cache: -10
if [[ "$HAS_CACHE_ACTION" == "true" && "$MISSING_PIP_CACHE" == "true" ]]; then
  PENALTY=10; [[ $(( SCORE - PENALTY )) -lt 0 ]] && PENALTY=$SCORE
  SCORE=$(( SCORE - PENALTY ))
fi

# Missing Docker layer cache: -12
if [[ "$MISSING_DOCKER_CACHE" == "true" ]]; then
  PENALTY=12; [[ $(( SCORE - PENALTY )) -lt 0 ]] && PENALTY=$SCORE
  SCORE=$(( SCORE - PENALTY ))
fi

# Parallelizable sequential jobs: -8
if [[ $CAN_PARALLELIZE_COUNT -gt 0 ]]; then
  PENALTY=$(( CAN_PARALLELIZE_COUNT * 8 ))
  [[ $PENALTY -gt 24 ]] && PENALTY=24
  SCORE=$(( SCORE - PENALTY ))
fi

# Full clone (no shallow): -5 per unoptimized checkout, max -15
if [[ "$NO_SHALLOW_CLONE" == "true" && $FULL_CLONE_COUNT -gt 0 ]]; then
  PENALTY=$(( FULL_CLONE_COUNT * 5 ))
  [[ $PENALTY -gt 15 ]] && PENALTY=15
  SCORE=$(( SCORE - PENALTY ))
fi

# e2e on every push: -10
if [[ "$E2E_ON_EVERY_PUSH" == "true" ]]; then
  SCORE=$(( SCORE - 10 ))
fi

# No concurrency group: -8
if [[ "$MISSING_CONCURRENCY" == "true" ]]; then
  SCORE=$(( SCORE - 8 ))
fi

# Install without cache: -6 per occurrence, max -12
if [[ "$INSTALL_WITHOUT_CACHE_BOOL" == "true" ]]; then
  SCORE=$(( SCORE - 6 ))
fi

# Duplicate installs: -6
if [[ "$DUPLICATE_INSTALLS" == "true" ]]; then
  SCORE=$(( SCORE - 6 ))
fi

# Dockerfile COPY before install: -8
if [[ "$COPY_BEFORE_INSTALL" == "true" ]]; then
  SCORE=$(( SCORE - 8 ))
fi

# No multi-stage Docker: -6
if [[ "$NO_MULTI_STAGE" == "true" && $DOCKER_BUILD_COUNT -gt 0 ]]; then
  SCORE=$(( SCORE - 6 ))
fi

# No path filters: -5
if [[ "$NO_PATH_FILTERS" == "true" ]]; then
  SCORE=$(( SCORE - 5 ))
fi

# Floor at 0
[[ $SCORE -lt 0 ]] && SCORE=0

# Status thresholds
if [[ $SCORE -ge 80 ]]; then   STATUS="good"
elif [[ $SCORE -ge 60 ]]; then STATUS="warning"
elif [[ $SCORE -ge 40 ]]; then STATUS="needs_work"
else                            STATUS="critical"
fi

# ── Emit JSON ─────────────────────────────────────────────────────────────────
jq -n \
  --argjson score "$SCORE" \
  --arg status "$STATUS" \
  --arg ci_system "$CI_SYSTEM" \
  --argjson workflow_count "$WORKFLOW_COUNT_JSON" \
  --argjson caching "$CACHING" \
  --argjson parallelization "$PARALLELIZATION" \
  --argjson redundant "$REDUNDANT" \
  --argjson test_suites "$TEST_SUITES" \
  --argjson checkout "$CHECKOUT" \
  --argjson docker "$DOCKER" \
  --argjson triggers "$TRIGGERS" \
  '{
    score: $score,
    status: $status,
    ci_system: $ci_system,
    workflow_count: $workflow_count,
    caching: $caching,
    parallelization: $parallelization,
    redundant: $redundant,
    test_suites: $test_suites,
    checkout: $checkout,
    docker: $docker,
    triggers: $triggers
  }'
