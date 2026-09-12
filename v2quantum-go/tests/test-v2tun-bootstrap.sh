#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="$PROJECT_DIR/install-v2tun.sh"
TMP_DIR="$(mktemp -d -t v2tun-bootstrap-test.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2tun-bootstrap-test.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

LOG="$TMP_DIR/install.log"
INSTALLER_FIXTURE="$TMP_DIR/installer.sh"
cat >"$INSTALLER_FIXTURE" <<'EOF'
#!/usr/bin/env bash
printf 'repo=%s\n' "${V2QUANTUM_REPO:-}" >>"${V2TUN_TEST_LOG:?}"
printf 'ref=%s\n' "${V2QUANTUM_REF:-}" >>"${V2TUN_TEST_LOG:?}"
printf 'mode=%s\n' "${V2QUANTUM_MANAGER_MODE:-}" >>"${V2TUN_TEST_LOG:?}"
printf 'args=%s\n' "$*" >>"${V2TUN_TEST_LOG:?}"
IFS= read -r terminal_value
printf 'input=%s\n' "$terminal_value" >>"${V2TUN_TEST_LOG:?}"
EOF

FAKE_CURL="$TMP_DIR/curl"
cat >"$FAKE_CURL" <<'EOF'
#!/usr/bin/env bash
destination=""
url=""
while (( $# > 0 )); do
  case "$1" in
    -o) destination="${2:-}"; shift 2; continue ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
[[ "$url" == *'/V2grop/backhaul-oneclick/codex/v2quantum-go-v1/v2quantum-go/scripts/oneclick.sh?cb='* ]]
cp "${V2TUN_TEST_INSTALLER:?}" "$destination"
EOF
chmod 755 "$FAKE_CURL" "$INSTALLER_FIXTURE"

printf 'terminal-stays-open\n' | env \
  V2TUN_BOOTSTRAP_SKIP_ROOT_CHECK=1 \
  V2TUN_BOOTSTRAP_CURL="$FAKE_CURL" \
  V2TUN_TEST_INSTALLER="$INSTALLER_FIXTURE" \
  V2TUN_TEST_LOG="$LOG" \
  bash "$BOOTSTRAP" >/dev/null

grep -qx 'repo=V2grop/backhaul-oneclick' "$LOG"
grep -qx 'ref=codex/v2quantum-go-v1' "$LOG"
grep -qx 'mode=tun' "$LOG"
grep -qx 'args=--source' "$LOG"
grep -qx 'input=terminal-stays-open' "$LOG"

echo "V2TUN final bootstrap tests passed"
