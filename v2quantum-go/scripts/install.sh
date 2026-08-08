#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

if (( EUID != 0 )); then
  echo "Run this installer as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SYSTEMCTL="${V2QUANTUM_SYSTEMCTL:-systemctl}"
INSTALL_BIN="${V2QUANTUM_INSTALL_BIN:-/usr/local/bin/v2quantum}"
INSTALL_MANAGER="${V2QUANTUM_INSTALL_MANAGER:-/usr/local/sbin/v2quantum-manager}"
INSTALLER_PATH="${V2QUANTUM_INSTALLER_PATH:-/usr/local/sbin/v2quantum-installer}"
INSTALL_WATCHDOG="${V2QUANTUM_INSTALL_WATCHDOG:-/usr/local/libexec/v2quantum-watchdog}"
INSTALL_UNIT="${V2QUANTUM_INSTALL_UNIT:-/etc/systemd/system/v2quantum@.service}"
INSTALL_WATCHDOG_UNIT="${V2QUANTUM_INSTALL_WATCHDOG_UNIT:-/etc/systemd/system/v2quantum-watchdog@.service}"
INSTALL_WATCHDOG_TIMER="${V2QUANTUM_INSTALL_WATCHDOG_TIMER:-/etc/systemd/system/v2quantum-watchdog@.timer}"
CONFIG_DIR="${V2QUANTUM_CONFIG_DIR:-/etc/v2quantum}"
STATE_DIR="${V2QUANTUM_STATE_DIR:-/var/lib/v2quantum}"
TMP_DIR="$(mktemp -d -t v2quantum-install.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2quantum-install.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

SOURCE_BINARY="${V2QUANTUM_BINARY:-}"
if [[ -n "$SOURCE_BINARY" ]]; then
  [[ -f "$SOURCE_BINARY" ]] || { echo "Binary not found: $SOURCE_BINARY" >&2; exit 1; }
elif command -v go >/dev/null 2>&1 && [[ -f "$PROJECT_DIR/go.mod" ]]; then
  VERSION="${V2QUANTUM_VERSION:-0.4.0}"
  echo "Building V2Quantum $VERSION from source..."
  (
    cd -- "$PROJECT_DIR"
    CGO_ENABLED=0 go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X main.version=$VERSION" \
      -o "$TMP_DIR/v2quantum" ./cmd/v2quantum
  )
  SOURCE_BINARY="$TMP_DIR/v2quantum"
else
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
  esac
  CANDIDATE="$PROJECT_DIR/dist/v2quantum-linux-$ARCH"
  [[ -f "$CANDIDATE" ]] || {
    echo "Go is unavailable and no release binary exists at $CANDIDATE" >&2
    exit 1
  }
  SOURCE_BINARY="$CANDIDATE"
fi

for required in \
  "$PROJECT_DIR/scripts/manager.sh" \
  "$PROJECT_DIR/scripts/watchdog.sh" \
  "$PROJECT_DIR/systemd/v2quantum@.service" \
  "$PROJECT_DIR/systemd/v2quantum-watchdog@.service" \
  "$PROJECT_DIR/systemd/v2quantum-watchdog@.timer"; do
  [[ -f "$required" ]] || { echo "Required payload is missing: $required" >&2; exit 1; }
done

install -d -m750 "$CONFIG_DIR" "$STATE_DIR/backups"
install -d -m755 "$(dirname -- "$INSTALL_BIN")" "$(dirname -- "$INSTALL_MANAGER")" \
  "$(dirname -- "$INSTALL_WATCHDOG")" "$(dirname -- "$INSTALL_UNIT")"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$STATE_DIR/backups/install-$STAMP"
BACKUP_CREATED=false
for target in "$INSTALL_BIN" "$INSTALL_MANAGER" "$INSTALLER_PATH" "$INSTALL_WATCHDOG" \
  "$INSTALL_UNIT" "$INSTALL_WATCHDOG_UNIT" "$INSTALL_WATCHDOG_TIMER"; do
  if [[ -f "$target" ]]; then
    if [[ "$BACKUP_CREATED" == false ]]; then
      install -d -m700 "$BACKUP_DIR"
      BACKUP_CREATED=true
    fi
    cp -a -- "$target" "$BACKUP_DIR/$(basename -- "$target")"
  fi
done

install -m755 "$SOURCE_BINARY" "$INSTALL_BIN"
install -m755 "$PROJECT_DIR/scripts/manager.sh" "$INSTALL_MANAGER"
install -m755 "$PROJECT_DIR/scripts/watchdog.sh" "$INSTALL_WATCHDOG"
install -m644 "$PROJECT_DIR/systemd/v2quantum@.service" "$INSTALL_UNIT"
install -m644 "$PROJECT_DIR/systemd/v2quantum-watchdog@.service" "$INSTALL_WATCHDOG_UNIT"
install -m644 "$PROJECT_DIR/systemd/v2quantum-watchdog@.timer" "$INSTALL_WATCHDOG_TIMER"
if [[ -f "$PROJECT_DIR/scripts/oneclick.sh" ]]; then
  install -m755 "$PROJECT_DIR/scripts/oneclick.sh" "$INSTALLER_PATH"
fi

"$SYSTEMCTL" daemon-reload
while IFS= read -r service; do
  [[ -n "$service" ]] || continue
  "$SYSTEMCTL" try-restart "$service" || true
done < <("$SYSTEMCTL" list-units --type=service --state=active 'v2quantum@*.service' \
  --no-legend 2>/dev/null | awk '{print $1}')

"$INSTALL_BIN" version
if [[ "$BACKUP_CREATED" == true ]]; then
  echo "Previous program files backed up at: $BACKUP_DIR"
fi
echo "Installed successfully."
echo "Open the manager with: v2quantum-manager"
