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
  local config_dir="$1" input="$2"
  printf '%s' "$input" | env \
    V2QUANTUM_BIN="$BIN" \
    V2QUANTUM_CONFIG_DIR="$config_dir" \
    V2QUANTUM_SYSTEMCTL=/usr/bin/true \
    "$MANAGER" >/dev/null
}

SERVER_DIR="$TMP_DIR/server"
run_manager "$SERVER_DIR" $'1\n2\n\n\n0\n'
test -s "$SERVER_DIR/iran.json"
test -s "$SERVER_DIR/iran.env"
set -a
# shellcheck disable=SC1090
source "$SERVER_DIR/iran.env"
set +a
"$BIN" check -config "$SERVER_DIR/iran.json" >/dev/null

TOKEN="$V2QUANTUM_PSK"
CLIENT_DIR="$TMP_DIR/client"
run_manager "$CLIENT_DIR" $'2\n2\n'"$TOKEN"$'\n\n127.0.0.1:8880\n0\n'
set -a
# shellcheck disable=SC1090
source "$CLIENT_DIR/outside.env"
set +a
"$BIN" check -config "$CLIENT_DIR/outside.json" >/dev/null

RAW_DIR="$TMP_DIR/raw"
run_manager "$RAW_DIR" $'1\n3\n\n\n\n\n\n\n\n\n0\n'
set -a
# shellcheck disable=SC1090
source "$RAW_DIR/iran.env"
set +a
"$BIN" check -config "$RAW_DIR/iran.json" >/dev/null
grep -q '"mode": "raw_icmp"' "$RAW_DIR/iran.json"

# Lowercase y is sufficient for removal; YES is not required.
run_manager "$SERVER_DIR" $'7\niran\ny\n0\n'
test ! -e "$SERVER_DIR/iran.json"
test ! -e "$SERVER_DIR/iran.env"

echo "manager smoke tests passed"
