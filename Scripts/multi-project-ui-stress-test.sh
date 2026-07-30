#!/bin/zsh
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
bundle="${1:-$root_dir/dist/Operator.app}"
executable="$bundle/Contents/MacOS/Operator"

if [[ ! -x "$executable" ]]; then
  print -u2 "Missing packaged Operator executable at $executable"
  exit 1
fi

scenario_root=$(mktemp -d /private/tmp/operator-multi-project-ui.XXXXXX)
project_root="$scenario_root/projects"
artifact_root="$scenario_root/artifacts"
state_path="$scenario_root/state.json"
log_path="$scenario_root/operator.jsonl"
report_path="$scenario_root/report.json"
mkdir -p "$project_root" "$artifact_root"

OPERATOR_STATE_PATH="$state_path" \
  OPERATOR_LOG_PATH="$log_path" \
  OPERATOR_MULTI_PROJECT_ROOT="$project_root" \
  OPERATOR_MULTI_PROJECT_ARTIFACT_DIR="$artifact_root" \
  OPERATOR_MULTI_PROJECT_REPORT="$report_path" \
  "$executable" --ui-testing --multi-project-ui-stress-test &
app_pid=$!

for _ in {1..300}; do
  if [[ -f "$report_path" ]]; then
    break
  fi
  if ! kill -0 "$app_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

wait "$app_pid"

if [[ ! -f "$report_path" ]]; then
  print -u2 "Operator exited without writing $report_path"
  exit 1
fi

jq -e '.passed == true' "$report_path" >/dev/null
print "Five-project UI stress test passed"
print "Scenario: $scenario_root"
print "Report: $report_path"
print "Screenshot: $artifact_root/five-projects-split-pane.png"
