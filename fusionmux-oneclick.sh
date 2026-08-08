#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

REPO="${V2QUANTUM_REPO:-V2grop/backhaul-oneclick}"
REF="${V2QUANTUM_REF:-main}"
URL="https://raw.githubusercontent.com/$REPO/$REF/v2quantum-go/scripts/oneclick.sh"
TMP_FILE="$(mktemp -t fusionmux-bootstrap.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" && "$TMP_FILE" == /tmp/fusionmux-bootstrap.* ]]; then
    rm -f -- "$TMP_FILE"
  fi
}
trap cleanup EXIT

[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid V2QUANTUM_REPO." >&2
  exit 2
}
[[ "$REF" =~ ^[-A-Za-z0-9._/]+$ && "$REF" != /* && "$REF" != *..* ]] || {
  echo "Invalid V2QUANTUM_REF." >&2
  exit 2
}

curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 --ipv4 \
  -o "$TMP_FILE" "$URL"
bash -n "$TMP_FILE"

ALLOW_SOURCE="${V2QUANTUM_ALLOW_SOURCE_BUILD:-0}"
if [[ "$REF" != "main" && -z "${V2QUANTUM_ALLOW_SOURCE_BUILD+x}" ]]; then
  ALLOW_SOURCE=1
fi
env \
  V2QUANTUM_REPO="$REPO" \
  V2QUANTUM_REF="$REF" \
  V2QUANTUM_ALLOW_SOURCE_BUILD="$ALLOW_SOURCE" \
  V2QUANTUM_MANAGER_MODE=fusion \
  bash "$TMP_FILE" "$@"
