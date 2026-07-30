#!/bin/zsh
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
bundle="${1:-$root_dir/dist/Operator.app}"
executable="$bundle/Contents/MacOS/Operator"
plist="$bundle/Contents/Info.plist"
icon="$bundle/Contents/Resources/Operator.icns"

if [[ ! -x "$executable" || ! -r "$plist" || ! -r "$icon" ]]; then
  print -u2 "Incomplete Operator bundle: $bundle"
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$bundle"
signature_details=$(/usr/bin/codesign -dv --verbose=4 "$bundle" 2>&1)
if [[ "$signature_details" != *"runtime"* ]]; then
  print -u2 "Packaged app is missing Hardened Runtime"
  exit 1
fi

/usr/bin/plutil -lint "$plist" >/dev/null
smoke_root=$(mktemp -d /private/tmp/operator-app-smoke.XXXXXX)
if [[ "${OPERATOR_KEEP_SMOKE_ARTIFACTS:-0}" == "1" ]]; then
  trap 'print "Preserved smoke artifacts: $smoke_root"' EXIT
else
  trap 'rm -rf "$smoke_root"' EXIT
fi

OPERATOR_STATE_PATH="$smoke_root/state.json" \
OPERATOR_LOG_PATH="$smoke_root/operator.jsonl" \
OPERATOR_SMOKE_REPORT="$smoke_root/report.json" \
  "$executable" --ui-testing --app-smoke-test

if [[ "$(/usr/bin/plutil -extract passed raw -o - "$smoke_root/report.json")" != "true" ]]; then
  print -u2 "Packaged app smoke report failed"
  /bin/cat "$smoke_root/report.json"
  exit 1
fi

/usr/bin/plutil -convert json -o /dev/null "$smoke_root/report.json"
state_valid=false
for _ in {1..20}; do
  if /usr/bin/plutil -convert json -o /dev/null "$smoke_root/state.json" 2>/dev/null; then
    state_valid=true
    break
  fi
  /bin/sleep 0.1
done
if [[ "$state_valid" != "true" ]]; then
  print -u2 "Packaged app did not leave a readable valid state file"
  exit 1
fi
print "Packaged app smoke test passed: $bundle"

exception_root=$(mktemp -d /private/tmp/operator-notification-exception-smoke.XXXXXX)
if [[ "${OPERATOR_KEEP_SMOKE_ARTIFACTS:-0}" == "1" ]]; then
  trap 'print "Preserved smoke artifacts: $smoke_root $exception_root"' EXIT
else
  trap 'rm -rf "$smoke_root" "$exception_root"' EXIT
fi

OPERATOR_TEST_NOTIFICATION_EXCEPTION=1 \
OPERATOR_STATE_PATH="$exception_root/state.json" \
OPERATOR_LOG_PATH="$exception_root/operator.jsonl" \
OPERATOR_SMOKE_REPORT="$exception_root/report.json" \
  "$executable" --ui-testing --app-smoke-test

if [[ "$(/usr/bin/plutil -extract passed raw -o - "$exception_root/report.json")" != "true" ]]; then
  print -u2 "Operator did not survive unavailable notification infrastructure"
  /bin/cat "$exception_root/report.json"
  exit 1
fi

if /usr/bin/grep -q '"category":"notifications.unavailable"' \
  "$exception_root/operator.jsonl"; then
  print -u2 "Operator touched notification infrastructure during default-off startup"
  exit 1
fi

print "Notification-disabled launch test passed without notification-center access: $bundle"
