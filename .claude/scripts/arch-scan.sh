#!/usr/bin/env bash
# arch-scan.sh
# Architecture scanner: circular dependencies, coupling metrics, layering violations, API surface.
#
# DESCRIPTION:
#   READ-ONLY analysis of structural/architectural issues. Produces findings in
#   refactor-finding.schema.json format. Does NOT modify any files.
#
#   Scan categories:
#     1. circular-dep  - Import cycles between modules/packages
#     2. coupling      - Fan-in/fan-out metrics (configurable thresholds)
#     3. layering      - Presentation→data direct imports, utility→business logic, test→test
#     4. api-surface   - Deprecated endpoints, naming inconsistencies, untested routes
#
# USAGE:
#   ./scripts/arch-scan.sh [OPTIONS]
#
# OPTIONS:
#   --output-file FILE        Output findings JSON (default: .refactor/arch-findings.json)
#   --source-dir DIR          Source directory to scan (default: current directory)
#   --fanout-threshold N      Max imports per module before flagging (default: 15)
#   --fanin-threshold N       Max times a module is imported before flagging (default: 20)
#   --categories LIST         Comma-separated: circular-dep,coupling,layering,api-surface (default: all)
#   --severity-threshold LVL  Minimum severity to report: critical|high|medium|low (default: low)
#   --format json|summary     Output format (default: json)
#   --dry-run                 Print what would be scanned, do not write output
#   --verbose                 Verbose logging
#   --help                    Show this help
#
# OUTPUT:
#   JSON array of findings conforming to refactor-finding.schema.json
#   Exit code 0: No critical/high findings
#   Exit code 1: Medium/low findings only
#   Exit code 2: Critical or high findings found
#
# EXAMPLES:
#   # Full scan with defaults
#   ./scripts/arch-scan.sh
#
#   # Circular dependencies only
#   ./scripts/arch-scan.sh --categories circular-dep
#
#   # Strict fan-out threshold
#   ./scripts/arch-scan.sh --fanout-threshold 10 --categories coupling
#
#   # Output to custom file
#   ./scripts/arch-scan.sh --output-file /tmp/arch.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Defaults ───────────────────────────────────────────────────────────────

OUTPUT_FILE="${OUTPUT_FILE:-.refactor/arch-findings.json}"
SOURCE_DIR="${SOURCE_DIR:-.}"
FANOUT_THRESHOLD="${FANOUT_THRESHOLD:-15}"
FANIN_THRESHOLD="${FANIN_THRESHOLD:-20}"
CATEGORIES="${CATEGORIES:-circular-dep,coupling,layering,api-surface}"
SEVERITY_THRESHOLD="${SEVERITY_THRESHOLD:-low}"
FORMAT="${FORMAT:-json}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
SCANNER_VERSION="1.0.0"

# ─── Argument Parsing ────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -50
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-file)        OUTPUT_FILE="$2"; shift 2 ;;
    --source-dir)         SOURCE_DIR="$2"; shift 2 ;;
    --fanout-threshold)   FANOUT_THRESHOLD="$2"; shift 2 ;;
    --fanin-threshold)    FANIN_THRESHOLD="$2"; shift 2 ;;
    --categories)         CATEGORIES="$2"; shift 2 ;;
    --severity-threshold) SEVERITY_THRESHOLD="$2"; shift 2 ;;
    --format)             FORMAT="$2"; shift 2 ;;
    --dry-run)            DRY_RUN="true"; shift ;;
    --verbose)            VERBOSE="true"; shift ;;
    --help|-h)            show_help ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ─── Utilities ───────────────────────────────────────────────────────────────
# Note: Using log_info, log_error, log_debug from lib/common.sh

log() {
  log_info "[arch-scan] $*"
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    log_debug "[arch-scan] $*"
  fi
}

check_deps() {
  local missing=()
  for cmd in jq git; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required commands: ${missing[*]}" >&2
    exit 2
  fi
}

category_enabled() {
  local cat="$1"
  echo "$CATEGORIES" | tr ',' '\n' | grep -qx "$cat"
}

severity_meets_threshold() {
  local sev="$1"
  local threshold="$2"
  local sev_num threshold_num
  case "$sev" in
    critical) sev_num=4 ;;
    high)     sev_num=3 ;;
    medium)   sev_num=2 ;;
    low)      sev_num=1 ;;
    *)        sev_num=0 ;;
  esac
  case "$threshold" in
    critical) threshold_num=4 ;;
    high)     threshold_num=3 ;;
    medium)   threshold_num=2 ;;
    low)      threshold_num=1 ;;
    *)        threshold_num=0 ;;
  esac
  [[ "$sev_num" -ge "$threshold_num" ]]
}

# Generate finding ID (RF-NNN format)
FINDING_COUNTER=0
next_finding_id() {
  FINDING_COUNTER=$((FINDING_COUNTER + 1))
  printf "RF-%03d" "$FINDING_COUNTER"
}

# Detect project type
detect_project_type() {
  if [[ -f "${SOURCE_DIR}/package.json" ]]; then
    echo "nodejs"
  elif [[ -f "${SOURCE_DIR}/pyproject.toml" || -f "${SOURCE_DIR}/requirements.txt" || -f "${SOURCE_DIR}/setup.py" ]]; then
    echo "python"
  elif [[ -f "${SOURCE_DIR}/go.mod" ]]; then
    echo "go"
  elif [[ -f "${SOURCE_DIR}/Cargo.toml" ]]; then
    echo "rust"
  else
    echo "mixed"
  fi
}

# ─── Exclusion Patterns ──────────────────────────────────────────────────────

EXCLUDE_DIRS=(
  "node_modules" ".git" "__pycache__" "venv" ".venv"
  "dist" "build" ".next" "coverage" ".nyc_output"
  ".refactor" ".claude"
)

build_find_exclude() {
  local args=()
  for d in "${EXCLUDE_DIRS[@]}"; do
    args+=(-not -path "*/${d}/*")
  done
  echo "${args[@]}"
}

build_grep_exclude() {
  local args=()
  for d in "${EXCLUDE_DIRS[@]}"; do
    args+=(--exclude-dir="$d")
  done
  echo "${args[@]}"
}

# ─── Import Graph Builder ─────────────────────────────────────────────────────
# Builds a mapping: file → [imported_files]
# Works for Python (import/from), TypeScript/JS (import/require)

build_import_graph() {
  local project_type="$1"
  # Returns JSON: {"file": ["dep1", "dep2", ...], ...}

  local tmp_graph
  tmp_graph=$(mktemp)

  echo '{' > "$tmp_graph"
  local first=true

  # Collect imports for each source file
  local find_args
  read -ra find_args <<< "$(build_find_exclude)"

  # Find source files based on project type
  local source_files=()
  case "$project_type" in
    python)
      while IFS= read -r f; do source_files+=("$f"); done < <(
        find "$SOURCE_DIR" "${find_args[@]}" -name "*.py" 2>/dev/null | sort
      )
      ;;
    nodejs)
      while IFS= read -r f; do source_files+=("$f"); done < <(
        find "$SOURCE_DIR" "${find_args[@]}" \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) 2>/dev/null | sort
      )
      ;;
    go)
      while IFS= read -r f; do source_files+=("$f"); done < <(
        find "$SOURCE_DIR" "${find_args[@]}" -name "*.go" 2>/dev/null | sort
      )
      ;;
    rust)
      while IFS= read -r f; do source_files+=("$f"); done < <(
        find "$SOURCE_DIR" "${find_args[@]}" -name "*.rs" 2>/dev/null | sort
      )
      ;;
    *)
      while IFS= read -r f; do source_files+=("$f"); done < <(
        find "$SOURCE_DIR" "${find_args[@]}" \( -name "*.py" -o -name "*.ts" -o -name "*.tsx" -o -name "*.js" \) 2>/dev/null | sort
      )
      ;;
  esac

  for file in "${source_files[@]+"${source_files[@]}"}"; do
    local rel_file="${file#./}"
    local imports=()

    # Detect per-file language if project is mixed
    local file_lang="$project_type"
    if [[ "$project_type" == "mixed" ]]; then
      case "$file" in
        *.py)  file_lang="python" ;;
        *.ts|*.tsx|*.jsx|*.js) file_lang="nodejs" ;;
        *.go)  file_lang="go" ;;
        *.rs)  file_lang="rust" ;;
      esac
    fi

    case "$file_lang" in
      python)
        # Extract: from X import Y, import X
        while IFS= read -r line; do
          # from module import ... → extract module
          if [[ "$line" =~ ^[[:space:]]*from[[:space:]]+([a-zA-Z0-9_.]+)[[:space:]]+import ]]; then
            imports+=("${BASH_REMATCH[1]}")
          # import module
          elif [[ "$line" =~ ^[[:space:]]*import[[:space:]]+([a-zA-Z0-9_.,[:space:]]+) ]]; then
            local mods="${BASH_REMATCH[1]}"
            while IFS=',' read -r mod; do
              mod="${mod// /}"
              [[ -n "$mod" ]] && imports+=("$mod")
            done <<< "$mods"
          fi
        done < <(grep -E "^[[:space:]]*(from|import)[[:space:]]" "$file" 2>/dev/null || true)
        ;;
      nodejs)
        # Extract: import X from 'Y', require('Y'), import('Y')
        while IFS= read -r line; do
          if [[ "$line" =~ from[[:space:]]+[\'\"](\.\.?/[^\'\"]+)[\'\"] ]]; then
            imports+=("${BASH_REMATCH[1]}")
          elif [[ "$line" =~ require\([[:space:]]*[\'\"](\.\.?/[^\'\"]+)[\'\"] ]]; then
            imports+=("${BASH_REMATCH[1]}")
          fi
        done < <(grep -E "(from|require)\s*[\'\"]" "$file" 2>/dev/null || true)
        ;;
      go)
        # Extract Go imports block
        while IFS= read -r line; do
          if [[ "$line" =~ \"([^\"]+)\" ]]; then
            imports+=("${BASH_REMATCH[1]}")
          fi
        done < <(grep -E '^\s+"' "$file" 2>/dev/null || true)
        ;;
    esac

    # Build JSON entry
    if [[ "${#imports[@]}" -gt 0 ]]; then
      local imports_json
      imports_json=$(printf '%s\n' "${imports[@]}" | jq -R . | jq -s .)
      if [[ "$first" == "true" ]]; then
        first=false
      else
        echo ',' >> "$tmp_graph"
      fi
      printf '"%s": %s' "$rel_file" "$imports_json" >> "$tmp_graph"
    fi
  done

  echo '}' >> "$tmp_graph"
  cat "$tmp_graph"
  rm -f "$tmp_graph"
}

# ─── Directory-level import graph ────────────────────────────────────────────
# Aggregates file-level imports to directory/module level

build_directory_graph() {
  local file_graph="$1"
  # Returns JSON: {"dir_a": ["dir_b", "dir_c"], ...}

  echo "$file_graph" | jq '
    to_entries |
    map(
      .key as $file |
      (($file | split("/") | .[:-1] | join("/")) // ".") as $dir |
      {
        dir: $dir,
        imports: [
          .value[] |
          # Normalize relative path to directory
          gsub("\\.[a-zA-Z0-9]+$"; "") |
          split("/") | .[:-1] | join("/") |
          select(. != "" and . != $dir)
        ] | unique
      }
    ) |
    group_by(.dir) |
    map({
      key: .[0].dir,
      value: [.[].imports[]] | unique
    }) |
    from_entries
  '
}

# ─── Scan: Circular Dependencies ─────────────────────────────────────────────

scan_circular_deps() {
  local project_type="$1"
  local findings=()

  log "Scanning circular dependencies..."

  local file_graph
  file_graph=$(build_import_graph "$project_type")

  local node_count
  node_count=$(echo "$file_graph" | jq 'keys | length')
  log_verbose "Import graph: $node_count nodes"

  if [[ "$node_count" -eq 0 ]]; then
    log_verbose "No imports found, skipping circular dep check"
    echo "[]"
    return
  fi

  # Directory-level cycle detection using DFS
  local dir_graph
  dir_graph=$(build_directory_graph "$file_graph")

  # Find cycles using jq-based DFS (detects simple cycles)
  local cycles
  cycles=$(echo "$dir_graph" | jq '
    . as $graph |
    keys as $nodes |
    # For each node, DFS to find if we can return to it
    [$nodes[] as $start |
      # BFS/DFS from start, track path
      def dfs(visited; path; current):
        if ($graph[current] // []) | map(. == $start) | any then
          # Found a cycle back to start
          [path + [current, $start]]
        else
          [($graph[current] // []) | .[] |
           . as $next |
           if (visited | map(. == $next) | any) then
             empty
           else
             dfs(visited + [current]; path + [current]; $next)[]
           end
          ]
        end;
      dfs([$start]; [$start]; $start)[]
    ] |
    # Deduplicate cycles (normalize by smallest element)
    group_by(sort | .[0]) |
    map(.[0]) |
    map(select(length > 2))  # Skip self-references
  ' 2>/dev/null || echo "[]")

  local cycle_count
  cycle_count=$(echo "$cycles" | jq 'length')
  log_verbose "Found $cycle_count circular dependency cycles"

  local results="[]"

  # Also check file-level for Python relative imports
  local file_cycles
  file_cycles=$(echo "$file_graph" | jq '
    . as $graph |
    keys as $nodes |
    [$nodes[] as $f |
      ($graph[$f] // []) as $deps |
      # Check if any dependency imports back
      ($deps[] | . as $dep |
        ($graph[$dep] // []) | map(. == $f or (. | contains($f))) | any
      ) // false |
      if . then {file: $f, mutual_deps: [$deps[] | . as $d | if ($graph[$d] // []) | map(contains($f)) | any then $d else empty end]}
      else empty
      end
    ]
  ' 2>/dev/null || echo "[]")

  # Generate findings for directory cycles
  if [[ "$cycle_count" -gt 0 ]]; then
    local i=0
    while [[ $i -lt $cycle_count ]] && [[ $i -lt 10 ]]; do
      local cycle
      cycle=$(echo "$cycles" | jq ".[$i]")
      local cycle_str
      cycle_str=$(echo "$cycle" | jq -r 'join(" → ")')
      local cycle_dirs
      cycle_dirs=$(echo "$cycle" | jq -r '.[]' | head -2)

      # Collect files in these directories as file_paths
      local file_paths
      file_paths=$(echo "$cycle" | jq -r '.[]' | while read -r dir; do
        find "$SOURCE_DIR/$dir" -maxdepth 1 -type f \( -name "*.py" -o -name "*.ts" -o -name "*.js" \) 2>/dev/null | head -2 | sed "s|^\./||"
      done | head -4 | jq -R . | jq -s '.' 2>/dev/null || echo '["unknown"]')

      [[ "$(echo "$file_paths" | jq 'length')" -eq 0 ]] && file_paths='["unknown"]'

      local fid
      fid=$(next_finding_id)

      local severity="high"
      local cycle_len
      cycle_len=$(echo "$cycle" | jq 'length')
      [[ "$cycle_len" -le 2 ]] && severity="critical"

      if severity_meets_threshold "$severity" "$SEVERITY_THRESHOLD"; then
        local finding
        finding=$(jq -n \
          --arg id "$fid" \
          --arg cycle "$cycle_str" \
          --arg severity "$severity" \
          --argjson file_paths "$file_paths" \
          --arg scanner_version "$SCANNER_VERSION" \
          --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{
            id: $id,
            dimension: "architecture",
            category: "circular-dep",
            severity: $severity,
            owning_agent: "architect",
            fallback_agent: "refactoring-specialist",
            file_paths: $file_paths,
            description: ("Circular dependency detected: \($cycle). Modules form an import cycle that prevents independent testing, increases coupling, and can cause initialization order issues."),
            suggested_fix: ("Break the cycle by: (1) extracting shared types/interfaces to a common module both can depend on, (2) applying Dependency Inversion - depend on abstractions not concretions, (3) using lazy imports or event-based communication to decouple the cycle."),
            acceptance_criteria: [
              "No import cycle exists between the identified modules",
              "Both modules can be imported/tested independently",
              "All existing tests pass after refactoring"
            ],
            status: "open",
            metadata: {
              created_at: $ts,
              scanner_version: $scanner_version,
              tags: ["circular-dep", "architecture"],
              effort_estimate: "m"
            }
          }')
        results=$(echo "$results" | jq ". + [$finding]")
      fi

      i=$((i + 1))
    done
  fi

  # Check for mutual file-level dependencies
  local mutual_count
  mutual_count=$(echo "$file_cycles" | jq 'length')
  if [[ "$mutual_count" -gt 0 ]]; then
    local i=0
    while [[ $i -lt $mutual_count ]] && [[ $i -lt 5 ]]; do
      local pair
      pair=$(echo "$file_cycles" | jq ".[$i]")
      local src_file
      src_file=$(echo "$pair" | jq -r '.file')
      local mutual_deps
      mutual_deps=$(echo "$pair" | jq '.mutual_deps')
      local mutual_dep_str
      mutual_dep_str=$(echo "$mutual_deps" | jq -r '.[] | select(. != null)' | head -3 | tr '\n' ', ' | sed 's/,$//')

      if [[ -n "$mutual_dep_str" ]]; then
        local fid
        fid=$(next_finding_id)
        local file_paths
        file_paths=$(echo "$pair" | jq '[.file] + (.mutual_deps // [])')

        local finding
        finding=$(jq -n \
          --arg id "$fid" \
          --arg src "$src_file" \
          --arg deps "$mutual_dep_str" \
          --argjson file_paths "$file_paths" \
          --arg scanner_version "$SCANNER_VERSION" \
          --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{
            id: $id,
            dimension: "architecture",
            category: "circular-dep",
            severity: "high",
            owning_agent: "architect",
            fallback_agent: "refactoring-specialist",
            file_paths: $file_paths,
            description: ("Mutual dependency detected: \($src) and \($deps) import each other. This creates a tightly coupled pair that cannot be tested or deployed independently."),
            suggested_fix: "Extract shared dependencies into a separate module. Consider using a mediator/facade pattern or dependency injection to break the mutual reference.",
            acceptance_criteria: [
              "Files no longer have a mutual import relationship",
              "Shared functionality is in a separate, independently importable module",
              "Unit tests for each module can run without the other"
            ],
            status: "open",
            metadata: {
              created_at: $ts,
              scanner_version: $scanner_version,
              tags: ["circular-dep", "mutual-dep"],
              effort_estimate: "m"
            }
          }')

        if severity_meets_threshold "high" "$SEVERITY_THRESHOLD"; then
          results=$(echo "$results" | jq ". + [$finding]")
        fi
      fi

      i=$((i + 1))
    done
  fi

  echo "$results"
}

# ─── Scan: Coupling ───────────────────────────────────────────────────────────

scan_coupling() {
  local project_type="$1"

  log "Scanning coupling metrics (fan-in/fan-out)..."

  local file_graph
  file_graph=$(build_import_graph "$project_type")

  local results="[]"
  local find_args
  read -ra find_args <<< "$(build_find_exclude)"

  # Compute fan-out (how many distinct modules does each file import)
  local fanout_data
  fanout_data=$(echo "$file_graph" | jq \
    --argjson threshold "$FANOUT_THRESHOLD" \
    '
    to_entries |
    map({file: .key, fanout: (.value | length)}) |
    map(select(.fanout > $threshold)) |
    sort_by(-.fanout)
    ')

  local fanout_count
  fanout_count=$(echo "$fanout_data" | jq 'length')
  log_verbose "Fan-out violations: $fanout_count (threshold: $FANOUT_THRESHOLD)"

  # Fan-out findings
  local i=0
  while [[ $i -lt $fanout_count ]] && [[ $i -lt 10 ]]; do
    local entry
    entry=$(echo "$fanout_data" | jq ".[$i]")
    local file fanout
    file=$(echo "$entry" | jq -r '.file')
    fanout=$(echo "$entry" | jq -r '.fanout')

    local severity="medium"
    [[ "$fanout" -gt $((FANOUT_THRESHOLD * 2)) ]] && severity="high"
    [[ "$fanout" -gt $((FANOUT_THRESHOLD * 3)) ]] && severity="critical"

    if severity_meets_threshold "$severity" "$SEVERITY_THRESHOLD"; then
      local fid
      fid=$(next_finding_id)

      local finding
      finding=$(jq -n \
        --arg id "$fid" \
        --arg file "$file" \
        --argjson fanout "$fanout" \
        --argjson threshold "$FANOUT_THRESHOLD" \
        --arg severity "$severity" \
        --arg scanner_version "$SCANNER_VERSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          id: $id,
          dimension: "architecture",
          category: "coupling",
          severity: $severity,
          owning_agent: "architect",
          fallback_agent: "refactoring-specialist",
          file_paths: [$file],
          description: ("High fan-out coupling: \($file) imports \($fanout) modules (threshold: \($threshold)). This module depends on too many others, making it brittle, hard to test, and likely violating the Single Responsibility Principle."),
          suggested_fix: "Decompose this module into smaller, focused modules each with a clear responsibility. Apply the Facade pattern to provide a unified interface while internally delegating to focused sub-modules. Consider if some dependencies can be injected rather than directly imported.",
          acceptance_criteria: [
            ("Module fan-out is reduced below " + ($threshold | tostring)),
            "Each sub-module has a single clear responsibility",
            "All existing tests pass after decomposition"
          ],
          status: "open",
          metadata: {
            created_at: $ts,
            scanner_version: $scanner_version,
            tags: ["coupling", "fan-out"],
            effort_estimate: (if $fanout > ($threshold * 3) then "l" elif $fanout > ($threshold * 2) then "m" else "s" end)
          }
        }')
      results=$(echo "$results" | jq ". + [$finding]")
    fi

    i=$((i + 1))
  done

  # Compute fan-in (how many files import each module)
  # Build a reverse map: module → [files_that_import_it]
  local fanin_data
  fanin_data=$(echo "$file_graph" | jq \
    --argjson threshold "$FANIN_THRESHOLD" \
    '
    # Build reverse index
    [to_entries[] | .key as $importer | .value[] as $dep | {dep: $dep, importer: $importer}] |
    group_by(.dep) |
    map({
      module: .[0].dep,
      fanin: length,
      importers: [.[].importer]
    }) |
    # High fan-in without being in a clearly named utility directory
    map(select(
      .fanin > $threshold and
      # Not obviously a utility (utils, lib, common, shared, helpers, types)
      (.module | test("util|lib|common|shared|helper|type|constant|config|index"; "i") | not)
    )) |
    sort_by(-.fanin)
    ')

  local fanin_count
  fanin_count=$(echo "$fanin_data" | jq 'length')
  log_verbose "Fan-in violations (non-utility): $fanin_count (threshold: $FANIN_THRESHOLD)"

  local i=0
  while [[ $i -lt $fanin_count ]] && [[ $i -lt 5 ]]; do
    local entry
    entry=$(echo "$fanin_data" | jq ".[$i]")
    local module fanin
    module=$(echo "$entry" | jq -r '.module')
    fanin=$(echo "$entry" | jq -r '.fanin')

    # High fan-in on non-utility = too much responsibility or hidden coupling
    local severity="medium"
    [[ "$fanin" -gt $((FANIN_THRESHOLD * 2)) ]] && severity="high"

    if severity_meets_threshold "$severity" "$SEVERITY_THRESHOLD"; then
      local fid
      fid=$(next_finding_id)
      local importers_sample
      importers_sample=$(echo "$entry" | jq '.importers[:3]')

      local finding
      finding=$(jq -n \
        --arg id "$fid" \
        --arg module "$module" \
        --argjson fanin "$fanin" \
        --argjson threshold "$FANIN_THRESHOLD" \
        --arg severity "$severity" \
        --argjson importers "$importers_sample" \
        --arg scanner_version "$SCANNER_VERSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          id: $id,
          dimension: "architecture",
          category: "coupling",
          severity: $severity,
          owning_agent: "architect",
          fallback_agent: "backend-developer",
          file_paths: ([$module] + $importers),
          description: ("High fan-in coupling on non-utility module: \($module) is imported by \($fanin) modules (threshold: \($threshold)). This suggests the module has grown into an unintentional god object or global dependency that creates hidden coupling across the codebase."),
          suggested_fix: "Review whether this module has a single clear responsibility. If it is acting as a utility, rename/move it to a utilities directory and document its role. If it has mixed concerns, decompose it into focused modules. Consider whether some importers should use dependency injection instead.",
          acceptance_criteria: [
            "Module responsibility is clearly defined and documented",
            "Module is either moved to utilities (if appropriate) or decomposed",
            ("Fan-in is below " + ($threshold | tostring) + " or the module is clearly marked as a shared utility")
          ],
          status: "open",
          metadata: {
            created_at: $ts,
            scanner_version: $scanner_version,
            tags: ["coupling", "fan-in"],
            effort_estimate: "l"
          }
        }')
      results=$(echo "$results" | jq ". + [$finding]")
    fi

    i=$((i + 1))
  done

  echo "$results"
}

# ─── Scan: Layering Violations ────────────────────────────────────────────────

scan_layering() {
  local project_type="$1"

  log "Scanning layering violations..."

  local results="[]"
  local grep_args
  read -ra grep_args <<< "$(build_grep_exclude)"

  # Define layer patterns (configurable via convention)
  # Layer order (top to bottom): presentation → business → data/persistence
  # Violations: lower layer importing from higher layer

  local PRESENTATION_PATTERNS=("pages" "views" "components" "ui" "routes" "controllers" "handlers")
  local BUSINESS_PATTERNS=("services" "usecases" "domain" "core" "business" "logic" "managers")
  local DATA_PATTERNS=("repositories" "models" "database" "db" "dao" "persistence" "store" "storage")
  local UTILITY_PATTERNS=("utils" "lib" "helpers" "common" "shared" "constants" "config")

  # Build regex patterns
  local presentation_re
  presentation_re=$(printf '%s|' "${PRESENTATION_PATTERNS[@]}" | sed 's/|$//')
  local business_re
  business_re=$(printf '%s|' "${BUSINESS_PATTERNS[@]}" | sed 's/|$//')
  local data_re
  data_re=$(printf '%s|' "${DATA_PATTERNS[@]}" | sed 's/|$//')
  local utility_re
  utility_re=$(printf '%s|' "${UTILITY_PATTERNS[@]}" | sed 's/|$//')

  # Violation 1: Presentation layer importing data layer directly
  # e.g., pages/foo.ts imports from repositories/bar.ts (skipping services)
  log_verbose "Checking presentation→data direct imports..."

  local pres_to_data_violations=()
  case "$project_type" in
    python)
      while IFS= read -r match; do
        pres_to_data_violations+=("$match")
      done < <(
        find "$SOURCE_DIR" -type f -name "*.py" \
          -regextype posix-extended -regex ".*/(${presentation_re})/.*" \
          2>/dev/null | while read -r f; do
          grep -nE "^(from|import)[[:space:]].*\b(${data_re})\b" "$f" 2>/dev/null | \
            sed "s|^|${f}:|" | head -3
        done | head -20 || true
      )
      ;;
    nodejs)
      while IFS= read -r match; do
        pres_to_data_violations+=("$match")
      done < <(
        find "$SOURCE_DIR" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" \) \
          -regextype posix-extended -regex ".*/(${presentation_re})/.*" \
          2>/dev/null | while read -r f; do
          grep -nE "from ['\"].*/(${data_re})/" "$f" 2>/dev/null | \
            sed "s|^|${f}:|" | head -3
        done | head -20 || true
      )
      ;;
  esac

  if [[ "${#pres_to_data_violations[@]}" -gt 0 ]]; then
    local file_paths
    file_paths=$(printf '%s\n' "${pres_to_data_violations[@]}" | \
      sed 's/:[0-9]*:.*$//' | sort -u | head -5 | jq -R . | jq -s .)

    if severity_meets_threshold "high" "$SEVERITY_THRESHOLD"; then
      local fid
      fid=$(next_finding_id)
      local count="${#pres_to_data_violations[@]}"
      local examples
      examples=$(printf '%s\n' "${pres_to_data_violations[@]}" | head -3 | tr '\n' '; ')

      local finding
      finding=$(jq -n \
        --arg id "$fid" \
        --argjson count "$count" \
        --arg examples "$examples" \
        --argjson file_paths "$file_paths" \
        --arg scanner_version "$SCANNER_VERSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          id: $id,
          dimension: "architecture",
          category: "coupling",
          severity: "high",
          owning_agent: "architect",
          fallback_agent: "backend-developer",
          file_paths: $file_paths,
          description: ("Layering violation: \($count) direct import(s) from presentation layer to data layer, bypassing the service/business layer. Examples: \($examples). This creates tight coupling between UI and persistence concerns."),
          suggested_fix: "Route all data access through the service/business layer. Presentation components should depend on service interfaces only. Create or use existing service methods to fetch data rather than importing repositories/models directly.",
          acceptance_criteria: [
            "No direct imports from presentation layer to data/repository layer",
            "All data access goes through service layer interfaces",
            "Presentation layer tests can mock the service layer without touching database"
          ],
          status: "open",
          metadata: {
            created_at: $ts,
            scanner_version: $scanner_version,
            tags: ["layering", "architecture"],
            effort_estimate: "m"
          }
        }')
      results=$(echo "$results" | jq ". + [$finding]")
    fi
  fi

  # Violation 2: Utility modules importing from business logic
  log_verbose "Checking utility→business logic imports..."

  local util_to_biz_violations=()
  case "$project_type" in
    python)
      while IFS= read -r match; do
        util_to_biz_violations+=("$match")
      done < <(
        find "$SOURCE_DIR" -type f -name "*.py" \
          -regextype posix-extended -regex ".*/(${utility_re})/.*" \
          2>/dev/null | while read -r f; do
          grep -nE "^(from|import)[[:space:]].*\b(${business_re})\b" "$f" 2>/dev/null | \
            sed "s|^|${f}:|" | head -3
        done | head -20 || true
      )
      ;;
    nodejs)
      while IFS= read -r match; do
        util_to_biz_violations+=("$match")
      done < <(
        find "$SOURCE_DIR" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" \) \
          -regextype posix-extended -regex ".*/(${utility_re})/.*" \
          2>/dev/null | while read -r f; do
          grep -nE "from ['\"].*/(${business_re})/" "$f" 2>/dev/null | \
            sed "s|^|${f}:|" | head -3
        done | head -20 || true
      )
      ;;
  esac

  if [[ "${#util_to_biz_violations[@]}" -gt 0 ]]; then
    local file_paths
    file_paths=$(printf '%s\n' "${util_to_biz_violations[@]}" | \
      sed 's/:[0-9]*:.*$//' | sort -u | head -5 | jq -R . | jq -s .)

    if severity_meets_threshold "medium" "$SEVERITY_THRESHOLD"; then
      local fid
      fid=$(next_finding_id)
      local count="${#util_to_biz_violations[@]}"
      local examples
      examples=$(printf '%s\n' "${util_to_biz_violations[@]}" | head -3 | tr '\n' '; ')

      local finding
      finding=$(jq -n \
        --arg id "$fid" \
        --argjson count "$count" \
        --arg examples "$examples" \
        --argjson file_paths "$file_paths" \
        --arg scanner_version "$SCANNER_VERSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          id: $id,
          dimension: "architecture",
          category: "coupling",
          severity: "medium",
          owning_agent: "architect",
          fallback_agent: "refactoring-specialist",
          file_paths: $file_paths,
          description: ("Layering violation: \($count) utility module(s) importing from business logic layer. Examples: \($examples). Utilities should be domain-agnostic; importing business logic creates an inverted dependency that breaks reusability."),
          suggested_fix: "Move the business logic dependency out of the utility module. If the utility needs business-specific behavior, pass it as a parameter/callback (dependency injection) rather than importing it directly. Pure utilities should only depend on language primitives and other utilities.",
          acceptance_criteria: [
            "Utility modules contain no imports from service/business logic layer",
            "Business-specific behavior is injected via parameters rather than hard-coded",
            "Utility modules can be used across different business domains without modification"
          ],
          status: "open",
          metadata: {
            created_at: $ts,
            scanner_version: $scanner_version,
            tags: ["layering", "utilities"],
            effort_estimate: "s"
          }
        }')
      results=$(echo "$results" | jq ". + [$finding]")
    fi
  fi

  # Violation 3: Test files importing from other test files
  log_verbose "Checking test→test cross-imports..."

  local test_to_test=()
  case "$project_type" in
    python)
      while IFS= read -r match; do
        test_to_test+=("$match")
      done < <(
        find "$SOURCE_DIR" -type f -name "test_*.py" -o -name "*_test.py" 2>/dev/null | \
          while read -r f; do
          grep -nE "^(from|import)[[:space:]]+(test_|tests\.)" "$f" 2>/dev/null | \
            sed "s|^|${f}:|" | head -2
        done | head -20 || true
      )
      ;;
    nodejs)
      while IFS= read -r match; do
        test_to_test+=("$match")
      done < <(
        find "$SOURCE_DIR" -type f \( -name "*.test.ts" -o -name "*.spec.ts" -o -name "*.test.js" \) 2>/dev/null | \
          while read -r f; do
          grep -nE "from ['\"].*\.(test|spec)\." "$f" 2>/dev/null | \
            sed "s|^|${f}:|" | head -2
        done | head -20 || true
      )
      ;;
  esac

  if [[ "${#test_to_test[@]}" -gt 0 ]]; then
    local file_paths
    file_paths=$(printf '%s\n' "${test_to_test[@]}" | \
      sed 's/:[0-9]*:.*$//' | sort -u | head -5 | jq -R . | jq -s .)

    if severity_meets_threshold "medium" "$SEVERITY_THRESHOLD"; then
      local fid
      fid=$(next_finding_id)
      local count="${#test_to_test[@]}"

      local finding
      finding=$(jq -n \
        --arg id "$fid" \
        --argjson count "$count" \
        --argjson file_paths "$file_paths" \
        --arg scanner_version "$SCANNER_VERSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          id: $id,
          dimension: "architecture",
          category: "coupling",
          severity: "medium",
          owning_agent: "architect",
          fallback_agent: "test-qa",
          file_paths: $file_paths,
          description: ("Test isolation violation: \($count) test file(s) importing from other test files. Tests should be independent; cross-test imports create fragile test suites where changes to shared test code break unrelated tests."),
          suggested_fix: "Extract shared test utilities into a dedicated test helpers/fixtures directory (e.g., tests/helpers/ or tests/fixtures/). Use test factory functions or fixture modules that are clearly marked as shared test infrastructure rather than test files.",
          acceptance_criteria: [
            "No test files import directly from other test files",
            "Shared test utilities are in a dedicated helpers/fixtures directory",
            "Each test file can run independently with pytest/jest --testPathPattern"
          ],
          status: "open",
          metadata: {
            created_at: $ts,
            scanner_version: $scanner_version,
            tags: ["layering", "test-isolation"],
            effort_estimate: "s"
          }
        }')
      results=$(echo "$results" | jq ". + [$finding]")
    fi
  fi

  echo "$results"
}

# ─── Scan: API Surface ────────────────────────────────────────────────────────

scan_api_surface() {
  local project_type="$1"

  log "Scanning API surface..."

  local results="[]"
  local find_args
  read -ra find_args <<< "$(build_find_exclude)"

  # 1. Detect deprecated endpoints still active
  log_verbose "Checking for deprecated endpoints..."

  local deprecated_routes=()
  while IFS= read -r match; do
    deprecated_routes+=("$match")
  done < <(
    grep -rn \
      --include="*.py" --include="*.ts" --include="*.js" \
      -E "@deprecated|# DEPRECATED|// DEPRECATED|@app\.route.*deprecated|router\.(get|post|put|delete|patch).*deprecated" \
      "${EXCLUDE_DIRS[@]/#/--exclude-dir=}" \
      "$SOURCE_DIR" 2>/dev/null | head -20 || true
  )

  if [[ "${#deprecated_routes[@]}" -gt 0 ]]; then
    local file_paths
    file_paths=$(printf '%s\n' "${deprecated_routes[@]}" | \
      sed 's/:[0-9]*:.*$//' | sort -u | head -5 | jq -R . | jq -s .)

    if severity_meets_threshold "medium" "$SEVERITY_THRESHOLD"; then
      local fid
      fid=$(next_finding_id)
      local count="${#deprecated_routes[@]}"

      local finding
      finding=$(jq -n \
        --arg id "$fid" \
        --argjson count "$count" \
        --argjson file_paths "$file_paths" \
        --arg scanner_version "$SCANNER_VERSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          id: $id,
          dimension: "architecture",
          category: "coupling",
          severity: "medium",
          owning_agent: "api-designer",
          fallback_agent: "backend-developer",
          file_paths: $file_paths,
          description: ("API surface: \($count) deprecated endpoint(s) still active in the codebase. Deprecated routes accumulate technical debt, confuse consumers, and may introduce security exposure if not properly maintained."),
          suggested_fix: "Audit deprecated endpoints: (1) if no active consumers, remove them; (2) if consumers exist, create a migration guide and set a removal deadline; (3) return 410 Gone with deprecation notice; (4) document in CHANGELOG.",
          acceptance_criteria: [
            "Each deprecated endpoint has either been removed or has a documented migration path",
            "Deprecated endpoints return deprecation headers (Deprecation, Sunset)",
            "API changelog documents the deprecation timeline"
          ],
          status: "open",
          metadata: {
            created_at: $ts,
            scanner_version: $scanner_version,
            tags: ["api-surface", "deprecated"],
            effort_estimate: "m"
          }
        }')
      results=$(echo "$results" | jq ". + [$finding]")
    fi
  fi

  # 2. Detect inconsistent endpoint naming
  log_verbose "Checking API endpoint naming consistency..."

  local routes_snake=()
  local routes_kebab=()
  local routes_camel=()

  # Collect route patterns
  while IFS= read -r line; do
    local route
    route=$(echo "$line" | grep -oE "['\"/][a-zA-Z0-9/_-]+['\"]" | head -1 | tr -d "'\"" || true)
    if [[ -n "$route" ]]; then
      if echo "$route" | grep -qE "^/[a-z_]+(_[a-z_]+)*"; then
        routes_snake+=("$route")
      elif echo "$route" | grep -qE "^/[a-z]+(-[a-z]+)+"; then
        routes_kebab+=("$route")
      elif echo "$route" | grep -qE "^/[a-z]+([A-Z][a-z]+)+"; then
        routes_camel+=("$route")
      fi
    fi
  done < <(
    grep -rn \
      --include="*.py" --include="*.ts" --include="*.js" \
      -E "(@app\.route|router\.(get|post|put|delete|patch|all)|app\.(get|post|put|delete|patch))\s*\(" \
      "${EXCLUDE_DIRS[@]/#/--exclude-dir=}" \
      "$SOURCE_DIR" 2>/dev/null | head -50 || true
  )

  # Check if mixed styles exist
  local style_count=0
  [[ "${#routes_snake[@]}" -gt 0 ]] && style_count=$((style_count + 1))
  [[ "${#routes_kebab[@]}" -gt 0 ]] && style_count=$((style_count + 1))
  [[ "${#routes_camel[@]}" -gt 0 ]] && style_count=$((style_count + 1))

  if [[ "$style_count" -gt 1 ]]; then
    # Determine dominant style
    local dominant="mixed"
    if [[ "${#routes_kebab[@]}" -ge "${#routes_snake[@]}" && "${#routes_kebab[@]}" -ge "${#routes_camel[@]}" ]]; then
      dominant="kebab-case"
    elif [[ "${#routes_snake[@]}" -ge "${#routes_camel[@]}" ]]; then
      dominant="snake_case"
    else
      dominant="camelCase"
    fi

    if severity_meets_threshold "low" "$SEVERITY_THRESHOLD"; then
      local fid
      fid=$(next_finding_id)

      local finding
      finding=$(jq -n \
        --arg id "$fid" \
        --arg dominant "$dominant" \
        --argjson snake_count "${#routes_snake[@]}" \
        --argjson kebab_count "${#routes_kebab[@]}" \
        --argjson camel_count "${#routes_camel[@]}" \
        --arg scanner_version "$SCANNER_VERSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          id: $id,
          dimension: "architecture",
          category: "naming",
          severity: "low",
          owning_agent: "api-designer",
          fallback_agent: "backend-developer",
          file_paths: ["(detected via API route scan)"],
          description: ("Inconsistent API endpoint naming: \($snake_count) snake_case, \($kebab_count) kebab-case, \($camel_count) camelCase routes detected. REST APIs should use a consistent naming convention (REST standard recommends kebab-case for URLs)."),
          suggested_fix: ("Standardize on \($dominant) (or REST-standard kebab-case). Update all endpoints and document the convention in API guidelines. Use a linting rule (e.g., eslint-plugin-url-naming or custom middleware) to enforce going forward."),
          acceptance_criteria: [
            "All API routes use a single consistent naming convention",
            "Naming convention is documented in API guidelines",
            "Lint rule or test enforces the convention on new routes"
          ],
          status: "open",
          metadata: {
            created_at: $ts,
            scanner_version: $scanner_version,
            tags: ["api-surface", "naming"],
            effort_estimate: "s"
          }
        }')
      results=$(echo "$results" | jq ". + [$finding]")
    fi
  fi

  # 3. Detect routes with no corresponding tests
  log_verbose "Checking for untested API routes..."

  local route_files=()
  while IFS= read -r f; do
    route_files+=("$f")
  done < <(
    grep -rl \
      --include="*.py" --include="*.ts" --include="*.js" \
      -E "(@app\.route|router\.(get|post|put|delete|patch)|app\.(get|post|put|delete|patch))" \
      "${EXCLUDE_DIRS[@]/#/--exclude-dir=}" \
      "$SOURCE_DIR" 2>/dev/null | grep -v "test\|spec" | head -20 || true
  )

  local untested_routes=()
  for route_file in "${route_files[@]+"${route_files[@]}"}"; do
    local basename_no_ext
    basename_no_ext=$(basename "$route_file" | sed 's/\.[^.]*$//')

    # Check if there's a corresponding test file
    local has_test=false
    if find "$SOURCE_DIR" -name "test_${basename_no_ext}*" -o -name "${basename_no_ext}.test.*" -o -name "${basename_no_ext}.spec.*" 2>/dev/null | grep -q .; then
      has_test=true
    fi
    if grep -rl "$basename_no_ext" "$SOURCE_DIR" --include="*.py" --include="*.ts" 2>/dev/null | grep -q "test\|spec"; then
      has_test=true
    fi

    if [[ "$has_test" == "false" ]]; then
      untested_routes+=("$route_file")
    fi
  done

  if [[ "${#untested_routes[@]}" -gt 0 ]]; then
    local file_paths
    file_paths=$(printf '%s\n' "${untested_routes[@]}" | head -5 | jq -R . | jq -s .)

    if severity_meets_threshold "medium" "$SEVERITY_THRESHOLD"; then
      local fid
      fid=$(next_finding_id)
      local count="${#untested_routes[@]}"

      local finding
      finding=$(jq -n \
        --arg id "$fid" \
        --argjson count "$count" \
        --argjson file_paths "$file_paths" \
        --arg scanner_version "$SCANNER_VERSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          id: $id,
          dimension: "architecture",
          category: "missing-tests",
          severity: "medium",
          owning_agent: "api-designer",
          fallback_agent: "test-qa",
          file_paths: $file_paths,
          description: ("API surface gap: \($count) route file(s) have no corresponding test coverage. Untested endpoints are invisible to CI, prone to regression, and create uncertainty about contract stability."),
          suggested_fix: "Create integration/contract tests for each untested route file. At minimum: (1) happy path with valid input, (2) error path with invalid input, (3) authentication/authorization check if applicable. Use frameworks like pytest-httpx, supertest, or similar.",
          acceptance_criteria: [
            "Every route file has at least one corresponding test file",
            "Tests cover happy path and error cases for each endpoint",
            "CI pipeline runs API tests on every PR"
          ],
          status: "open",
          metadata: {
            created_at: $ts,
            scanner_version: $scanner_version,
            tags: ["api-surface", "missing-tests"],
            effort_estimate: "m"
          }
        }')
      results=$(echo "$results" | jq ". + [$finding]")
    fi
  fi

  # 4. Detect unused API routes (defined but never referenced)
  log_verbose "Checking for potentially unused API routes..."

  # Collect all defined route paths
  local all_routes=()
  while IFS= read -r line; do
    local route
    route=$(echo "$line" | grep -oE "(['\"])/[a-zA-Z0-9/_:-]+(['\"])" | tr -d "'\"" | head -1 || true)
    [[ -n "$route" ]] && all_routes+=("$route")
  done < <(
    grep -rn \
      --include="*.py" --include="*.ts" --include="*.js" \
      -E "(@app\.route|router\.(get|post|put|delete|patch|all)|app\.(get|post|put|delete|patch))" \
      "${EXCLUDE_DIRS[@]/#/--exclude-dir=}" \
      "$SOURCE_DIR" 2>/dev/null | grep -v "test\|spec" | head -30 || true
  )

  local unused_routes=()
  for route in "${all_routes[@]+"${all_routes[@]}"}"; do
    # Check if this route path is referenced anywhere (in tests, clients, docs)
    local ref_count
    ref_count=$(grep -rl \
      --include="*.py" --include="*.ts" --include="*.js" --include="*.md" \
      "${EXCLUDE_DIRS[@]/#/--exclude-dir=}" \
      "$route" "$SOURCE_DIR" 2>/dev/null | wc -l | tr -d ' ')

    # If only referenced once (the definition itself), it's potentially unused
    if [[ "$ref_count" -le 1 ]]; then
      unused_routes+=("$route")
    fi
  done

  if [[ "${#unused_routes[@]}" -gt 3 ]]; then
    # Only flag if there are several unused routes (reduces false positives)
    if severity_meets_threshold "low" "$SEVERITY_THRESHOLD"; then
      local fid
      fid=$(next_finding_id)
      local count="${#unused_routes[@]}"
      local route_list
      route_list=$(printf '%s\n' "${unused_routes[@]}" | head -5 | jq -R . | jq -s .)

      local finding
      finding=$(jq -n \
        --arg id "$fid" \
        --argjson count "$count" \
        --argjson route_list "$route_list" \
        --arg scanner_version "$SCANNER_VERSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          id: $id,
          dimension: "architecture",
          category: "dead-code",
          severity: "low",
          owning_agent: "api-designer",
          fallback_agent: "backend-developer",
          file_paths: ["(detected via route reference analysis)"],
          description: ("Potentially unused API routes: \($count) route path(s) appear to have no references in tests, clients, or documentation. Sample: \($route_list | join(\", \")). Dead routes add maintenance burden and confusion."),
          suggested_fix: "Verify each route against API consumers (clients, tests, external docs). Remove routes confirmed unused. For routes with external consumers not in-repo, add documentation/tests referencing them. Consider adding route coverage to CI.",
          acceptance_criteria: [
            "Each API route is referenced in at least one test or documented consumer",
            "Unused routes are either removed or documented with known external consumers",
            "Route inventory is maintained in API documentation"
          ],
          status: "open",
          metadata: {
            created_at: $ts,
            scanner_version: $scanner_version,
            tags: ["api-surface", "dead-code"],
            effort_estimate: "s"
          }
        }')
      results=$(echo "$results" | jq ". + [$finding]")
    fi
  fi

  echo "$results"
}

# ─── Summary Output ───────────────────────────────────────────────────────────

print_summary() {
  local findings="$1"

  local total critical high medium low
  total=$(echo "$findings" | jq 'length')
  critical=$(echo "$findings" | jq '[.[] | select(.severity == "critical")] | length')
  high=$(echo "$findings" | jq '[.[] | select(.severity == "high")] | length')
  medium=$(echo "$findings" | jq '[.[] | select(.severity == "medium")] | length')
  low=$(echo "$findings" | jq '[.[] | select(.severity == "low")] | length')

  echo ""
  echo "┌─────────────────────────────────────────────┐"
  echo "│        Architecture Scan Summary            │"
  echo "├─────────────────────────────────────────────┤"
  printf "│  Total findings:  %-26s│\n" "$total"
  printf "│  🔴 Critical:     %-26s│\n" "$critical"
  printf "│  🟠 High:         %-26s│\n" "$high"
  printf "│  🟡 Medium:       %-26s│\n" "$medium"
  printf "│  🟢 Low:          %-26s│\n" "$low"
  echo "├─────────────────────────────────────────────┤"

  # By category
  echo "│  By category:                               │"
  local categories
  categories=$(echo "$findings" | jq -r '[.[].category] | unique[]')
  while IFS= read -r cat; do
    local cat_count
    cat_count=$(echo "$findings" | jq --arg c "$cat" '[.[] | select(.category == $c)] | length')
    printf "│    %-20s %-22s│\n" "$cat" "$cat_count finding(s)"
  done <<< "$categories"

  echo "└─────────────────────────────────────────────┘"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps

  log "Architecture scanner v${SCANNER_VERSION}"
  log "  Source dir:       $SOURCE_DIR"
  log "  Output file:      $OUTPUT_FILE"
  log "  Categories:       $CATEGORIES"
  log "  Fan-out threshold: $FANOUT_THRESHOLD"
  log "  Fan-in threshold:  $FANIN_THRESHOLD"
  log "  Severity floor:   $SEVERITY_THRESHOLD"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY-RUN mode: would scan $SOURCE_DIR for categories: $CATEGORIES"
    log "  Output would be written to: $OUTPUT_FILE"
    exit 0
  fi

  # Detect project type
  local project_type
  project_type=$(detect_project_type)
  log "  Project type:     $project_type"

  # Initialize findings array
  local all_findings="[]"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Run enabled scan categories
  if category_enabled "circular-dep"; then
    local circular_findings
    circular_findings=$(scan_circular_deps "$project_type")
    all_findings=$(echo "$all_findings" | jq ". + $circular_findings")
    local count
    count=$(echo "$circular_findings" | jq 'length')
    log "  circular-dep: $count finding(s)"
  fi

  if category_enabled "coupling"; then
    local coupling_findings
    coupling_findings=$(scan_coupling "$project_type")
    all_findings=$(echo "$all_findings" | jq ". + $coupling_findings")
    local count
    count=$(echo "$coupling_findings" | jq 'length')
    log "  coupling: $count finding(s)"
  fi

  if category_enabled "layering"; then
    local layering_findings
    layering_findings=$(scan_layering "$project_type")
    all_findings=$(echo "$all_findings" | jq ". + $layering_findings")
    local count
    count=$(echo "$layering_findings" | jq 'length')
    log "  layering: $count finding(s)"
  fi

  if category_enabled "api-surface"; then
    local api_findings
    api_findings=$(scan_api_surface "$project_type")
    all_findings=$(echo "$all_findings" | jq ". + $api_findings")
    local count
    count=$(echo "$api_findings" | jq 'length')
    log "  api-surface: $count finding(s)"
  fi

  # Re-index IDs to be globally unique and sequential
  all_findings=$(echo "$all_findings" | jq '
    to_entries | map(.value + {id: ("RF-" + (((.key + 1) | tostring) | if length < 3 then ("00" + .) else if length < 4 then ("0" + .) else . end end))}) | .
  ')

  # Output
  if [[ "$FORMAT" == "summary" ]]; then
    print_summary "$all_findings" >&2
    echo "$all_findings" | jq .
  else
    # Ensure output directory exists
    local output_dir
    output_dir=$(dirname "$OUTPUT_FILE")
    mkdir -p "$output_dir"

    echo "$all_findings" | jq . > "$OUTPUT_FILE"
    log "Findings written to: $OUTPUT_FILE"

    # Print summary to stderr
    print_summary "$all_findings" >&2
  fi

  # Determine exit code
  local critical_count high_count
  critical_count=$(echo "$all_findings" | jq '[.[] | select(.severity == "critical")] | length')
  high_count=$(echo "$all_findings" | jq '[.[] | select(.severity == "high")] | length')
  local total_count
  total_count=$(echo "$all_findings" | jq 'length')

  if [[ "$critical_count" -gt 0 || "$high_count" -gt 0 ]]; then
    log "Exit code 2: critical or high findings detected"
    exit 2
  elif [[ "$total_count" -gt 0 ]]; then
    log "Exit code 1: medium/low findings only"
    exit 1
  else
    log "Exit code 0: no findings"
    exit 0
  fi
}

main "$@"
