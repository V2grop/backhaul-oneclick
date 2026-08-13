#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo env PATH="$PATH" bash "$0" "$@"
  fi
  echo "manager integration test skipped: root or sudo is required"
  exit 0
fi

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-$PROJECT_DIR/bin/v2quantum}"
MANAGER="$PROJECT_DIR/scripts/manager.sh"
TMP_DIR="$(mktemp -d -t v2quantum-manager-test.XXXXXX)"

"$MANAGER" --version | grep -qx 'v2quantum-manager 0.3.1'

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2quantum-manager-test.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

run_manager() {
  local config_dir="$1" input="$2" output_file="${3:-/dev/null}" systemctl="${4:-/usr/bin/true}"
  local state_dir="$config_dir/state"
  local run_dir="$config_dir/run"
  mkdir -p "$run_dir"
  printf '%s' "$input" | env \
    V2QUANTUM_BIN="$BIN" \
    V2QUANTUM_CONFIG_DIR="$config_dir" \
    V2QUANTUM_STATE_DIR="$state_dir" \
    V2QUANTUM_RUN_DIR="$run_dir" \
    V2QUANTUM_SYSTEMCTL="$systemctl" \
    V2QUANTUM_JOURNALCTL=/usr/bin/true \
    V2QUANTUM_SS=/usr/bin/false \
    V2QUANTUM_SYSCTL="${V2Q_TEST_SYSCTL:-sysctl}" \
    V2QUANTUM_SYSCTL_CONFIG="$config_dir/90-v2quantum-udp.conf" \
    V2QUANTUM_HOST_TUNING="${V2Q_TEST_HOST_TUNING:-0}" \
    "$MANAGER" >"$output_file"
}

SERVER_DIR="$TMP_DIR/server"
SERVER_OUTPUT="$TMP_DIR/server-output.txt"
run_manager "$SERVER_DIR" $'1\n2\n2\n\n\n\n\n0\n' "$SERVER_OUTPUT"
SERVER_INSTANCE="iran-quantum_udp-8890"
test -s "$SERVER_DIR/$SERVER_INSTANCE.json"
test -s "$SERVER_DIR/$SERVER_INSTANCE.env"
grep -q '"profile": "balanced"' "$SERVER_DIR/$SERVER_INSTANCE.json"
grep -q '"auto_tune": true' "$SERVER_DIR/$SERVER_INSTANCE.json"
set -a
# shellcheck disable=SC1090
source "$SERVER_DIR/$SERVER_INSTANCE.env"
set +a
"$BIN" check -config "$SERVER_DIR/$SERVER_INSTANCE.json" >/dev/null

TOKEN="$V2QUANTUM_PSK"
SETUP_CODE="$(grep '^V2Q3_' "$SERVER_OUTPUT")"
test -n "$SETUP_CODE"
CLIENT_DIR="$TMP_DIR/client"
run_manager "$CLIENT_DIR" $'2\n'"$SETUP_CODE"$'\n\n\n0\n'
CLIENT_INSTANCE="outside-quantum_udp-8890"
grep -q '"profile": "balanced"' "$CLIENT_DIR/$CLIENT_INSTANCE.json"
grep -q '"auto_tune": true' "$CLIENT_DIR/$CLIENT_INSTANCE.json"
set -a
# shellcheck disable=SC1090
source "$CLIENT_DIR/$CLIENT_INSTANCE.env"
set +a
"$BIN" check -config "$CLIENT_DIR/$CLIENT_INSTANCE.json" >/dev/null

# The new manager must still import setup codes emitted by the previous release.
LEGACY_CODE="V2Q2_${SETUP_CODE#V2Q3_}"
LEGACY_CLIENT_DIR="$TMP_DIR/legacy-client"
run_manager "$LEGACY_CLIENT_DIR" $'2\n'"$LEGACY_CODE"$'\n\n\n0\n'
test -s "$LEGACY_CLIENT_DIR/$CLIENT_INSTANCE.json"
grep -q '"profile": "balanced"' "$LEGACY_CLIENT_DIR/$CLIENT_INSTANCE.json"

MULTI_SERVER_DIR="$TMP_DIR/multi-server"
MULTI_SERVER_OUTPUT="$TMP_DIR/multi-server-output.txt"
run_manager "$MULTI_SERVER_DIR" $'1\n2\n2\n25001,25002\n\n\nmulti\n0\n' "$MULTI_SERVER_OUTPUT"
MULTI_CODE="$(grep '^V2Q3_' "$MULTI_SERVER_OUTPUT")"
test -n "$MULTI_CODE"
grep -q '"name": "map-2"' "$MULTI_SERVER_DIR/iran-multi.json"
MULTI_CLIENT_DIR="$TMP_DIR/multi-client"
run_manager "$MULTI_CLIENT_DIR" $'2\n'"$MULTI_CODE"$'\n127.0.0.1:26001,127.0.0.1:26002\n\n0\n'
grep -q '"name": "map-2"' "$MULTI_CLIENT_DIR/outside-multi.json"
set -a
# shellcheck disable=SC1090
source "$MULTI_CLIENT_DIR/outside-multi.env"
set +a
"$BIN" check -config "$MULTI_CLIENT_DIR/outside-multi.json" >/dev/null

RAW_DIR="$TMP_DIR/raw"
run_manager "$RAW_DIR" $'1\n3\n2\n\n\n\n\n\n\n3\n\n\n0\n'
RAW_INSTANCE="iran-raw-2445"
set -a
# shellcheck disable=SC1090
source "$RAW_DIR/$RAW_INSTANCE.env"
set +a
"$BIN" check -config "$RAW_DIR/$RAW_INSTANCE.json" >/dev/null
grep -q '"mode": "raw_icmp"' "$RAW_DIR/$RAW_INSTANCE.json"
grep -q '"expected_peer_source_ip": "198.51.100.20"' "$RAW_DIR/$RAW_INSTANCE.json"
grep -q '"spoof_source_ip": ""' "$RAW_DIR/$RAW_INSTANCE.json"

# Automatic mode must use only the source returned by the safe assigned-IP scanner.
REAL_BIN="$BIN"
SCAN_BIN="$TMP_DIR/v2quantum-scan-fixture"
cat >"$SCAN_BIN" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "spoof-scan" ]]; then
  printf 'fixture scan selected 192.0.2.10\\n' >&2
  printf '192.0.2.10\\n'
  exit 0
fi
exec "$REAL_BIN" "\$@"
EOF
chmod 755 "$SCAN_BIN"
BIN="$SCAN_BIN"
AUTO_RAW_DIR="$TMP_DIR/raw-auto"
run_manager "$AUTO_RAW_DIR" $'1\n3\n2\n25041\n192.0.2.10\n198.51.100.20\neth0\n22066\n1200\n1\n198.51.100.55\n192.0.2.10\nauto\n0\n'
BIN="$REAL_BIN"
grep -q '"spoof_source_ip": "192.0.2.10"' "$AUTO_RAW_DIR/iran-auto.json"
grep -q '"expected_peer_source_ip": "198.51.100.55"' "$AUTO_RAW_DIR/iran-auto.json"

# Manual mode keeps source, destination and expected peer source independent.
MANUAL_RAW_DIR="$TMP_DIR/raw-manual"
run_manager "$MANUAL_RAW_DIR" $'1\n3\n2\n25042\n192.0.2.10\n198.51.100.20\neth0\n22066\n1200\n2\n192.0.2.10\n203.0.113.20\n203.0.113.30\ny\n192.0.2.10\nmanual\n0\n'
grep -q '"spoof_source_ip": "192.0.2.10"' "$MANUAL_RAW_DIR/iran-manual.json"
grep -q '"spoof_destination_ip": "203.0.113.30"' "$MANUAL_RAW_DIR/iran-manual.json"
grep -q '"expected_peer_source_ip": "203.0.113.20"' "$MANUAL_RAW_DIR/iran-manual.json"

# Independent L3 TUN setup code must create valid, separately named peers.
TUN_SERVER_DIR="$TMP_DIR/tun-server"
TUN_SERVER_OUTPUT="$TMP_DIR/tun-server-output.txt"
SYSCTL_FIXTURE="$TMP_DIR/sysctl-fixture"
cat >"$SYSCTL_FIXTURE" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
  case "${2:-}" in
    net.core.rmem_max) echo 67108864 ;;
    *) echo 212992 ;;
  esac
  exit 0
fi
[[ "$*" == -q\ -p\ * ]]
EOF
chmod 755 "$SYSCTL_FIXTURE"
V2Q_TEST_HOST_TUNING=1 V2Q_TEST_SYSCTL="$SYSCTL_FIXTURE" \
  run_manager "$TUN_SERVER_DIR" $'3\n1\n2\n2\n\n192.0.2.10\n\n\n\n\n\nalpha-tun\n0\n0\n' "$TUN_SERVER_OUTPUT"
TUN_SERVER_INSTANCE="iran-alpha-tun"
test -s "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.json"
grep -q '"tun": {' "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.json"
grep -q '"pool": 1' "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.json"
grep -q '"profile": "balanced"' "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.json"
test -s "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.portmap"
grep -q '^MAP=443=443$' "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.portmap"
grep -q '^LOCAL_IP=10.77.0.1$' "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.portmap"
grep -q '^PEER_IP=10.77.0.2$' "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.portmap"
grep -q '^net.core.rmem_max = 67108864$' "$TUN_SERVER_DIR/90-v2quantum-udp.conf"
grep -q '^net.core.wmem_max = 33554432$' "$TUN_SERVER_DIR/90-v2quantum-udp.conf"
grep -q '^net.ipv4.ip_forward = 1$' "$TUN_SERVER_DIR/90-v2quantum-udp.conf"
set -a
# shellcheck disable=SC1090
source "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.env"
set +a
"$BIN" check -config "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.json" >/dev/null
TUN_CODE="$(grep '^V2T2_' "$TUN_SERVER_OUTPUT")"
test -n "$TUN_CODE"

TUN_CLIENT_DIR="$TMP_DIR/tun-client"
run_manager "$TUN_CLIENT_DIR" $'3\n2\n'"$TUN_CODE"$'\n\n\n0\n0\n'
TUN_CLIENT_INSTANCE="outside-alpha-tun"
test -s "$TUN_CLIENT_DIR/$TUN_CLIENT_INSTANCE.json"
grep -q '"local_address": "10.77.0.2/30"' "$TUN_CLIENT_DIR/$TUN_CLIENT_INSTANCE.json"
grep -q '"peer_address": "10.77.0.1"' "$TUN_CLIENT_DIR/$TUN_CLIENT_INSTANCE.json"
set -a
# shellcheck disable=SC1090
source "$TUN_CLIENT_DIR/$TUN_CLIENT_INSTANCE.env"
set +a
"$BIN" check -config "$TUN_CLIENT_DIR/$TUN_CLIENT_INSTANCE.json" >/dev/null

LEGACY_TUN_CODE="V2T1_${TUN_CODE#V2T2_}"
LEGACY_TUN_CLIENT_DIR="$TMP_DIR/legacy-tun-client"
run_manager "$LEGACY_TUN_CLIENT_DIR" $'3\n2\n'"$LEGACY_TUN_CODE"$'\n\n\n0\n0\n'
test -s "$LEGACY_TUN_CLIENT_DIR/$TUN_CLIENT_INSTANCE.json"
grep -q '"profile": "balanced"' "$LEGACY_TUN_CLIENT_DIR/$TUN_CLIENT_INSTANCE.json"

# An existing Iran TUN changes or removes its forwarding rule without recreation or a setup code.
run_manager "$TUN_SERVER_DIR" $'3\n6\niran-alpha-tun\n8443=443\n0\n0\n'
grep -q '^MAP=8443=443$' "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.portmap"
run_manager "$TUN_SERVER_DIR" $'3\n6\niran-alpha-tun\n-\n0\n0\n'
test ! -e "$TUN_SERVER_DIR/$TUN_SERVER_INSTANCE.portmap"

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
V2Q_TEST_SYSTEMCTL_LOG="$FAIL_LOG" \
  run_manager "$FAILED_DIR" $'1\n2\n2\n25111\n8891\n198.51.100.10\nfailed\n0\n' /dev/null "$FAIL_SYSTEMCTL"
test ! -e "$FAILED_DIR/iran-failed.json"
test ! -e "$FAILED_DIR/iran-failed.env"
grep -q '^disable --now v2quantum@iran-failed.service$' "$FAIL_LOG"

# A second tunnel must coexist, and a failed new tunnel must not alter the first.
COEXIST_DIR="$TMP_DIR/coexist"
run_manager "$COEXIST_DIR" $'1\n2\n2\n25121\n8892\n198.51.100.11\nprimary\n1\n2\n2\n25122\n8893\n198.51.100.12\nsecondary\n0\n'
test -s "$COEXIST_DIR/iran-primary.json"
test -s "$COEXIST_DIR/iran-secondary.json"
grep -q '0.0.0.0:25121' "$COEXIST_DIR/iran-primary.json"
grep -q '0.0.0.0:25122' "$COEXIST_DIR/iran-secondary.json"
cp "$COEXIST_DIR/iran-primary.json" "$TMP_DIR/original-primary.json"
cp "$COEXIST_DIR/iran-primary.env" "$TMP_DIR/original-primary.env"
: >"$FAIL_LOG"
V2Q_TEST_SYSTEMCTL_LOG="$FAIL_LOG" \
  run_manager "$COEXIST_DIR" $'1\n2\n2\n25123\n8894\n198.51.100.13\nfailed-third\n0\n' /dev/null "$FAIL_SYSTEMCTL"
test ! -e "$COEXIST_DIR/iran-failed-third.json"
test ! -e "$COEXIST_DIR/iran-failed-third.env"
cmp "$TMP_DIR/original-primary.json" "$COEXIST_DIR/iran-primary.json"
cmp "$TMP_DIR/original-primary.env" "$COEXIST_DIR/iran-primary.env"

# Lowercase y is sufficient for removal; YES is not required.
mkdir -p "$SERVER_DIR/state/backups/$SERVER_INSTANCE-20260101-000000"
printf 'old\n' >"$SERVER_DIR/state/backups/$SERVER_INSTANCE-20260101-000000/$SERVER_INSTANCE.json"
run_manager "$SERVER_DIR" $'9\n'"$SERVER_INSTANCE"$'\ny\n0\n'
test ! -e "$SERVER_DIR/$SERVER_INSTANCE.json"
test ! -e "$SERVER_DIR/$SERVER_INSTANCE.env"
test ! -e "$SERVER_DIR/state/backups/$SERVER_INSTANCE-20260101-000000"

echo "manager smoke tests passed"
