#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG="$PROJECT_DIR/scripts/watchdog.sh"
TMP_DIR="$(mktemp -d -t v2quantum-watchdog-test.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2quantum-watchdog-test.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/config" "$TMP_DIR/run"
printf '{}\n' >"$TMP_DIR/config/outside.json"

run_watchdog() {
  local bin="$1"
  env \
    V2QUANTUM_BIN="$bin" \
    V2QUANTUM_CONFIG_DIR="$TMP_DIR/config" \
    V2QUANTUM_SYSTEMCTL=/usr/bin/true \
    V2QUANTUM_LOGGER=/usr/bin/true \
    V2QUANTUM_RUN_DIR="$TMP_DIR/run" \
    "$WATCHDOG" outside
}

run_watchdog /usr/bin/false
test "$(cat "$TMP_DIR/run/v2quantum-watchdog-outside.failures")" = 1
run_watchdog /usr/bin/false
test "$(cat "$TMP_DIR/run/v2quantum-watchdog-outside.failures")" = 2
run_watchdog /usr/bin/false
test "$(cat "$TMP_DIR/run/v2quantum-watchdog-outside.failures")" = 0
run_watchdog /usr/bin/true
test "$(cat "$TMP_DIR/run/v2quantum-watchdog-outside.failures")" = 0

echo "watchdog smoke tests passed"
