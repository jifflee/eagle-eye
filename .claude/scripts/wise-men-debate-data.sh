#!/bin/bash
set -euo pipefail
# wise-men-debate-data.sh
# Gathers issue data for Four Wise Men decision framework
set -e

MODE="${1:-}"

if [[ "$MODE" == "--backlog" ]]; then
  gh issue list --label "backlog" --json number,title,labels,milestone --limit 10 | jq '{
    mode: "backlog",
    issues: [.[] | {number, title, labels: [.labels[].name], milestone: .milestone.title}]
  }'
  exit 0
fi

ISSUE_NUMBER="$MODE"
if [[ -z "$ISSUE_NUMBER" ]]; then
  echo '{"error":"Usage: wise-men-debate-data.sh <issue_number> | --backlog"}' >&2
  exit 1
fi

gh issue view "$ISSUE_NUMBER" --json number,title,body,labels,milestone,createdAt | jq '{
  mode: "single",
  issue: {
    number,
    title,
    labels: [.labels[].name],
    milestone: .milestone.title,
    body_length: (.body | length)
  }
}'
