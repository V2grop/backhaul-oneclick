#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/oneclick-xhttp-cdn.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
TMP_DIR="$TEST_DIR"
fail() { echo "FAIL: $*" >&2; exit 1; }
INSTANCE=cf1 DOMAIN=cdn.example.com UUID=123e4567-e89b-12d3-a456-426614174000
XHTTP_PATH=/xhttp-abcdef123456 XHTTP_MODE=auto EDGE_PORT=443 ORIGIN_PORT=18080
TUNNEL_DIRECTION=direct TRAFFIC_SCOPE=ports CLEAN_IP=104.16.1.1
BIND_ADDRESS=0.0.0.0 TARGET_HOST=127.0.0.1
parse_mappings '2444=8444'
code="$(make_setup_code_v2)"
reverse_code="XHC2_$(printf '%s' "$(base64url_decode "${code#XHC2_}")" | sed 's/2|direct|/2|reverse|/' | base64url_encode)"
! (parse_setup_code "$reverse_code") || fail 'Legacy Reverse code accepted.'
! (TUNNEL_DIRECTION=reverse; make_setup_code_v2) || fail 'Reverse code generated.'
! bash "$ROOT_DIR/oneclick-xhttp-cdn.sh" reverse-server >/dev/null 2>&1 || fail 'Reverse CLI accepted.'
! (EDGE_PORT=8443; validate_client_values) || fail 'Auto/gRPC accepted port 8443.'
(EDGE_PORT=8443; XHTTP_MODE=packet-up; validate_client_values)
! (parse_mappings '2444=443'; validate_client_values) || fail 'Mapping loops into Nginx.'
! (parse_mappings '2444=18080'; validate_client_values) || fail 'Mapping loops into Xray.'
! (prompt_required 'Test EOF' unused </dev/null) 2>/dev/null || fail 'Required prompt ignored EOF.'
# Edge checks must not accept error pages, HTTP/1.1 or a different website.
(
  curl() {
    local output
    while (($#)); do
      if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
    done
    printf '%s' "${FAKE_BODY:-xhttp-direct-origin-ok}" >"$output"
    printf '%s|104.16.1.1|%s' "$FAKE_STATUS" "${FAKE_HTTP_VERSION:-2}"
  }
  for FAKE_STATUS in 403 502 504 521 522 523 525 526 301 429; do
    ! test_clean_ip "$DOMAIN" "$CLEAN_IP" 443 "$XHTTP_PATH" || fail "HTTP $FAKE_STATUS accepted."
  done
  FAKE_STATUS=200
  test_clean_ip "$DOMAIN" "$CLEAN_IP" 443 "$XHTTP_PATH"
  FAKE_BODY='Different website'
  ! test_clean_ip "$DOMAIN" "$CLEAN_IP" 443 "$XHTTP_PATH" || fail 'Wrong origin accepted.'
  FAKE_BODY=xhttp-direct-origin-ok FAKE_HTTP_VERSION=1.1
  ! test_clean_ip "$DOMAIN" "$CLEAN_IP" 443 "$XHTTP_PATH" || fail 'HTTP/1.1 accepted.'
)
# Streamed invocation must retain error handling when saved as a regular file.
mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/bash" <<'EOF'
#!/bin/bash
if [[ "$1" == -n ]]; then cp "$2" "$CAPTURED_SCRIPT"; fi
exec /bin/bash "$@"
EOF
chmod +x "$TEST_DIR/bin/bash"
CAPTURED_SCRIPT="$TEST_DIR/captured.sh" PATH="$TEST_DIR/bin:$PATH" \
  /bin/bash <(cat "$ROOT_DIR/oneclick-xhttp-cdn.sh") --version >"$TEST_DIR/version"
grep -qx 'xhttp-cdn-manager 3.0.1' "$TEST_DIR/version"
grep -qx 'set -Eeuo pipefail' "$TEST_DIR/captured.sh"
grep -qx 'umask 027' "$TEST_DIR/captured.sh"
bash -n "$TEST_DIR/captured.sh"
# The executable body survives the stream exactly.
sed -n '/^SCRIPT_VERSION=/,$p' "$ROOT_DIR/oneclick-xhttp-cdn.sh" >"$TEST_DIR/original-body"
sed -n '/^SCRIPT_VERSION=/,$p' "$TEST_DIR/captured.sh" >"$TEST_DIR/captured-body"
cmp "$TEST_DIR/original-body" "$TEST_DIR/captured-body"
# Packet-up has an HTTP upstream; stream-up/auto has an H2 gRPC upstream.
TLS_CERT=/tmp/test.crt TLS_KEY=/tmp/test.key
XHTTP_MODE=packet-up
write_nginx_config "$TEST_DIR/packet.conf"
grep -Fq 'proxy_pass http://127.0.0.1:18080;' "$TEST_DIR/packet.conf"
! grep -q grpc_pass "$TEST_DIR/packet.conf"
XHTTP_MODE=stream-up
write_nginx_config "$TEST_DIR/stream.conf"
grep -Fq 'grpc_pass grpc://127.0.0.1:18080;' "$TEST_DIR/stream.conf"
grep -Fq 'location = /xhttp-abcdef123456/health' "$TEST_DIR/stream.conf"
printf '[PASS] XHTTP Direct regression tests passed.\n'
