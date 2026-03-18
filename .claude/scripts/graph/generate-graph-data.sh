#!/usr/bin/env bash
# size-ok: graph data generator reads manifests and builds node+edge JSON; inline logic is intentional
# generate-graph-data.sh
# Reads all agent manifests and produces a graph data JSON file for Neo4j-style visualization.
#
# Usage:
#   ./scripts/graph/generate-graph-data.sh [--output FILE] [--help]
#
# Output:
#   JSON with { nodes: [...], edges: [...] } suitable for D3.js / Cytoscape.js rendering.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFESTS_DIR="${REPO_ROOT}/manifests"
OUTPUT_FILE="${REPO_ROOT}/scripts/graph/graph-data.json"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--output FILE]"
      echo ""
      echo "Reads agent manifests from manifests/ and emits graph-data.json."
      echo ""
      echo "Options:"
      echo "  --output FILE  Path to write the JSON output (default: scripts/graph/graph-data.json)"
      echo "  --help         Show this help"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Collect nodes from manifests
# ---------------------------------------------------------------------------
echo "Reading manifests from: ${MANIFESTS_DIR}" >&2

nodes_json="[]"

for manifest in "${MANIFESTS_DIR}"/*.json; do
  [[ -f "$manifest" ]] || continue

  name=$(jq -r '.name // empty' "$manifest" 2>/dev/null) || continue
  [[ -z "$name" ]] && continue

  # Skip non-agent manifests (ones without trust_tier)
  trust_tier=$(jq -r '.trust_tier // empty' "$manifest" 2>/dev/null)
  [[ -z "$trust_tier" ]] && continue

  display_name=$(jq -r '.display_name // .name' "$manifest")
  description=$(jq -r '.description // ""' "$manifest")
  model=$(jq -r '.model // "haiku"' "$manifest")
  permission_level=$(jq -r '.permission_level // "READ-ONLY"' "$manifest")
  sdlc_phase=$(jq -r '.metadata.sdlc_phase // "governance"' "$manifest")
  agent_category=$(jq -r '.metadata.agent_category // "governance"' "$manifest")
  domains=$(jq -c '.capabilities.domains // []' "$manifest")

  node=$(jq -n \
    --arg id "$name" \
    --arg label "$display_name" \
    --arg description "$description" \
    --arg model "$model" \
    --arg trust_tier "$trust_tier" \
    --arg permission_level "$permission_level" \
    --arg sdlc_phase "$sdlc_phase" \
    --arg agent_category "$agent_category" \
    --argjson domains "$domains" \
    '{
      id: $id,
      label: $label,
      description: $description,
      model: $model,
      trust_tier: $trust_tier,
      permission_level: $permission_level,
      sdlc_phase: $sdlc_phase,
      agent_category: $agent_category,
      domains: $domains
    }')

  nodes_json=$(echo "$nodes_json" | jq --argjson node "$node" '. + [$node]')
done

# ---------------------------------------------------------------------------
# Build edges (relationships between agents)
# Relationship types:
#   - DELEGATES_TO:   PM/orchestrators delegate work to specialist agents
#   - REVIEWS:        Review agents review output of implementation agents
#   - REQUIRED_BY:    requires_review_from constraint in manifest
#   - PRECEDES:       SDLC phase sequencing
# ---------------------------------------------------------------------------

edges_json="[]"

add_edge() {
  local source="$1"
  local target="$2"
  local rel_type="$3"
  local label="${4:-}"

  # Only add edge if both nodes exist
  source_exists=$(echo "$nodes_json" | jq --arg id "$source" 'any(.[]; .id == $id)')
  target_exists=$(echo "$nodes_json" | jq --arg id "$target" 'any(.[]; .id == $id)')

  if [[ "$source_exists" == "true" && "$target_exists" == "true" ]]; then
    edge=$(jq -n \
      --arg source "$source" \
      --arg target "$target" \
      --arg type "$rel_type" \
      --arg label "${label:-$rel_type}" \
      '{ source: $source, target: $target, type: $type, label: $label }')
    edges_json=$(echo "$edges_json" | jq --argjson edge "$edge" '. + [$edge]')
  fi
}

# PM Orchestrator delegates to all planning and design agents
add_edge "pm-orchestrator" "product-spec-ux"      "DELEGATES_TO" "delegates to"
add_edge "pm-orchestrator" "architect"             "DELEGATES_TO" "delegates to"
add_edge "pm-orchestrator" "security-iam-design"   "DELEGATES_TO" "delegates to"
add_edge "pm-orchestrator" "data-storage"          "DELEGATES_TO" "delegates to"
add_edge "pm-orchestrator" "backend-developer"     "DELEGATES_TO" "delegates to"
add_edge "pm-orchestrator" "frontend-developer"    "DELEGATES_TO" "delegates to"
add_edge "pm-orchestrator" "test-qa"               "DELEGATES_TO" "delegates to"
add_edge "pm-orchestrator" "documentation"         "DELEGATES_TO" "delegates to"
add_edge "pm-orchestrator" "deployment"            "DELEGATES_TO" "delegates to"

# Design agents feed into implementation agents (SDLC sequencing)
add_edge "product-spec-ux"      "architect"            "PRECEDES" "informs"
add_edge "architect"            "backend-developer"    "PRECEDES" "guides"
add_edge "architect"            "frontend-developer"   "PRECEDES" "guides"
add_edge "security-iam-design"  "backend-developer"    "PRECEDES" "constrains"
add_edge "security-iam-design"  "frontend-developer"   "PRECEDES" "constrains"
add_edge "data-storage"         "backend-developer"    "PRECEDES" "schema for"

# Implementation → QA/review
add_edge "backend-developer"   "test-qa"          "PRECEDES" "tested by"
add_edge "frontend-developer"  "test-qa"          "PRECEDES" "tested by"
add_edge "backend-developer"   "code-reviewer"    "PRECEDES" "reviewed by"
add_edge "frontend-developer"  "code-reviewer"    "PRECEDES" "reviewed by"

# Pre-PR agents → PR review agents
add_edge "test-qa"             "pr-test"              "PRECEDES"  "validates"
add_edge "security-iam-prepr"  "pr-security-iam"      "PRECEDES"  "validates"
add_edge "documentation"       "pr-documentation"     "PRECEDES"  "validates"
add_edge "code-reviewer"       "pr-code-reviewer"     "PRECEDES"  "escalates to"

# Pre-PR → deployment
add_edge "pr-code-reviewer"    "deployment"           "PRECEDES"  "approved for"
add_edge "pr-security-iam"     "deployment"           "PRECEDES"  "cleared for"

# Governance agents
add_edge "guardrails-policy"   "backend-developer"    "REVIEWS"   "enforces on"
add_edge "guardrails-policy"   "frontend-developer"   "REVIEWS"   "enforces on"
add_edge "performance-engineering" "backend-developer" "REVIEWS"  "benchmarks"

# requires_review_from edges from manifests
for manifest in "${MANIFESTS_DIR}"/*.json; do
  [[ -f "$manifest" ]] || continue
  name=$(jq -r '.name // empty' "$manifest" 2>/dev/null) || continue
  [[ -z "$name" ]] && continue

  # Read requires_review_from array
  reviewers=$(jq -r '.constraints.requires_review_from // [] | .[]' "$manifest" 2>/dev/null) || true
  while IFS= read -r reviewer; do
    [[ -z "$reviewer" ]] && continue
    add_edge "$reviewer" "$name" "REQUIRED_BY" "must review"
  done <<< "$reviewers"
done

# Milestone manager → governance
add_edge "milestone-manager"   "pm-orchestrator"      "DELEGATES_TO" "reports to"
add_edge "repo-workflow"       "pm-orchestrator"      "DELEGATES_TO" "reports to"

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
node_count=$(echo "$nodes_json" | jq 'length')
edge_count=$(echo "$edges_json" | jq 'length')

output=$(jq -n \
  --argjson nodes "$nodes_json" \
  --argjson edges "$edges_json" \
  '{
    meta: {
      generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      node_count: ($nodes | length),
      edge_count: ($edges | length)
    },
    nodes: $nodes,
    edges: $edges
  }')

echo "$output" > "$OUTPUT_FILE"

echo "Graph data written to: ${OUTPUT_FILE}" >&2
echo "  Nodes: ${node_count}" >&2
echo "  Edges: ${edge_count}" >&2
echo "$output"
