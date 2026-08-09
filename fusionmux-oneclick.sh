#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

REPO="${TUNNEL_MANAGER_REPO:-${V2QUANTUM_REPO:-V2grop/backhaul-oneclick}}"
REF="${TUNNEL_MANAGER_REF:-${V2QUANTUM_REF:-main}}"
URL="https://raw.githubusercontent.com/$REPO/$REF/oneclick-universal.sh"
TMP_FILE="$(mktemp -t tunnel-manager-bootstrap.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" && "$TMP_FILE" == /tmp/tunnel-manager-bootstrap.* ]]; then
    rm -f -- "$TMP_FILE"
  fi
}
trap cleanup EXIT

[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid tunnel manager repository." >&2
  exit 2
}
[[ "$REF" =~ ^[-A-Za-z0-9._/]+$ && "$REF" != /* && "$REF" != *..* ]] || {
  echo "Invalid tunnel manager ref." >&2
  exit 2
}

curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 --ipv4 \
  -o "$TMP_FILE" "$URL"
bash -n "$TMP_FILE"

# Compatibility entry point: opening this file without an argument now shows
# the complete manager. Pass --fusion only when the dedicated FusionMux menu is
# intentionally required.
env \
  TUNNEL_MANAGER_REPO="$REPO" \
  TUNNEL_MANAGER_REF="$REF" \
  bash "$TMP_FILE" "$@"
