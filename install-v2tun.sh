#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Short, branch-pinned V2TUN installer/updater for both Iran and outside.
REPO="${V2QUANTUM_REPO:-${TUNNEL_MANAGER_REPO:-V2grop/backhaul-oneclick}}"
REF="${V2QUANTUM_REF:-${TUNNEL_MANAGER_REF:-codex/v2quantum-go-v1}}"
CURL_BIN="${V2TUN_BOOTSTRAP_CURL:-curl}"
SKIP_ROOT_CHECK="${V2TUN_BOOTSTRAP_SKIP_ROOT_CHECK:-0}"

# Backward-compatible helper only. The recommended entry point is now the
# Universal Tunnel Manager. Keep this wrapper interactive for older commands.
BOOTSTRAP_INPUT_FD=0
if [[ ! -t 0 ]]; then
  if { exec {bootstrap_tty_fd}</dev/tty; } 2>/dev/null; then
    BOOTSTRAP_INPUT_FD="$bootstrap_tty_fd"
  fi
fi

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid V2Quantum repository." >&2
  exit 2
fi
if [[ ! "$REF" =~ ^[-A-Za-z0-9._/]+$ || "$REF" == /* || "$REF" == *..* ]]; then
  echo "Invalid V2Quantum ref." >&2
  exit 2
fi
if [[ "$SKIP_ROOT_CHECK" != "1" && ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo -i" >&2
  exit 1
fi
command -v "$CURL_BIN" >/dev/null 2>&1 || {
  echo "curl is required." >&2
  exit 1
}

TMP_FILE="$(mktemp -t v2tun-final-installer.XXXXXX)"
cleanup() {
  if [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" && "$TMP_FILE" == /tmp/v2tun-final-installer.* ]]; then
    rm -f -- "$TMP_FILE"
  fi
}
trap cleanup EXIT

URL="https://raw.githubusercontent.com/$REPO/$REF/v2quantum-go/scripts/oneclick.sh?cb=$(date +%s)"
"$CURL_BIN" -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 --ipv4 \
  -o "$TMP_FILE" "$URL"
bash -n "$TMP_FILE"

env \
  V2QUANTUM_REPO="$REPO" \
  V2QUANTUM_REF="$REF" \
  V2QUANTUM_MANAGER_MODE=tun \
  bash "$TMP_FILE" --source <&"$BOOTSTRAP_INPUT_FD"
