#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="$PROJECT_DIR/fusionmux-oneclick.sh"
TMP_DIR="$(mktemp -d -t fusionmux-bootstrap-test.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/fusionmux-bootstrap-test.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

FAKE_BIN="$TMP_DIR/bin"
FIXTURE="$TMP_DIR/oneclick-universal.sh"
LOG="$TMP_DIR/result.log"
mkdir -p "$FAKE_BIN"

cat >"$FIXTURE" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' \
  "${TUNNEL_MANAGER_REPO:-}" "${TUNNEL_MANAGER_REF:-}" "$*" \
  >>"${FUSION_BOOTSTRAP_TEST_LOG:?}"
EOF

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
destination=""
while (( $# > 0 )); do
  if [[ "$1" == "-o" ]]; then
    destination="${2:-}"
    shift 2
    continue
  fi
  shift
done
cp "${FUSION_BOOTSTRAP_TEST_FIXTURE:?}" "$destination"
EOF
chmod 755 "$FAKE_BIN/curl" "$FIXTURE"

PATH="$FAKE_BIN:/usr/bin:/bin" \
FUSION_BOOTSTRAP_TEST_FIXTURE="$FIXTURE" \
FUSION_BOOTSTRAP_TEST_LOG="$LOG" \
V2QUANTUM_REPO=V2grop/backhaul-oneclick \
V2QUANTUM_REF=codex/fusionmux-v1 \
bash "$BOOTSTRAP"

PATH="$FAKE_BIN:/usr/bin:/bin" \
FUSION_BOOTSTRAP_TEST_FIXTURE="$FIXTURE" \
FUSION_BOOTSTRAP_TEST_LOG="$LOG" \
TUNNEL_MANAGER_REPO=V2grop/backhaul-oneclick \
TUNNEL_MANAGER_REF=codex/fusionmux-v1 \
bash "$BOOTSTRAP" --fusion

grep -qx 'V2grop/backhaul-oneclick|codex/fusionmux-v1|' "$LOG"
grep -qx 'V2grop/backhaul-oneclick|codex/fusionmux-v1|--fusion' "$LOG"

echo "Unified compatibility bootstrap tests passed"
