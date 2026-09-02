#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$PROJECT_DIR/scripts/portmap.sh"
TMP_DIR="$(mktemp -d -t v2quantum-portmap-test.XXXXXX)"

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2quantum-portmap-test.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

CONFIG_DIR="$TMP_DIR/config"
IPTABLES="$TMP_DIR/iptables"
IP="$TMP_DIR/ip"
SYSCTL="$TMP_DIR/sysctl"
IPTABLES_STATE="$TMP_DIR/iptables.state"
IPTABLES_LOG="$TMP_DIR/iptables.log"
SYSCTL_LOG="$TMP_DIR/sysctl.log"
mkdir -p "$CONFIG_DIR"
: >"$IPTABLES_STATE"
: >"$IPTABLES_LOG"

cat >"$IPTABLES" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${V2Q_TEST_IPTABLES_LOG:?}"
operation=""
for argument in "$@"; do
  case "$argument" in
    -C|-I|-D) operation="$argument"; break ;;
  esac
done
signature="$(printf '%s\n' "$*" | sed -E -e 's/ -(C|I|D) / -RULE /' -e 's/( -RULE [^ ]+) 1 /\1 /')"
if [[ "$operation" == "-I" && -n "${V2Q_TEST_FAIL_INSERT:-}" && "$signature" == *"$V2Q_TEST_FAIL_INSERT"* ]]; then
  exit 1
fi
case "$operation" in
  -C)
    grep -Fqx -- "$signature" "${V2Q_TEST_IPTABLES_STATE:?}"
    ;;
  -I)
    grep -Fqx -- "$signature" "${V2Q_TEST_IPTABLES_STATE:?}" 2>/dev/null || \
      printf '%s\n' "$signature" >>"${V2Q_TEST_IPTABLES_STATE:?}"
    ;;
  -D)
    grep -Fqx -- "$signature" "${V2Q_TEST_IPTABLES_STATE:?}" || exit 1
    grep -Fvx -- "$signature" "${V2Q_TEST_IPTABLES_STATE:?}" >"${V2Q_TEST_IPTABLES_STATE:?}.new" || true
    mv "${V2Q_TEST_IPTABLES_STATE:?}.new" "${V2Q_TEST_IPTABLES_STATE:?}"
    ;;
  *) exit 2 ;;
esac
EOF

cat >"$IP" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "link show dev v2q12345678" ]]
EOF

cat >"$SYSCTL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${V2Q_TEST_SYSCTL_LOG:?}"
[[ "$*" == "-q -w net.ipv4.ip_forward=1" ]]
EOF
chmod 755 "$IPTABLES" "$IP" "$SYSCTL"

cat >"$CONFIG_DIR/iran-test.portmap" <<'EOF'
VERSION=1
DEVICE=v2q12345678
LOCAL_IP=10.77.0.1
PEER_IP=10.77.0.2
PUBLIC_INTERFACE=eth0
MAP=443=443
EOF

run_helper() {
  env \
    V2QUANTUM_CONFIG_DIR="$CONFIG_DIR" \
    V2QUANTUM_IPTABLES="$IPTABLES" \
    V2QUANTUM_IP="$IP" \
    V2QUANTUM_SYSCTL="$SYSCTL" \
    V2Q_TEST_IPTABLES_STATE="$IPTABLES_STATE" \
    V2Q_TEST_IPTABLES_LOG="$IPTABLES_LOG" \
    V2Q_TEST_SYSCTL_LOG="$SYSCTL_LOG" \
    bash "$HELPER" "$@"
}

run_helper apply iran-test
test "$(wc -l <"$IPTABLES_STATE")" -eq 5
grep -q -- '-j DNAT --to-destination 10.77.0.2:443' "$IPTABLES_STATE"
grep -q -- '-j SNAT --to-source 10.77.0.1' "$IPTABLES_STATE"
test "$(grep -c -- '-t filter -RULE FORWARD' "$IPTABLES_STATE")" -eq 2
grep -q -- '-j TCPMSS --clamp-mss-to-pmtu' "$IPTABLES_STATE"
grep -q '^\-q -w net.ipv4.ip_forward=1$' "$SYSCTL_LOG"

# Applying twice is idempotent and must not duplicate a firewall rule.
run_helper apply iran-test
test "$(wc -l <"$IPTABLES_STATE")" -eq 5
test "$(grep -c -- ' -I ' "$IPTABLES_LOG")" -eq 5

run_helper remove iran-test
test ! -s "$IPTABLES_STATE"

# A partial apply failure rolls back every rule already inserted in that attempt.
if V2Q_TEST_FAIL_INSERT=':forward' run_helper apply iran-test >/dev/null 2>&1; then
  echo "injected iptables failure unexpectedly succeeded" >&2
  exit 1
fi
test ! -s "$IPTABLES_STATE"

# Configuration is parsed as data; unknown shell-like keys are rejected, never sourced.
printf 'TOUCH=%s\n' "$TMP_DIR/should-not-exist" >>"$CONFIG_DIR/iran-test.portmap"
if run_helper apply iran-test >/dev/null 2>&1; then
  echo "invalid portmap configuration was accepted" >&2
  exit 1
fi
test ! -e "$TMP_DIR/should-not-exist"

echo "portmap isolation tests passed"
