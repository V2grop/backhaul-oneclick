#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT_DIR/oneclick-v3-en.sh"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

bash -n "$WRAPPER"
grep -Fq 'V2TUN in oneclick-universal.sh' "$WRAPPER" || fail 'Legacy TUN replacement notice is missing.'

decoded="$({
  sed -n "/<<'BACKHAUL_MANAGER_V312_EN_BASE64'/,/^BACKHAUL_MANAGER_V312_EN_BASE64$/p" "$WRAPPER" \
    | sed '1d;$d' | base64 -d
})"
patched="$(printf '%s\n' "$decoded" | sed \
  -e '/^# Supports:/ s/, tun$//' \
  -e '/^  echo "10) tun"$/d' \
  -e 's/Select transport \[1-10\]/Select transport [1-9]/' \
  -e '/^    10|tun) TRANSPORT="tun" ;;$/d' \
  -e 's/|anytls|tun)/|anytls)/' \
  -e 's/Remove ${SEL_SERVICE}? Type YES to confirm:/Remove ${SEL_SERVICE}? [y\/N]:/' \
  -e 's/if \[\[ "$confirm" == "YES" \]\]; then/confirm="${confirm,,}"; if [[ "$confirm" == "y" || "$confirm" == "yes" ]]; then/' \
  -e 's@          rm -f "$SEL_UNIT" "$f"@          rm -f "$SEL_UNIT" "$f"\n          rm -f -- "${SEL_UNIT}.bak-"* "${f}.bak-"* 2>/dev/null || true@' \
  -e 's/Type REMOVE to confirm complete removal:/Continue with complete removal? [y\/N]:/' \
  -e 's/\[\[ "$confirm" == "REMOVE" \]\] || return/confirm="${confirm,,}"; [[ "$confirm" == "y" || "$confirm" == "yes" ]] || return/')"

printf '%s\n' "$patched" | bash -n
grep -Fq 'Select transport [1-9]' <<<"$patched" || fail 'Layer-4 transport menu was not patched.'
! grep -Fq '10) tun' <<<"$patched" || fail 'Unsupported legacy TUN remains visible.'
! grep -Fq '10|tun) TRANSPORT="tun"' <<<"$patched" || fail 'Unsupported legacy TUN remains selectable.'
grep -Fq 'Remove ${SEL_SERVICE}? [y/N]:' <<<"$patched" || fail 'Lowercase tunnel removal prompt is missing.'
grep -Fq '"${SEL_UNIT}.bak-"*' <<<"$patched" || fail 'Per-tunnel backup cleanup is missing.'
grep -Fq 'Continue with complete removal? [y/N]:' <<<"$patched" || fail 'Lowercase full removal prompt is missing.'

printf '[PASS] Standard Backhaul wrapper tests passed.\n'
