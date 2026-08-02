#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "Run this installer as root." >&2
  exit 1
fi
for command in curl sha256sum install systemctl; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

REPO="${V2QUANTUM_REPO:-V2grop/backhaul-oneclick}"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

ASSET="v2quantum-linux-$ARCH"
RELEASE_BASE="https://github.com/$REPO/releases/latest/download"
TMP_DIR="$(mktemp -d -t v2quantum-remote.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2quantum-remote.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

echo "Downloading the latest V2Quantum release for $ARCH..."
curl -fL --retry 3 --connect-timeout 10 -o "$TMP_DIR/$ASSET" "$RELEASE_BASE/$ASSET"
curl -fL --retry 3 --connect-timeout 10 -o "$TMP_DIR/SHA256SUMS" "$RELEASE_BASE/SHA256SUMS"
curl -fL --retry 3 --connect-timeout 10 -o "$TMP_DIR/v2quantum-manager" "$RELEASE_BASE/v2quantum-manager"
curl -fL --retry 3 --connect-timeout 10 -o "$TMP_DIR/v2quantum@.service" "$RELEASE_BASE/v2quantum@.service"
(
  cd -- "$TMP_DIR"
  grep -E "  ($ASSET|v2quantum-manager|v2quantum@\\.service)\$" SHA256SUMS > SHA256SUMS.selected
  [[ "$(wc -l < SHA256SUMS.selected)" -eq 3 ]]
  sha256sum -c SHA256SUMS.selected
)

install -Dm755 "$TMP_DIR/$ASSET" /usr/local/bin/v2quantum
install -Dm755 "$TMP_DIR/v2quantum-manager" /usr/local/sbin/v2quantum-manager
install -Dm644 "$TMP_DIR/v2quantum@.service" /etc/systemd/system/v2quantum@.service
install -d -m750 /etc/v2quantum
systemctl daemon-reload

/usr/local/bin/v2quantum version
echo "Installed successfully. Run: v2quantum-manager"
