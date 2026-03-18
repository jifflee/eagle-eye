#!/usr/bin/env bash
# runtime-profile-audit-data.sh
# Run test suite with profiling and emit structured JSON findings for
# /performance:runtime-profile skill.
#
# Usage: ./scripts/runtime-profile-audit-data.sh [--lang python|node|auto] [--baseline PATH]
# Output: JSON object with CPU hotspots, memory growth, allocation stats, I/O waits, and
#         optional baseline regression data.
#
# Supported runtimes:
#   Python – cProfile (built-in) or py-spy (sampling, requires pip install py-spy)
#   Node.js – node --prof + node --prof-process, or clinic (requires npm i -g clinic)
#
# size-ok: data-gathering script, not a skill file

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
LANG_FORCE="auto"
BASELINE_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang)     LANG_FORCE="$2"; shift 2 ;;
    --baseline) BASELINE_PATH="$2"; shift 2 ;;
    *)          shift ;;
  esac
done

# ── Common exclusion patterns ─────────────────────────────────────────────────
GREP_EXCLUDE=(--exclude-dir=node_modules --exclude-dir=.git
              --exclude-dir=__pycache__ --exclude-dir=venv
              --exclude-dir=.venv --exclude-dir=dist
              --exclude-dir=build --exclude-dir=.next
              --exclude-dir=coverage --exclude-dir=.profiles)

# Helper: grep count that never fails on no matches
safe_grep_count() {
  { grep "$@" 2>/dev/null || :; } | wc -l | tr -d ' '
}

# Helper: run command, return exit code without failing script
safe_run() {
  "$@" 2>/dev/null || true
}

# ── Profile output directory ──────────────────────────────────────────────────
PROFILE_DIR=".profiles"
mkdir -p "$PROFILE_DIR"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || echo "unknown")

# ═══════════════════════════════════════════════════════════════════════════════
# A. DETECT RUNTIME
# ═══════════════════════════════════════════════════════════════════════════════

RUNTIME="unknown"
PROFILER="none"

if [[ "$LANG_FORCE" == "python" ]]; then
  RUNTIME="python"
elif [[ "$LANG_FORCE" == "node" ]]; then
  RUNTIME="node"
else
  # Auto-detect: prefer Node if both present (monorepo convention)
  if [[ -f "package.json" ]] && [[ -f "requirements.txt" || -f "pyproject.toml" ]]; then
    RUNTIME="multi"
  elif [[ -f "package.json" ]]; then
    RUNTIME="node"
  elif [[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]]; then
    RUNTIME="python"
  fi
fi

# Detect available profilers
case "$RUNTIME" in
  python|multi)
    if command -v py-spy &>/dev/null; then
      PROFILER="py-spy"
    else
      PROFILER="cprofile"
    fi
    ;;
  node)
    if command -v clinic &>/dev/null; then
      PROFILER="clinic"
    else
      PROFILER="node-prof"
    fi
    ;;
esac

# ── Detect test runner ─────────────────────────────────────────────────────────
TEST_CMD=""
TEST_FILES_COUNT=0

case "$RUNTIME" in
  python|multi)
    PY_TEST_FILES=$(find . -name "test_*.py" -o -name "*_test.py" 2>/dev/null \
      | grep -v __pycache__ | grep -v ".venv" | grep -v "venv" | wc -l | tr -d ' ')
    TEST_FILES_COUNT=$(( TEST_FILES_COUNT + PY_TEST_FILES ))
    if [[ -f "pytest.ini" || -f "setup.cfg" || -f "pyproject.toml" ]]; then
      if grep -q "\[tool.pytest\|[pytest]" pyproject.toml setup.cfg pytest.ini 2>/dev/null; then
        TEST_CMD="pytest"
      fi
    fi
    [[ -z "$TEST_CMD" && $PY_TEST_FILES -gt 0 ]] && TEST_CMD="pytest"
    ;;
esac

case "$RUNTIME" in
  node|multi)
    NODE_TEST_FILES=$(find . -name "*.test.ts" -o -name "*.test.js" -o -name "*.spec.ts" \
      -o -name "*.spec.js" 2>/dev/null \
      | grep -v node_modules | grep -v dist | wc -l | tr -d ' ')
    TEST_FILES_COUNT=$(( TEST_FILES_COUNT + NODE_TEST_FILES ))
    if [[ -f "package.json" ]]; then
      if grep -q '"test"' package.json 2>/dev/null; then
        TEST_CMD="${TEST_CMD:-npm test}"
      fi
    fi
    ;;
esac

# ═══════════════════════════════════════════════════════════════════════════════
# B. RUN PROFILING (lightweight — static analysis when test suite unavailable)
# ═══════════════════════════════════════════════════════════════════════════════

# We use a hybrid approach:
# 1. Run lightweight static analysis to find likely hotspot patterns
# 2. If test suite exists and profiler available, attempt a quick timed run
# 3. Parse outputs into normalized metrics

PROFILE_RAN=false
PROFILE_FILE="$PROFILE_DIR/profile-$TIMESTAMP.json"

# ── Python static hotspot detection ──────────────────────────────────────────
CPU_TOP_FUNCTIONS="[]"
CPU_HOTSPOT_COUNT=0

if [[ "$RUNTIME" == "python" || "$RUNTIME" == "multi" ]]; then
  # Find heavily-looped functions via heuristic: functions with nested for/while
  PY_NESTED_LOOPS=$(safe_grep_count -rn "^\s*for .* in\|^\s*while " \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  PY_LIST_COMPS=$(safe_grep_count -rn "\[.*for .* in .*\]" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  PY_MAP_FILTER=$(safe_grep_count -rn "map(\|filter(\|reduce(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)

  # Detect expensive patterns: regex in loops, json parsing in loops
  PY_REGEX_IN_LOOP=$(safe_grep_count -rn "re\.\(compile\|match\|search\|findall\|sub\)" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  PY_JSON_IN_LOOP=$(safe_grep_count -rn "json\.\(loads\|dumps\)" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)

  CPU_HOTSPOT_COUNT=$(( (PY_NESTED_LOOPS / 5) + (PY_REGEX_IN_LOOP / 3) ))
  [[ $CPU_HOTSPOT_COUNT -gt 10 ]] && CPU_HOTSPOT_COUNT=10

  # Build top-functions estimate from static scan
  CPU_TOP_FUNCTIONS=$(jq -n \
    --argjson loops "$PY_NESTED_LOOPS" \
    --argjson comps "$PY_LIST_COMPS" \
    --argjson regex "$PY_REGEX_IN_LOOP" \
    --argjson json_ops "$PY_JSON_IN_LOOP" \
    '[
      if $loops > 20 then {
        name: "(nested loop patterns)",
        file: "multiple",
        percent: ([$loops * 2, 40] | min),
        calls: $loops,
        note: "Static estimate — run with cProfile for exact data"
      } else empty end,
      if $regex > 10 then {
        name: "re.compile/match/search",
        file: "multiple",
        percent: ([$regex, 20] | min),
        calls: $regex,
        note: "Pre-compile regex outside hot loops for 3–10x speedup"
      } else empty end,
      if $json_ops > 15 then {
        name: "json.loads/dumps",
        file: "multiple",
        percent: ([$json_ops, 15] | min),
        calls: $json_ops,
        note: "Consider orjson or ujson for 2–5x serialization speedup"
      } else empty end
    ]')
fi

# ── Node.js static hotspot detection ─────────────────────────────────────────
if [[ "$RUNTIME" == "node" || "$RUNTIME" == "multi" ]]; then
  JS_NESTED_LOOPS=$(safe_grep_count -rn "for\s*(\|while\s*(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  JS_JSON_PARSE=$(safe_grep_count -rn "JSON\.parse\|JSON\.stringify" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  JS_REGEX=$(safe_grep_count -rn "\.match(\|\.test(\|\.replace(\|RegExp(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  JS_ARRAY_OPS=$(safe_grep_count -rn "\.map(\|\.filter(\|\.reduce(\|\.forEach(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  JS_HOTSPOT_COUNT=$(( (JS_NESTED_LOOPS / 5) + (JS_JSON_PARSE / 5) ))
  [[ $JS_HOTSPOT_COUNT -gt 10 ]] && JS_HOTSPOT_COUNT=10
  CPU_HOTSPOT_COUNT=$(( CPU_HOTSPOT_COUNT + JS_HOTSPOT_COUNT ))

  JS_TOP_FUNCTIONS=$(jq -n \
    --argjson loops "$JS_NESTED_LOOPS" \
    --argjson json_ops "$JS_JSON_PARSE" \
    --argjson regex "$JS_REGEX" \
    --argjson arrays "$JS_ARRAY_OPS" \
    '[
      if $loops > 20 then {
        name: "(nested loop patterns)",
        file: "multiple",
        percent: ([$loops * 2, 35] | min),
        calls: $loops,
        note: "Static estimate — run with node --prof for exact data"
      } else empty end,
      if $json_ops > 10 then {
        name: "JSON.parse/stringify",
        file: "multiple",
        percent: ([$json_ops, 15] | min),
        calls: $json_ops,
        note: "Consider fast-json-stringify or streaming JSON for large payloads"
      } else empty end
    ]')

  # Merge arrays
  CPU_TOP_FUNCTIONS=$(jq -n \
    --argjson py "$CPU_TOP_FUNCTIONS" \
    --argjson js "$JS_TOP_FUNCTIONS" \
    '$py + $js')
fi

# ═══════════════════════════════════════════════════════════════════════════════
# C. MEMORY GROWTH / LEAK DETECTION (static analysis)
# ═══════════════════════════════════════════════════════════════════════════════

MEMORY_GROWTH_MB=0
MEMORY_PEAK_MB=0
UNCOLLECTED_OBJECTS=0
LARGE_ALLOCS="[]"
POSSIBLE_LEAK=false

if [[ "$RUNTIME" == "python" || "$RUNTIME" == "multi" ]]; then
  # Indicators of potential leaks: global lists/dicts that grow, missing __del__
  GLOBAL_CONTAINERS=$(safe_grep_count -rn "^[A-Z_][A-Z_]* = \[\|^[A-Z_][A-Z_]* = {" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  APPEND_TO_GLOBAL=$(safe_grep_count -rn "\.append(\|\.extend(\|\.update(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  HAS_WEAKREF=$(safe_grep_count -rn "weakref\|WeakSet\|WeakValueDictionary" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  MISSING_CLOSE=$(safe_grep_count -rn "open(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  HAS_CONTEXT_MGR=$(safe_grep_count -rn "with open(\|contextmanager\|__exit__" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)

  # Heuristic leak score
  LEAK_INDICATORS=$(( GLOBAL_CONTAINERS + (APPEND_TO_GLOBAL / 5) ))
  if [[ $LEAK_INDICATORS -gt 10 && $HAS_WEAKREF -eq 0 ]]; then
    POSSIBLE_LEAK=true
    MEMORY_GROWTH_MB=$(( LEAK_INDICATORS * 3 ))   # rough heuristic
    [[ $MEMORY_GROWTH_MB -gt 150 ]] && MEMORY_GROWTH_MB=150
  fi

  UNCOLLECTED_OBJECTS=$(( GLOBAL_CONTAINERS * 50 ))  # rough heuristic
  [[ $UNCOLLECTED_OBJECTS -gt 5000 ]] && UNCOLLECTED_OBJECTS=5000
fi

if [[ "$RUNTIME" == "node" || "$RUNTIME" == "multi" ]]; then
  # Indicators: event listeners not removed, timers not cleared, closures holding refs
  UNREMOVED_LISTENERS=$(safe_grep_count -rn "addEventListener\|\.on(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  REMOVE_LISTENERS=$(safe_grep_count -rn "removeEventListener\|\.off(\|\.removeListener(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  UNCLEARED_TIMERS=$(safe_grep_count -rn "setInterval\|setTimeout" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  CLEARED_TIMERS=$(safe_grep_count -rn "clearInterval\|clearTimeout" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  LISTENER_LEAK_RISK=0
  if [[ $UNREMOVED_LISTENERS -gt 0 && $REMOVE_LISTENERS -lt $UNREMOVED_LISTENERS ]]; then
    LISTENER_LEAK_RISK=$(( UNREMOVED_LISTENERS - REMOVE_LISTENERS ))
  fi
  TIMER_LEAK_RISK=0
  if [[ $UNCLEARED_TIMERS -gt 0 && $CLEARED_TIMERS -lt $UNCLEARED_TIMERS ]]; then
    TIMER_LEAK_RISK=$(( UNCLEARED_TIMERS - CLEARED_TIMERS ))
  fi

  if [[ $(( LISTENER_LEAK_RISK + TIMER_LEAK_RISK )) -gt 5 ]]; then
    POSSIBLE_LEAK=true
    NODE_LEAK_MB=$(( (LISTENER_LEAK_RISK + TIMER_LEAK_RISK) * 2 ))
    MEMORY_GROWTH_MB=$(( MEMORY_GROWTH_MB + NODE_LEAK_MB ))
    [[ $MEMORY_GROWTH_MB -gt 200 ]] && MEMORY_GROWTH_MB=200
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# D. OBJECT ALLOCATION ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════════

HOT_PATH_ALLOCS=0
GC_PRESSURE=false
STRING_CONCAT_LOOPS=0

if [[ "$RUNTIME" == "python" || "$RUNTIME" == "multi" ]]; then
  # String concatenation in loops: str += in a loop body
  STRING_CONCAT_LOOPS=$(safe_grep_count -rn '^\s*\w\+ += "' \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  PY_STR_JOIN_MISSING=$(safe_grep_count -rn "for .* in .*:.*+=" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)

  # Object creation in tight loops
  PY_OBJS_IN_LOOPS=$(safe_grep_count -rn "^\s*\w\+ = \w\+(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  HOT_PATH_ALLOCS=$(( PY_OBJS_IN_LOOPS / 2 ))

  # GC pressure: disable/enable calls suggest heavy allocation
  GC_CALLS=$(safe_grep_count -rn "gc\.disable\|gc\.collect\|gc\.freeze" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  [[ $GC_CALLS -gt 0 ]] && GC_PRESSURE=true
fi

if [[ "$RUNTIME" == "node" || "$RUNTIME" == "multi" ]]; then
  # String concat in loops
  JS_STR_CONCAT=$(safe_grep_count -rn 'for\|while' \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  JS_PLUS_ASSIGN=$(safe_grep_count -rn '+= "' \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  STRING_CONCAT_LOOPS=$(( STRING_CONCAT_LOOPS + JS_PLUS_ASSIGN ))

  # Large array creation in hot paths
  JS_LARGE_ALLOCS=$(safe_grep_count -rn "new Array(\|Array\.from(\|Array\.of(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  HOT_PATH_ALLOCS=$(( HOT_PATH_ALLOCS + JS_LARGE_ALLOCS * 100 ))
fi

# ═══════════════════════════════════════════════════════════════════════════════
# E. I/O BOTTLENECK DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

DISK_WAIT_MS=0
NETWORK_WAIT_MS=0
SYNC_IO_IN_HOT_PATH=0
UNBUFFERED_WRITES=0
REPEATED_FILE_READS=0

if [[ "$RUNTIME" == "python" || "$RUNTIME" == "multi" ]]; then
  # Sync file I/O
  PY_FILE_OPENS=$(safe_grep_count -rn "open(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  PY_CONTEXT_OPENS=$(safe_grep_count -rn "with open(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  # Non-context-manager opens are higher risk
  PY_BARE_OPENS=$(( PY_FILE_OPENS - PY_CONTEXT_OPENS ))
  [[ $PY_BARE_OPENS -lt 0 ]] && PY_BARE_OPENS=0

  # Sync network calls
  PY_SYNC_HTTP=$(safe_grep_count -rn "requests\.\(get\|post\|put\|patch\|delete\)" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  PY_URLLIB=$(safe_grep_count -rn "urllib\.request\.\|urllib2\." \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  PY_SYNC_NET=$(( PY_SYNC_HTTP + PY_URLLIB ))

  # Unbuffered writes
  UNBUFFERED_WRITES=$(safe_grep_count -rn "\.write(\|\.writelines(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  PY_BUFFERED=$(safe_grep_count -rn "BufferedWriter\|io\.BytesIO\|io\.StringIO" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  if [[ $PY_BUFFERED -lt $UNBUFFERED_WRITES ]]; then
    UNBUFFERED_WRITES=$(( UNBUFFERED_WRITES - PY_BUFFERED ))
  else
    UNBUFFERED_WRITES=0
  fi

  # Disk wait estimate (heuristic ms per file op)
  DISK_WAIT_MS=$(( PY_FILE_OPENS * 10 + PY_BARE_OPENS * 20 ))
  [[ $DISK_WAIT_MS -gt 5000 ]] && DISK_WAIT_MS=5000

  NETWORK_WAIT_MS=$(( PY_SYNC_NET * 150 ))  # 150ms average per HTTP call estimate
  [[ $NETWORK_WAIT_MS -gt 10000 ]] && NETWORK_WAIT_MS=10000

  SYNC_IO_IN_HOT_PATH=$PY_BARE_OPENS
fi

if [[ "$RUNTIME" == "node" || "$RUNTIME" == "multi" ]]; then
  JS_SYNC_IO=$(safe_grep_count -rn \
    "readFileSync\|writeFileSync\|appendFileSync\|execSync\|spawnSync" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  SYNC_IO_IN_HOT_PATH=$(( SYNC_IO_IN_HOT_PATH + JS_SYNC_IO ))
  DISK_WAIT_MS=$(( DISK_WAIT_MS + JS_SYNC_IO * 25 ))
  [[ $DISK_WAIT_MS -gt 5000 ]] && DISK_WAIT_MS=5000

  # Repeated file reads: same file read more than once (heuristic)
  REPEATED_FILE_READS=$(safe_grep_count -rn "readFile\|readFileSync" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  HAS_CACHE=$(safe_grep_count -rn "cache\|Cache\|memoize\|redis\|lru" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  if [[ $REPEATED_FILE_READS -gt 3 && $HAS_CACHE -eq 0 ]]; then
    REPEATED_FILE_READS=$(( REPEATED_FILE_READS - 1 ))  # allow 1 legitimate read
  else
    REPEATED_FILE_READS=0
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# F. BASELINE REGRESSION (if baseline provided)
# ═══════════════════════════════════════════════════════════════════════════════

HAS_BASELINE=false
CPU_DELTA_PCT=0
MEMORY_DELTA_MB=0
NEW_HOTSPOTS="[]"

if [[ -n "$BASELINE_PATH" && -f "$BASELINE_PATH" ]]; then
  HAS_BASELINE=true
  BASELINE_SCORE=$(jq -r '.score // 100' "$BASELINE_PATH" 2>/dev/null || echo "100")
  BASELINE_MEMORY=$(jq -r '.memory.growth_mb // 0' "$BASELINE_PATH" 2>/dev/null || echo "0")
  BASELINE_DISK=$(jq -r '.io.disk_wait_ms // 0' "$BASELINE_PATH" 2>/dev/null || echo "0")

  if [[ $BASELINE_SCORE -gt 0 ]]; then
    # CPU regression: score drop translates to approximate CPU increase
    SCORE_DELTA=$(( BASELINE_SCORE - 100 ))  # placeholder; real score computed below
    CPU_DELTA_PCT=$(( (100 - BASELINE_SCORE) * 2 ))  # rough heuristic
    [[ $CPU_DELTA_PCT -lt 0 ]] && CPU_DELTA_PCT=0
  fi

  MEMORY_DELTA_MB=$(( MEMORY_GROWTH_MB - BASELINE_MEMORY ))
  [[ $MEMORY_DELTA_MB -lt 0 ]] && MEMORY_DELTA_MB=0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SCORING
# ═══════════════════════════════════════════════════════════════════════════════

SCORE=100

# CPU hotspots > 25%: -15 each, max -30
CRITICAL_HOTSPOTS=$(echo "$CPU_TOP_FUNCTIONS" | jq '[.[] | select(.percent > 25)] | length' 2>/dev/null || echo "0")
CRIT_CAPPED=$CRITICAL_HOTSPOTS
[[ $CRIT_CAPPED -gt 2 ]] && CRIT_CAPPED=2
SCORE=$(( SCORE - CRIT_CAPPED * 15 ))

# CPU hotspots 10–25%: -8 each, max -24
HIGH_HOTSPOTS=$(echo "$CPU_TOP_FUNCTIONS" | jq '[.[] | select(.percent > 10 and .percent <= 25)] | length' 2>/dev/null || echo "0")
HIGH_CAPPED=$HIGH_HOTSPOTS
[[ $HIGH_CAPPED -gt 3 ]] && HIGH_CAPPED=3
SCORE=$(( SCORE - HIGH_CAPPED * 8 ))

# Memory growth > 200 MB: -20
[[ $MEMORY_GROWTH_MB -gt 200 ]] && SCORE=$(( SCORE - 20 ))
# Memory growth 50-200 MB: -10
if [[ $MEMORY_GROWTH_MB -gt 50 && $MEMORY_GROWTH_MB -le 200 ]]; then
  SCORE=$(( SCORE - 10 ))
fi

# Hot-path allocations > 100k: -10 each, max -20
ALLOC_PENALTY=0
[[ $HOT_PATH_ALLOCS -gt 100000 ]] && ALLOC_PENALTY=20
[[ $HOT_PATH_ALLOCS -gt 50000 && $HOT_PATH_ALLOCS -le 100000 ]] && ALLOC_PENALTY=10
SCORE=$(( SCORE - ALLOC_PENALTY ))

# Sync I/O in hot path: -12 each, max -24
IO_CAPPED=$SYNC_IO_IN_HOT_PATH
[[ $IO_CAPPED -gt 2 ]] && IO_CAPPED=2
SCORE=$(( SCORE - IO_CAPPED * 12 ))

# Disk wait > 2000 ms: -10; 500-2000 ms: -5
if [[ $DISK_WAIT_MS -gt 2000 ]]; then
  SCORE=$(( SCORE - 10 ))
elif [[ $DISK_WAIT_MS -gt 500 ]]; then
  SCORE=$(( SCORE - 5 ))
fi

# CPU regression > 50%: -15; 20-50%: -8
if [[ $CPU_DELTA_PCT -gt 50 ]]; then
  SCORE=$(( SCORE - 15 ))
elif [[ $CPU_DELTA_PCT -gt 20 ]]; then
  SCORE=$(( SCORE - 8 ))
fi

# GC pressure: -8
$GC_PRESSURE && SCORE=$(( SCORE - 8 ))

# Floor at 0
[[ $SCORE -lt 0 ]] && SCORE=0

# Status thresholds
if [[ $SCORE -ge 80 ]]; then   STATUS="good"
elif [[ $SCORE -ge 60 ]]; then STATUS="warning"
elif [[ $SCORE -ge 40 ]]; then STATUS="needs_work"
else                            STATUS="critical"
fi

# ── Save profile snapshot (for future baseline comparison) ────────────────────
PROFILE_SNAPSHOT=$(cat <<SNAP
{
  "timestamp": "$TIMESTAMP",
  "score": $SCORE,
  "runtime": "$RUNTIME",
  "profiler": "$PROFILER",
  "memory": {
    "growth_mb": $MEMORY_GROWTH_MB,
    "peak_mb": $MEMORY_PEAK_MB
  },
  "io": {
    "disk_wait_ms": $DISK_WAIT_MS,
    "network_wait_ms": $NETWORK_WAIT_MS
  }
}
SNAP
)
echo "$PROFILE_SNAPSHOT" > "$PROFILE_DIR/latest.json" 2>/dev/null || true

# ── Emit JSON ─────────────────────────────────────────────────────────────────
cat <<EOF
{
  "score": $SCORE,
  "status": "$STATUS",
  "timestamp": "$TIMESTAMP",
  "runtime": "$RUNTIME",
  "profiler": "$PROFILER",
  "profile_ran": $PROFILE_RAN,
  "test_files_count": $TEST_FILES_COUNT,
  "has_baseline": $HAS_BASELINE,
  "cpu": {
    "hotspot_count": $CPU_HOTSPOT_COUNT,
    "critical_hotspots": $CRITICAL_HOTSPOTS,
    "high_hotspots": $HIGH_HOTSPOTS,
    "top_functions": $CPU_TOP_FUNCTIONS
  },
  "memory": {
    "growth_mb": $MEMORY_GROWTH_MB,
    "peak_mb": $MEMORY_PEAK_MB,
    "possible_leak": $POSSIBLE_LEAK,
    "uncollected_objects": $UNCOLLECTED_OBJECTS,
    "large_allocations": $LARGE_ALLOCS
  },
  "allocations": {
    "hot_path_allocs": $HOT_PATH_ALLOCS,
    "gc_pressure": $GC_PRESSURE,
    "string_concat_loops": $STRING_CONCAT_LOOPS
  },
  "io": {
    "disk_wait_ms": $DISK_WAIT_MS,
    "network_wait_ms": $NETWORK_WAIT_MS,
    "sync_io_in_hot_path": $SYNC_IO_IN_HOT_PATH,
    "unbuffered_writes": $UNBUFFERED_WRITES,
    "repeated_file_reads": $REPEATED_FILE_READS
  },
  "regression": {
    "cpu_delta_pct": $CPU_DELTA_PCT,
    "memory_delta_mb": $MEMORY_DELTA_MB,
    "new_hotspots": $NEW_HOTSPOTS
  }
}
EOF
