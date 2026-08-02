#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-$PROJECT_DIR/bin/v2quantum}"
MANAGER="$PROJECT_DIR/scripts/manager.sh"
TMP_DIR="$(mktemp -d -t v2quantum-manager-test.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2quantum-manager-test.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

run_manager() {
  local config_dir="$1" input="$2" output_file="${3:-/dev/null}" systemctl="${4:-/usr/bin/true}"
  local state_dir="$config_dir/state"
  printf '%s' "$input" | env \
    V2QUANTUM_BIN="$BIN" \
    V2QUANTUM_CONFIG_DIR="$config_dir" \
    V2QUANTUM_STATE_DIR="$state_dir" \
    V2QUANTUM_SYSTEMCTL="$systemctl" \
    V2QUANTUM_JOURNALCTL=/usr/bin/true \
    V2QUANTUM_SS=/usr/bin/false \
    "$MANAGER" >"$output_file"
}

SERVER_DIR="$TMP_DIR/server"
SERVER_OUTPUT="$TMP_DIR/server-output.txt"
run_manager "$SERVER_DIR" $'1\n2\n2\n\n\n\n0\n' "$SERVER_OUTPUT"
test -s "$SERVER_DIR/iran.json"
test -s "$SERVER_DIR/iran.env"
set -a
# shellcheck disable=SC1090
source "$SERVER_DIR/iran.env"
set +a
"$BIN" check -config "$SERVER_DIR/iran.json" >/dev/null

TOKEN="$V2QUANTUM_PSK"
SETUP_CODE="$(grep '^V2Q1_' "$SERVER_OUTPUT")"
test -n "$SETUP_CODE"
CLIENT_DIR="$TMP_DIR/client"
run_manager "$CLIENT_DIR" $'2\n'"$SETUP_CODE"$'\n\n0\n'
set -a
# shellcheck disable=SC1090
source "$CLIENT_DIR/outside.env"
set +a
"$BIN" check -config "$CLIENT_DIR/outside.json" >/dev/null

MULTI_SERVER_DIR="$TMP_DIR/multi-server"
MULTI_SERVER_OUTPUT="$TMP_DIR/multi-server-output.txt"
run_manager "$MULTI_SERVER_DIR" $'1\n2\n2\n25001,25002\n\n\n0\n' "$MULTI_SERVER_OUTPUT"
MULTI_CODE="$(grep '^V2Q1_' "$MULTI_SERVER_OUTPUT")"
test -n "$MULTI_CODE"
grep -q '"name": "map-2"' "$MULTI_SERVER_DIR/iran.json"
MULTI_CLIENT_DIR="$TMP_DIR/multi-client"
run_manager "$MULTI_CLIENT_DIR" $'2\n'"$MULTI_CODE"$'\n127.0.0.1:26001,127.0.0.1:26002\n0\n'
grep -q '"name": "map-2"' "$MULTI_CLIENT_DIR/outside.json"
set -a
# shellcheck disable=SC1090
source "$MULTI_CLIENT_DIR/outside.env"
set +a
"$BIN" check -config "$MULTI_CLIENT_DIR/outside.json" >/dev/null

RAW_DIR="$TMP_DIR/raw"
run_manager "$RAW_DIR" $'1\n3\n2\n\n\n\n\n\n\n\n\n\n0\n'
set -a
# shellcheck disable=SC1090
source "$RAW_DIR/iran.env"
set +a
"$BIN" check -config "$RAW_DIR/iran.json" >/dev/null
grep -q '"mode": "raw_icmp"' "$RAW_DIR/iran.json"

# A failed first start must not leave an enabled, half-configured instance.
FAIL_SYSTEMCTL="$TMP_DIR/systemctl-fail"
FAIL_LOG="$TMP_DIR/systemctl-fail.log"
cat >"$FAIL_SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${V2Q_TEST_SYSTEMCTL_LOG:?}"
case "${1:-}" in
  restart|is-active) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod 755 "$FAIL_SYSTEMCTL"
FAILED_DIR="$TMP_DIR/failed-new"
if V2Q_TEST_SYSTEMCTL_LOG="$FAIL_LOG" \
  run_manager "$FAILED_DIR" $'1\n2\n2\n25111\n8891\n198.51.100.10\n' /dev/null "$FAIL_SYSTEMCTL"; then
  echo "manager unexpectedly accepted a failed service start" >&2
  exit 1
fi
test ! -e "$FAILED_DIR/iran.json"
test ! -e "$FAILED_DIR/iran.env"
grep -q '^disable --now v2quantum@iran.service$' "$FAIL_LOG"

# Reconfiguration failure must restore the previous working files.
ROLLBACK_DIR="$TMP_DIR/rollback"
run_manager "$ROLLBACK_DIR" $'1\n2\n2\n25121\n8892\n198.51.100.11\n0\n'
cp "$ROLLBACK_DIR/iran.json" "$TMP_DIR/original-iran.json"
cp "$ROLLBACK_DIR/iran.env" "$TMP_DIR/original-iran.env"
: >"$FAIL_LOG"
if V2Q_TEST_SYSTEMCTL_LOG="$FAIL_LOG" \
  run_manager "$ROLLBACK_DIR" $'1\n2\n2\n25122\n8893\n198.51.100.12\n' /dev/null "$FAIL_SYSTEMCTL"; then
  echo "manager unexpectedly accepted a failed reconfiguration" >&2
  exit 1
fi
cmp "$TMP_DIR/original-iran.json" "$ROLLBACK_DIR/iran.json"
cmp "$TMP_DIR/original-iran.env" "$ROLLBACK_DIR/iran.env"

# Lowercase y is sufficient for removal; YES is not required.
run_manager "$SERVER_DIR" $'9\niran\ny\n0\n'
test ! -e "$SERVER_DIR/iran.json"
test ! -e "$SERVER_DIR/iran.env"

echo "manager smoke tests passed"
