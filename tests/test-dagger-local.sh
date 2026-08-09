#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT_DIR/oneclick-dagger-local.sh"
TMP_DIR="$(mktemp -d -t dagger-local-test.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/dagger-local-test.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

SETUP_FIXTURE="$TMP_DIR/setup.sh"
BINARY_FIXTURE="$TMP_DIR/DaggerConnect3.2.patched"
LOG="$TMP_DIR/setup.log"

cat >"$SETUP_FIXTURE" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS= read -r supplied_binary
test -f "$supplied_binary"
printf 'setup-ran\n' >"${DAGGER_TEST_LOG:?}"
printf 'binary-sha=%s\n' "$(sha256sum "$supplied_binary" | awk '{print $1}')" >>"$DAGGER_TEST_LOG"
IFS= read -r menu_choice || true
printf 'menu-choice=%s\n' "${menu_choice:-}" >>"$DAGGER_TEST_LOG"
EOF
printf 'local binary fixture\n' >"$BINARY_FIXTURE"
chmod 755 "$SETUP_FIXTURE" "$BINARY_FIXTURE"

setup_sha="$(sha256sum "$SETUP_FIXTURE" | awk '{print $1}')"
binary_sha="$(sha256sum "$BINARY_FIXTURE" | awk '{print $1}')"
setup_before="$setup_sha"
binary_before="$binary_sha"

bash -n "$ADAPTER"
grep -q 'DEFAULT_SETUP_SHA256="1f8893c74381bc84b73bdc1f68dadc2f8f39c1ce5b66402d71f77f5394535ad3"' "$ADAPTER"
grep -q 'DEFAULT_BINARY_SHA256="ac19385f703c9db5bf3bb50c66fe874f53478d307f31f3fc6defc74c49ffddbc"' "$ADAPTER"

env \
  DAGGER_SETUP_PATH="$SETUP_FIXTURE" \
  DAGGER_BINARY_PATH="$BINARY_FIXTURE" \
  DAGGER_EXPECTED_SETUP_SHA256="$setup_sha" \
  DAGGER_EXPECTED_BINARY_SHA256="$binary_sha" \
  bash "$ADAPTER" --check-only >/dev/null
test ! -e "$LOG"

printf '0\n' | env \
  DAGGER_SETUP_PATH="$SETUP_FIXTURE" \
  DAGGER_BINARY_PATH="$BINARY_FIXTURE" \
  DAGGER_EXPECTED_SETUP_SHA256="$setup_sha" \
  DAGGER_EXPECTED_BINARY_SHA256="$binary_sha" \
  DAGGER_INSTALLED_BINARY="$TMP_DIR/not-installed" \
  DAGGER_LOCAL_SKIP_ROOT_CHECK=1 \
  DAGGER_TEST_LOG="$LOG" \
  bash "$ADAPTER" -y >/dev/null

grep -qx 'setup-ran' "$LOG"
grep -qx "binary-sha=$binary_sha" "$LOG"
grep -qx 'menu-choice=0' "$LOG"
test "$(sha256sum "$SETUP_FIXTURE" | awk '{print $1}')" = "$setup_before"
test "$(sha256sum "$BINARY_FIXTURE" | awk '{print $1}')" = "$binary_before"

if env \
  DAGGER_SETUP_PATH="$SETUP_FIXTURE" \
  DAGGER_BINARY_PATH="$BINARY_FIXTURE" \
  DAGGER_EXPECTED_SETUP_SHA256="$setup_sha" \
  DAGGER_EXPECTED_BINARY_SHA256="$(printf '0%.0s' {1..64})" \
  bash "$ADAPTER" --check-only >/dev/null 2>&1; then
  echo "checksum mismatch was accepted" >&2
  exit 1
fi

echo "Dagger local adapter tests passed"
