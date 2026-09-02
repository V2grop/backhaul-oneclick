#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${V2QUANTUM_REPO:-V2grop/backhaul-oneclick}"
REF="${V2QUANTUM_REF:-main}"
URL="https://raw.githubusercontent.com/$REPO/$REF/v2quantum-go/scripts/oneclick.sh"
TMP_FILE="$(mktemp -t v2quantum-remote.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" && "$TMP_FILE" == /tmp/v2quantum-remote.* ]]; then
    rm -f -- "$TMP_FILE"
  fi
}
trap cleanup EXIT

curl -fL --retry 3 --connect-timeout 15 --ipv4 -o "$TMP_FILE" "$URL"
bash "$TMP_FILE" "$@"
