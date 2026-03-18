#!/usr/bin/env bash
# parse-dependencies.sh - Parse skill dependencies from contract/frontmatter
# Part of the skill composition framework (#224)
#
# Usage:
#   ./scripts/composition/parse-dependencies.sh <skill-name>
#   ./scripts/composition/parse-dependencies.sh --file <contract-file>
#   ./scripts/composition/parse-dependencies.sh --validate <skill-name>
#
# Output: JSON dependency graph or validation result

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTRACTS_DIR="$REPO_ROOT/contracts/skills"
TIER_REGISTRY="$REPO_ROOT/.claude/tier-registry.json"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <skill-name>

Parse skill dependencies and build dependency graph.

Options:
  --file <path>       Parse specific contract file
  --validate          Validate dependencies (check circular, missing refs)
  --graph             Output DOT format for graphviz visualization
  --tiers             Show tier analysis only
  --json              Output as JSON (default)
  -h, --help          Show this help message

Examples:
  $(basename "$0") sprint-work
  $(basename "$0") --validate sprint-work
  $(basename "$0") --file contracts/skills/sprint-work.contract.yaml
  $(basename "$0") --graph sprint-work | dot -Tpng -o graph.png
EOF
}

# Find contract file for a skill
find_contract() {
    local skill_name="$1"
    local contract_file="$CONTRACTS_DIR/${skill_name}.contract.yaml"

    if [[ -f "$contract_file" ]]; then
        echo "$contract_file"
        return 0
    fi

    return 1
}

# Python-based YAML to JSON parser (more portable than yq)
yaml_to_json() {
    python3 -c "
import sys
import json
import yaml

try:
    data = yaml.safe_load(sys.stdin)
    print(json.dumps(data, indent=2))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
    sys.exit(1)
"
}

# Parse dependencies from contract YAML
parse_dependencies() {
    local contract_file="$1"

    if [[ ! -f "$contract_file" ]]; then
        echo '{"error": "Contract file not found", "file": "'"$contract_file"'"}'
        return 1
    fi

    # Convert YAML to JSON and process
    cat "$contract_file" | yaml_to_json | jq --arg file "$contract_file" '
        # Get skill name
        .skill as $skill |

        # Get dependencies array (default to empty)
        (.dependencies // []) as $deps |

        # Calculate tier number from string
        def tier_num: ltrimstr("T") | tonumber;

        # Calculate effective tier (max of all dependency tiers)
        (if ($deps | length) > 0 then
            $deps | map(.tier // "T0" | tier_num) | max
        else 0 end) as $max_tier |

        # Build dependency graph
        {
            skill: ($skill // "unknown"),
            contract_file: $file,
            dependencies: $deps | map({
                name: .name,
                type: .type,
                required: (.required // true),
                tier: (.tier // "T0"),
                inputs: (.inputs // {}),
                output_as: (.output_as // .name),
                when: .when,
                retry: .retry
            }),
            dependency_count: ($deps | length),
            effective_tier: ("T" + ($max_tier | tostring)),
            execution_order: ($deps | map(.output_as // .name)),
            has_circular: false
        }
    '
}

# Validate dependency graph for issues
validate_dependencies() {
    local contract_file="$1"

    if [[ ! -f "$contract_file" ]]; then
        echo '{"error": "Contract file not found", "file": "'"$contract_file"'"}'
        return 1
    fi

    # Parse and validate
    cat "$contract_file" | yaml_to_json | jq --arg file "$contract_file" '
        .skill as $skill |
        (.dependencies // []) as $deps |

        # Collect validation issues
        (
            # Check 1: Self-reference
            (if ($deps | map(select(.name == $skill)) | length) > 0 then
                ["Circular dependency: skill depends on itself"]
            else [] end) +

            # Check 2: Invalid forward references
            ($deps | to_entries | map(
                .key as $idx |
                ($deps[0:$idx] | map(.output_as // .name)) as $prior_outputs |
                .value.inputs // {} | to_entries | map(
                    select(.value.from != null) |
                    .value.from | split(".")[0] as $ref_name |
                    if ($prior_outputs | index($ref_name)) == null and $ref_name != "input" then
                        "Dependency \(.value.name // $idx) references unknown output: \($ref_name)"
                    else empty end
                )
            ) | flatten)
        ) as $issues |

        # Collect warnings
        (
            # High-tier dependencies
            (if ($deps | map(select(.tier == "T3")) | length) > 0 then
                ["High-tier (T3) dependencies require individual prompts: " +
                 ($deps | map(select(.tier == "T3")) | map(.name) | join(", "))]
            else [] end)
        ) as $warnings |

        # Calculate effective tier
        def tier_num: ltrimstr("T") | tonumber;
        (if ($deps | length) > 0 then
            $deps | map(.tier // "T0" | tier_num) | max
        else 0 end) as $max_tier |

        {
            valid: (($issues | length) == 0),
            skill: ($skill // "unknown"),
            contract_file: $file,
            issues: $issues,
            warnings: $warnings,
            dependency_graph: {
                skill: ($skill // "unknown"),
                dependencies: $deps | map({
                    name: .name,
                    type: .type,
                    required: (.required // true),
                    tier: (.tier // "T0"),
                    inputs: (.inputs // {}),
                    output_as: (.output_as // .name)
                }),
                dependency_count: ($deps | length),
                effective_tier: ("T" + ($max_tier | tostring)),
                execution_order: ($deps | map(.output_as // .name))
            }
        }
    '
}

# Output dependency graph in DOT format for visualization
output_dot_graph() {
    local contract_file="$1"
    local parsed
    parsed=$(parse_dependencies "$contract_file")

    local skill_name
    skill_name=$(echo "$parsed" | jq -r '.skill')

    cat <<EOF
digraph dependencies {
  rankdir=LR;
  node [shape=box];

  // Skill node
  "$skill_name" [style=filled, fillcolor=lightblue, label="$skill_name\\n(composed)"];

EOF

    # Add dependency nodes and edges
    echo "$parsed" | jq -r '
        .dependencies | to_entries | map(
            .value as $dep |
            .key as $idx |

            # Node definition
            "  \"" + $dep.name + "\" [" +
            (if $dep.type == "primitive" then "shape=ellipse" else "shape=box" end) +
            ", label=\"" + $dep.name + "\\n(" + $dep.tier + ")\"];"
        ) | .[]
    '

    echo ""

    # Add execution flow edges
    echo "$parsed" | jq -r --arg skill "$skill_name" '
        .dependencies | to_entries | map(
            .value as $dep |
            .key as $idx |
            if $idx == 0 then
                "  start -> \"" + $dep.name + "\";"
            else
                "  \"" + .[$idx - 1].value.name + "\" -> \"" + $dep.name + "\";"
            end
        ) | .[],
        ("  \"" + (.dependencies | last | .name) + "\" -> \"" + $skill + "\";")
    '

    cat <<EOF

  start [shape=circle, label="", width=0.2, style=filled, fillcolor=black];
}
EOF
}

# Show tier analysis
show_tier_analysis() {
    local contract_file="$1"
    local parsed
    parsed=$(parse_dependencies "$contract_file")

    echo "$parsed" | jq -r '
        "Skill: " + .skill,
        "Effective Tier: " + .effective_tier,
        "Dependency Count: " + (.dependency_count | tostring),
        "",
        "Dependencies by Tier:",
        (
            .dependencies | group_by(.tier) | sort_by(.[0].tier) | map(
                "  " + .[0].tier + ": " + (map(.name) | join(", "))
            ) | if length == 0 then ["  (none)"] else . end | .[]
        ),
        "",
        "Execution Batching:",
        "  Auto (T0/T1): " + ([.dependencies[] | select(.tier == "T0" or .tier == "T1")] | map(.name) | if length == 0 then "(none)" else join(", ") end),
        "  Prompt Once (T2): " + ([.dependencies[] | select(.tier == "T2")] | map(.name) | if length == 0 then "(none)" else join(", ") end),
        "  Prompt Each (T3): " + ([.dependencies[] | select(.tier == "T3")] | map(.name) | if length == 0 then "(none)" else join(", ") end)
    '
}

# Main
main() {
    local mode="json"
    local skill_name=""
    local contract_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)
                contract_file="$2"
                shift 2
                ;;
            --validate)
                mode="validate"
                shift
                ;;
            --graph)
                mode="graph"
                shift
                ;;
            --tiers)
                mode="tiers"
                shift
                ;;
            --json)
                mode="json"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
            *)
                skill_name="$1"
                shift
                ;;
        esac
    done

    # Resolve contract file
    if [[ -z "$contract_file" ]]; then
        if [[ -z "$skill_name" ]]; then
            echo "Error: Must specify skill name or --file" >&2
            usage >&2
            exit 1
        fi

        contract_file=$(find_contract "$skill_name") || true
        if [[ -z "$contract_file" ]]; then
            echo '{"error": "Contract not found for skill", "skill": "'"$skill_name"'"}'
            exit 1
        fi
    fi

    case "$mode" in
        json)
            parse_dependencies "$contract_file"
            ;;
        validate)
            validate_dependencies "$contract_file"
            ;;
        graph)
            output_dot_graph "$contract_file"
            ;;
        tiers)
            show_tier_analysis "$contract_file"
            ;;
    esac
}

main "$@"
