#!/usr/bin/env bash
# framework-scan.sh
# Framework-specific scanner for the claude-agents framework.
#
# Detects issues specific to the claude-agents structure: skill/agent overlap,
# stale manifests, hook efficiency, and deprecated aliases.
#
# READ-ONLY analysis. Produces findings in refactor-finding.schema.json format.
#
# USAGE:
#   ./scripts/framework-scan.sh [OPTIONS]
#
# OPTIONS:
#   --framework-dir DIR       Framework root directory (default: .)
#   --output-file FILE        Output findings JSON (default: .refactor/framework-findings.json)
#   --categories LIST         Comma-separated: skill-overlap,agent-overlap,stale-manifests,
#                             hook-efficiency,deprecated-aliases
#   --severity-threshold LVL  Minimum severity: critical|high|medium|low (default: low)
#   --format json|summary     Output format (default: json)
#   --dry-run                 Print scan plan, do not execute
#   --verbose                 Verbose output
#
# OUTPUT:
#   JSON array of findings conforming to refactor-finding.schema.json
#   Exit codes: 0=no findings, 1=medium/low only, 2=critical/high found
#
# NOTE: This script delegates the heavy analysis to framework-scan.py.
#       Use framework-scan.py directly for full Python-powered scanning.

set -euo pipefail

SCANNER_VERSION="1.0.0"

# ─── Defaults ────────────────────────────────────────────────────────────────

FRAMEWORK_DIR="."
OUTPUT_FILE=".refactor/framework-findings.json"
CATEGORIES="skill-overlap,agent-overlap,stale-manifests,hook-efficiency,deprecated-aliases"
SEVERITY_THRESHOLD="low"
FORMAT="json"
DRY_RUN=false
VERBOSE=false

# ─── Argument parsing ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --framework-dir)      FRAMEWORK_DIR="$2";        shift 2 ;;
    --output-file)        OUTPUT_FILE="$2";           shift 2 ;;
    --categories)         CATEGORIES="$2";            shift 2 ;;
    --severity-threshold) SEVERITY_THRESHOLD="$2";    shift 2 ;;
    --format)             FORMAT="$2";                shift 2 ;;
    --dry-run)            DRY_RUN=true;               shift ;;
    --verbose)            VERBOSE=true;               shift ;;
    --help|-h)
      grep '^# ' "$0" | head -30 | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "[framework-scan] Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# ─── Setup ───────────────────────────────────────────────────────────────────

log()  { echo "[framework-scan] $*" >&2; }
vlog() { [[ "$VERBOSE" == true ]] && echo "[framework-scan:verbose] $*" >&2 || true; }

FRAMEWORK_DIR="$(cd "$FRAMEWORK_DIR" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCANNER="${SCRIPT_DIR}/framework-scan.py"

severity_order() {
  case "$1" in
    critical) echo 4 ;; high) echo 3 ;; medium) echo 2 ;; low) echo 1 ;; *) echo 0 ;;
  esac
}

meets_threshold() {
  [[ $(severity_order "$1") -ge $(severity_order "$2") ]]
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ"; }

FINDING_COUNTER=0
next_id() {
  FINDING_COUNTER=$((FINDING_COUNTER + 1))
  printf "RF-%03d" "$FINDING_COUNTER"
}

# Temporary file for collecting findings
FINDINGS_TMPFILE="$(mktemp)"
trap 'rm -f "$FINDINGS_TMPFILE"' EXIT
echo "[]" > "$FINDINGS_TMPFILE"

# Append a Python-produced JSON object to our findings list
append_finding() {
  local json_obj="$1"
  [[ -z "$json_obj" ]] && return 0
  python3 -c "
import json, sys
arr = json.load(open('$FINDINGS_TMPFILE'))
try:
    obj = json.loads(sys.argv[1])
    arr.append(obj)
    import json as j2
    open('$FINDINGS_TMPFILE', 'w').write(j2.dumps(arr))
except Exception as e:
    pass  # Skip invalid JSON
" "$json_obj" 2>/dev/null || true
}

# Make a finding JSON object
make_finding() {
  python3 -c "
import json, sys
data = {
    'id': sys.argv[1],
    'dimension': sys.argv[2],
    'category': sys.argv[3],
    'severity': sys.argv[4],
    'owning_agent': sys.argv[5],
    'fallback_agent': sys.argv[6],
    'file_paths': json.loads(sys.argv[7]),
    'description': sys.argv[8],
    'suggested_fix': sys.argv[9],
    'acceptance_criteria': json.loads(sys.argv[10]),
    'status': 'open',
    'metadata': {
        'created_at': '$(now_iso)',
        'scanner_version': '$SCANNER_VERSION',
        'tags': json.loads(sys.argv[11]),
        'effort_estimate': sys.argv[12],
    }
}
print(json.dumps(data))
" "$@" 2>/dev/null
}

# ─── DRY RUN ─────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
  log "Framework scanner v${SCANNER_VERSION}"
  log "  Framework dir: ${FRAMEWORK_DIR}"
  log "  Categories: ${CATEGORIES}"
  log "  Severity threshold: ${SEVERITY_THRESHOLD}"
  log "DRY-RUN: would scan ${FRAMEWORK_DIR}"
  log "DRY-RUN: output → ${OUTPUT_FILE}"
  exit 0
fi

log "Framework scanner v${SCANNER_VERSION}"
log "  Framework dir: ${FRAMEWORK_DIR}"
log "  Categories: ${CATEGORIES}"
log "  Severity threshold: ${SEVERITY_THRESHOLD}"

# ─── Discover directories ─────────────────────────────────────────────────────

COMMANDS_DIR=""
AGENTS_DIR=""
HOOKS_DIR=""

[[ -d "${FRAMEWORK_DIR}/.claude/commands" ]] && COMMANDS_DIR="${FRAMEWORK_DIR}/.claude/commands"
[[ -z "$COMMANDS_DIR" && -d "${FRAMEWORK_DIR}/core/commands" ]] && COMMANDS_DIR="${FRAMEWORK_DIR}/core/commands"

[[ -d "${FRAMEWORK_DIR}/.claude/agents" ]] && AGENTS_DIR="${FRAMEWORK_DIR}/.claude/agents"
[[ -z "$AGENTS_DIR" && -d "${FRAMEWORK_DIR}/core/agents" ]] && AGENTS_DIR="${FRAMEWORK_DIR}/core/agents"

[[ -d "${FRAMEWORK_DIR}/.claude/hooks" ]] && HOOKS_DIR="${FRAMEWORK_DIR}/.claude/hooks"
[[ -z "$HOOKS_DIR" && -d "${FRAMEWORK_DIR}/core/hooks" ]] && HOOKS_DIR="${FRAMEWORK_DIR}/core/hooks"

vlog "Commands dir: ${COMMANDS_DIR:-<none>}"
vlog "Agents dir:   ${AGENTS_DIR:-<none>}"
vlog "Hooks dir:    ${HOOKS_DIR:-<none>}"

# ─── Scan: Skill Overlap ─────────────────────────────────────────────────────

if echo "$CATEGORIES" | grep -qF "skill-overlap"; then
  log "Scanning skill overlap..."
  COUNT=0

  if [[ -n "$COMMANDS_DIR" ]]; then
    # Collect skill files
    SKILL_FILES=()
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && SKILL_FILES+=("$_line")
    done < <(find "$COMMANDS_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | sort)
    vlog "Discovered ${#SKILL_FILES[@]} skill(s)"

    # Check for deprecated markers in skills
    for skill_file in "${SKILL_FILES[@]}"; do
      skill_name="$(basename "$skill_file" .md)"
      rel_path="${skill_file#"${FRAMEWORK_DIR}/"}"
      content="$(cat "$skill_file" 2>/dev/null || echo "")"

      if echo "$content" | grep -qiE '(^#.*deprecated|deprecated.*alias|alias for|renamed to|^>.*deprecated|LEGACY)'; then
        vlog "Deprecated skill: $skill_name"
        meets_threshold "medium" "$SEVERITY_THRESHOLD" || continue

        fid="$(next_id)"
        finding="$(make_finding \
          "$fid" \
          "framework" \
          "dead-code" \
          "medium" \
          "documentation-librarian" \
          "refactoring-specialist" \
          "[\"$rel_path\"]" \
          "Deprecated skill: \`$skill_name\` contains deprecated or alias markers but remains active. Deprecated skills accumulate technical debt and confuse users about which skill to use." \
          "Review \`$skill_name\` and either remove it if obsolete, update to the replacement skill, or remove the deprecation markers if still actively needed. Update any documentation referencing this skill." \
          "[\"Skill \`$skill_name\` is removed or its deprecated markers resolved\", \"No active workflows reference the deprecated skill\", \"Documentation is updated accordingly\"]" \
          "[\"deprecated-alias\", \"skill-overlap\", \"framework\"]" \
          "s")"
        append_finding "$finding"
        COUNT=$((COUNT + 1))
      fi
    done

    # Agent reference grouping: check for many skills wrapping same agent
    # Use a temp file to accumulate "agent_ref skill_name" pairs (bash 3.2 compatible)
    _AGENT_REFS_TMP="$(mktemp)"
    for skill_file in "${SKILL_FILES[@]}"; do
      skill_name="$(basename "$skill_file" .md)"
      # Extract subagent_type references
      while IFS= read -r agent_ref; do
        [[ ${#agent_ref} -gt 3 ]] || continue
        echo "$agent_ref $skill_name" >> "$_AGENT_REFS_TMP"
      done < <(grep -oE '"subagent_type"[^"]*"[a-z][a-z0-9-]+"' "$skill_file" 2>/dev/null \
        | grep -oE '"[a-z][a-z0-9-]+"$' | tr -d '"' || true)
    done

    # Process unique agent refs and count occurrences
    if [[ -s "$_AGENT_REFS_TMP" ]]; then
      while IFS= read -r agent_ref; do
        count="$(grep -c "^${agent_ref} " "$_AGENT_REFS_TMP" 2>/dev/null || echo 0)"
        if [[ $count -ge 3 ]]; then
          vlog "Agent '$agent_ref' referenced by $count skills"
          meets_threshold "low" "$SEVERITY_THRESHOLD" || continue

          skills_sample="$(grep "^${agent_ref} " "$_AGENT_REFS_TMP" 2>/dev/null \
            | awk '{print $2}' | head -5 | tr '\n' ', ' | sed 's/, $//')"

          fid="$(next_id)"
          finding="$(make_finding \
            "$fid" \
            "framework" \
            "dedup" \
            "low" \
            "documentation-librarian" \
            "refactoring-specialist" \
            "[\"${COMMANDS_DIR#"${FRAMEWORK_DIR}/"}\"]" \
            "Multiple skills ($count) reference agent \`$agent_ref\`: $skills_sample. These may be thin wrappers that could be consolidated into a single parameterized skill." \
            "Audit the $count skills wrapping \`$agent_ref\`. Consolidate if use cases are closely related, keeping separate skills only when genuinely distinct contexts require different agent instructions." \
            "[\"Each skill wrapping \`$agent_ref\` has a documented distinct use case\", \"Redundant wrappers are consolidated or removed\", \"Remaining skills are differentiated by clear naming\"]" \
            "[\"skill-overlap\", \"agent-wrapper\", \"framework\"]" \
            "m")"
          append_finding "$finding"
          COUNT=$((COUNT + 1))
        fi
      done < <(awk '{print $1}' "$_AGENT_REFS_TMP" | sort -u 2>/dev/null)
    fi
    rm -f "$_AGENT_REFS_TMP"
  fi

  log "  skill-overlap: $COUNT finding(s)"
fi

# ─── Scan: Agent Overlap ─────────────────────────────────────────────────────

if echo "$CATEGORIES" | grep -qF "agent-overlap"; then
  log "Scanning agent overlap..."
  COUNT=0

  if [[ -n "$AGENTS_DIR" ]]; then
    AGENT_FILES=()
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && AGENT_FILES+=("$_line")
    done < <(find "$AGENTS_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | sort)
    vlog "Discovered ${#AGENT_FILES[@]} agent(s)"

    # Compare agents pairwise for significant content overlap
    for (( i=0; i<${#AGENT_FILES[@]}; i++ )); do
      a1="${AGENT_FILES[$i]}"
      size1="$(wc -c < "$a1" 2>/dev/null || echo 0)"
      [[ $size1 -lt 300 ]] && continue

      for (( j=i+1; j<${#AGENT_FILES[@]}; j++ )); do
        a2="${AGENT_FILES[$j]}"
        size2="$(wc -c < "$a2" 2>/dev/null || echo 0)"
        [[ $size2 -lt 300 ]] && continue
        [[ $COUNT -ge 3 ]] && break 2

        name1="$(basename "$a1" .md)"
        name2="$(basename "$a2" .md)"

        # Use Python for word overlap computation
        overlap="$(python3 - <<'PYEOF' 2>/dev/null || echo "0"
import re, sys

def sig_words(text):
    stop = {'this','that','with','from','have','will','should','must','when',
            'where','which','each','your','their','about','also','into','more',
            'than','then','they','what','been','agent','skill','tool','task',
            'work','used','uses','code','file','make','take','need','only',
            'both','some','such','like','well','just'}
    return {w for w in re.findall(r'[a-zA-Z]{4,}', text.lower()) if w not in stop}

with open(sys.argv[1]) as f:
    t1 = f.read(2000)
with open(sys.argv[2]) as f:
    t2 = f.read(2000)

w1 = sig_words(t1)
w2 = sig_words(t2)
if not w1 or not w2:
    print(0)
else:
    inter = len(w1 & w2)
    smaller = min(len(w1), len(w2))
    print(int(100 * inter / smaller) if smaller > 0 else 0)
PYEOF
python3 -c "
import re, sys
def sig(t):
    stop={'this','that','with','from','have','will','should','must','when','where',
          'which','each','your','their','about','also','into','more','than','then',
          'they','what','been','agent','skill','tool','task','work','used','uses'}
    return {w for w in re.findall(r'[a-zA-Z]{4,}', t.lower()) if w not in stop}
with open('$a1') as f: t1=f.read(2000)
with open('$a2') as f: t2=f.read(2000)
w1,w2=sig(t1),sig(t2)
if not w1 or not w2: print(0)
else:
    inter=len(w1&w2); smaller=min(len(w1),len(w2))
    print(int(100*inter/smaller) if smaller>0 else 0)
" 2>/dev/null || echo "0")"

        if [[ "$overlap" -ge 70 ]] 2>/dev/null; then
          vlog "Agent overlap: $name1 ~ $name2 ($overlap%)"
          meets_threshold "medium" "$SEVERITY_THRESHOLD" || continue

          rel1="${a1#"${FRAMEWORK_DIR}/"}"
          rel2="${a2#"${FRAMEWORK_DIR}/"}"

          fid="$(next_id)"
          finding="$(make_finding \
            "$fid" \
            "framework" \
            "dedup" \
            "medium" \
            "documentation-librarian" \
            "architect" \
            "[\"$rel1\", \"$rel2\"]" \
            "High prompt similarity between agents \`$name1\` and \`$name2\` (~$overlap% word overlap). Agents with very similar prompts may be consolidatable or may have drifted from their intended specialization." \
            "Review \`$name1\` and \`$name2\`. If distinct: expand their differentiating sections to clarify unique responsibilities. If redundant: merge into one agent and update all routing references." \
            "[\"Agent prompts are clearly differentiated with specific responsibilities\", \"Merged agent (if applicable) handles all previous routing scenarios\", \"No routing ambiguity between the two agents\"]" \
            "[\"agent-overlap\", \"prompt-dedup\", \"framework\"]" \
            "m")"
          append_finding "$finding"
          COUNT=$((COUNT + 1))
        fi
      done
    done
  fi

  log "  agent-overlap: $COUNT finding(s)"
fi

# ─── Scan: Stale Manifests ────────────────────────────────────────────────────

if echo "$CATEGORIES" | grep -qF "stale-manifests"; then
  log "Scanning stale manifests..."
  COUNT=0

  MANIFEST_FILES=()
  [[ -f "${FRAMEWORK_DIR}/.claude/.manifest.json" ]] && MANIFEST_FILES+=("${FRAMEWORK_DIR}/.claude/.manifest.json")
  [[ -f "${FRAMEWORK_DIR}/.sync-manifest.json" ]] && MANIFEST_FILES+=("${FRAMEWORK_DIR}/.sync-manifest.json")

  vlog "Checking ${#MANIFEST_FILES[@]} manifest file(s)"

  for manifest_path in "${MANIFEST_FILES[@]}"; do
    rel_manifest="${manifest_path#"${FRAMEWORK_DIR}/"}"

    # Validate JSON first
    if ! python3 -m json.tool "$manifest_path" > /dev/null 2>&1; then
      meets_threshold "high" "$SEVERITY_THRESHOLD" || continue
      fid="$(next_id)"
      finding="$(make_finding \
        "$fid" \
        "framework" \
        "framework-pattern" \
        "high" \
        "guardrails-policy" \
        "documentation-librarian" \
        "[\"$rel_manifest\"]" \
        "Manifest file \`$rel_manifest\` contains invalid JSON. A corrupt manifest may cause framework tools to fail silently or use stale file references." \
        "Repair or regenerate \`$rel_manifest\`. Run scripts/generate-manifest.sh to produce a fresh manifest. Validate with: python3 -m json.tool $rel_manifest" \
        "[\"$rel_manifest is valid JSON\", \"Manifest passes schema validation\", \"Framework tools operate correctly with the refreshed manifest\"]" \
        "[\"stale-manifest\", \"invalid-json\", \"framework\"]" \
        "xs")"
      append_finding "$finding"
      COUNT=$((COUNT + 1))
      continue
    fi

    # Check for missing files and hash mismatches using Python
    RESULT="$(python3 - <<PYEOF 2>/dev/null || echo "0 0 none none"
import json, hashlib
from pathlib import Path

framework_dir = Path("$FRAMEWORK_DIR")
manifest = json.loads(Path("$manifest_path").read_text())
files_section = manifest.get("files", manifest.get("entries", {}))

missing = []
mismatches = []

for src_path, entry in files_section.items():
    if not isinstance(entry, dict):
        continue
    target_str = entry.get("target", src_path)
    candidates = [
        framework_dir / ".claude" / target_str,
        framework_dir / target_str,
    ]
    target_path = next((c for c in candidates if c.exists()), None)

    if target_path is None:
        missing.append(target_str)
        continue

    manifest_hash = entry.get("hash")
    if manifest_hash:
        try:
            actual = hashlib.sha256(target_path.read_bytes()).hexdigest()
            if actual != manifest_hash:
                mismatches.append(str(target_path.relative_to(framework_dir)))
        except Exception:
            pass

missing_sample = ",".join(missing[:3]) or "none"
mismatch_sample = ",".join(mismatches[:3]) or "none"
print(len(missing), len(mismatches), missing_sample, mismatch_sample)
PYEOF
)"

    missing_count="$(echo "$RESULT" | awk '{print $1}')"
    mismatch_count="$(echo "$RESULT" | awk '{print $2}')"
    missing_sample="$(echo "$RESULT" | awk '{print $3}')"
    mismatch_sample="$(echo "$RESULT" | awk '{print $4}')"

    if [[ "${missing_count:-0}" -gt 0 ]] && meets_threshold "high" "$SEVERITY_THRESHOLD"; then
      vlog "Manifest $rel_manifest: $missing_count missing file(s): $missing_sample"
      fid="$(next_id)"
      finding="$(make_finding \
        "$fid" \
        "framework" \
        "framework-pattern" \
        "high" \
        "guardrails-policy" \
        "documentation-librarian" \
        "[\"$rel_manifest\"]" \
        "Stale manifest: \`$rel_manifest\` references $missing_count file(s) that do not exist on disk: $missing_sample. Stale references cause framework sync tools to fail or report false positives." \
        "Regenerate \`$rel_manifest\` using scripts/generate-manifest.sh to remove stale references and reflect the current filesystem state." \
        "[\"All files listed in \`$rel_manifest\` exist on disk\", \"Manifest passes validation with no missing-file errors\", \"Framework sync/install tools complete without errors\"]" \
        "[\"stale-manifest\", \"missing-files\", \"framework\"]" \
        "s")"
      append_finding "$finding"
      COUNT=$((COUNT + 1))
    fi

    if [[ "${mismatch_count:-0}" -gt 0 ]] && meets_threshold "medium" "$SEVERITY_THRESHOLD"; then
      vlog "Manifest $rel_manifest: $mismatch_count hash mismatch(es): $mismatch_sample"
      fid="$(next_id)"
      finding="$(make_finding \
        "$fid" \
        "framework" \
        "framework-pattern" \
        "medium" \
        "guardrails-policy" \
        "documentation-librarian" \
        "[\"$rel_manifest\"]" \
        "Manifest hash mismatches in \`$rel_manifest\`: $mismatch_count file(s) modified since the manifest was generated: $mismatch_sample. The manifest does not reflect current file contents." \
        "Regenerate \`$rel_manifest\` with scripts/generate-manifest.sh after verifying the file changes are intentional. If changes were accidental, restore: git checkout HEAD -- <file>" \
        "[\"All hashes in \`$rel_manifest\` match actual file contents\", \"Manifest generated_at timestamp is recent\", \"No hash mismatch warnings from framework tools\"]" \
        "[\"stale-manifest\", \"hash-mismatch\", \"framework\"]" \
        "xs")"
      append_finding "$finding"
      COUNT=$((COUNT + 1))
    fi
  done

  log "  stale-manifests: $COUNT finding(s)"
fi

# ─── Scan: Hook Efficiency ────────────────────────────────────────────────────

if echo "$CATEGORIES" | grep -qF "hook-efficiency"; then
  log "Scanning hook efficiency..."
  COUNT=0

  if [[ -n "$HOOKS_DIR" ]]; then
    HOOK_FILES=()
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && HOOK_FILES+=("$_line")
    done < <(find "$HOOKS_DIR" -maxdepth 1 \( -name "*.py" -o -name "*.sh" \) 2>/dev/null | sort)
    vlog "Discovered ${#HOOK_FILES[@]} hook(s)"

    # Check for hooks without early-exit conditions
    for hook_file in "${HOOK_FILES[@]}"; do
      hook_name="$(basename "$hook_file")"
      rel_hook="${hook_file#"${FRAMEWORK_DIR}/"}"
      hook_size="$(wc -c < "$hook_file" 2>/dev/null || echo 0)"

      [[ $hook_size -lt 500 ]] && continue
      # Only check Python hooks (shell hooks naturally branch early)
      [[ "$hook_file" != *.py ]] && continue

      # Count conditional statements in first 30 lines
      has_condition="$(head -30 "$hook_file" 2>/dev/null \
        | grep -cE '^\s*(if |elif |for |while |match |case )' || echo 0)"

      if [[ "${has_condition:-0}" -eq 0 ]]; then
        vlog "Potentially unconditional hook: $hook_name"
        meets_threshold "low" "$SEVERITY_THRESHOLD" || continue

        fid="$(next_id)"
        finding="$(make_finding \
          "$fid" \
          "framework" \
          "framework-pattern" \
          "low" \
          "backend-developer" \
          "guardrails-policy" \
          "[\"$rel_hook\"]" \
          "Hook \`$hook_name\` may run without early-exit conditions. Hooks that execute full logic on every trigger add latency to every matching event even when no action is needed. This is inefficient for high-frequency hooks like UserPromptSubmit." \
          "Add an early-exit guard in \`$hook_name\` that checks context before doing heavy processing. Check tool name, file extension, or input content in the first few lines and exit 0 immediately when not relevant." \
          "[\"Hook exits early when the triggering context does not match\", \"Hook only executes full logic for relevant operations\", \"Hook behavior is unchanged for matching contexts\"]" \
          "[\"hook-efficiency\", \"performance\", \"framework\"]" \
          "s")"
        append_finding "$finding"
        COUNT=$((COUNT + 1))
      fi
    done

    # Check for duplicate logic between hooks
    for (( i=0; i<${#HOOK_FILES[@]}; i++ )); do
      h1="${HOOK_FILES[$i]}"
      size1="$(wc -c < "$h1" 2>/dev/null || echo 0)"
      [[ $size1 -lt 100 ]] && continue

      for (( j=i+1; j<${#HOOK_FILES[@]}; j++ )); do
        h2="${HOOK_FILES[$j]}"
        size2="$(wc -c < "$h2" 2>/dev/null || echo 0)"
        [[ $size2 -lt 100 ]] && continue
        [[ $COUNT -ge 5 ]] && break 2

        name1="$(basename "$h1")"
        name2="$(basename "$h2")"

        overlap="$(python3 -c "
import re
def sig(t):
    stop={'this','that','with','from','have','will','should','must','when','exit',
          'print','json','load','read','path','data','return','import','class','def'}
    return {w for w in re.findall(r'[a-zA-Z]{4,}', t.lower()) if w not in stop}
try:
    with open('$h1') as f: t1=f.read(1500)
    with open('$h2') as f: t2=f.read(1500)
    w1,w2=sig(t1),sig(t2)
    if not w1 or not w2: print(0)
    else:
        inter=len(w1&w2); smaller=min(len(w1),len(w2))
        print(int(100*inter/smaller) if smaller>0 else 0)
except: print(0)
" 2>/dev/null || echo "0")"

        if [[ "${overlap:-0}" -ge 60 ]] 2>/dev/null; then
          vlog "Hook logic overlap: $name1 ~ $name2 ($overlap%)"
          meets_threshold "medium" "$SEVERITY_THRESHOLD" || continue

          rel1="${h1#"${FRAMEWORK_DIR}/"}"
          rel2="${h2#"${FRAMEWORK_DIR}/"}"

          fid="$(next_id)"
          finding="$(make_finding \
            "$fid" \
            "framework" \
            "dedup" \
            "medium" \
            "backend-developer" \
            "refactoring-specialist" \
            "[\"$rel1\", \"$rel2\"]" \
            "Duplicate hook logic between \`$name1\` and \`$name2\` (~$overlap% word overlap). Duplicate code means bugs must be fixed in multiple places and behavior can diverge over time." \
            "Extract shared logic from \`$name1\` and \`$name2\` into a shared utility module (e.g., hooks/hook-utils.py or hooks/common.sh). Both hooks then import/source the shared module." \
            "[\"Shared logic exists in exactly one location\", \"Both hooks produce identical outputs for identical inputs\", \"No copy-paste code between hook implementations\"]" \
            "[\"hook-efficiency\", \"duplicate-logic\", \"framework\"]" \
            "m")"
          append_finding "$finding"
          COUNT=$((COUNT + 1))
        fi
      done
    done
  fi

  log "  hook-efficiency: $COUNT finding(s)"
fi

# ─── Scan: Deprecated Aliases ─────────────────────────────────────────────────

if echo "$CATEGORIES" | grep -qF "deprecated-aliases"; then
  log "Scanning deprecated aliases..."
  COUNT=0

  if [[ -n "$COMMANDS_DIR" ]]; then
    SKILL_FILES=()
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && SKILL_FILES+=("$_line")
    done < <(find "$COMMANDS_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | sort)
    vlog "Checking ${#SKILL_FILES[@]} skills for deprecated aliases"

    # Build existing skill name set
    EXISTING_NAMES=()
    for f in "${SKILL_FILES[@]}"; do
      EXISTING_NAMES+=("$(basename "$f" .md)")
    done

    for skill_file in "${SKILL_FILES[@]}"; do
      skill_name="$(basename "$skill_file" .md)"
      rel_path="${skill_file#"${FRAMEWORK_DIR}/"}"
      content="$(cat "$skill_file" 2>/dev/null || echo "")"

      # Look for deprecated markers (distinct from skill-overlap scan to avoid double-reporting)
      if echo "$content" | grep -qiE '(deprecated|LEGACY|use .* instead|alias for|renamed to)'; then
        vlog "Deprecated marker in: $skill_name"
        meets_threshold "medium" "$SEVERITY_THRESHOLD" || continue

        # Determine redirect target if any
        redirect_target="$(echo "$content" | grep -ioE 'use [`"]?([a-z][a-z0-9-]+)[`"]? instead' \
          | grep -oE '[a-z][a-z0-9-]+' | head -1 || true)"

        if [[ -n "$redirect_target" ]]; then
          # Check if redirect target exists
          target_exists=false
          for existing in "${EXISTING_NAMES[@]}"; do
            [[ "$existing" == "$redirect_target" ]] && target_exists=true && break
          done

          severity="medium"
          $target_exists || severity="high"

          desc_extra=""
          fix_extra=""
          [[ -n "$redirect_target" ]] && desc_extra="and redirects to \`$redirect_target\` "
          [[ "$target_exists" == false && -n "$redirect_target" ]] && desc_extra="${desc_extra}(which does not exist) "

          fid="$(next_id)"
          finding="$(make_finding \
            "$fid" \
            "framework" \
            "dead-code" \
            "$severity" \
            "documentation-librarian" \
            "refactoring-specialist" \
            "[\"$rel_path\"]" \
            "Deprecated skill alias: \`$skill_name\` is marked as deprecated ${desc_extra}but is still active. Deprecated skills accumulate technical debt and confuse users." \
            "Remove \`$skill_name\` if no longer needed. Ensure any replacement skill exists and handles all use cases. Update documentation and any callers of this skill." \
            "[\"Skill \`$skill_name\` is removed or its status is resolved\", \"No active workflows reference this deprecated skill\", \"Replacement skill (if any) handles all previous use cases\"]" \
            "[\"deprecated-alias\", \"dead-code\", \"framework\"]" \
            "s")"
          append_finding "$finding"
          COUNT=$((COUNT + 1))
        fi
      fi

      # Check for broken /skill-name references
      BROKEN_REFS=()
      while IFS= read -r _ref; do
        [[ -n "$_ref" ]] && BROKEN_REFS+=("$_ref")
      done < <(
        echo "$content" \
        | grep -oE '/[a-z][a-z0-9-]+' \
        | sed 's|/||' \
        | grep '-' \
        | grep -v -E '^(usr|bin|etc|var|tmp|opt|home|claude|dev|proc|sys|github|workspace)$' \
        | sort -u \
        | while IFS= read -r ref; do
            found=false
            for existing in "${EXISTING_NAMES[@]}"; do
              [[ "$existing" == "$ref" ]] && found=true && break
            done
            $found || echo "$ref"
          done 2>/dev/null || true
      )

      if [[ ${#BROKEN_REFS[@]} -gt 0 ]]; then
        ref_list="$(IFS=', '; echo "${BROKEN_REFS[*]:0:5}")"
        ref_count="${#BROKEN_REFS[@]}"
        vlog "Broken refs in $skill_name: $ref_list"
        meets_threshold "medium" "$SEVERITY_THRESHOLD" || continue

        fid="$(next_id)"
        finding="$(make_finding \
          "$fid" \
          "framework" \
          "dead-code" \
          "medium" \
          "documentation-librarian" \
          "refactoring-specialist" \
          "[\"$rel_path\"]" \
          "Broken skill references in \`$skill_name\`: $ref_count reference(s) to non-existent skills: $ref_list. References to renamed or removed skills cause user confusion and may silently fail." \
          "In \`$skill_name\`, update references ($ref_list) to current skill names. Search for all occurrences with: grep -rE '/$ref' .claude/commands/" \
          "[\"All skill references in \`$skill_name\` resolve to existing skills\", \"No broken /skill-name references remain in the file\", \"Skill invocations succeed without skill-not-found errors\"]" \
          "[\"deprecated-alias\", \"broken-reference\", \"framework\"]" \
          "s")"
        append_finding "$finding"
        COUNT=$((COUNT + 1))
      fi
    done
  fi

  log "  deprecated-aliases: $COUNT finding(s)"
fi

# ─── Finalize output ──────────────────────────────────────────────────────────

# Re-index finding IDs and write output
python3 - <<PYEOF
import json
from pathlib import Path

findings = json.load(open("$FINDINGS_TMPFILE"))

# Re-index sequentially
for i, f in enumerate(findings):
    f['id'] = f'RF-{i+1:03d}'

output_file = Path("$OUTPUT_FILE")
output_file.parent.mkdir(parents=True, exist_ok=True)
output_file.write_text(json.dumps(findings, indent=2) + '\n')
PYEOF

log "Findings written to: ${OUTPUT_FILE}"

# Print summary
python3 - <<PYEOF >&2
import json, sys
from collections import defaultdict

findings = json.load(open("$OUTPUT_FILE"))
total = len(findings)
by_sev = defaultdict(int)
by_cat = defaultdict(int)
for f in findings:
    by_sev[f['severity']] += 1
    by_cat[f['category']] += 1

print('')
print('┌─────────────────────────────────────────────┐')
print('│       Framework Scan Summary                │')
print('├─────────────────────────────────────────────┤')
print(f'│  Total findings:  {total:<26}│')
print(f'│  🔴 Critical:     {by_sev["critical"]:<26}│')
print(f'│  🟠 High:         {by_sev["high"]:<26}│')
print(f'│  🟡 Medium:       {by_sev["medium"]:<26}│')
print(f'│  🟢 Low:          {by_sev["low"]:<26}│')
print('├─────────────────────────────────────────────┤')
print('│  By category:                               │')
for cat, count in sorted(by_cat.items()):
    print(f'│    {cat:<20} {count:<22}│')
print('└─────────────────────────────────────────────┘')
PYEOF

# Exit code based on severity
python3 -c "
import json, sys
findings = json.load(open('$OUTPUT_FILE'))
critical = sum(1 for f in findings if f['severity'] == 'critical')
high = sum(1 for f in findings if f['severity'] == 'high')
if critical > 0 or high > 0:
    sys.exit(2)
elif findings:
    sys.exit(1)
else:
    sys.exit(0)
"
