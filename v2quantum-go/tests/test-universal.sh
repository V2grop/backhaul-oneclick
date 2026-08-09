#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LAUNCHER="$PROJECT_DIR/oneclick-universal.sh"
TMP_DIR="$(mktemp -d -t universal-manager-test.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/universal-manager-test.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

FIXTURES="$TMP_DIR/fixtures"
LOG="$TMP_DIR/actions.log"
SHORTCUT="$TMP_DIR/tunnel-manager"
mkdir -p "$FIXTURES"

for name in backhaul xwsmux realm; do
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "printf '${name}\\n' >>\"\${TUNNEL_TEST_LOG:?}\"" \
    >"$FIXTURES/$name.sh"
done

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''v2quantum:%s:%s:%s\n'\'' "${V2QUANTUM_REF:-}" "${V2QUANTUM_ALLOW_SOURCE_BUILD:-}" "${V2QUANTUM_MANAGER_MODE:-}" >>"${TUNNEL_TEST_LOG:?}"' \
  >"$FIXTURES/v2quantum.sh"

FAKE_CURL="$TMP_DIR/curl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'destination=""' \
  'url=""' \
  'while (( $# > 0 )); do' \
  '  case "$1" in' \
  '    -o) destination="${2:-}"; shift 2; continue ;;' \
  '    http://*|https://*) url="$1" ;;' \
  '  esac' \
  '  shift' \
  'done' \
  'case "$url" in' \
  '  */missing-xwsmux.sh) exit 22 ;;' \
  '  */oneclick-v3-en.sh) source_file="$TUNNEL_TEST_FIXTURES/backhaul.sh" ;;' \
  '  */oneclick-xwsmux-max.sh) source_file="$TUNNEL_TEST_FIXTURES/xwsmux.sh" ;;' \
  '  */v2quantum-oneclick.sh) source_file="$TUNNEL_TEST_FIXTURES/v2quantum.sh" ;;' \
  '  */realm.sh) source_file="$TUNNEL_TEST_FIXTURES/realm.sh" ;;' \
  '  */oneclick-universal.sh) source_file="$TUNNEL_TEST_LAUNCHER" ;;' \
  '  *) echo "unexpected URL: $url" >&2; exit 1 ;;' \
  'esac' \
  'cp "$source_file" "$destination"' \
  >"$FAKE_CURL"
chmod 755 "$FAKE_CURL"

FAKE_SYSTEMCTL="$TMP_DIR/systemctl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''service test loaded active running\n'\''' \
  >"$FAKE_SYSTEMCTL"
chmod 755 "$FAKE_SYSTEMCTL"

FAKE_SS="$TMP_DIR/ss"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''tcp LISTEN 0 128 0.0.0.0:8890 users:(("v2quantum",pid=1,fd=3))\n'\''' \
  >"$FAKE_SS"
chmod 755 "$FAKE_SS"

COMMON_ENV=(
  TUNNEL_MANAGER_SKIP_ROOT_CHECK=1
  TUNNEL_MANAGER_REPO=V2grop/backhaul-oneclick
  TUNNEL_MANAGER_REF=codex/v2quantum-go-v1
  TUNNEL_MANAGER_CURL="$FAKE_CURL"
  TUNNEL_MANAGER_SYSTEMCTL="$FAKE_SYSTEMCTL"
  TUNNEL_MANAGER_SS="$FAKE_SS"
  TUNNEL_MANAGER_SHORTCUT="$SHORTCUT"
  TUNNEL_MANAGER_REALM_COMMAND="$TMP_DIR/missing-irealm"
  TUNNEL_MANAGER_V2QUANTUM_COMMAND="$TMP_DIR/missing-v2quantum-manager"
  TUNNEL_TEST_FIXTURES="$FIXTURES"
  TUNNEL_TEST_LAUNCHER="$LAUNCHER"
  TUNNEL_TEST_LOG="$LOG"
)

env "${COMMON_ENV[@]}" bash "$LAUNCHER" --help >"$TMP_DIR/help.txt"
grep -q -- '--xwsmux-max' "$TMP_DIR/help.txt"
grep -q -- '--v2quantum' "$TMP_DIR/help.txt"
grep -q -- '--fusion' "$TMP_DIR/help.txt"
grep -q -- '--tun' "$TMP_DIR/help.txt"
grep -q -- '--realm' "$TMP_DIR/help.txt"

env "${COMMON_ENV[@]}" bash "$LAUNCHER" --backhaul >/dev/null
env "${COMMON_ENV[@]}" \
  TUNNEL_MANAGER_XWSMUX_MAX_URL=https://invalid.example/missing-xwsmux.sh \
  bash "$LAUNCHER" --xwsmux-max >/dev/null 2>&1
env "${COMMON_ENV[@]}" bash "$LAUNCHER" --v2quantum >/dev/null
env "${COMMON_ENV[@]}" bash "$LAUNCHER" --fusion >/dev/null
env "${COMMON_ENV[@]}" bash "$LAUNCHER" --tun >/dev/null
printf 'y\n' | env "${COMMON_ENV[@]}" bash "$LAUNCHER" --realm >/dev/null

grep -qx 'backhaul' "$LOG"
grep -qx 'xwsmux' "$LOG"
grep -qx 'realm' "$LOG"
grep -qx 'v2quantum:codex/v2quantum-go-v1:1:all' "$LOG"
grep -qx 'v2quantum:codex/v2quantum-go-v1:1:fusion' "$LOG"
grep -qx 'v2quantum:codex/v2quantum-go-v1:1:tun' "$LOG"

env "${COMMON_ENV[@]}" bash "$LAUNCHER" --status >"$TMP_DIR/status.txt"
grep -q 'service test loaded active running' "$TMP_DIR/status.txt"
grep -q 'v2quantum' "$TMP_DIR/status.txt"

env "${COMMON_ENV[@]}" bash "$LAUNCHER" --capabilities >"$TMP_DIR/capabilities.txt"
grep -q 'Pengu and Dagger licensed binaries are not bundled' "$TMP_DIR/capabilities.txt"
grep -q 'quantum_udp is the carrier' "$TMP_DIR/capabilities.txt"
grep -q 'assigned-IP ICMP scanning' "$TMP_DIR/capabilities.txt"
grep -q 'separate working L3 TUN' "$TMP_DIR/capabilities.txt"
grep -q 'FusionMux Pro' "$TMP_DIR/capabilities.txt"
grep -q 'mirrors.aliyun.com/golang' "$PROJECT_DIR/v2quantum-go/scripts/oneclick.sh"
grep -q 'golang.google.cn/dl' "$PROJECT_DIR/v2quantum-go/scripts/oneclick.sh"

env "${COMMON_ENV[@]}" bash "$LAUNCHER" --install-shortcut >/dev/null
test -x "$SHORTCUT"
env "${COMMON_ENV[@]}" bash "$LAUNCHER" --remove-shortcut -y >/dev/null
test ! -e "$SHORTCUT"

printf '0\n' | env "${COMMON_ENV[@]}" bash "$LAUNCHER" >"$TMP_DIR/menu.txt"
grep -q '1) Backhaul family - Standard / XWSMUX Max / TUN' "$TMP_DIR/menu.txt"
grep -q '2) V2Quantum family - TCP / Quantum / Raw / FusionMux / TUN' "$TMP_DIR/menu.txt"
grep -q '3) Realm - TCP/UDP port forwarding' "$TMP_DIR/menu.txt"
if grep -q '^2) XWSMUX Max' "$TMP_DIR/menu.txt"; then
  echo "XWSMUX Max is still duplicated in the top-level menu" >&2
  exit 1
fi

printf '1\n0\n0\n' | env "${COMMON_ENV[@]}" bash "$LAUNCHER" >"$TMP_DIR/backhaul-menu.txt"
grep -q 'Backhaul family' "$TMP_DIR/backhaul-menu.txt"
grep -q '1) Standard Backhaul - layer-4 transports' "$TMP_DIR/backhaul-menu.txt"
grep -q '2) XWSMUX Max - optimized Cloudflare profile' "$TMP_DIR/backhaul-menu.txt"
grep -q '3) V2TUN - independent encrypted layer-3 tunnel' "$TMP_DIR/backhaul-menu.txt"

echo "universal launcher tests passed"
