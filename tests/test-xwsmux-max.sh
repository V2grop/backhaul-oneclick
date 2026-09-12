#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="${ROOT_DIR}/oneclick-xwsmux-max.sh"
TEST_DIR="$(mktemp -d)"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fqx "$expected" "$file" || fail "Missing line in ${file}: ${expected}"
}

bash -n "$MANAGER"
source "$MANAGER"
ORIGINAL_BASE_DIR="$BASE_DIR"

validate_token '0123456789abcdef' || fail 'Valid token rejected.'
! validate_token 'short' || fail 'Short token accepted.'
validate_endpoint 'pak.example.com:8880' || fail 'Valid endpoint rejected.'
! validate_endpoint 'pak.example.com' || fail 'Endpoint without port accepted.'
validate_edge '172.67.138.250' || fail 'Valid Edge IP rejected.'

TRANSPORT=xwsmux
TOKEN=0123456789abcdef0123456789abcdef
KEEPALIVE=20
NODELAY=true
HEARTBEAT=5
CHANNEL_SIZE=8192
ACCEPT_UDP=false
PROXY_PROTOCOL=false
MUX_CON=16
MUX_VERSION=2
FRAME_SIZE=32768
RECV_BUFFER=8388608
STREAM_BUFFER=65536
LOG_LEVEL=info
BIND_ADDR=0.0.0.0:8880
PORT_ITEMS=(2444=443)
write_server_config "$TEST_DIR/server.toml"

REMOTE_ADDR=pak.example.com:8880
EDGE_IP=172.67.138.250
POOL=16
AGGRESSIVE_POOL=true
DIAL_TIMEOUT=8
RETRY_INTERVAL=1
write_client_config "$TEST_DIR/client.toml"

assert_contains "$TEST_DIR/server.toml" 'transport = "xwsmux"'
assert_contains "$TEST_DIR/server.toml" 'mux_con = 16'
assert_contains "$TEST_DIR/server.toml" 'mux_framesize = 32768'
assert_contains "$TEST_DIR/server.toml" '  "2444=443",'
assert_contains "$TEST_DIR/client.toml" 'connection_pool = 16'
assert_contains "$TEST_DIR/client.toml" 'aggressive_pool = true'
assert_contains "$TEST_DIR/client.toml" 'retry_interval = 1'
assert_contains "$TEST_DIR/client.toml" 'edge_ip = "172.67.138.250"'

# The XWSMUX manager must not manage or remove unrelated Backhaul transports.
BASE_DIR="$TEST_DIR/configs"
mkdir -p "$BASE_DIR"
cp "$TEST_DIR/server.toml" "$BASE_DIR/iran8880.toml"
cp "$TEST_DIR/client.toml" "$BASE_DIR/kharej8880.toml"
printf '[server]\ntransport = "tcp"\n' >"$BASE_DIR/iran7777.toml"
systemctl() { return 0; }
warn() { :; }
list_tunnels >/dev/null
test "${#TUNNEL_CONFIGS[@]}" -eq 2 || fail 'Unrelated Backhaul transports leaked into XWSMUX management.'
[[ " ${TUNNEL_CONFIGS[*]} " != *'iran7777.toml'* ]] || fail 'A standard Backhaul tunnel was listed by XWSMUX manager.'
BASE_DIR="$ORIGINAL_BASE_DIR"

mkdir -p "$TEST_DIR/systemd" "$TEST_DIR/libexec"
ROLE=client
TUNNEL_PORT=8880
CONFIG=/root/backhaul-core/kharej8880.toml
UNIT="$TEST_DIR/systemd/backhaul-kharej8880.service"
SERVICE=backhaul-kharej8880
DESCRIPTION='Backhaul Kharej xwsmux Max Port 8880'
BIN=/root/backhaul-core/backhaul_premium
write_unit "$UNIT"
assert_contains "$UNIT" 'Restart=always'
assert_contains "$UNIT" 'RestartSec=1'
assert_contains "$UNIT" 'KillMode=mixed'
assert_contains "$UNIT" 'StartLimitIntervalSec=300'
assert_contains "$UNIT" 'StartLimitBurst=60'

SERVICE_DIR="$TEST_DIR/systemd"
WATCHDOG_DIR="$TEST_DIR/libexec"
WATCHDOG=true
ok() { :; }
install_watchdog
bash -n "$TEST_DIR/libexec/backhaul-kharej8880"
assert_contains "$TEST_DIR/systemd/backhaul-kharej8880-watchdog.timer" 'OnUnitActiveSec=15s'
assert_contains "$TEST_DIR/systemd/backhaul-kharej8880-watchdog.timer" 'OnBootSec=30s'
grep -Fq 'FAILURE_THRESHOLD=2' "$TEST_DIR/libexec/backhaul-kharej8880" || fail 'Watchdog threshold was not hardened.'
grep -Fq 'RESTART_COOLDOWN=45' "$TEST_DIR/libexec/backhaul-kharej8880" || fail 'Watchdog cooldown is missing.'
grep -Fq 'forcing a clean start' "$TEST_DIR/libexec/backhaul-kharej8880" || fail 'Watchdog hard recovery is missing.'

# Two consecutive missing client sessions must trigger one bounded restart.
FAKE_BIN="$TEST_DIR/fake-bin"
WATCHDOG_STATE="$TEST_DIR/watchdog-state"
WATCHDOG_LOG="$TEST_DIR/watchdog-actions.log"
mkdir -p "$FAKE_BIN" "$WATCHDOG_STATE"
: >"$WATCHDOG_LOG"
cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  show) printf '4242\n' ;;
  is-active) exit 0 ;;
  restart|start|kill|reset-failed) printf '%s\n' "$*" >>"${XWS_TEST_LOG:?}" ;;
esac
EOF
cat >"$FAKE_BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$FAKE_BIN/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$FAKE_BIN/systemctl" "$FAKE_BIN/ss" "$FAKE_BIN/logger" "$FAKE_BIN/sleep"
for _ in 1 2; do
  PATH="$FAKE_BIN:$PATH" \
    XWS_TEST_LOG="$WATCHDOG_LOG" \
    BACKHAUL_WATCHDOG_STATE_DIR="$WATCHDOG_STATE" \
    bash "$TEST_DIR/libexec/backhaul-kharej8880"
done
grep -Fqx 'restart backhaul-kharej8880.service' "$WATCHDOG_LOG" || fail 'Watchdog did not restart a stale client transport.'
test "$(grep -Fc 'restart backhaul-kharej8880.service' "$WATCHDOG_LOG")" -eq 1 || fail 'Watchdog restarted more than once.'

printf '[PASS] XWSMUX Max configuration and service tests passed.\n'
