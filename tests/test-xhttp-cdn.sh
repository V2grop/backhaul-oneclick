#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="${ROOT_DIR}/oneclick-xhttp-cdn.sh"
TEST_DIR="$(mktemp -d -t xhttp-cdn-test.XXXXXX)"

cleanup() {
  if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" && "$TEST_DIR" == /tmp/xhttp-cdn-test.* ]]; then
    rm -rf -- "$TEST_DIR"
  fi
}
trap cleanup EXIT

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

assert_jq() {
  local file="$1" expression="$2" message="$3"
  jq -e "$expression" "$file" >/dev/null || fail "$message"
}

bash -n "$MANAGER"
source "$MANAGER"

# With the manager's umask 027, fresh program directories start as 0750 and a
# root-owned path cannot be traversed by the xhttp-cdn service user. The repair
# helper must make only the isolated runtime path executable while configs stay
# protected separately under CONFIG_DIR.
(
  BASE_DIR="$TEST_DIR/runtime/opt/xhttp-cdn"
  BIN_DIR="$BASE_DIR/bin"
  BIN="$BIN_DIR/xray"
  mkdir -p "$BIN_DIR"
  : >"$BIN"
  chmod 750 "$BASE_DIR" "$BIN_DIR" "$BIN"
  ensure_xray_runtime_access
  [[ "$(stat -c '%a' "$BASE_DIR")" == 755 ]] || fail 'Xray base directory is not service-traversable.'
  [[ "$(stat -c '%a' "$BIN_DIR")" == 755 ]] || fail 'Xray binary directory is not service-traversable.'
  [[ "$(stat -c '%a' "$BIN")" == 755 ]] || fail 'Xray binary is not executable by the service user.'
)

validate_instance cf1 || fail 'Valid instance name rejected.'
! validate_instance '../cf1' || fail 'Unsafe instance name accepted.'
validate_domain cdn.example.com || fail 'Valid domain rejected.'
! validate_domain 'cdn..example.com' || fail 'Invalid domain accepted.'
validate_ipv4 104.16.1.1 || fail 'Valid clean IPv4 rejected.'
! validate_ipv4 999.16.1.1 || fail 'Invalid IPv4 accepted.'
validate_xhttp_path /xhttp-abcdef123456 || fail 'Valid XHTTP path rejected.'
! validate_xhttp_path '/short' || fail 'Short XHTTP path accepted.'
validate_cert_mode letsencrypt || fail 'Let\x27s Encrypt certificate mode rejected.'
validate_cert_mode self-signed || fail 'Self-signed certificate mode rejected.'
validate_cert_mode existing || fail 'Existing certificate mode rejected.'
! validate_cert_mode flexible || fail 'Unsupported no-TLS certificate mode accepted.'
validate_email admin@example.com || fail 'Valid ACME email rejected.'
! validate_email admin-at-example.com || fail 'Invalid ACME email accepted.'
validate_cloudflare_token 0123456789abcdef0123456789abcdef01234567 || fail 'Valid Cloudflare token rejected.'
! validate_cloudflare_token short || fail 'Short Cloudflare token accepted.'

show_server_install_guide >"$TEST_DIR/server-guide.txt"
grep -Fq 'FOREIGN_SERVER_IP' "$TEST_DIR/server-guide.txt" || fail 'Foreign guide does not label the foreign IP.'
grep -Fq 'Enter only CDN_HOSTNAME.' "$TEST_DIR/server-guide.txt" || fail 'Easy foreign guide does not describe its single input.'
show_client_install_guide >"$TEST_DIR/client-guide.txt"
grep -Fq 'IRAN_PORT=FOREIGN_SERVICE_PORT' "$TEST_DIR/client-guide.txt" || fail 'Iran guide does not explain the mapping direction.'
grep -Fq 'Do not enter FOREIGN_SERVER_IP as CLEAN_CLOUDFLARE_IP.' "$TEST_DIR/client-guide.txt" || fail 'Iran guide does not distinguish the clean IP.'
parse_mappings '2444=443,2083,8443=8443' || fail 'Valid mappings rejected.'
[[ "${MAPPING_LISTEN_PORTS[*]}" == '2444 2083 8443' ]] || fail 'Listen ports parsed incorrectly.'
[[ "${MAPPING_TARGET_PORTS[*]}" == '443 2083 8443' ]] || fail 'Target ports parsed incorrectly.'
! parse_mappings '2444=443,2444=8443' || fail 'Duplicate local mapping accepted.'

(
  collect_server_easy_values <<< $'cdn.example.com\n'
  [[ "$INSTANCE" == cf1 ]] || fail 'Easy foreign setup did not select the default instance.'
  [[ "$DOMAIN" == cdn.example.com ]] || fail 'Easy foreign setup did not accept the hostname.'
  [[ "$ORIGIN_PORT" == 18080 ]] || fail 'Easy foreign setup did not select its internal port.'
  validate_uuid "$UUID" || fail 'Easy foreign setup did not generate a valid UUID.'
  validate_xhttp_path "$XHTTP_PATH" || fail 'Easy foreign setup did not generate a valid secret path.'
  [[ "$XHTTP_MODE" == auto ]] || fail 'Easy foreign setup did not select automatic XHTTP mode.'
  [[ "$CERT_MODE" == self-signed ]] || fail 'Easy foreign setup did not select its zero-input certificate.'
)

DOMAIN=cdn.example.com
UUID=123e4567-e89b-12d3-a456-426614174000
XHTTP_PATH=/xhttp-abcdef123456
XHTTP_MODE=auto
code="$(make_setup_code)"
[[ "$code" == XHC1_* ]] || fail 'Setup code prefix is missing.'
easy_command="$(make_iran_easy_command "$code")"
[[ "$easy_command" == *'XHTTP_CDN_SETUP_CODE=XHC1_'* ]] || fail 'Easy Iran command does not carry the private setup data.'
[[ "$easy_command" == *' easy-client' ]] || fail 'Easy Iran command does not launch the automatic client workflow.'
[[ "$easy_command" == *'oneclick-xhttp-cdn.sh'*'?cb='* ]] || fail 'Easy Iran command does not bypass stale Raw GitHub cache.'
bash -n <<<"$easy_command" || fail 'Generated easy Iran command is not valid Bash.'
DOMAIN='' UUID='' XHTTP_PATH='' XHTTP_MODE='' EDGE_PORT=''
parse_setup_code "$code" || fail 'Generated setup code could not be parsed.'
[[ "$DOMAIN" == cdn.example.com ]] || fail 'Setup code domain mismatch.'
[[ "$UUID" == 123e4567-e89b-12d3-a456-426614174000 ]] || fail 'Setup code UUID mismatch.'
[[ "$XHTTP_PATH" == /xhttp-abcdef123456 ]] || fail 'Setup code path mismatch.'
[[ "$EDGE_PORT" == 443 && "$XHTTP_MODE" == auto ]] || fail 'Setup code transport mismatch.'
! parse_setup_code 'XHC1_broken' || fail 'Damaged setup code accepted.'

(
  collect_client_easy_values "$code" <<< $'104.16.1.1\n2444=8444,2083=2083\n'
  [[ "$INSTANCE" == cf1 ]] || fail 'Easy Iran workflow did not select the default instance.'
  [[ "$CLEAN_IP" == 104.16.1.1 ]] || fail 'Easy Iran workflow did not accept the clean IP.'
  [[ "$BIND_ADDRESS" == 0.0.0.0 ]] || fail 'Easy Iran workflow did not use the public bind default.'
  [[ "$TARGET_HOST" == 127.0.0.1 ]] || fail 'Easy Iran workflow did not use the foreign loopback target.'
  [[ "${MAPPING_ITEMS[*]}" == '2444=8444 2083=2083' ]] || fail 'Easy Iran workflow parsed mappings incorrectly.'
)

usage >"$TEST_DIR/usage.txt"
grep -Fq 'xhttp-cdn-manager easy-client' "$TEST_DIR/usage.txt" || fail 'Easy Iran CLI is missing from help.'
grep -Fq 'xhttp-cdn-manager iran-command' "$TEST_DIR/usage.txt" || fail 'Iran command recovery is missing from help.'
grep -Fq 'xhttp-cdn-manager remove' "$TEST_DIR/usage.txt" || fail 'Easy removal is missing from help.'

INSTANCE=cf1
ORIGIN_PORT=18080
write_server_config "$TEST_DIR/server.json"
jq empty "$TEST_DIR/server.json"
assert_jq "$TEST_DIR/server.json" '.inbounds[0].listen == "127.0.0.1"' 'Server origin is not loopback-only.'
assert_jq "$TEST_DIR/server.json" '.inbounds[0].port == 18080' 'Server origin port mismatch.'
assert_jq "$TEST_DIR/server.json" '.inbounds[0].streamSettings.network == "xhttp"' 'Server transport is not XHTTP.'
assert_jq "$TEST_DIR/server.json" '.inbounds[0].streamSettings.security == "none"' 'Loopback Xray unexpectedly terminates TLS.'
assert_jq "$TEST_DIR/server.json" '.inbounds[0].streamSettings.xhttpSettings.mode == "auto"' 'Server XHTTP mode mismatch.'

parse_mappings '2444=443,2083=2083'
BIND_ADDRESS=0.0.0.0
TARGET_HOST=127.0.0.1
CLEAN_IP=104.16.1.1
write_client_config "$TEST_DIR/client.json"
jq empty "$TEST_DIR/client.json"
print_client_route_summary >"$TEST_DIR/client-route.txt"
grep -Fq 'IRAN_SERVER_IP:2444 -> 104.16.1.1:443 -> cdn.example.com -> 127.0.0.1:443' "$TEST_DIR/client-route.txt" || fail 'Final connection route is not explained correctly.'
assert_jq "$TEST_DIR/client.json" '.inbounds | length == 2' 'Client mapping count mismatch.'
assert_jq "$TEST_DIR/client.json" '.inbounds[0].port == 2444 and .inbounds[0].settings.port == 443' 'First mapping mismatch.'
assert_jq "$TEST_DIR/client.json" '.inbounds[1].port == 2083 and .inbounds[1].settings.port == 2083' 'Second mapping mismatch.'
assert_jq "$TEST_DIR/client.json" '.outbounds[0].settings.vnext[0].address == "104.16.1.1"' 'Clean IP is not the dial address.'
assert_jq "$TEST_DIR/client.json" '.outbounds[0].settings.vnext[0].port == 443' 'Cloudflare port is not 443.'
assert_jq "$TEST_DIR/client.json" '.outbounds[0].streamSettings.tlsSettings.serverName == "cdn.example.com"' 'TLS SNI mismatch.'
assert_jq "$TEST_DIR/client.json" '.outbounds[0].streamSettings.xhttpSettings.host == "cdn.example.com"' 'HTTP Host mismatch.'
assert_jq "$TEST_DIR/client.json" '.outbounds[0].streamSettings.xhttpSettings.path == "/xhttp-abcdef123456"' 'XHTTP path mismatch.'
assert_jq "$TEST_DIR/client.json" '.outbounds[0].streamSettings.tlsSettings.allowInsecure == false' 'TLS verification was disabled.'
assert_jq "$TEST_DIR/client.json" '(.outbounds[0] | has("mux")) | not' 'mux.cool must not be enabled for XHTTP.'

TLS_CERT=/etc/ssl/cloudflare/cdn.example.com.pem
TLS_KEY=/etc/ssl/cloudflare/cdn.example.com.key
write_nginx_config "$TEST_DIR/nginx.conf"
grep -Fq 'server_name cdn.example.com;' "$TEST_DIR/nginx.conf" || fail 'Nginx hostname missing.'
grep -Fq 'location ^~ /xhttp-abcdef123456 {' "$TEST_DIR/nginx.conf" || fail 'Nginx XHTTP path missing.'
grep -Fq 'grpc_pass grpc://127.0.0.1:18080;' "$TEST_DIR/nginx.conf" || fail 'Nginx loopback upstream mismatch.'
grep -Fq 'grpc_set_header CF-Connecting-IP $http_cf_connecting_ip;' "$TEST_DIR/nginx.conf" || fail 'Cloudflare client-IP forwarding missing.'

# A command that scrolled off-screen must be rebuildable from an existing
# foreign JSON/Nginx pair and stored root-only for menu option 2.
(
  CONFIG_DIR="$TEST_DIR/recover/config"
  SYSTEMD_DIR="$TEST_DIR/recover/systemd"
  NGINX_CONF_DIR="$TEST_DIR/recover/nginx"
  mkdir -p "$CONFIG_DIR" "$SYSTEMD_DIR" "$NGINX_CONF_DIR"
  INSTANCE=cf1
  DOMAIN=cdn.example.com
  UUID=123e4567-e89b-12d3-a456-426614174000
  XHTTP_PATH=/xhttp-abcdef123456
  XHTTP_MODE=auto
  ORIGIN_PORT=18080
  TLS_CERT=/etc/ssl/cloudflare/cdn.example.com.pem
  TLS_KEY=/etc/ssl/cloudflare/cdn.example.com.key
  service_paths server "$INSTANCE"
  write_server_config "$CONFIG"
  write_nginx_config "$NGINX_CONFIG"
  DOMAIN='' UUID='' XHTTP_PATH='' XHTTP_MODE='' ORIGIN_PORT=''
  print_iran_easy_command cf1 >"$TEST_DIR/recovered-command.txt"
  command_file="$(iran_command_file cf1)"
  [[ -s "$command_file" ]] || fail 'Recovered Iran command was not saved.'
  [[ "$(stat -c '%a' "$command_file")" == 600 ]] || fail 'Recovered Iran command is not root-only.'
  grep -Fq ' easy-client' "$command_file" || fail 'Recovered Iran command does not launch easy-client.'
  grep -Fq 'choose menu option 2' "$TEST_DIR/recovered-command.txt" || fail 'Command recovery instructions are missing.'
)

# With a single installation, deletion must auto-select it and require no role
# or instance-name entry. FORCE only skips the yes/no prompt in this test.
(
  CONFIG_DIR="$TEST_DIR/remove/config"
  SYSTEMD_DIR="$TEST_DIR/remove/systemd"
  NGINX_CONF_DIR="$TEST_DIR/remove/nginx"
  CERT_DIR="$TEST_DIR/remove/certs"
  CERTBOT_CREDENTIALS_DIR="$TEST_DIR/remove/certbot"
  mkdir -p "$CONFIG_DIR" "$SYSTEMD_DIR" "$NGINX_CONF_DIR" "$CERT_DIR" "$CERTBOT_CREDENTIALS_DIR"
  : >"$CONFIG_DIR/server-cf1.json"
  : >"$SYSTEMD_DIR/xhttp-cdn-server-cf1.service"
  : >"$NGINX_CONF_DIR/xhttp-cdn-cf1.conf"
  : >"$CONFIG_DIR/iran-install-cf1.txt"
  : >"$CERT_DIR/cf1.crt"
  : >"$CERT_DIR/cf1.key"
  : >"$CERTBOT_CREDENTIALS_DIR/cloudflare-cf1.ini"
  systemctl() { return 0; }
  nginx() { return 0; }
  FORCE=true
  remove_instance_interactive </dev/null
  [[ ! -e "$CONFIG_DIR/server-cf1.json" ]] || fail 'Easy deletion left the server configuration behind.'
  [[ ! -e "$SYSTEMD_DIR/xhttp-cdn-server-cf1.service" ]] || fail 'Easy deletion left the service unit behind.'
  [[ ! -e "$NGINX_CONF_DIR/xhttp-cdn-cf1.conf" ]] || fail 'Easy deletion left the Nginx configuration behind.'
  [[ ! -e "$CONFIG_DIR/iran-install-cf1.txt" ]] || fail 'Easy deletion left the saved Iran command behind.'
)

SERVICE_USER=xhttp-cdn
BIN=/opt/xhttp-cdn/bin/xray
write_unit "$TEST_DIR/client.service" client cf1 /etc/xhttp-cdn/client-cf1.json
grep -Fq 'ExecStart=/opt/xhttp-cdn/bin/xray run -config /etc/xhttp-cdn/client-cf1.json' "$TEST_DIR/client.service" || fail 'Isolated binary/config paths missing.'
grep -Fq 'NoNewPrivileges=true' "$TEST_DIR/client.service" || fail 'Systemd hardening missing.'
grep -Fq 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$TEST_DIR/client.service" || fail 'Low-port capability is not bounded.'

# The zero-input certificate option must produce an isolated keypair without
# touching Nginx, Xray, Backhaul, or another certificate directory.
TMP_DIR="$TEST_DIR/manager-tmp"
CERT_DIR="$TEST_DIR/certs"
mkdir -p "$TMP_DIR"
generate_self_signed_certificate
[[ "$TLS_CERT" == "$TEST_DIR/certs/cf1.crt" ]] || fail 'Self-signed certificate path escaped the isolated directory.'
[[ "$TLS_KEY" == "$TEST_DIR/certs/cf1.key" ]] || fail 'Self-signed key path escaped the isolated directory.'
openssl x509 -in "$TLS_CERT" -noout -subject | grep -Fq 'CN = cdn.example.com' || fail 'Self-signed certificate CN mismatch.'
openssl x509 -in "$TLS_CERT" -noout -ext subjectAltName | grep -Fq 'DNS:cdn.example.com' || fail 'Self-signed certificate SAN mismatch.'
[[ "$(stat -c '%a' "$TLS_KEY")" == 600 ]] || fail 'Self-signed private key permissions are unsafe.'

# Exercise the automatic DNS-01 plumbing with a fake Certbot. The token must be
# stored in a root-only file and never added to an Xray or Nginx config.
FAKE_CERTBOT="$TEST_DIR/fake-certbot"
cat >"$FAKE_CERTBOT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "plugins" ]]; then
  echo '* dns-cloudflare'
  exit 0
fi
[[ "${1:-}" == "certonly" ]] || exit 2
cert_name=''
while (( $# > 0 )); do
  case "$1" in
    --cert-name) cert_name="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "${XHTTP_TEST_LE_LIVE_DIR:?}/${cert_name}"
: >"${XHTTP_TEST_LE_LIVE_DIR}/${cert_name}/fullchain.pem"
: >"${XHTTP_TEST_LE_LIVE_DIR}/${cert_name}/privkey.pem"
EOF
chmod 755 "$FAKE_CERTBOT"
CERTBOT_BIN="$FAKE_CERTBOT"
CERTBOT_CREDENTIALS_DIR="$TEST_DIR/certbot"
LE_LIVE_DIR="$TEST_DIR/letsencrypt/live"
LE_RENEW_HOOK="$TEST_DIR/renewal-hooks/deploy/reload-nginx"
ACME_EMAIL=admin@example.com
CF_API_TOKEN=0123456789abcdef0123456789abcdef01234567
systemctl() { return 1; }
XHTTP_TEST_LE_LIVE_DIR="$LE_LIVE_DIR" obtain_letsencrypt_certificate
[[ "$TLS_CERT" == "$LE_LIVE_DIR/xhttp-cdn-cf1/fullchain.pem" ]] || fail 'Let\x27s Encrypt certificate path mismatch.'
[[ "$(stat -c '%a' "$CERTBOT_CREDENTIALS_DIR/cloudflare-cf1.ini")" == 600 ]] || fail 'Cloudflare credential permissions are unsafe.'
grep -Fq 'dns_cloudflare_api_token = ' "$CERTBOT_CREDENTIALS_DIR/cloudflare-cf1.ini" || fail 'Cloudflare token file was not created.'
[[ -x "$LE_RENEW_HOOK" ]] || fail 'Certbot renewal reload hook is missing.'
! grep -Fq 'dns_cloudflare_api_token' "$TEST_DIR/server.json" || fail 'Cloudflare token leaked into Xray config.'
! grep -Fq 'dns_cloudflare_api_token' "$TEST_DIR/nginx.conf" || fail 'Cloudflare token leaked into Nginx config.'

[[ "$BASE_DIR" == /opt/xhttp-cdn ]] || fail 'Default base directory is not isolated.'
[[ "$CONFIG_DIR" == /etc/xhttp-cdn ]] || fail 'Default configuration directory is not isolated.'

if [[ -n "${XRAY_TEST_BIN:-}" ]]; then
  "$XRAY_TEST_BIN" run -test -config "$TEST_DIR/server.json"
  "$XRAY_TEST_BIN" run -test -config "$TEST_DIR/client.json"
fi

# v2 profile/mapping coverage: TCP and UDP may share a local number, while a
# duplicate protocol or a `both` collision must be rejected.
parse_mappings 'tcp:2444=8444,udp:2444=8443,both:5353=53' \
  || fail 'Protocol-aware mappings were rejected.'
[[ "${MAPPING_PROTOCOLS[*]}" == 'tcp udp both' ]] || fail 'Mapping protocols were not preserved.'
[[ "$(serialize_mappings)" == 'tcp:2444=8444,udp:2444=8443,both:5353=53' ]] \
  || fail 'Canonical mapping serialization is wrong.'
! parse_mappings 'tcp:2444=8444,tcp:2444=443' || fail 'Exact protocol collision accepted.'
! parse_mappings 'both:5353=53,udp:5353=53' || fail '`both` protocol collision accepted.'
! parse_mappings 'tcp:1=2,,udp:3=4' || fail 'Malformed comma mapping accepted.'

validate_edge_port 443 || fail 'Cloudflare default edge port rejected.'
validate_edge_port 8443 || fail 'Cloudflare alternate edge port rejected.'
! validate_edge_port 80 || fail 'Unsupported edge port accepted.'
ALLOW_CUSTOM_EDGE_PORT=1
validate_edge_port 80 || fail 'Custom edge port override rejected.'
ALLOW_CUSTOM_EDGE_PORT=0
validate_direction reverse || fail 'Reverse direction rejected.'
validate_scope all || fail 'All traffic scope rejected.'
validate_tun_name xhttp0 || fail 'Valid TUN name rejected.'
! validate_tun_name 0bad || fail 'Invalid TUN name accepted.'
validate_tun_gateway 172.30.0.1/30 || fail 'Valid TUN gateway rejected.'
validate_dns_list '1.1.1.1,8.8.8.8' || fail 'Valid DNS list rejected.'

# Full XHC2 pairing round-trip, including reverse direction and every profile
# field. The code is deliberately opaque so UUID/path values are not printed
# into the normal prompts.
INSTANCE=rev1
DOMAIN=cdn.example.com
UUID=123e4567-e89b-12d3-a456-426614174000
XHTTP_PATH=/xhttp-abcdef123456
XHTTP_MODE=auto
EDGE_PORT=8443
TUNNEL_DIRECTION=reverse
TRAFFIC_SCOPE=all
ORIGIN_PORT=18080
SOCKS_PORT=10808
SOCKS_BIND=127.0.0.1
TUN_NAME=xhttp0
TUN_MTU=1500
TUN_GATEWAY=172.30.0.1/30
TUN_DNS='1.1.1.1,8.8.8.8'
parse_mappings 'tcp:2444=8444,udp:5353=53,both:8443=8443' || fail 'Full mapping setup failed.'
xhc2_code="$(make_setup_code_v2)"
[[ "$xhc2_code" == XHC2_* ]] || fail 'XHC2 prefix is missing.'
DOMAIN=''; UUID=''; XHTTP_PATH=''; EDGE_PORT=''; TUNNEL_DIRECTION=''; TRAFFIC_SCOPE=''
parse_setup_code "$xhc2_code" || fail 'XHC2 setup code could not be parsed.'
[[ "$INSTANCE" == rev1 && "$TUNNEL_DIRECTION" == reverse && "$TRAFFIC_SCOPE" == all ]] \
  || fail 'XHC2 direction/profile mismatch.'
[[ "$EDGE_PORT" == 8443 && "$SOCKS_PORT" == 10808 && "$TUN_NAME" == xhttp0 ]] \
  || fail 'XHC2 optional settings mismatch.'
[[ "$(serialize_mappings)" == 'tcp:2444=8444,udp:5353=53,both:8443=8443' ]] \
  || fail 'XHC2 mappings mismatch.'

# Generate every inbound in the all profile and validate it with the official
# Xray binary when the test runner provides one.
CLEAN_IP=104.16.1.1
BIND_ADDRESS=0.0.0.0
TARGET_HOST=127.0.0.1
write_client_config "$TEST_DIR/client-all.json"
assert_jq "$TEST_DIR/client-all.json" '.inbounds | length == 5' 'All profile inbound count mismatch.'
assert_jq "$TEST_DIR/client-all.json" '[.inbounds[].protocol] | index("socks") != null' 'SOCKS inbound missing from all profile.'
assert_jq "$TEST_DIR/client-all.json" '[.inbounds[].protocol] | index("tun") != null' 'TUN inbound missing from all profile.'
assert_jq "$TEST_DIR/client-all.json" '.inbounds[] | select(.protocol == "tun") | .settings.autoSystemRoutingTable == ["0.0.0.0/0"]' 'TUN default route missing.'
assert_jq "$TEST_DIR/client-all.json" '.outbounds[0].streamSettings.xhttpSettings.extra.xmux.maxConcurrency == "8-16"' 'Native XMUX concurrency missing.'
assert_jq "$TEST_DIR/client-all.json" '.outbounds[0].streamSettings.xhttpSettings.extra.xmux.maxConnections == 0' 'Native XMUX maxConnections mismatch.'
assert_jq "$TEST_DIR/client-all.json" '(.outbounds[0] | has("mux")) | not' 'Legacy mux unexpectedly enabled.'

TRAFFIC_SCOPE=all
write_unit "$TEST_DIR/client-all.service" client rev1 /etc/xhttp-cdn/client-rev1.json
grep -Fq 'ExecStartPre=/opt/xhttp-cdn/bin/xray run -test -config /etc/xhttp-cdn/client-rev1.json' "$TEST_DIR/client-all.service" || fail 'Xray preflight is missing.'
grep -Fq 'AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE' "$TEST_DIR/client-all.service" || fail 'TUN capabilities are missing.'
grep -Fq 'AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW' "$TEST_DIR/client-all.service" || fail 'TUN socket interface capability is missing.'
grep -Fq 'DeviceAllow=/dev/net/tun rw' "$TEST_DIR/client-all.service" || fail 'TUN device permission is missing.'

SYSTEMD_DIR="$TEST_DIR/watchdog-systemd"
mkdir -p "$SYSTEMD_DIR"
WATCHDOG_INTERVAL=60
write_watchdog_units xhttp-cdn-client-rev1
grep -Fq 'OnUnitActiveSec=60s' "$SYSTEMD_DIR/xhttp-cdn-client-rev1-watchdog.timer" || fail 'Watchdog interval is wrong.'
grep -Fq 'systemctl restart xhttp-cdn-client-rev1.service' "$SYSTEMD_DIR/xhttp-cdn-client-rev1-watchdog.service" || fail 'Watchdog restart action is missing.'

EDGE_PORT=443
TLS_CERT=/etc/ssl/cloudflare/cdn.example.com.pem
TLS_KEY=/etc/ssl/cloudflare/cdn.example.com.key
write_nginx_config "$TEST_DIR/nginx-buffering.conf"
grep -Fq 'proxy_buffering off;' "$TEST_DIR/nginx-buffering.conf" || fail 'Nginx proxy buffering is enabled.'
grep -Fq 'proxy_request_buffering off;' "$TEST_DIR/nginx-buffering.conf" || fail 'Nginx request buffering is enabled.'
grep -Fq 'grpc_buffer_size 16k;' "$TEST_DIR/nginx-buffering.conf" || fail 'Nginx gRPC buffer tuning is missing.'

if [[ -n "${XRAY_TEST_BIN:-}" ]]; then
  "$XRAY_TEST_BIN" run -test -config "$TEST_DIR/client-all.json"
fi

printf '[PASS] Independent XHTTP CDN configuration tests passed.\n'
