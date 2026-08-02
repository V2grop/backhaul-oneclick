#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "Run this installer as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
INSTALL_BIN="/usr/local/bin/v2quantum"
INSTALL_MANAGER="/usr/local/sbin/v2quantum-manager"
INSTALL_UNIT="/etc/systemd/system/v2quantum@.service"
TMP_DIR="$(mktemp -d -t v2quantum-install.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2quantum-install.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

SOURCE_BINARY="${V2QUANTUM_BINARY:-}"
if [[ -n "$SOURCE_BINARY" ]]; then
  if [[ ! -f "$SOURCE_BINARY" ]]; then
    echo "V2QUANTUM_BINARY does not point to a file: $SOURCE_BINARY" >&2
    exit 1
  fi
elif command -v go >/dev/null 2>&1 && [[ -f "$PROJECT_DIR/go.mod" ]]; then
  VERSION="${V2QUANTUM_VERSION:-0.1.0}"
  echo "Building V2Quantum $VERSION from local source..."
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
  if [[ ! -f "$CANDIDATE" ]]; then
    echo "Go is unavailable and no release binary was found at $CANDIDATE" >&2
    echo "Provide one with: V2QUANTUM_BINARY=/path/to/v2quantum $0" >&2
    exit 1
  fi
  SOURCE_BINARY="$CANDIDATE"
fi

install -Dm755 "$SOURCE_BINARY" "$INSTALL_BIN"
install -Dm755 "$PROJECT_DIR/scripts/manager.sh" "$INSTALL_MANAGER"
install -Dm644 "$PROJECT_DIR/systemd/v2quantum@.service" "$INSTALL_UNIT"
install -d -m750 /etc/v2quantum
systemctl daemon-reload

"$INSTALL_BIN" version
echo
echo "Installed successfully. Start the simple setup menu with:"
echo "  v2quantum-manager"
