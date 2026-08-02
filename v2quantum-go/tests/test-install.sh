#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo env PATH="$PATH" bash "$0" "$@"
  fi
  echo "installer isolation test skipped: root or sudo is required"
  exit 0
fi

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_BINARY="${1:-$PROJECT_DIR/bin/v2quantum}"
INSTALL_SCRIPT="$PROJECT_DIR/scripts/install.sh"
TMP_DIR="$(mktemp -d -t v2quantum-install-test.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2quantum-install-test.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

ROOT="$TMP_DIR/root"
SYSTEMCTL="$TMP_DIR/systemctl"
SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
INSTALL_BIN="$ROOT/usr/local/bin/v2quantum"
INSTALL_MANAGER="$ROOT/usr/local/sbin/v2quantum-manager"
INSTALLER_PATH="$ROOT/usr/local/sbin/v2quantum-installer"
INSTALL_WATCHDOG="$ROOT/usr/local/libexec/v2quantum-watchdog"
INSTALL_UNIT="$ROOT/etc/systemd/system/v2quantum@.service"
INSTALL_WATCHDOG_UNIT="$ROOT/etc/systemd/system/v2quantum-watchdog@.service"
INSTALL_WATCHDOG_TIMER="$ROOT/etc/systemd/system/v2quantum-watchdog@.timer"
CONFIG_DIR="$ROOT/etc/v2quantum"
STATE_DIR="$ROOT/var/lib/v2quantum"
BACKHAUL_SENTINEL="$ROOT/etc/systemd/system/backhaul-user.service"

mkdir -p "$(dirname -- "$INSTALL_MANAGER")" "$(dirname -- "$INSTALL_UNIT")"
printf 'old manager\n' >"$INSTALL_MANAGER"
printf 'old unit\n' >"$INSTALL_UNIT"
printf 'user backhaul sentinel\n' >"$BACKHAUL_SENTINEL"
cp "$BACKHAUL_SENTINEL" "$TMP_DIR/backhaul-before"

cat >"$SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${V2Q_TEST_SYSTEMCTL_LOG:?}"
if [[ "${1:-}" == "list-units" ]]; then
  printf 'v2quantum@outside.service loaded active running test\n'
fi
exit 0
EOF
chmod 755 "$SYSTEMCTL"

env \
  V2Q_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  V2QUANTUM_BINARY="$SOURCE_BINARY" \
  V2QUANTUM_SYSTEMCTL="$SYSTEMCTL" \
  V2QUANTUM_INSTALL_BIN="$INSTALL_BIN" \
  V2QUANTUM_INSTALL_MANAGER="$INSTALL_MANAGER" \
  V2QUANTUM_INSTALLER_PATH="$INSTALLER_PATH" \
  V2QUANTUM_INSTALL_WATCHDOG="$INSTALL_WATCHDOG" \
  V2QUANTUM_INSTALL_UNIT="$INSTALL_UNIT" \
  V2QUANTUM_INSTALL_WATCHDOG_UNIT="$INSTALL_WATCHDOG_UNIT" \
  V2QUANTUM_INSTALL_WATCHDOG_TIMER="$INSTALL_WATCHDOG_TIMER" \
  V2QUANTUM_CONFIG_DIR="$CONFIG_DIR" \
  V2QUANTUM_STATE_DIR="$STATE_DIR" \
  bash "$INSTALL_SCRIPT" >/dev/null

test -x "$INSTALL_BIN"
test -x "$INSTALL_MANAGER"
test -x "$INSTALLER_PATH"
test -x "$INSTALL_WATCHDOG"
test -s "$INSTALL_UNIT"
test -s "$INSTALL_WATCHDOG_UNIT"
test -s "$INSTALL_WATCHDOG_TIMER"
"$INSTALL_BIN" version | grep -q '^v2quantum-go '
grep -q '^daemon-reload$' "$SYSTEMCTL_LOG"
grep -q '^try-restart v2quantum@outside.service$' "$SYSTEMCTL_LOG"
grep -Rqx -- 'old manager' "$STATE_DIR/backups"
grep -Rqx -- 'old unit' "$STATE_DIR/backups"
cmp "$TMP_DIR/backhaul-before" "$BACKHAUL_SENTINEL"

echo "installer isolation tests passed"
