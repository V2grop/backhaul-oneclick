#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Independent XHTTP/CDN endpoint and full-tunnel manager.
#
# This manager deliberately does not reuse or modify an existing Xray, X-UI,
# Backhaul, V2Quantum, Realm, Nginx server block, or systemd service.  It keeps
# its own Xray binary, JSON configurations, units, and Nginx snippets.

SCRIPT_VERSION="2.0.0"
REPO="${XHTTP_CDN_REPO:-V2grop/backhaul-oneclick}"
REF="${XHTTP_CDN_REF:-${TUNNEL_MANAGER_REF:-main}}"
RAW_BASE="${XHTTP_CDN_RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${REF}}"
SELF_URL="${XHTTP_CDN_SELF_URL:-${RAW_BASE}/oneclick-xhttp-cdn.sh}"
SOURCE_STATE="${XHTTP_CDN_SOURCE_STATE:-/etc/xhttp-cdn/source.env}"

# Preserve the selected repository branch for an installed manager. This is
# data-only parsing; the state file is never sourced as shell code.
if [[ -z "${XHTTP_CDN_REPO+x}" && -z "${XHTTP_CDN_REF+x}" && -r "$SOURCE_STATE" ]]; then
  stored_repo="$(awk -F= '$1 == "REPO" {sub(/^[^=]*=/, ""); print; exit}' "$SOURCE_STATE")"
  stored_ref="$(awk -F= '$1 == "REF" {sub(/^[^=]*=/, ""); print; exit}' "$SOURCE_STATE")"
  stored_self_url="$(awk -F= '$1 == "SELF_URL" {sub(/^[^=]*=/, ""); print; exit}' "$SOURCE_STATE")"
  if [[ "$stored_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ \
        && "$stored_ref" =~ ^[-A-Za-z0-9._/]+$ \
        && "$stored_ref" != /* && "$stored_ref" != *..* ]]; then
    REPO="$stored_repo"
    REF="$stored_ref"
    RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
    SELF_URL="${stored_self_url:-${RAW_BASE}/oneclick-xhttp-cdn.sh}"
  fi
  unset stored_repo stored_ref stored_self_url
fi

XRAY_VERSION="${XHTTP_CDN_XRAY_VERSION:-v26.7.28}"
XRAY_REPO="${XHTTP_CDN_XRAY_REPO:-XTLS/Xray-core}"
BASE_DIR="${XHTTP_CDN_BASE_DIR:-/opt/xhttp-cdn}"
BIN_DIR="${XHTTP_CDN_BIN_DIR:-${BASE_DIR}/bin}"
BIN="${XHTTP_CDN_BIN:-${BIN_DIR}/xray}"
CONFIG_DIR="${XHTTP_CDN_CONFIG_DIR:-/etc/xhttp-cdn}"
SYSTEMD_DIR="${XHTTP_CDN_SYSTEMD_DIR:-/etc/systemd/system}"
NGINX_ROOT="${XHTTP_CDN_NGINX_ROOT:-/etc/nginx}"
NGINX_CONF_DIR="${XHTTP_CDN_NGINX_CONF_DIR:-/etc/nginx/conf.d}"
SELF_PATH="${XHTTP_CDN_SELF_PATH:-/usr/local/sbin/xhttp-cdn-manager}"
SERVICE_USER="${XHTTP_CDN_SERVICE_USER:-xhttp-cdn}"
CERT_DIR="${XHTTP_CDN_CERT_DIR:-${CONFIG_DIR}/certs}"
CERTBOT_CREDENTIALS_DIR="${XHTTP_CDN_CERTBOT_CREDENTIALS_DIR:-${CONFIG_DIR}/certbot}"
CERTBOT_BIN="${XHTTP_CDN_CERTBOT_BIN:-certbot}"
LE_LIVE_DIR="${XHTTP_CDN_LE_LIVE_DIR:-/etc/letsencrypt/live}"
LE_RENEW_HOOK="${XHTTP_CDN_LE_RENEW_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/90-xhttp-cdn-reload-nginx}"
SKIP_ROOT_CHECK="${XHTTP_CDN_SKIP_ROOT_CHECK:-0}"
SKIP_DEP_INSTALL="${XHTTP_CDN_SKIP_DEP_INSTALL:-0}"

# XHTTP profile defaults.  The same names are used in the prompts, metadata,
# pairing code and generated Xray JSON so an operator can understand a setup
# without translating between several different vocabularies.
ALLOW_CUSTOM_EDGE_PORT="${XHTTP_CDN_ALLOW_CUSTOM_EDGE_PORT:-0}"
ALLOW_PUBLIC_SOCKS="${XHTTP_CDN_ALLOW_PUBLIC_SOCKS:-0}"
TUNNEL_DIRECTION="${XHTTP_CDN_TUNNEL_DIRECTION:-${XHTTP_CDN_DIRECTION:-direct}}"
TRAFFIC_SCOPE="${XHTTP_CDN_TRAFFIC_SCOPE:-${XHTTP_CDN_SCOPE:-ports}}"
EDGE_PORT="${XHTTP_CDN_EDGE_PORT:-443}"
SOCKS_PORT="${XHTTP_CDN_SOCKS_PORT:-10808}"
SOCKS_BIND="${XHTTP_CDN_SOCKS_BIND:-127.0.0.1}"
TUN_NAME="${XHTTP_CDN_TUN_NAME:-xhttp0}"
TUN_MTU="${XHTTP_CDN_TUN_MTU:-1500}"
TUN_GATEWAY="${XHTTP_CDN_TUN_GATEWAY:-172.30.0.1/30}"
TUN_DNS="${XHTTP_CDN_TUN_DNS:-1.1.1.1,8.8.8.8}"
TUN_OUTBOUND_INTERFACE="${XHTTP_CDN_TUN_OUTBOUND_INTERFACE:-}"
XMUX_MAX_CONCURRENCY="${XHTTP_CDN_XMUX_MAX_CONCURRENCY:-8-16}"
XMUX_MAX_CONNECTIONS="${XHTTP_CDN_XMUX_MAX_CONNECTIONS:-0}"
XMUX_C_MAX_REUSE_TIMES="${XHTTP_CDN_XMUX_C_MAX_REUSE_TIMES:-2-8}"
XMUX_H_MAX_REQUEST_TIMES="${XHTTP_CDN_XMUX_H_MAX_REQUEST_TIMES:-600-900}"
XMUX_H_MAX_REUSABLE_SECS="${XHTTP_CDN_XMUX_H_MAX_REUSABLE_SECS:-1800-3000}"
XMUX_X_PADDING_BYTES="${XHTTP_CDN_XMUX_X_PADDING_BYTES:-100-1000}"
XMUX_STREAM_UP_SECS="${XHTTP_CDN_XMUX_STREAM_UP_SECS:-20-80}"
WATCHDOG_INTERVAL="${XHTTP_CDN_WATCHDOG_INTERVAL:-60}"
ENABLE_WATCHDOG="${XHTTP_CDN_ENABLE_WATCHDOG:-1}"

# Values are intentionally initialized so that the file can be sourced by
# tests and by the universal launcher without nounset surprises.
INSTANCE="${INSTANCE:-}"
DOMAIN="${DOMAIN:-}"
UUID="${UUID:-}"
XHTTP_PATH="${XHTTP_PATH:-}"
XHTTP_MODE="${XHTTP_MODE:-auto}"
ORIGIN_PORT="${ORIGIN_PORT:-18080}"
CLEAN_IP="${CLEAN_IP:-}"
BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
MAPPINGS="${MAPPINGS:-}"
CERT_MODE="${CERT_MODE:-self-signed}"
ACME_EMAIL="${ACME_EMAIL:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"

TMP_DIR=""
FORCE=false

C_RESET=$'\033[0m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[0;31m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'

info() { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

xhttp_cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/xhttp-cdn.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap xhttp_cleanup EXIT
fi

ensure_tmp_dir() {
  if [[ -z "$TMP_DIR" ]]; then
    TMP_DIR="$(mktemp -d -t xhttp-cdn.XXXXXX)"
  else
    mkdir -p "$TMP_DIR"
  fi
}

pause_menu() {
  echo
  IFS= read -r -p "Press Enter to continue..." _
}

prompt_default() {
  local prompt="$1" default="$2" out_var="$3" value
  IFS= read -r -p "${prompt} [${default}]: " value
  printf -v "$out_var" '%s' "${value:-$default}"
}

prompt_required() {
  local prompt="$1" out_var="$2" value
  while true; do
    IFS= read -r -p "${prompt}: " value
    if [[ -n "$value" ]]; then
      printf -v "$out_var" '%s' "$value"
      return 0
    fi
    warn "A value is required."
  done
}

confirm() {
  local prompt="$1" answer
  if [[ "$FORCE" == true ]]; then
    return 0
  fi
  printf '%s [y/N]: ' "$prompt" >&2
  IFS= read -r answer
  answer="${answer,,}"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

show_ip_names() {
  cat <<'EOF'
IP names used by this installer / معنی نام آی‌پی‌ها:
  FOREIGN_SERVER_IP       = آی‌پی عمومی سرور خارج
  IRAN_SERVER_IP          = آی‌پی عمومی همین سرور ایران؛ کاربران به آن وصل می‌شوند
  CLEAN_CLOUDFLARE_IP     = آی‌پی تمیز کلودفلر که فقط روی سرور PEER وارد می‌شود

Important / مهم:
  - Cloudflare DNS: CDN_HOSTNAME -> XHTTP_ENDPOINT_SERVER with Proxy ON (orange cloud).
  - Do not put the peer IP or CLEAN_CLOUDFLARE_IP in that DNS record.
  - The peer public IP stays DNS-only/direct; only the endpoint is proxied.
EOF
}

show_server_install_guide() {
  cat <<'EOF'
============================================================
EASY FOREIGN INSTALL / نصب آسان روی سرور خارج
============================================================
Enter only CDN_HOSTNAME. Example: xhttp.example.com
UUID, secret path, internal port, XHTTP mode and certificate are automatic.

Cloudflare A record: CDN_HOSTNAME -> FOREIGN_SERVER_IP (orange cloud ON)
Cloudflare SSL mode: Full
EOF
  echo
}

show_reverse_server_install_guide() {
  cat <<'EOF'
============================================================
EASY REVERSE ENDPOINT / نصب آسان ریورس
============================================================
Run this option on the server that owns the private service (normally IRAN).
Enter only CDN_HOSTNAME. The endpoint listens locally and prints one complete
peer command for the other server (normally FOREIGN). No UUID, path, or port
mapping is required on this screen.

Cloudflare A record: CDN_HOSTNAME -> this endpoint server (orange cloud ON)
Cloudflare SSL mode: Full
EOF
  echo
}

show_client_install_guide() {
  cat <<'EOF'
============================================================
ADVANCED IRAN INSTALL / نصب دستی و پیشرفتهٔ ایران
============================================================
Run this option only on the IRAN server.

Normally, do not use this advanced command. Copy the WHOLE easy-install command printed by
the FOREIGN server and paste it on Iran. It asks only the clean IP and mapping.

This manual screen needs:
  1. XHC2_PAIRING_CODE (or older XHC1_SETUP_CODE) copied from the XHTTP endpoint server.
  2. CLEAN_CLOUDFLARE_IP reachable from this IRAN server.
  3. Port mapping in this exact format:
       IRAN_PORT=FOREIGN_SERVICE_PORT
     Example: 2444=8444

Users will connect to IRAN_SERVER_IP:IRAN_PORT.
Do not enter FOREIGN_SERVER_IP as CLEAN_CLOUDFLARE_IP.
EOF
  echo
  show_ip_names
  echo
}

show_simple_guide() {
  show_server_install_guide
  cat <<'EOF'
============================================================
EASY IRAN INSTALL / نصب آسان روی سرور ایران
============================================================
On the FOREIGN server choose menu option 2 and copy the complete command.
Paste it on the IRAN server. It asks only:
  1. CLEAN_CLOUDFLARE_IP
  2. PORT_MAPPING, example: 2444=8444

Simple example / مثال ساده:
  Normal setup    : copy ONE complete command from foreign and paste on Iran
  Iran asks only : CLEAN_CLOUDFLARE_IP and IRAN_PORT=FOREIGN_SERVICE_PORT
  Cloudflare DNS : xhttp.example.com -> FOREIGN_SERVER_IP (orange cloud ON)
  Iran mapping   : 2444=8444
  User connects  : IRAN_SERVER_IP:2444
  Final target   : 127.0.0.1:8444 on the FOREIGN server

Connection path:
  IRAN_SERVER_IP:2444 -> CLEAN_CLOUDFLARE_IP:EDGE_PORT
  -> xhttp.example.com -> FOREIGN_SERVER_IP -> 127.0.0.1:8444
EOF
  cat <<'EOF'

Reverse setup / مدل ریورس:
  1. On the endpoint server choose EASY REVERSE ENDPOINT and enter CDN_HOSTNAME.
  2. Copy the printed peer command to the other server.
  3. The peer asks only CLEAN_CLOUDFLARE_IP (and a port mapping if no mapping
     was embedded). Users then connect to the peer's public IP.

Profiles: ports = TCP/UDP mappings; socks = private SOCKS; tun = full IPv4;
all = ports + SOCKS + TUN in one XHTTP connection.
EOF
}

require_root() {
  if [[ "$SKIP_ROOT_CHECK" != "1" && ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Run as root: sudo -i"
  fi
}

validate_instance() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

validate_ipv4() {
  local ip="$1" part
  local -a octets
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$ip"
  ((${#octets[@]} == 4)) || return 1
  for part in "${octets[@]}"; do
    ((10#$part >= 0 && 10#$part <= 255)) || return 1
  done
  [[ "$ip" != "0.0.0.0" && "$ip" != "255.255.255.255" ]]
}

validate_domain() {
  local domain="${1,,}" label
  local -a labels
  [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *..* ]] || return 1
  [[ ! "$domain" =~ ^[0-9.]+$ ]] || return 1
  IFS='.' read -r -a labels <<<"$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

validate_uuid() {
  [[ "${1,,}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

validate_xhttp_path() {
  local path="$1"
  [[ ${#path} -ge 9 && ${#path} -le 128 ]] || return 1
  [[ "$path" =~ ^/[A-Za-z0-9][A-Za-z0-9/_-]+$ ]] || return 1
  [[ "$path" != *..* && "$path" != *//* && "$path" != */ ]]
}

validate_bind_address() {
  [[ "$1" == "0.0.0.0" || "$1" == "127.0.0.1" ]] || validate_ipv4 "$1"
}

validate_target_host() {
  [[ "$1" == "localhost" ]] || validate_ipv4 "$1" || validate_domain "$1"
}

validate_mode() {
  [[ "$1" == "auto" || "$1" == "packet-up" ]]
}

validate_edge_port() {
  local port="${1:-}"
  validate_port "$port" || return 1
  if [[ "$ALLOW_CUSTOM_EDGE_PORT" == "1" || "${XHTTP_CDN_ALLOW_CUSTOM_EDGE_PORT:-0}" == "1" ]]; then
    return 0
  fi
  case "$((10#$port))" in
    443|2053|2083|2087|2096|8443) return 0 ;;
    *) return 1 ;;
  esac
}

validate_tunnel_direction() {
  [[ "${1,,}" == direct || "${1,,}" == reverse ]]
}

validate_direction() { validate_tunnel_direction "$@"; }

validate_traffic_scope() {
  case "${1,,}" in
    ports|socks|tun|all) return 0 ;;
    *) return 1 ;;
  esac
}

validate_scope() { validate_traffic_scope "$@"; }

validate_tun_name() {
  [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]]
}

validate_tun_mtu() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && ((10#$1 >= 576 && 10#$1 <= 9000))
}

validate_tun_gateway() {
  local value="${1:-}" address prefix
  [[ "$value" =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
  address="${BASH_REMATCH[1]}"
  prefix="${BASH_REMATCH[2]}"
  validate_ipv4 "$address" || return 1
  ((10#$prefix >= 1 && 10#$prefix <= 32))
}

validate_dns_list() {
  local raw="${1:-}" dns
  local -a values
  raw="${raw,,}"
  raw="${raw//[[:space:]]/}"
  [[ -n "$raw" && "$raw" != ,* && "$raw" != *, && "$raw" != *,,* ]] || return 1
  IFS=',' read -r -a values <<<"$raw"
  ((${#values[@]} > 0)) || return 1
  for dns in "${values[@]}"; do
    validate_ipv4 "$dns" || return 1
  done
}

validate_int_range() {
  local value="${1:-}" from to
  if [[ "$value" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    from="${BASH_REMATCH[1]}"; to="${BASH_REMATCH[2]}"
    ((10#$from <= 10#$to))
  elif [[ "$value" =~ ^[0-9]+$ ]]; then
    return 0
  else
    return 1
  fi
}

validate_xmux_settings() {
  validate_int_range "$XMUX_MAX_CONCURRENCY" || return 1
  validate_int_range "$XMUX_MAX_CONNECTIONS" || return 1
  validate_int_range "$XMUX_C_MAX_REUSE_TIMES" || return 1
  validate_int_range "$XMUX_H_MAX_REQUEST_TIMES" || return 1
  validate_int_range "$XMUX_H_MAX_REUSABLE_SECS" || return 1
  validate_int_range "$XMUX_X_PADDING_BYTES" || return 1
  validate_int_range "$XMUX_STREAM_UP_SECS" || return 1
}

validate_watchdog_settings() {
  [[ "$ENABLE_WATCHDOG" == 0 || "$ENABLE_WATCHDOG" == 1 ]] || return 1
  [[ "$WATCHDOG_INTERVAL" =~ ^[0-9]+$ ]] && ((10#$WATCHDOG_INTERVAL >= 15 && 10#$WATCHDOG_INTERVAL <= 86400))
}

validate_tun_settings() {
  validate_tun_name "$TUN_NAME" || return 1
  validate_tun_mtu "$TUN_MTU" || return 1
  validate_tun_gateway "$TUN_GATEWAY" || return 1
  validate_dns_list "$TUN_DNS" || return 1
}

validate_tun_interface() {
  [[ "${1:-}" == auto || "${1:-}" =~ ^[A-Za-z][A-Za-z0-9_.:-]{0,14}$ ]]
}

resolve_tun_outbound_interface() {
  local candidate="${TUN_OUTBOUND_INTERFACE:-}"
  if [[ -n "$candidate" ]]; then
    validate_tun_interface "$candidate" || return 1
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    candidate="$(ip -4 route show default 2>/dev/null \
      | awk 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  fi
  if validate_tun_interface "$candidate"; then
    TUN_OUTBOUND_INTERFACE="$candidate"
  else
    # Xray's automatic updater remains a safe fallback on hosts where the
    # default route is not visible during installation (for example a VPS
    # network namespace). A detected fixed interface avoids route-update loops.
    TUN_OUTBOUND_INTERFACE="auto"
  fi
}

validate_cert_mode() {
  [[ "$1" == "letsencrypt" || "$1" == "self-signed" || "$1" == "existing" ]]
}

validate_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[A-Za-z]{2,63}$ ]]
}

validate_cloudflare_token() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{20,256}$ ]]
}

validate_absolute_path() {
  [[ "$1" =~ ^/[A-Za-z0-9_./@+-]+$ && "$1" != *..* ]]
}

MAPPING_ITEMS=()
MAPPING_PROTOCOLS=()
MAPPING_LISTEN_PORTS=()
MAPPING_TARGET_PORTS=()

validate_mapping_protocol() {
  case "${1,,}" in
    tcp|udp|both) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_mapping_protocols() {
  local value="${1,,}"
  case "$value" in
    tcp|tcp4|tcp6) printf 'tcp' ;;
    udp|udp4|udp6) printf 'udp' ;;
    both|all|tcp,udp|udp,tcp|tcp+udp|udp+tcp) printf 'both' ;;
    *) return 1 ;;
  esac
}

# Kept as a named helper because older automation called this function while
# experimenting with protocol lists.
parse_mapping_protocols() { normalize_mapping_protocols "$@"; }

mapping_network() {
  case "${1,,}" in
    tcp) printf 'tcp' ;;
    udp) printf 'udp' ;;
    both) printf 'tcp,udp' ;;
    *) return 1 ;;
  esac
}

parse_mappings() {
  local raw="${1:-}" item body protocol listen_port target_port previous_index
  local explicit
  local -a items
  MAPPING_ITEMS=()
  MAPPING_PROTOCOLS=()
  MAPPING_LISTEN_PORTS=()
  MAPPING_TARGET_PORTS=()
  raw="${raw,,}"
  raw="${raw//[[:space:]]/}"
  [[ -n "$raw" && "$raw" != ,* && "$raw" != *, && "$raw" != *,,* ]] || return 1
  IFS=',' read -r -a items <<<"$raw"
  ((${#items[@]} > 0)) || return 1
  for item in "${items[@]}"; do
    protocol='tcp'
    body="$item"
    explicit=false
    if [[ "$body" =~ ^(tcp|udp|both):(.*)$ ]]; then
      protocol="${BASH_REMATCH[1],,}"
      body="${BASH_REMATCH[2]}"
      explicit=true
    fi
    validate_mapping_protocol "$protocol" || return 1
    if [[ "$body" =~ ^([0-9]{1,5})=([0-9]{1,5})$ ]]; then
      listen_port="${BASH_REMATCH[1]}"
      target_port="${BASH_REMATCH[2]}"
    elif [[ "$body" =~ ^[0-9]{1,5}$ ]]; then
      listen_port="$body"
      target_port="$body"
    else
      return 1
    fi
    validate_port "$listen_port" && validate_port "$target_port" || return 1
    listen_port=$((10#$listen_port))
    target_port=$((10#$target_port))
    for previous_index in "${!MAPPING_LISTEN_PORTS[@]}"; do
      [[ "${MAPPING_LISTEN_PORTS[$previous_index]}" == "$listen_port" ]] || continue
      # TCP and UDP can share a local number; an exact protocol or a `both`
      # entry is a collision because two inbounds would receive the same flow.
      if [[ "${MAPPING_PROTOCOLS[$previous_index]}" == "$protocol" \
            || "${MAPPING_PROTOCOLS[$previous_index]}" == both \
            || "$protocol" == both ]]; then
        return 1
      fi
    done
    if [[ "$protocol" == tcp ]]; then
      # Preserve the original short syntax for old scripts and setup codes.
      MAPPING_ITEMS+=("${listen_port}=${target_port}")
    else
      MAPPING_ITEMS+=("${protocol}:${listen_port}=${target_port}")
    fi
    MAPPING_PROTOCOLS+=("$protocol")
    MAPPING_LISTEN_PORTS+=("$listen_port")
    MAPPING_TARGET_PORTS+=("$target_port")
  done
  MAPPINGS="$(mapping_items_raw)"
}

mapping_items_raw() {
  local i
  for i in "${!MAPPING_LISTEN_PORTS[@]}"; do
    [[ "$i" -eq 0 ]] || printf ','
    printf '%s=%s' "${MAPPING_LISTEN_PORTS[$i]}" "${MAPPING_TARGET_PORTS[$i]}"
  done
}

serialize_mappings() {
  local i protocol
  for i in "${!MAPPING_LISTEN_PORTS[@]}"; do
    [[ "$i" -eq 0 ]] || printf ','
    protocol="${MAPPING_PROTOCOLS[$i]:-tcp}"
    printf '%s:%s=%s' "$protocol" "${MAPPING_LISTEN_PORTS[$i]}" "${MAPPING_TARGET_PORTS[$i]}"
  done
}

generate_uuid() {
  if [[ -x "$BIN" ]]; then
    "$BIN" uuid 2>/dev/null | head -n1
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\n' </proc/sys/kernel/random/uuid
  else
    local hex
    hex="$(openssl rand -hex 16)"
    printf '%s-%s-%s-%s-%s' \
      "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
  fi
}

generate_path() {
  printf '/xhttp-%s' "$(openssl rand -hex 12)"
}

base64url_encode() {
  base64 -w0 | tr '+/' '-_' | tr -d '='
}

base64url_decode() {
  local value="$1" padding
  value="${value//-/+}"
  value="${value//_/\/}"
  case $((${#value} % 4)) in
    0) padding='' ;;
    2) padding='==' ;;
    3) padding='=' ;;
    *) return 1 ;;
  esac
  printf '%s%s' "$value" "$padding" | base64 -d 2>/dev/null
}

make_setup_code() {
  local payload
  payload="1|${DOMAIN}|${UUID}|${XHTTP_PATH}|443|${XHTTP_MODE}"
  printf 'XHC1_%s' "$(printf '%s' "$payload" | base64url_encode)"
}

pair_value() {
  [[ "${1:-}" == "-" ]] && printf '' || printf '%s' "${1:-}"
}

make_setup_code_v2() {
  local mappings payload edge scope direction
  direction="${TUNNEL_DIRECTION:-direct}"
  scope="${TRAFFIC_SCOPE:-ports}"
  edge="${EDGE_PORT:-443}"
  if ((${#MAPPING_LISTEN_PORTS[@]} == 0)) && [[ -n "${MAPPINGS:-}" ]]; then
    parse_mappings "$MAPPINGS" >/dev/null 2>&1 || true
  fi
  mappings="$(serialize_mappings 2>/dev/null || true)"
  # '-' is an unambiguous empty-field marker. It also keeps trailing optional
  # fields intact when the code is split by older Bash versions.
  : "${INSTANCE:=cf1}"
  : "${ORIGIN_PORT:=18080}"
  : "${SOCKS_PORT:=10808}"
  : "${SOCKS_BIND:=127.0.0.1}"
  : "${TUN_NAME:=xhttp0}"
  : "${TUN_MTU:=1500}"
  : "${TUN_GATEWAY:=172.30.0.1/30}"
  : "${TUN_DNS:=1.1.1.1,8.8.8.8}"
  [[ -n "$mappings" ]] || mappings='-'
  payload="2|${direction}|${INSTANCE}|${DOMAIN}|${UUID}|${XHTTP_PATH}|${edge}|${XHTTP_MODE}|${scope}|${ORIGIN_PORT}|${SOCKS_PORT}|${SOCKS_BIND}|${TUN_NAME}|${TUN_MTU}|${TUN_GATEWAY}|${TUN_DNS}|${mappings}"
  printf 'XHC2_%s' "$(printf '%s' "$payload" | base64url_encode)"
}

make_xhc2_setup_code() { make_setup_code_v2 "$@"; }
make_pairing_code() { make_setup_code_v2 "$@"; }

make_iran_easy_command() {
  local setup_code="$1" url separator='?' action='easy-client'
  if [[ "$setup_code" == XHC2_* ]]; then
    local decoded
    decoded="$(base64url_decode "${setup_code#XHC2_}" 2>/dev/null || true)"
    [[ "$(cut -d'|' -f2 <<<"$decoded")" == reverse ]] && action='easy-reverse-client'
  elif [[ "${TUNNEL_DIRECTION:-direct}" == reverse ]]; then
    action='easy-reverse-client'
  fi
  [[ "$SELF_URL" == *\?* ]] && separator='&'
  url="${SELF_URL}${separator}cb=$(date +%s)"
  printf 'XHTTP_CDN_SETUP_CODE=%q XHTTP_CDN_REPO=%q XHTTP_CDN_REF=%q bash <(curl -fsSL --ipv4 %q) %s' \
    "$setup_code" "$REPO" "$REF" "$url" "$action"
}

iran_command_file() {
  local name="$1"
  printf '%s/iran-install-%s.txt' "$CONFIG_DIR" "$name"
}

peer_command_file() {
  local name="$1"
  printf '%s/peer-install-%s.txt' "$CONFIG_DIR" "$name"
}

metadata_path() {
  local role name
  if [[ $# -ge 2 ]]; then
    role="$1"; name="$2"
  elif [[ "${1:-}" == server || "${1:-}" == client ]]; then
    role="$1"; name="${INSTANCE:-cf1}"
  else
    role="${ROLE:-client}"; name="${1:-${INSTANCE:-cf1}}"
  fi
  printf '%s/%s-%s.meta' "$CONFIG_DIR" "$role" "$name"
}

metadata_value() {
  local file="$1" key="$2" default="${3:-}" value
  # Accept both metadata_value FILE KEY [DEFAULT] and the older
  # metadata_value KEY FILE [DEFAULT] spelling.
  if [[ ! -r "$file" && -r "$key" ]]; then
    local swap="$file"
    file="$key"; key="$swap"
  elif [[ ! -r "$file" && ! -r "$key" && -n "${META:-${METADATA_PATH:-}}" ]]; then
    default="$key"
    key="$file"
    file="${META:-${METADATA_PATH:-}}"
  fi
  [[ -r "$file" ]] || { printf '%s' "$default"; return 0; }
  value="$(awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null || true)"
  printf '%s' "${value:-$default}"
}

write_metadata() {
  local role="${1:-${ROLE:-client}}" name="${2:-${INSTANCE:-cf1}}" destination temp mappings metadata_group=root
  destination="$(metadata_path "$role" "$name")"
  mappings="$(serialize_mappings 2>/dev/null || true)"
  mkdir -p "$CONFIG_DIR"
  if getent group "$SERVICE_USER" >/dev/null 2>&1; then metadata_group="$SERVICE_USER"; fi
  ensure_tmp_dir
  temp="${TMP_DIR}/$(basename "$destination").tmp"
  cat >"$temp" <<EOF
# XHTTP CDN metadata; values are data only and are never sourced as shell.
ROLE=${role}
INSTANCE=${name}
TUNNEL_DIRECTION=${TUNNEL_DIRECTION:-direct}
TRAFFIC_SCOPE=${TRAFFIC_SCOPE:-ports}
DOMAIN=${DOMAIN:-}
EDGE_PORT=${EDGE_PORT:-443}
ORIGIN_PORT=${ORIGIN_PORT:-18080}
XHTTP_MODE=${XHTTP_MODE:-auto}
SOCKS_PORT=${SOCKS_PORT:-10808}
SOCKS_BIND=${SOCKS_BIND:-127.0.0.1}
TUN_NAME=${TUN_NAME:-xhttp0}
TUN_MTU=${TUN_MTU:-1500}
TUN_GATEWAY=${TUN_GATEWAY:-172.30.0.1/30}
TUN_DNS=${TUN_DNS:-1.1.1.1,8.8.8.8}
TUN_OUTBOUND_INTERFACE=${TUN_OUTBOUND_INTERFACE:-auto}
MAPPINGS=${mappings}
CERT_MODE=${CERT_MODE:-self-signed}
TLS_CERT=${TLS_CERT:-}
TLS_KEY=${TLS_KEY:-}
EOF
  install -o root -g "$metadata_group" -m 640 "$temp" "$destination"
  METADATA_PATH="$destination"
}

watchdog_paths() {
  local service="${1:-${SERVICE:-}}"
  if [[ "$service" != xhttp-cdn-* && $# -ge 2 ]]; then
    service="xhttp-cdn-${1}-${2}"
  fi
  [[ -n "$service" ]] || return 1
  WATCHDOG_SERVICE="${SYSTEMD_DIR}/${service}-watchdog.service"
  WATCHDOG_TIMER="${SYSTEMD_DIR}/${service}-watchdog.timer"
  WATCHDOG_SERVICE_NAME="${service}-watchdog"
  WATCHDOG_TARGET_SERVICE="${service}"
}

write_watchdog_units() {
  local service="${1:-${SERVICE:-}}"
  watchdog_paths "$service"
  mkdir -p "$SYSTEMD_DIR"
  cat >"$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=Watchdog for XHTTP CDN ${service}
After=${service}.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/bin/systemctl is-active --quiet ${service}.service || /bin/systemctl restart ${service}.service'
EOF
  cat >"$WATCHDOG_TIMER" <<EOF
[Unit]
Description=Periodic watchdog for XHTTP CDN ${service}

[Timer]
OnBootSec=30s
OnUnitActiveSec=${WATCHDOG_INTERVAL}s
Unit=${service}-watchdog.service
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
}

# Singular names are retained for scripts written against the first v2 draft.
write_watchdog_unit() { write_watchdog_units "$@"; }
write_watchdog_timer() {
  local service="${1:-${SERVICE:-}}"
  watchdog_paths "$service"
  mkdir -p "$SYSTEMD_DIR"
  cat >"$WATCHDOG_TIMER" <<EOF
[Unit]
Description=Periodic watchdog for XHTTP CDN ${service}

[Timer]
OnBootSec=30s
OnUnitActiveSec=${WATCHDOG_INTERVAL}s
Unit=${service}-watchdog.service
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$WATCHDOG_TIMER"
}

snapshot_file() {
  local source="$1" snapshot="$2"
  if [[ -e "$source" ]]; then
    cp -a -- "$source" "$snapshot"
    printf 'present' >"${snapshot}.state"
  else
    rm -f -- "$snapshot" 2>/dev/null || true
    printf 'absent' >"${snapshot}.state"
  fi
}

restore_snapshot() {
  local snapshot="$1" destination="$2" state=""
  if [[ -r "${snapshot}.state" ]]; then state="$(<"${snapshot}.state")"; fi
  if [[ "$state" == present || -e "$snapshot" ]]; then
    mkdir -p "$(dirname "$destination")"
    cp -a -- "$snapshot" "$destination"
  else
    rm -f -- "$destination"
  fi
}

rollback_instance_files() {
  local role="${1:-${ROLE:-client}}" name="${2:-${INSTANCE:-cf1}}" snapshot_dir="${3:-${TMP_DIR:-}}" path snapshot
  if [[ -d "${1:-}" && $# -ge 3 ]]; then
    snapshot_dir="$1"; role="$2"; name="$3"
  fi
  service_paths "$role" "$name"
  [[ -d "$snapshot_dir" ]] || return 0
  for path in "$CONFIG" "$UNIT" "$NGINX_CONFIG" "$(metadata_path "$role" "$name")"; do
    [[ -n "$path" ]] || continue
    snapshot="${snapshot_dir}/$(basename "$path")"
    restore_snapshot "$snapshot" "$path"
  done
  watchdog_paths "$SERVICE"
  for path in "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"; do
    restore_snapshot "${snapshot_dir}/$(basename "$path")" "$path"
  done
}

save_iran_easy_command() {
  local command_file setup_code
  command_file="$(iran_command_file "$INSTANCE")"
  setup_code="$(make_setup_code_v2)"
  mkdir -p "$CONFIG_DIR"
  make_iran_easy_command "$setup_code" >"$command_file"
  printf '\n' >>"$command_file"
  chmod 600 "$command_file"
  if [[ "${TUNNEL_DIRECTION:-direct}" == reverse ]]; then
    local peer_file
    peer_file="$(peer_command_file "$INSTANCE")"
    cp -f -- "$command_file" "$peer_file"
    chmod 600 "$peer_file"
  fi
}

load_server_pairing_values() {
  local name="$1" config nginx_config metadata_value_read mappings
  validate_instance "$name" || die "Invalid instance name."
  service_paths server "$name"
  config="$CONFIG"
  nginx_config="$NGINX_CONFIG"
  [[ -r "$config" ]] || die "Server instance '${name}' has no readable Xray configuration."
  [[ -r "$nginx_config" ]] || die "Server instance '${name}' has no readable Nginx configuration."

  INSTANCE="$name"
  DOMAIN="$(awk '$1 == "server_name" {gsub(/;/, "", $2); print $2; exit}' "$nginx_config")"
  UUID="$(jq -er '.inbounds[0].settings.clients[0].id' "$config")" || die "Could not recover the UUID for '${name}'."
  XHTTP_PATH="$(jq -er '.inbounds[0].streamSettings.xhttpSettings.path' "$config")" || die "Could not recover the XHTTP path for '${name}'."
  XHTTP_MODE="$(jq -er '.inbounds[0].streamSettings.xhttpSettings.mode' "$config")" || die "Could not recover the XHTTP mode for '${name}'."
  ORIGIN_PORT="$(jq -er '.inbounds[0].port' "$config")" || die "Could not recover the internal port for '${name}'."

  # New installations carry a sidecar with the profile and direction. Older
  # XHC1 installations remain fully recoverable from their JSON/Nginx pair.
  METADATA_PATH="$(metadata_path server "$name")"
  if [[ -r "$METADATA_PATH" ]]; then
    metadata_value_read="$(metadata_value "$METADATA_PATH" TUNNEL_DIRECTION direct)"; TUNNEL_DIRECTION="${metadata_value_read:-direct}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" TRAFFIC_SCOPE ports)"; TRAFFIC_SCOPE="${metadata_value_read:-ports}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" EDGE_PORT 443)"; EDGE_PORT="${metadata_value_read:-443}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" SOCKS_PORT 10808)"; SOCKS_PORT="${metadata_value_read:-10808}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" SOCKS_BIND 127.0.0.1)"; SOCKS_BIND="${metadata_value_read:-127.0.0.1}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" TUN_NAME xhttp0)"; TUN_NAME="${metadata_value_read:-xhttp0}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" TUN_MTU 1500)"; TUN_MTU="${metadata_value_read:-1500}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" TUN_GATEWAY 172.30.0.1/30)"; TUN_GATEWAY="${metadata_value_read:-172.30.0.1/30}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" TUN_DNS '1.1.1.1,8.8.8.8')"; TUN_DNS="${metadata_value_read:-1.1.1.1,8.8.8.8}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" CERT_MODE self-signed)"; CERT_MODE="${metadata_value_read:-self-signed}"
    metadata_value_read="$(metadata_value "$METADATA_PATH" TLS_CERT '')"; TLS_CERT="$metadata_value_read"
    metadata_value_read="$(metadata_value "$METADATA_PATH" TLS_KEY '')"; TLS_KEY="$metadata_value_read"
    mappings="$(metadata_value "$METADATA_PATH" MAPPINGS '')"
    if [[ -n "$mappings" ]]; then
      parse_mappings "$mappings" || true
    else
      MAPPING_ITEMS=(); MAPPING_PROTOCOLS=(); MAPPING_LISTEN_PORTS=(); MAPPING_TARGET_PORTS=(); MAPPINGS=''
    fi
  else
    TUNNEL_DIRECTION='direct'; TRAFFIC_SCOPE='ports'; EDGE_PORT=443
    SOCKS_PORT=10808; SOCKS_BIND=127.0.0.1; TUN_NAME=xhttp0; TUN_MTU=1500
    TUN_GATEWAY=172.30.0.1/30; TUN_DNS='1.1.1.1,8.8.8.8'; TUN_OUTBOUND_INTERFACE=''
    CERT_MODE='self-signed'; TLS_CERT=''; TLS_KEY=''
    MAPPING_ITEMS=(); MAPPING_PROTOCOLS=(); MAPPING_LISTEN_PORTS=(); MAPPING_TARGET_PORTS=(); MAPPINGS=''
  fi

  # Recover the Nginx listener when the sidecar predates EDGE_PORT metadata.
  if [[ "$EDGE_PORT" == 443 ]]; then
    local recovered_edge
    recovered_edge="$(awk '/^[[:space:]]*listen[[:space:]]+[0-9]+([[:space:]]|;)/ {for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+([;]|$)/) {gsub(/;/,"",$i); print $i; exit}}' "$nginx_config" || true)"
    [[ "$recovered_edge" =~ ^[0-9]+$ ]] && EDGE_PORT="$recovered_edge"
  fi

  validate_domain "$DOMAIN" || die "Could not recover a valid CDN hostname for '${name}'."
  validate_uuid "$UUID" || die "Recovered UUID for '${name}' is invalid."
  validate_xhttp_path "$XHTTP_PATH" || die "Recovered XHTTP path for '${name}' is invalid."
  validate_mode "$XHTTP_MODE" || die "Recovered XHTTP mode for '${name}' is invalid."
}

print_iran_easy_command() {
  local name="$1" command_file destination input_text
  load_server_pairing_values "$name"
  save_iran_easy_command
  command_file="$(iran_command_file "$INSTANCE")"
  if [[ "$TUNNEL_DIRECTION" == reverse ]]; then
    destination='FOREIGN SERVER / سرور خارج'
  else
    destination='IRAN SERVER / سرور ایران'
  fi
  input_text='CLEAN_CLOUDFLARE_IP'
  if [[ ("$TRAFFIC_SCOPE" == ports || "$TRAFFIC_SCOPE" == all) && ${#MAPPING_ITEMS[@]} -eq 0 ]]; then
    input_text+=' and PORT_MAPPING'
  fi
  echo
  printf '%sCOPY THIS ONE COMPLETE COMMAND TO THE %s:%s\n' "$C_BOLD" "$destination" "$C_RESET"
  cat "$command_file"
  echo
  echo "On the peer it asks only: ${input_text}."
  echo "If this screen is lost, choose menu option 2 to show the command again."
}

parse_setup_code() {
  local code="${1:-}" payload version parsed_domain parsed_uuid parsed_path parsed_port parsed_mode extra
  local -a fields
  if [[ "$code" == XHC1_* ]]; then
    payload="$(base64url_decode "${code#XHC1_}")" || return 1
    IFS='|' read -r version parsed_domain parsed_uuid parsed_path parsed_port parsed_mode extra <<<"$payload"
    [[ "$version" == "1" && -z "${extra:-}" ]] || return 1
    validate_domain "$parsed_domain" || return 1
    validate_uuid "$parsed_uuid" || return 1
    validate_xhttp_path "$parsed_path" || return 1
    [[ "$parsed_port" == "443" ]] || return 1
    validate_mode "$parsed_mode" || return 1
    DOMAIN="$parsed_domain"; UUID="$parsed_uuid"; XHTTP_PATH="$parsed_path"
    EDGE_PORT=443; XHTTP_MODE="$parsed_mode"
    TUNNEL_DIRECTION=direct; TRAFFIC_SCOPE=ports; ORIGIN_PORT=18080
    SOCKS_PORT=10808; SOCKS_BIND=127.0.0.1; TUN_NAME=xhttp0; TUN_MTU=1500
    TUN_GATEWAY=172.30.0.1/30; TUN_DNS='1.1.1.1,8.8.8.8'
    MAPPING_ITEMS=(); MAPPING_PROTOCOLS=(); MAPPING_LISTEN_PORTS=(); MAPPING_TARGET_PORTS=(); MAPPINGS=''
    return 0
  fi
  [[ "$code" == XHC2_* ]] || return 1
  payload="$(base64url_decode "${code#XHC2_}")" || return 1
  IFS='|' read -r -a fields <<<"$payload"
  ((${#fields[@]} >= 8)) || return 1
  version="${fields[0]}"
  [[ "$version" == 2 ]] || return 1
  local field_count=${#fields[@]} last_index mappings_field='-'
  last_index=$((field_count - 1))
  # Early v2 codes sometimes stopped at the mapping field (for example
  # 2|direction|instance|domain|uuid|path|edge|mode|scope|mappings). Pull that
  # field out before filling optional origin/SOCKS/TUN defaults below.
  if ((field_count < 17)) && [[ "${fields[$last_index]:-}" =~ ^((tcp|udp|both):)?[0-9]{1,5}=[0-9]{1,5}(,((tcp|udp|both):)?[0-9]{1,5}=[0-9]{1,5})*$ ]]; then
    mappings_field="${fields[$last_index]}"
    fields[$last_index]='-'
  fi

  # Full v2 layout is documented in the README. A few short layouts were
  # emitted by early branch builds; accepting them makes copied commands
  # upgrade-safe instead of forcing an endpoint recreation.
  local offset=0
  if [[ "${fields[1]:-}" == direct || "${fields[1]:-}" == reverse ]]; then
    offset=0
  else
    # Transitional layout omitted direction and started at instance.
    offset=1
    TUNNEL_DIRECTION=direct
  fi
  local idx
  if ((offset == 0)); then
    TUNNEL_DIRECTION="${fields[1]}"
    idx=2
  else
    idx=1
  fi
  # Increment the index in the current shell; doing it inside $(...) would
  # happen in a subshell and make every field read as fields[1].
  INSTANCE="$(pair_value "${fields[$idx]:-cf1}")"; ((idx++))
  [[ -n "$INSTANCE" ]] || INSTANCE=cf1
  DOMAIN="$(pair_value "${fields[$idx]:-}")"; ((idx++))
  UUID="$(pair_value "${fields[$idx]:-}")"; ((idx++))
  XHTTP_PATH="$(pair_value "${fields[$idx]:-}")"; ((idx++))
  EDGE_PORT="$(pair_value "${fields[$idx]:-443}")"; ((idx++)); [[ -n "$EDGE_PORT" ]] || EDGE_PORT=443
  XHTTP_MODE="$(pair_value "${fields[$idx]:-auto}")"; ((idx++)); [[ -n "$XHTTP_MODE" ]] || XHTTP_MODE=auto
  TRAFFIC_SCOPE="$(pair_value "${fields[$idx]:-ports}")"; ((idx++)); [[ -n "$TRAFFIC_SCOPE" ]] || TRAFFIC_SCOPE=ports
  ORIGIN_PORT="$(pair_value "${fields[$idx]:-18080}")"; ((idx++)); [[ -n "$ORIGIN_PORT" ]] || ORIGIN_PORT=18080
  SOCKS_PORT="$(pair_value "${fields[$idx]:-10808}")"; ((idx++)); [[ -n "$SOCKS_PORT" ]] || SOCKS_PORT=10808
  SOCKS_BIND="$(pair_value "${fields[$idx]:-127.0.0.1}")"; ((idx++)); [[ -n "$SOCKS_BIND" ]] || SOCKS_BIND=127.0.0.1
  TUN_NAME="$(pair_value "${fields[$idx]:-xhttp0}")"; ((idx++)); [[ -n "$TUN_NAME" ]] || TUN_NAME=xhttp0
  TUN_MTU="$(pair_value "${fields[$idx]:-1500}")"; ((idx++)); [[ -n "$TUN_MTU" ]] || TUN_MTU=1500
  TUN_GATEWAY="$(pair_value "${fields[$idx]:-172.30.0.1/30}")"; ((idx++)); [[ -n "$TUN_GATEWAY" ]] || TUN_GATEWAY=172.30.0.1/30
  TUN_DNS="$(pair_value "${fields[$idx]:-1.1.1.1,8.8.8.8}")"; ((idx++)); [[ -n "$TUN_DNS" ]] || TUN_DNS='1.1.1.1,8.8.8.8'
  [[ "$mappings_field" != - ]] || mappings_field="${fields[$idx]:--}"
  MAPPING_ITEMS=(); MAPPING_PROTOCOLS=(); MAPPING_LISTEN_PORTS=(); MAPPING_TARGET_PORTS=(); MAPPINGS=''
  [[ "$mappings_field" == - || -z "$mappings_field" ]] || parse_mappings "$mappings_field" || return 1
  MAPPINGS="$(mapping_items_raw 2>/dev/null || true)"

  validate_tunnel_direction "$TUNNEL_DIRECTION" || return 1
  validate_instance "$INSTANCE" || return 1
  validate_domain "$DOMAIN" || return 1
  validate_uuid "$UUID" || return 1
  validate_xhttp_path "$XHTTP_PATH" || return 1
  if ! validate_edge_port "$EDGE_PORT"; then
    # The endpoint may intentionally use a provider-specific edge port and
    # has already encoded that choice in a trusted pairing code. Keep the
    # normal allow-list for interactive validation, but let the peer consume
    # a valid encoded port without requiring a second hidden environment flag.
    validate_port "$EDGE_PORT" || return 1
  fi
  validate_mode "$XHTTP_MODE" || return 1
  validate_traffic_scope "$TRAFFIC_SCOPE" || return 1
  validate_port "$ORIGIN_PORT" || return 1
  if [[ "$TRAFFIC_SCOPE" == socks || "$TRAFFIC_SCOPE" == all ]]; then
    validate_port "$SOCKS_PORT" || return 1
    validate_bind_address "$SOCKS_BIND" || return 1
  fi
  if [[ "$TRAFFIC_SCOPE" == tun || "$TRAFFIC_SCOPE" == all ]]; then
    validate_tun_settings || return 1
  fi
  # Port mappings may intentionally be empty in an endpoint pairing code. In
  # that case the easy peer workflow asks for them with clear local/remote
  # labels instead of forcing endpoint recreation.
  return 0
}

architecture_asset() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'Xray-linux-64.zip' ;;
    aarch64|arm64) printf 'Xray-linux-arm64-v8a.zip' ;;
    *) die "Unsupported architecture: $(uname -m). Supported: amd64, arm64." ;;
  esac
}

ensure_dependencies() {
  local role="$1"
  local -a missing=() packages=(ca-certificates curl unzip openssl jq iproute2)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  if [[ "$role" == "server" ]]; then
    command -v nginx >/dev/null 2>&1 || missing+=(nginx)
    packages+=(nginx)
  fi
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  [[ "$SKIP_DEP_INSTALL" != "1" ]] || die "Missing dependencies: ${missing[*]}"
  command -v apt-get >/dev/null 2>&1 || die "Install the missing dependencies first: ${missing[*]}"
  info "Installing required packages: ${missing[*]}"
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" >/dev/null
}

ensure_certbot_cloudflare() {
  if command -v "$CERTBOT_BIN" >/dev/null 2>&1 \
      && "$CERTBOT_BIN" plugins 2>/dev/null | grep -q 'dns-cloudflare'; then
    return 0
  fi
  [[ "$SKIP_DEP_INSTALL" != "1" ]] || die "Certbot Cloudflare DNS plugin is missing."
  command -v apt-get >/dev/null 2>&1 \
    || die "Install Certbot and the Cloudflare DNS plugin first."
  info "Installing Certbot and its Cloudflare DNS plugin..."
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    certbot python3-certbot-dns-cloudflare >/dev/null
  command -v "$CERTBOT_BIN" >/dev/null 2>&1 \
    || die "Certbot installation failed."
  "$CERTBOT_BIN" plugins 2>/dev/null | grep -q 'dns-cloudflare' \
    || die "The installed Certbot does not expose the dns-cloudflare plugin."
}

install_certbot_reload_hook() {
  local hook_dir hook_tmp
  hook_dir="$(dirname "$LE_RENEW_HOOK")"
  mkdir -p "$hook_dir"
  ensure_tmp_dir
  hook_tmp="${TMP_DIR}/reload-nginx"
  cat >"$hook_tmp" <<'EOF'
#!/usr/bin/env sh
set -eu
/usr/sbin/nginx -t
/bin/systemctl reload nginx
EOF
  install -o root -g root -m 755 "$hook_tmp" "$LE_RENEW_HOOK"
  if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  fi
}

obtain_letsencrypt_certificate() {
  local credentials cert_name credentials_tmp
  validate_email "$ACME_EMAIL" || die "Invalid Let's Encrypt account email."
  validate_cloudflare_token "$CF_API_TOKEN" \
    || die "Invalid Cloudflare API token format."
  ensure_certbot_cloudflare
  mkdir -p "$CERTBOT_CREDENTIALS_DIR"
  chmod 700 "$CERTBOT_CREDENTIALS_DIR"
  credentials="${CERTBOT_CREDENTIALS_DIR}/cloudflare-${INSTANCE}.ini"
  ensure_tmp_dir
  credentials_tmp="${TMP_DIR}/cloudflare.ini"
  printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" >"$credentials_tmp"
  install -o root -g root -m 600 "$credentials_tmp" "$credentials"
  CF_API_TOKEN=""

  cert_name="xhttp-cdn-${INSTANCE}"
  info "Requesting/refreshing a Let's Encrypt certificate with DNS-01..."
  "$CERTBOT_BIN" certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$credentials" \
    --dns-cloudflare-propagation-seconds 30 \
    --preferred-challenges dns-01 \
    --cert-name "$cert_name" \
    --domain "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    --email "$ACME_EMAIL" \
    --keep-until-expiring

  TLS_CERT="${LE_LIVE_DIR}/${cert_name}/fullchain.pem"
  TLS_KEY="${LE_LIVE_DIR}/${cert_name}/privkey.pem"
  [[ -r "$TLS_CERT" && -r "$TLS_KEY" ]] \
    || die "Certbot completed without producing the expected certificate files."
  install_certbot_reload_hook
  ok "Let's Encrypt certificate is installed with automatic renewal."
}

generate_self_signed_certificate() {
  local cert_tmp key_tmp
  mkdir -p "$CERT_DIR"
  TLS_CERT="${CERT_DIR}/${INSTANCE}.crt"
  TLS_KEY="${CERT_DIR}/${INSTANCE}.key"
  ensure_tmp_dir
  cert_tmp="${TMP_DIR}/self-signed.crt"
  key_tmp="${TMP_DIR}/self-signed.key"
  info "Generating an automatic self-signed origin certificate..."
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes -x509 -days 825 -sha256 \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN}" \
    -keyout "$key_tmp" -out "$cert_tmp" >/dev/null 2>&1
  openssl x509 -in "$cert_tmp" -noout -checkend 86400 >/dev/null \
    || die "Generated origin certificate is invalid."
  install -o root -g root -m 644 "$cert_tmp" "$TLS_CERT"
  install -o root -g root -m 600 "$key_tmp" "$TLS_KEY"
  ok "Self-signed origin certificate generated. Cloudflare SSL mode must be Full, not Full (strict)."
}

prepare_server_certificate() {
  case "$CERT_MODE" in
    letsencrypt) obtain_letsencrypt_certificate ;;
    self-signed) generate_self_signed_certificate ;;
    existing) : ;;
    *) die "Unknown certificate mode: $CERT_MODE" ;;
  esac
}

ensure_service_user() {
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    return 0
  fi
  useradd --system --no-create-home --home-dir /nonexistent \
    --shell /usr/sbin/nologin "$SERVICE_USER"
}

ensure_xray_runtime_access() {
  local directory
  # umask 027 intentionally protects generated configuration, but it also
  # makes freshly-created program directories 0750/root:root. The dedicated
  # systemd user must be able to traverse these two non-secret directories in
  # order to execute Xray. Configuration remains protected under /etc.
  for directory in "$BASE_DIR" "$BIN_DIR"; do
    [[ -d "$directory" ]] || continue
    chmod 755 "$directory"
  done
  [[ ! -f "$BIN" ]] || chmod 755 "$BIN"
}

download_xray() {
  local asset release_base archive digest expected actual extracted
  asset="$(architecture_asset)"
  release_base="https://github.com/${XRAY_REPO}/releases/download/${XRAY_VERSION}"
  ensure_tmp_dir
  archive="${TMP_DIR}/${asset}"
  digest="${archive}.dgst"
  extracted="${TMP_DIR}/xray"

  info "Downloading isolated Xray core ${XRAY_VERSION}..."
  curl -fL --ipv4 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
    -o "$archive" "${release_base}/${asset}"
  curl -fL --ipv4 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
    -o "$digest" "${release_base}/${asset}.dgst"
  expected="$(awk -F'= ' '$1 == "SHA2-256" {print tolower($2)}' "$digest")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "The official Xray digest is invalid."
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "Xray archive SHA-256 verification failed."
  unzip -p "$archive" xray >"$extracted"
  chmod 755 "$extracted"
  "$extracted" version >/dev/null 2>&1 || die "The downloaded Xray binary cannot run."
  mkdir -p "$BIN_DIR"
  ensure_xray_runtime_access
  install -o root -g root -m 755 "$extracted" "${BIN}.new"
  mv -f -- "${BIN}.new" "$BIN"
  ensure_xray_runtime_access
  ok "Isolated Xray installed: $BIN"
}

ensure_xray() {
  # Repair installations made by v1.1.0 before testing/reusing the binary.
  ensure_xray_runtime_access
  if [[ -x "$BIN" ]] && "$BIN" version 2>/dev/null | grep -Fq "${XRAY_VERSION#v}"; then
    return 0
  fi
  download_xray
}

install_self() {
  local state_tmp
  [[ "$0" == "$SELF_PATH" ]] && return 0
  if [[ -r "$0" && -f "$0" ]]; then
    install -o root -g root -m 755 "$0" "$SELF_PATH" 2>/dev/null || true
  fi
  ensure_tmp_dir
  state_tmp="${TMP_DIR}/source.env"
  printf 'REPO=%s\nREF=%s\nSELF_URL=%s\n' "$REPO" "$REF" "$SELF_URL" >"$state_tmp"
  install -o root -g root -m 640 "$state_tmp" "$SOURCE_STATE"
}

backup_file() {
  local file="$1" stamp
  [[ -e "$file" ]] || return 0
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -a -- "$file" "${file}.bak-${stamp}"
  info "Backup: ${file}.bak-${stamp}"
}

service_paths() {
  local role="$1" name="$2"
  CONFIG="${CONFIG_DIR}/${role}-${name}.json"
  SERVICE="xhttp-cdn-${role}-${name}"
  UNIT="${SYSTEMD_DIR}/${SERVICE}.service"
  if [[ "$role" == "server" ]]; then
    NGINX_CONFIG="${NGINX_CONF_DIR}/xhttp-cdn-${name}.conf"
  else
    NGINX_CONFIG=""
  fi
}

native_xhttp_extra_json() {
  local max_connections_json
  if [[ "${XMUX_MAX_CONNECTIONS:-0}" =~ ^[0-9]+$ ]]; then
    max_connections_json="${XMUX_MAX_CONNECTIONS:-0}"
  else
    max_connections_json="\"${XMUX_MAX_CONNECTIONS:-0}\""
  fi
  jq -cn \
    --arg padding "${XMUX_X_PADDING_BYTES:-100-1000}" \
    --arg stream_up "${XMUX_STREAM_UP_SECS:-20-80}" \
    --arg max_concurrency "${XMUX_MAX_CONCURRENCY:-8-16}" \
    --arg c_reuse "${XMUX_C_MAX_REUSE_TIMES:-2-8}" \
    --arg h_requests "${XMUX_H_MAX_REQUEST_TIMES:-600-900}" \
    --arg h_reusable "${XMUX_H_MAX_REUSABLE_SECS:-1800-3000}" \
    --argjson max_connections "$max_connections_json" \
    '{
      xPaddingBytes: $padding,
      scStreamUpServerSecs: $stream_up,
      xmux: {
        maxConcurrency: $max_concurrency,
        maxConnections: $max_connections,
        cMaxReuseTimes: $c_reuse,
        hMaxRequestTimes: $h_requests,
        hMaxReusableSecs: $h_reusable
      }
    }'
}

write_server_config() {
  local destination="$1" extra origin_port_json
  origin_port_json=$((10#${ORIGIN_PORT:-18080}))
  extra="$(native_xhttp_extra_json)"
  jq -n \
    --arg instance "${INSTANCE:-cf1}" \
    --arg uuid "$UUID" \
    --arg path "$XHTTP_PATH" \
    --arg mode "${XHTTP_MODE:-auto}" \
    --argjson port "$origin_port_json" \
    --argjson extra "$extra" \
    '{
      log: {loglevel: "warning"},
      inbounds: [{
        tag: ("xhttp-cdn-server-" + $instance),
        listen: "127.0.0.1",
        port: $port,
        protocol: "vless",
        settings: {
          clients: [{id: $uuid, email: ("xhttp-cdn-" + $instance)}],
          decryption: "none"
        },
        streamSettings: {
          network: "xhttp",
          security: "none",
          sockopt: {tcpKeepAliveIdle: 60, tcpKeepAliveInterval: 15, tcpFastOpen: true},
          xhttpSettings: {path: $path, mode: $mode, extra: $extra}
        }
      }],
      outbounds: [{tag: "direct", protocol: "freedom"}]
    }' >"$destination"
}

write_client_config() {
  local destination="$1" inbounds='[]' tags='[]' i listen_port target_port tag network extra dns_json edge_port_json socks_port_json mtu_json
  local scope="${TRAFFIC_SCOPE:-ports}"
  edge_port_json=$((10#${EDGE_PORT:-443}))
  socks_port_json=$((10#${SOCKS_PORT:-10808}))
  mtu_json=$((10#${TUN_MTU:-1500}))
  if [[ "$scope" == ports || "$scope" == all ]]; then
    for i in "${!MAPPING_LISTEN_PORTS[@]}"; do
      listen_port="${MAPPING_LISTEN_PORTS[$i]}"
      target_port="${MAPPING_TARGET_PORTS[$i]}"
      network="$(mapping_network "${MAPPING_PROTOCOLS[$i]:-tcp}")"
      tag="xhttp-map-${MAPPING_PROTOCOLS[$i]:-tcp}-${listen_port}-${target_port}"
      inbounds="$(jq -c \
        --arg tag "$tag" \
        --arg listen "${BIND_ADDRESS:-0.0.0.0}" \
        --arg target "${TARGET_HOST:-127.0.0.1}" \
        --arg network "$network" \
        --argjson listen_port "$((10#$listen_port))" \
        --argjson target_port "$((10#$target_port))" \
        '. + [{
          tag: $tag,
          listen: $listen,
          port: $listen_port,
          protocol: "dokodemo-door",
          settings: {address: $target, port: $target_port, network: $network}
        }]' <<<"$inbounds")"
      tags="$(jq -c --arg tag "$tag" '. + [$tag]' <<<"$tags")"
    done
  fi

  if [[ "$scope" == socks || "$scope" == all ]]; then
    tag="xhttp-socks"
    inbounds="$(jq -c \
      --arg tag "$tag" --arg listen "${SOCKS_BIND:-127.0.0.1}" \
      --argjson port "$socks_port_json" \
      '. + [{tag:$tag, listen:$listen, port:$port, protocol:"socks",
             settings:{auth:"noauth", udp:true}}]' <<<"$inbounds")"
    tags="$(jq -c --arg tag "$tag" '. + [$tag]' <<<"$tags")"
  fi

  if [[ "$scope" == tun || "$scope" == all ]]; then
    resolve_tun_outbound_interface || die "Invalid TUN_OUTBOUND_INTERFACE."
    tag="xhttp-tun"
    dns_json='[]'
    local dns
    IFS=',' read -r -a dns_values <<<"${TUN_DNS:-1.1.1.1,8.8.8.8}"
    for dns in "${dns_values[@]}"; do
      dns_json="$(jq -c --arg dns "$dns" '. + [$dns]' <<<"$dns_json")"
    done
    inbounds="$(jq -c \
      --arg tag "$tag" --arg name "${TUN_NAME:-xhttp0}" \
      --arg gateway "${TUN_GATEWAY:-172.30.0.1/30}" \
      --argjson mtu "$mtu_json" --argjson dns "$dns_json" \
      --arg tun_interface "${TUN_OUTBOUND_INTERFACE:-auto}" \
      '. + [{tag:$tag, port:0, protocol:"tun", settings:{
        name:$name, desc:"XHTTP CDN full tunnel", mtu:$mtu, gateway:[$gateway],
        dns:$dns, userLevel:0, autoSystemRoutingTable:["0.0.0.0/0"],
        autoOutboundsInterface:$tun_interface}}]' <<<"$inbounds")"
    tags="$(jq -c --arg tag "$tag" '. + [$tag]' <<<"$tags")"
  fi

  extra="$(native_xhttp_extra_json)"
  jq -n \
    --argjson inbounds "$inbounds" \
    --argjson tags "$tags" \
    --arg clean_ip "$CLEAN_IP" \
    --arg domain "$DOMAIN" \
    --arg uuid "$UUID" \
    --arg path "$XHTTP_PATH" \
    --arg mode "${XHTTP_MODE:-auto}" \
    --argjson edge_port "$edge_port_json" \
    --argjson extra "$extra" \
    '{
      log: {loglevel: "warning"},
      inbounds: $inbounds,
      outbounds: [{
        tag: "xhttp-cdn-out",
        protocol: "vless",
        settings: {
          vnext: [{
            address: $clean_ip,
            port: $edge_port,
            users: [{id: $uuid, encryption: "none"}]
          }]
        },
        streamSettings: {
          network: "xhttp",
          security: "tls",
          sockopt: {tcpKeepAliveIdle: 60, tcpKeepAliveInterval: 15, tcpFastOpen: true},
          tlsSettings: {
            serverName: $domain,
            allowInsecure: false,
            fingerprint: "chrome",
            alpn: ["h2"]
          },
          xhttpSettings: {host: $domain, path: $path, mode: $mode, extra: $extra}
        }
      }],
      routing: {
        domainStrategy: "AsIs",
        rules: [{type: "field", inboundTag: $tags, outboundTag: "xhttp-cdn-out"}]
      }
    }' >"$destination"
}

ensure_tun_device() {
  [[ "$TRAFFIC_SCOPE" == tun || "$TRAFFIC_SCOPE" == all ]] || return 0
  if [[ ! -e /dev/net/tun ]]; then
    mkdir -p /dev/net 2>/dev/null || true
    modprobe tun 2>/dev/null || true
    [[ -e /dev/net/tun ]] || mknod /dev/net/tun c 10 200 2>/dev/null || true
    [[ -e /dev/net/tun ]] && chmod 666 /dev/net/tun || true
  fi
  if [[ -e /dev/net/tun ]]; then
    chown "${SERVICE_USER}:${SERVICE_USER}" /dev/net/tun 2>/dev/null || true
  else
    warn '/dev/net/tun is not available; the TUN profile will stay inactive until the kernel device is enabled.'
  fi
}

write_unit() {
  local destination="$1" role="$2" name="$3" config="$4"
  local capabilities='CAP_NET_BIND_SERVICE' device_allow='' address_families='AF_INET AF_INET6 AF_UNIX'
  if [[ "$role" == client && ("${TRAFFIC_SCOPE:-ports}" == tun || "${TRAFFIC_SCOPE:-ports}" == all) ]]; then
    # CAP_NET_ADMIN creates the TUN/routes; CAP_NET_RAW keeps SO_BINDTODEVICE
    # usable on kernels where CAP_NET_ADMIN alone is insufficient.
    capabilities='CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW'
    device_allow='DeviceAllow=/dev/net/tun rw'
    address_families+=' AF_NETLINK'
  fi
  cat >"$destination" <<EOF
[Unit]
Description=Independent XHTTP CDN ${role} (${name})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=20

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStartPre=${BIN} run -test -config ${config}
ExecStart=${BIN} run -config ${config}
Restart=always
RestartSec=2
TimeoutStopSec=15
KillMode=mixed
LimitNOFILE=1048576
AmbientCapabilities=${capabilities}
CapabilityBoundingSet=${capabilities}
${device_allow}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=${address_families}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_config() {
  local destination="$1" edge_port_json
  edge_port_json=$((10#${EDGE_PORT:-443}))
  cat >"$destination" <<EOF
# Managed only by xhttp-cdn-manager for instance: ${INSTANCE}
# A dedicated, previously unused hostname is required. Existing server blocks
# are never edited by this manager.
server {
    # Ubuntu 22.04/24.04 package compatibility (Nginx 1.18/1.24).
    listen ${edge_port_json} ssl http2;
    listen [::]:${edge_port_json} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:XHTTP_CDN:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    location ^~ ${XHTTP_PATH} {
        client_max_body_size 0;
        proxy_buffering off;
        proxy_request_buffering off;
        grpc_buffer_size 16k;
        grpc_read_timeout 3600s;
        grpc_send_timeout 3600s;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header CF-Connecting-IP \$http_cf_connecting_ip;
        grpc_pass grpc://127.0.0.1:${ORIGIN_PORT};
    }

    location / {
        default_type text/plain;
        return 404 "Not Found\n";
    }
}
EOF
}

validate_xray_config() {
  local file="$1" output
  if ! output="$("$BIN" run -test -config "$file" 2>&1)"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

domain_in_other_nginx_config() {
  local candidate line
  [[ -d "$NGINX_ROOT" ]] || return 1
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$NGINX_CONFIG" ]] && continue
    while IFS= read -r line; do
      [[ "$line" == *"server_name"*"$DOMAIN"* ]] && return 0
    done <"$candidate"
  done < <(find "$NGINX_ROOT" -type f \( -name '*.conf' -o -path '*/sites-enabled/*' \) -print0 2>/dev/null)
  return 1
}

check_port_available() {
  local port="$1" ignored_service="${2:-}" output owner_pid
  command -v ss >/dev/null 2>&1 || return 0
  output="$(ss -H -ltnup "sport = :${port}" 2>/dev/null || true)"
  [[ -z "$output" ]] && return 0
  if [[ -n "$ignored_service" ]]; then
    owner_pid="$(systemctl show -p MainPID --value "$ignored_service" 2>/dev/null || true)"
    if [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] && grep -Fq "pid=${owner_pid}," <<<"$output"; then
      return 0
    fi
  fi
  warn "Local port ${port} is already listening:"
  printf '%s\n' "$output"
  return 1
}

test_clean_ip() {
  local domain="$1" ip="$2" port="${3:-${EDGE_PORT:-443}}" status remote
  validate_domain "$domain" || die "Invalid domain: $domain"
  validate_ipv4 "$ip" || die "Invalid Cloudflare IPv4 address: $ip"
  validate_edge_port "$port" || die "Invalid Cloudflare edge port: $port"
  info "Testing TLS/H2 route ${ip}:${port} with SNI/Host ${domain}..."
  local result
  if ! result="$(curl -sS --ipv4 --http2 --connect-timeout 10 --max-time 20 \
      --resolve "${domain}:${port}:${ip}" -o /dev/null \
      -w '%{http_code}|%{remote_ip}' "https://${domain}:${port}/" 2>&1)"; then
    warn "The edge test failed: $result"
    return 1
  fi
  IFS='|' read -r status remote <<<"$result"
  [[ "$status" =~ ^[1-5][0-9][0-9]$ ]] || {
    warn "No valid HTTP response was received from the selected edge."
    return 1
  }
  ok "Cloudflare edge responded with HTTP ${status}; remote IP: ${remote}."
}

validate_server_request() {
  validate_instance "$INSTANCE" || die "Instance name must match [a-z0-9][a-z0-9_-]{0,31}."
  validate_domain "$DOMAIN" || die "Invalid dedicated Cloudflare hostname."
  validate_uuid "$UUID" || die "Invalid UUID."
  validate_xhttp_path "$XHTTP_PATH" || die "Path must be a secret /path using letters, numbers, slash, underscore or dash."
  validate_mode "$XHTTP_MODE" || die "XHTTP mode must be auto or packet-up."
  validate_port "$ORIGIN_PORT" || die "Invalid loopback origin port."
  validate_tunnel_direction "$TUNNEL_DIRECTION" || die "TUNNEL_DIRECTION must be direct or reverse."
  validate_traffic_scope "$TRAFFIC_SCOPE" || die "TRAFFIC_SCOPE must be ports, socks, tun or all."
  validate_edge_port "$EDGE_PORT" || die "EDGE_PORT is not a Cloudflare proxied port (443, 2053, 2083, 2087, 2096 or 8443). Set XHTTP_CDN_ALLOW_CUSTOM_EDGE_PORT=1 only when your edge supports another port."
  validate_xmux_settings || die "Invalid native XHTTP XMUX range."
  validate_watchdog_settings || die "Invalid watchdog settings."
  if [[ "$TRAFFIC_SCOPE" == socks || "$TRAFFIC_SCOPE" == all ]]; then
    validate_port "$SOCKS_PORT" || die "Invalid SOCKS_PORT."
    validate_bind_address "$SOCKS_BIND" || die "Invalid SOCKS_BIND."
    [[ "$SOCKS_BIND" == 127.0.0.1 || "$ALLOW_PUBLIC_SOCKS" == 1 ]] \
      || die "SOCKS_BIND is public. Keep it 127.0.0.1 or explicitly set XHTTP_CDN_ALLOW_PUBLIC_SOCKS=1."
  fi
  if [[ "$TRAFFIC_SCOPE" == tun || "$TRAFFIC_SCOPE" == all ]]; then
    validate_tun_settings || die "Invalid TUN settings."
  fi
  validate_cert_mode "$CERT_MODE" || die "Invalid certificate mode."
  if [[ "$CERT_MODE" == "letsencrypt" ]]; then
    validate_email "$ACME_EMAIL" || die "Invalid Let's Encrypt account email."
    validate_cloudflare_token "$CF_API_TOKEN" || die "Invalid Cloudflare API token."
  fi
}

validate_certificate_files() {
  validate_absolute_path "$TLS_CERT" || die "Unsafe TLS certificate path."
  validate_absolute_path "$TLS_KEY" || die "Unsafe TLS private-key path."
  [[ -r "$TLS_CERT" ]] || die "TLS certificate is not readable: $TLS_CERT"
  [[ -r "$TLS_KEY" ]] || die "TLS private key is not readable: $TLS_KEY"
}

validate_client_values() {
  validate_instance "$INSTANCE" || die "Instance name must match [a-z0-9][a-z0-9_-]{0,31}."
  validate_domain "$DOMAIN" || die "Invalid Cloudflare hostname."
  validate_uuid "$UUID" || die "Invalid UUID."
  validate_xhttp_path "$XHTTP_PATH" || die "Invalid XHTTP path."
  validate_mode "$XHTTP_MODE" || die "XHTTP mode must be auto or packet-up."
  validate_tunnel_direction "$TUNNEL_DIRECTION" || die "TUNNEL_DIRECTION must be direct or reverse."
  validate_traffic_scope "$TRAFFIC_SCOPE" || die "TRAFFIC_SCOPE must be ports, socks, tun or all."
  validate_edge_port "$EDGE_PORT" || die "EDGE_PORT is not a Cloudflare proxied port."
  validate_xmux_settings || die "Invalid native XHTTP XMUX range."
  validate_watchdog_settings || die "Invalid watchdog settings."
  validate_ipv4 "$CLEAN_IP" || die "Clean IP must be a valid Cloudflare IPv4 address."
  validate_bind_address "$BIND_ADDRESS" || die "Invalid local bind IPv4 address."
  validate_target_host "$TARGET_HOST" || die "Invalid foreign target host."
  if [[ "$TRAFFIC_SCOPE" == socks || "$TRAFFIC_SCOPE" == all ]]; then
    validate_port "$SOCKS_PORT" || die "Invalid SOCKS_PORT."
    validate_bind_address "$SOCKS_BIND" || die "Invalid SOCKS_BIND."
    [[ "$SOCKS_BIND" == 127.0.0.1 || "$ALLOW_PUBLIC_SOCKS" == 1 ]] \
      || die "SOCKS_BIND is public; set XHTTP_CDN_ALLOW_PUBLIC_SOCKS=1 explicitly if this is intentional."
  fi
  if [[ "$TRAFFIC_SCOPE" == tun || "$TRAFFIC_SCOPE" == all ]]; then
    validate_tun_settings || die "Invalid TUN settings."
    resolve_tun_outbound_interface || die "Invalid TUN_OUTBOUND_INTERFACE."
  fi
  if [[ "$TRAFFIC_SCOPE" == ports || "$TRAFFIC_SCOPE" == all ]]; then
    ((${#MAPPING_ITEMS[@]} > 0)) || die "At least one port mapping is required for the ports/all profile."
  fi
}

prepare_install() {
  local role="$1"
  require_root
  ensure_dependencies "$role"
  ensure_xray
  ensure_service_user
  mkdir -p "$CONFIG_DIR" "$SYSTEMD_DIR"
  chown root:"$SERVICE_USER" "$CONFIG_DIR"
  chmod 750 "$CONFIG_DIR"
  [[ "$role" != server ]] || mkdir -p "$NGINX_CONF_DIR"
  [[ "$role" != client ]] || ensure_tun_device
  install_self
}

snapshot_instance_state() {
  local role="$1" name="$2" snapshot_dir="$3" path
  service_paths "$role" "$name"
  mkdir -p "$snapshot_dir"
  for path in "$CONFIG" "$UNIT" "$NGINX_CONFIG" "$(metadata_path "$role" "$name")"; do
    [[ -n "$path" ]] || continue
    snapshot_file "$path" "${snapshot_dir}/$(basename "$path")"
  done
  watchdog_paths "$SERVICE"
  for path in "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"; do
    snapshot_file "$path" "${snapshot_dir}/$(basename "$path")"
  done
}

restore_instance_state() {
  local role="$1" name="$2" snapshot_dir="$3" path
  service_paths "$role" "$name"
  for path in "$CONFIG" "$UNIT" "$NGINX_CONFIG" "$(metadata_path "$role" "$name")"; do
    [[ -n "$path" ]] || continue
    restore_snapshot "${snapshot_dir}/$(basename "$path")" "$path"
  done
  watchdog_paths "$SERVICE"
  for path in "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"; do
    restore_snapshot "${snapshot_dir}/$(basename "$path")" "$path"
  done
}

rollback_failed_install() {
  local role="$1" name="$2" snapshot_dir="$3"
  # Keep every failure path recoverable, including a non-zero systemctl
  # enable/restart.  With `set -e`, those commands must be guarded explicitly
  # or the shell would exit before restoring the previous instance files.
  restore_instance_state "$role" "$name" "$snapshot_dir" || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ "$role" == server ]] && command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || true
    fi
  fi
}

enable_instance_watchdog() {
  local service="$1"
  [[ "$ENABLE_WATCHDOG" == 1 ]] || return 0
  write_watchdog_units "$service"
  systemctl daemon-reload
  systemctl enable --now "${service}-watchdog.timer" >/dev/null 2>&1 || \
    warn "Could not enable watchdog timer for ${service}; the tunnel itself is still installed."
}

disable_instance_watchdog() {
  local service="$1"
  watchdog_paths "$service"
  systemctl disable --now "${service}-watchdog.timer" "${service}-watchdog.service" >/dev/null 2>&1 || true
}

install_server_values() {
  local temp_config temp_unit temp_nginx previous_nginx snapshot_dir
  validate_server_request
  service_paths server "$INSTANCE"
  if [[ -e "$CONFIG" || -e "$UNIT" || -e "$NGINX_CONFIG" ]]; then
    confirm "Replace only the existing XHTTP CDN server instance '${INSTANCE}'?" || return 0
  fi
  domain_in_other_nginx_config && die "Another Nginx file already uses ${DOMAIN}. Use a dedicated unused subdomain; existing blocks are not edited."
  check_port_available "$ORIGIN_PORT" "$SERVICE" || die "Choose a free loopback origin port."
  prepare_server_certificate
  validate_certificate_files

  ensure_tmp_dir
  temp_config="${TMP_DIR}/server.json"
  temp_unit="${TMP_DIR}/server.service"
  temp_nginx="${TMP_DIR}/nginx.conf"
  previous_nginx="${TMP_DIR}/previous-nginx.conf"
  snapshot_dir="${TMP_DIR}/snapshot-server-${INSTANCE}"
  snapshot_instance_state server "$INSTANCE" "$snapshot_dir"
  write_server_config "$temp_config"
  write_unit "$temp_unit" server "$INSTANCE" "$CONFIG"
  write_nginx_config "$temp_nginx"
  validate_xray_config "$temp_config" || die "Xray rejected the generated server configuration."

  backup_file "$CONFIG"
  backup_file "$UNIT"
  backup_file "$NGINX_CONFIG"
  [[ -e "$NGINX_CONFIG" ]] && cp -a -- "$NGINX_CONFIG" "$previous_nginx"
  install -o root -g root -m 644 "$temp_nginx" "$NGINX_CONFIG"

  if ! nginx -t; then
    restore_instance_state server "$INSTANCE" "$snapshot_dir"
    nginx -t >/dev/null 2>&1 || true
    die "Nginx rejected the isolated snippet. The previous state was restored."
  fi
  install -o root -g "$SERVICE_USER" -m 640 "$temp_config" "$CONFIG"
  install -o root -g root -m 644 "$temp_unit" "$UNIT"
  write_metadata server "$INSTANCE"
  if [[ "$ENABLE_WATCHDOG" == 1 ]]; then
    write_watchdog_units "$SERVICE"
  else
    disable_instance_watchdog "$SERVICE"
    watchdog_paths "$SERVICE"
    rm -f -- "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
  fi
  if ! systemctl daemon-reload; then
    rollback_failed_install server "$INSTANCE" "$snapshot_dir"
    die "systemd could not reload after the XHTTP CDN change; the previous state was restored."
  fi
  if ! systemctl enable "$SERVICE" >/dev/null; then
    rollback_failed_install server "$INSTANCE" "$snapshot_dir"
    die "Could not enable the XHTTP CDN server service; the previous state was restored."
  fi
  if ! systemctl restart "$SERVICE"; then
    journalctl -u "$SERVICE" -n 80 --no-pager -o cat || true
    rollback_failed_install server "$INSTANCE" "$snapshot_dir"
    die "The XHTTP CDN server service could not restart; the previous state was restored."
  fi
  if ! (systemctl reload nginx 2>/dev/null || systemctl restart nginx); then
    rollback_failed_install server "$INSTANCE" "$snapshot_dir"
    die "Nginx could not reload after the XHTTP CDN change; the previous state was restored."
  fi
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE"; then
    journalctl -u "$SERVICE" -n 80 --no-pager -o cat || true
    rollback_failed_install server "$INSTANCE" "$snapshot_dir"
    die "The XHTTP CDN server service did not become active; the previous state was restored."
  fi
  enable_instance_watchdog "$SERVICE"

  ok "Independent XHTTP CDN endpoint is active."
  echo "Service      : $SERVICE"
  echo "Xray origin  : 127.0.0.1:${ORIGIN_PORT}"
  echo "CDN hostname : $DOMAIN"
  echo "XHTTP path   : $XHTTP_PATH"
  echo "Direction    : ${TUNNEL_DIRECTION^^} endpoint"
  echo "Profile      : $TRAFFIC_SCOPE"
  echo "Edge port    : $EDGE_PORT"
  echo "Certificate  : $CERT_MODE"
  echo "Cloudflare DNS: ${DOMAIN} -> XHTTP_ENDPOINT_SERVER (this server, Proxied ON)"
  echo
  cloudflare_checklist
  print_iran_easy_command "$INSTANCE"
}

print_client_route_summary() {
  local i listen_port target_port listener_label target_label protocol
  if [[ "${TUNNEL_DIRECTION:-direct}" == reverse ]]; then
    listener_label='FOREIGN_SERVER_IP'
    target_label='IRAN_SERVER_IP'
  else
    listener_label='IRAN_SERVER_IP'
    target_label='FOREIGN_SERVER_IP'
  fi
  echo "Users connect : ${listener_label} (public IP of this peer)"
  echo "Clean edge   : CLEAN_CLOUDFLARE_IP=${CLEAN_IP}:${EDGE_PORT:-443}"
  echo "CDN hostname : $DOMAIN"
  for i in "${!MAPPING_LISTEN_PORTS[@]}"; do
    listen_port="${MAPPING_LISTEN_PORTS[$i]}"
    target_port="${MAPPING_TARGET_PORTS[$i]}"
    protocol="${MAPPING_PROTOCOLS[$i]:-tcp}"
    echo "Route         : ${listener_label}:${listen_port} -> ${CLEAN_IP}:${EDGE_PORT:-443} -> ${DOMAIN} -> ${TARGET_HOST}:${target_port} (${protocol^^}; ${target_label} side)"
  done
  if [[ "${TRAFFIC_SCOPE:-ports}" == socks || "${TRAFFIC_SCOPE:-ports}" == all ]]; then
    echo "SOCKS         : ${SOCKS_BIND}:${SOCKS_PORT} (private by default)"
  fi
  if [[ "${TRAFFIC_SCOPE:-ports}" == tun || "${TRAFFIC_SCOPE:-ports}" == all ]]; then
    echo "TUN           : ${TUN_NAME} / gateway ${TUN_GATEWAY} / MTU ${TUN_MTU}"
  fi
}

install_client_values() {
  local temp_config temp_unit i snapshot_dir
  validate_client_values
  service_paths client "$INSTANCE"
  if [[ -e "$CONFIG" || -e "$UNIT" ]]; then
    confirm "Replace only the existing XHTTP CDN client instance '${INSTANCE}'?" || return 0
  fi
  for i in "${MAPPING_LISTEN_PORTS[@]}"; do
    if ! check_port_available "$i" "$SERVICE"; then
      die "Local mapping port ${i} is occupied; no process was stopped or removed."
    fi
  done
  if [[ "$TRAFFIC_SCOPE" == socks || "$TRAFFIC_SCOPE" == all ]]; then
    if ! check_port_available "$SOCKS_PORT" "$SERVICE"; then
      die "SOCKS_PORT ${SOCKS_PORT} is occupied; choose another private port."
    fi
  fi

  ensure_tmp_dir
  temp_config="${TMP_DIR}/client.json"
  temp_unit="${TMP_DIR}/client.service"
  snapshot_dir="${TMP_DIR}/snapshot-client-${INSTANCE}"
  snapshot_instance_state client "$INSTANCE" "$snapshot_dir"
  write_client_config "$temp_config"
  write_unit "$temp_unit" client "$INSTANCE" "$CONFIG"
  validate_xray_config "$temp_config" || die "Xray rejected the generated client configuration."

  backup_file "$CONFIG"
  backup_file "$UNIT"
  install -o root -g "$SERVICE_USER" -m 640 "$temp_config" "$CONFIG"
  install -o root -g root -m 644 "$temp_unit" "$UNIT"
  write_metadata client "$INSTANCE"
  if [[ "$ENABLE_WATCHDOG" == 1 ]]; then
    write_watchdog_units "$SERVICE"
  else
    disable_instance_watchdog "$SERVICE"
    watchdog_paths "$SERVICE"
    rm -f -- "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
  fi
  ensure_tun_device
  if ! systemctl daemon-reload; then
    rollback_failed_install client "$INSTANCE" "$snapshot_dir"
    die "systemd could not reload after the XHTTP CDN change; the previous state was restored."
  fi
  if ! systemctl enable "$SERVICE" >/dev/null; then
    rollback_failed_install client "$INSTANCE" "$snapshot_dir"
    die "Could not enable the XHTTP CDN client service; the previous state was restored."
  fi
  if ! systemctl restart "$SERVICE"; then
    journalctl -u "$SERVICE" -n 80 --no-pager -o cat || true
    rollback_failed_install client "$INSTANCE" "$snapshot_dir"
    die "The XHTTP CDN client service could not restart; the previous state was restored."
  fi
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE"; then
    journalctl -u "$SERVICE" -n 80 --no-pager -o cat || true
    rollback_failed_install client "$INSTANCE" "$snapshot_dir"
    die "The XHTTP CDN client service did not become active; the previous state was restored."
  fi
  enable_instance_watchdog "$SERVICE"

  ok "Independent XHTTP CDN peer tunnel is active."
  echo "Service     : $SERVICE"
  echo "Direction   : ${TUNNEL_DIRECTION^^} peer"
  echo "Profile     : $TRAFFIC_SCOPE"
  print_client_route_summary
  echo
  test_clean_ip "$DOMAIN" "$CLEAN_IP" || warn "The service is installed, but this clean IP is not currently reachable from this server."
}

reset_profile_defaults() {
  TUNNEL_DIRECTION="${XHTTP_CDN_TUNNEL_DIRECTION:-${XHTTP_CDN_DIRECTION:-direct}}"
  TRAFFIC_SCOPE="${XHTTP_CDN_TRAFFIC_SCOPE:-${XHTTP_CDN_SCOPE:-ports}}"
  EDGE_PORT="${XHTTP_CDN_EDGE_PORT:-443}"
  SOCKS_PORT="${XHTTP_CDN_SOCKS_PORT:-10808}"
  SOCKS_BIND="${XHTTP_CDN_SOCKS_BIND:-127.0.0.1}"
  TUN_NAME="${XHTTP_CDN_TUN_NAME:-xhttp0}"
  TUN_MTU="${XHTTP_CDN_TUN_MTU:-1500}"
  TUN_GATEWAY="${XHTTP_CDN_TUN_GATEWAY:-172.30.0.1/30}"
  TUN_DNS="${XHTTP_CDN_TUN_DNS:-1.1.1.1,8.8.8.8}"
  TUN_OUTBOUND_INTERFACE="${XHTTP_CDN_TUN_OUTBOUND_INTERFACE:-}"
  MAPPING_ITEMS=(); MAPPING_PROTOCOLS=(); MAPPING_LISTEN_PORTS=(); MAPPING_TARGET_PORTS=(); MAPPINGS=''
}

show_scope_choices() {
  cat <<'EOF'
Traffic scope / نوع تونل:
  ports = نگاشت TCP/UDP پورت‌ها (ساده و پیش‌فرض)
  socks = پراکسی SOCKS خصوصی روی همین سرور
  tun   = تونل کامل IPv4 از طریق رابط TUN
  all   = ports + SOCKS + TUN در یک اتصال XHTTP
EOF
}

collect_profile_options() {
  local direction_choice scope_choice mappings
  prompt_default "[profile] TUNNEL_DIRECTION (direct or reverse)" "${TUNNEL_DIRECTION:-direct}" direction_choice
  TUNNEL_DIRECTION="${direction_choice,,}"
  show_scope_choices
  prompt_default "TRAFFIC_SCOPE (ports/socks/tun/all)" "${TRAFFIC_SCOPE:-ports}" TRAFFIC_SCOPE
  TRAFFIC_SCOPE="${TRAFFIC_SCOPE,,}"
  prompt_default "EDGE_PORT (Cloudflare: 443, 2053, 2083, 2087, 2096, 8443)" "${EDGE_PORT:-443}" EDGE_PORT
  if [[ "$TRAFFIC_SCOPE" == ports || "$TRAFFIC_SCOPE" == all ]]; then
    prompt_default "PORT_MAPPINGS (tcp:2444=8444,udp:5353=53,both:8443=8443; Enter keeps peer prompt)" "" mappings
    [[ -z "$mappings" ]] || parse_mappings "$mappings" || die "Invalid PORT_MAPPINGS."
  fi
  if [[ "$TRAFFIC_SCOPE" == socks || "$TRAFFIC_SCOPE" == all ]]; then
    prompt_default "SOCKS_PORT" "${SOCKS_PORT:-10808}" SOCKS_PORT
    prompt_default "SOCKS_BIND (127.0.0.1 is recommended)" "${SOCKS_BIND:-127.0.0.1}" SOCKS_BIND
  fi
  if [[ "$TRAFFIC_SCOPE" == tun || "$TRAFFIC_SCOPE" == all ]]; then
    prompt_default "TUN_NAME (max 15 characters)" "${TUN_NAME:-xhttp0}" TUN_NAME
    prompt_default "TUN_MTU" "${TUN_MTU:-1500}" TUN_MTU
    prompt_default "TUN_GATEWAY (IPv4/CIDR)" "${TUN_GATEWAY:-172.30.0.1/30}" TUN_GATEWAY
    prompt_default "TUN_DNS (comma separated IPv4)" "${TUN_DNS:-1.1.1.1,8.8.8.8}" TUN_DNS
  fi
}

collect_server_easy_values() {
  reset_profile_defaults
  TUNNEL_DIRECTION="direct"
  TRAFFIC_SCOPE="ports"
  INSTANCE="cf1"
  ORIGIN_PORT="18080"
  UUID="$(generate_uuid)"
  XHTTP_PATH="$(generate_path)"
  XHTTP_MODE="auto"
  CERT_MODE="self-signed"
  ACME_EMAIL=""
  CF_API_TOKEN=""
  TLS_CERT=""
  TLS_KEY=""

  prompt_required "[1/1] CDN_HOSTNAME / دامنه کلودفلر (example: xhttp.example.com)" DOMAIN
  DOMAIN="${DOMAIN,,}"
  ok "All private XHTTP settings were generated automatically."
}

collect_server_advanced_values() {
  local suggested_uuid suggested_path default_cert default_key cert_choice
  reset_profile_defaults
  prompt_default "[1/6] INSTANCE_NAME (Enter is recommended)" "cf1" INSTANCE
  prompt_required "[2/6] CDN_HOSTNAME (orange-cloud domain, example: xhttp.example.com)" DOMAIN
  DOMAIN="${DOMAIN,,}"
  prompt_default "[3/6] INTERNAL_XRAY_PORT (private; do not open in firewall)" "18080" ORIGIN_PORT
  suggested_uuid="$(generate_uuid)"
  prompt_default "[4/6] VLESS_UUID (press Enter to generate)" "$suggested_uuid" UUID
  suggested_path="$(generate_path)"
  prompt_default "[5/6] SECRET_XHTTP_PATH (press Enter to generate)" "$suggested_path" XHTTP_PATH
  prompt_default "[6/6] XHTTP_MODE (press Enter for auto; alternative: packet-up)" "auto" XHTTP_MODE

  echo
  collect_profile_options

  echo
  echo "Origin certificate / گواهی سرور خارج:"
  echo "1) Automatic Let's Encrypt via Cloudflare DNS API (recommended / Full strict)"
  echo "2) Automatic self-signed certificate (easiest, no token / Cloudflare Full)"
  echo "3) Use an existing certificate"
  IFS= read -r -p "Choose [1-3, default 2 = easiest]: " cert_choice
  case "${cert_choice:-2}" in
    1)
      CERT_MODE="letsencrypt"
      prompt_required "Let's Encrypt account email" ACME_EMAIL
      echo "Create a Cloudflare token limited to this zone with Zone:DNS:Edit."
      echo "The token is stored locally as root-only and is never printed."
      IFS= read -r -s -p "Cloudflare API token: " CF_API_TOKEN
      echo
      ;;
    2)
      CERT_MODE="self-signed"
      ACME_EMAIL=""
      CF_API_TOKEN=""
      TLS_CERT=""
      TLS_KEY=""
      ;;
    3)
      CERT_MODE="existing"
      ACME_EMAIL=""
      CF_API_TOKEN=""
      default_cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
      default_key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
      if [[ ! -r "$default_cert" || ! -r "$default_key" ]]; then
        default_cert="/etc/ssl/cloudflare/${DOMAIN}.pem"
        default_key="/etc/ssl/cloudflare/${DOMAIN}.key"
      fi
      prompt_default "Origin TLS certificate path" "$default_cert" TLS_CERT
      prompt_default "Origin TLS private-key path" "$default_key" TLS_KEY
      ;;
    *) die "Invalid certificate selection." ;;
  esac
}

collect_client_values() {
  local setup_code mappings
  prompt_default "[1] INSTANCE_NAME (Enter is recommended)" "cf1" INSTANCE
  prompt_required "[2] XHC2/XHC1_PAIRING_CODE copied from the endpoint server" setup_code
  parse_setup_code "$setup_code" || die "Invalid or damaged XHC pairing code."
  # XHC2 carries the instance/profile itself. XHC1 keeps the operator's
  # explicitly selected name for backward compatibility.
  [[ "$setup_code" == XHC2_* ]] || INSTANCE="${INSTANCE:-cf1}"
  if [[ "$TUNNEL_DIRECTION" == reverse ]]; then
    prompt_required "[3] CLEAN_CLOUDFLARE_IP (edge IPv4; not Iran IP, not foreign IP)" CLEAN_IP
  else
    prompt_required "[3] CLEAN_CLOUDFLARE_IP (edge IPv4; not Iran IP, not foreign IP)" CLEAN_IP
  fi
  prompt_default "[4] PEER_BIND_ADDRESS (0.0.0.0 lets users reach this peer)" "0.0.0.0" BIND_ADDRESS
  prompt_default "[5] ENDPOINT_TARGET_HOST (usually 127.0.0.1)" "127.0.0.1" TARGET_HOST
  if [[ "$TRAFFIC_SCOPE" == ports || "$TRAFFIC_SCOPE" == all ]]; then
    echo
    echo "Port mapping / نگاشت پورت: LOCAL_PORT=REMOTE_TARGET_PORT"
    echo "Example: 2444=8444 means users connect to PEER_SERVER_IP:2444"
    echo "         and traffic reaches 127.0.0.1:8444 on the endpoint server."
    if ((${#MAPPING_ITEMS[@]} == 0)); then
      prompt_required "PORT_MAPPINGS (tcp:2444=8444, udp:5353=53, both:8443=8443)" mappings
      parse_mappings "$mappings" || die "Invalid mappings. Use LOCAL_PORT=REMOTE_TARGET_PORT."
    else
      echo "Embedded PORT_MAPPINGS: $(serialize_mappings)"
    fi
  fi
}

collect_client_easy_values() {
  local setup_code="$1" mappings
  [[ -n "$setup_code" ]] || die "The automatic Iran command is missing its private pairing data."
  parse_setup_code "$setup_code" || die "The automatic Iran command is invalid or damaged. Copy the whole command again."
  [[ "$setup_code" == XHC2_* ]] || INSTANCE="cf1"
  BIND_ADDRESS="0.0.0.0"
  TARGET_HOST="127.0.0.1"

  ok "Foreign settings received automatically; no setup code entry is needed."
  prompt_required "[1] CLEAN_CLOUDFLARE_IP (not Iran IP, not foreign IP)" CLEAN_IP
  if [[ "$TRAFFIC_SCOPE" == ports || "$TRAFFIC_SCOPE" == all ]]; then
    if ((${#MAPPING_ITEMS[@]} == 0)); then
      echo
      echo "Port mapping: LOCAL_PORT=REMOTE_TARGET_PORT"
      echo "Example: 2444=8444"
      prompt_required "[2] PORT_MAPPING" mappings
      parse_mappings "$mappings" || die "Invalid mapping. Example: 2444=8444 or 2444=8444,2083=2083."
    else
      echo "Embedded PORT_MAPPING: $(serialize_mappings)"
    fi
  fi
}

install_server_interactive() {
  show_server_install_guide
  collect_server_easy_values
  prepare_install server
  install_server_values
}

install_reverse_server_interactive() {
  show_reverse_server_install_guide
  collect_server_easy_values
  TUNNEL_DIRECTION="reverse"
  prepare_install server
  install_server_values
}

install_server_advanced_interactive() {
  show_server_install_guide
  collect_server_advanced_values
  prepare_install server
  install_server_values
}

install_client_interactive() {
  show_client_install_guide
  prepare_install client
  collect_client_values
  install_client_values
}

install_client_easy_interactive() {
  local setup_code="$1"
  require_root
  if [[ "$setup_code" == XHC2_* ]]; then
    parse_setup_code "$setup_code" || die "The automatic peer command is invalid or damaged."
  fi
  logo
  if [[ "${TUNNEL_DIRECTION:-direct}" == reverse ]]; then
    echo "EASY REVERSE PEER INSTALL / نصب آسان سمت مقابل ریورس"
  else
    echo "EASY IRAN INSTALL / نصب آسان ایران"
  fi
  echo "Private foreign settings are already inside the copied command."
  echo
  collect_client_easy_values "$setup_code"
  prepare_install client
  install_client_values
}

install_reverse_client_interactive() {
  local setup_code="${1:-${XHTTP_CDN_SETUP_CODE:-}}"
  [[ -n "$setup_code" ]] || die "Paste the complete reverse peer command or set XHTTP_CDN_SETUP_CODE."
  install_client_easy_interactive "$setup_code"
}

cloudflare_checklist() {
  local ssl_mode="Full (strict)"
  [[ "${CERT_MODE:-letsencrypt}" == "self-signed" ]] && ssl_mode="Full"
  cat <<EOF
Cloudflare requirements:
  1. Create A for CDN_HOSTNAME -> the XHTTP endpoint server.
  2. Enable Proxy (orange cloud).
  3. Set SSL/TLS mode to ${ssl_mode}.
  4. Enable Network -> gRPC.
  5. Allow TCP/${EDGE_PORT:-443} to Nginx on the endpoint server.
  6. On the peer, enter CLEAN_CLOUDFLARE_IP; SNI/Host stays CDN_HOSTNAME.
  7. Users connect to the peer public IP; the endpoint stays behind Cloudflare.

This profile uses TLS/H2 + XHTTP auto (stream-up through Cloudflare). If the
CDN path is incompatible, create the instance with packet-up mode. XHTTP uses
its native XMUX (max concurrency ${XMUX_MAX_CONCURRENCY:-8-16}); mux.cool is
intentionally not enabled. The ${TRAFFIC_SCOPE:-ports} profile carries the
selected port mappings, private SOCKS listener and/or full IPv4 TUN.
EOF
}

discover_instances() {
  local filter="${1:-all}" file base role name service status
  INSTANCE_ROLES=()
  INSTANCE_NAMES=()
  INSTANCE_STATUSES=()
  shopt -s nullglob
  for file in "$CONFIG_DIR"/server-*.json "$CONFIG_DIR"/client-*.json; do
    base="$(basename "$file" .json)"
    role="${base%%-*}"
    name="${base#*-}"
    [[ "$filter" == "all" || "$role" == "$filter" ]] || continue
    validate_instance "$name" || continue
    service="xhttp-cdn-${role}-${name}"
    status="$(systemctl is-active "$service" 2>/dev/null || true)"
    INSTANCE_ROLES+=("$role")
    INSTANCE_NAMES+=("$name")
    INSTANCE_STATUSES+=("${status:-unknown}")
  done
  shopt -u nullglob
}

list_instances() {
  local i
  discover_instances all
  if ((${#INSTANCE_NAMES[@]} == 0)); then
    warn "No XHTTP CDN installations found."
    return 0
  fi
  for i in "${!INSTANCE_NAMES[@]}"; do
    printf '%d) %s / %s / %s\n' "$((i + 1))" \
      "${INSTANCE_ROLES[$i]}" "${INSTANCE_NAMES[$i]}" "${INSTANCE_STATUSES[$i]}"
  done
}

select_instance() {
  local filter="${1:-all}" choice index i number
  discover_instances "$filter"
  if ((${#INSTANCE_NAMES[@]} == 0)); then
    warn "No matching XHTTP CDN installation was found."
    return 1
  fi
  if ((${#INSTANCE_NAMES[@]} == 1)); then
    SELECTED_ROLE="${INSTANCE_ROLES[0]}"
    SELECTED_INSTANCE="${INSTANCE_NAMES[0]}"
    echo "Selected: ${SELECTED_ROLE} / ${SELECTED_INSTANCE}"
    return 0
  fi

  echo "Choose one installation:"
  for i in "${!INSTANCE_NAMES[@]}"; do
    printf '%d) %s / %s / %s\n' "$((i + 1))" \
      "${INSTANCE_ROLES[$i]}" "${INSTANCE_NAMES[$i]}" "${INSTANCE_STATUSES[$i]}"
  done
  while true; do
    IFS= read -r -p "Number [1-${#INSTANCE_NAMES[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      number=$((10#$choice))
      if ((number >= 1 && number <= ${#INSTANCE_NAMES[@]})); then
        index=$((number - 1))
        SELECTED_ROLE="${INSTANCE_ROLES[$index]}"
        SELECTED_INSTANCE="${INSTANCE_NAMES[$index]}"
        return 0
      fi
    fi
    warn "Enter one number from the list."
  done
}

show_iran_command_interactive() {
  local requested="${1:-}"
  require_root
  if [[ -n "$requested" ]]; then
    validate_instance "$requested" || die "Invalid instance name."
    SELECTED_INSTANCE="$requested"
  else
    select_instance server || return 0
  fi
  print_iran_easy_command "$SELECTED_INSTANCE"
}

remove_instance() {
  local role="$1" name="$2" service config unit nginx_config command_file peer_file metadata_file watchdog_service watchdog_timer
  service_paths "$role" "$name"
  service="$SERVICE"
  config="$CONFIG"
  unit="$UNIT"
  nginx_config="$NGINX_CONFIG"
  command_file="$(iran_command_file "$name")"
  peer_file="$(peer_command_file "$name")"
  metadata_file="$(metadata_path "$role" "$name")"
  watchdog_paths "$service"
  watchdog_service="$WATCHDOG_SERVICE"
  watchdog_timer="$WATCHDOG_TIMER"

  systemctl disable --now "$service" 2>/dev/null || true
  systemctl disable --now "${service}-watchdog.timer" "${service}-watchdog.service" 2>/dev/null || true
  rm -f -- "$unit" "$config" "$metadata_file" "$watchdog_service" "$watchdog_timer"
  if [[ "$role" == "server" ]]; then
    rm -f -- "$nginx_config" "$command_file" "$peer_file" \
      "${CERT_DIR}/${name}.crt" "${CERT_DIR}/${name}.key" \
      "${CERTBOT_CREDENTIALS_DIR}/cloudflare-${name}.ini"
    nginx -t && systemctl reload nginx || true
  fi
  systemctl daemon-reload
  systemctl reset-failed "$service" 2>/dev/null || true
  ok "Removed ${role} / ${name}. Other tunnel transports were untouched."
}

remove_instance_interactive() {
  require_root
  select_instance all || return 0
  confirm "Delete ${SELECTED_ROLE} / ${SELECTED_INSTANCE}?" || {
    echo "Cancelled."
    return 0
  }
  remove_instance "$SELECTED_ROLE" "$SELECTED_INSTANCE"
}

update_core() {
  local service
  require_root
  ensure_dependencies client
  download_xray
  while IFS= read -r service; do
    [[ -n "$service" ]] && systemctl restart "$service" || true
  done < <(systemctl list-unit-files --type=service --no-legend 'xhttp-cdn-*.service' 2>/dev/null \
    | awk '$1 !~ /-watchdog\.service$/ {sub(/\.service$/, "", $1); print $1}')
  ok "Isolated XHTTP CDN Xray core updated; unrelated Xray and tunnel services were not restarted."
}

update_manager() {
  local temp url separator='?'
  require_root
  ensure_tmp_dir
  temp="${TMP_DIR}/oneclick-xhttp-cdn.sh"
  [[ "$SELF_URL" == *\?* ]] && separator='&'
  url="${SELF_URL}${separator}cb=$(date +%s)"
  curl -fL --ipv4 --retry 3 --connect-timeout 15 -o "$temp" "$url"
  bash -n "$temp" || die "Downloaded manager failed the shell syntax check."
  install -o root -g root -m 755 "$temp" "$SELF_PATH"
  ok "Manager updated: $SELF_PATH"
}

logo() {
  printf '%s%sIndependent XHTTP CDN / Clean-IP Forwarder%s\n' "$C_CYAN" "$C_BOLD" "$C_RESET"
  printf 'Manager %s | isolated Xray %s\n\n' "$SCRIPT_VERSION" "$XRAY_VERSION"
}

main_menu() {
  local choice domain ip edge_port
  while true; do
    clear 2>/dev/null || true
    logo
    echo "1) EASY DIRECT endpoint on FOREIGN server (asks only CDN_HOSTNAME)"
    echo "2) Show/copy the PEER install command"
    echo "3) Delete an XHTTP CDN installation"
    echo "4) Show status"
    echo "5) Test CLEAN_CLOUDFLARE_IP on the peer server"
    echo "6) Update the isolated Xray core"
    echo "7) Update this XHTTP CDN manager"
    echo "8) Show the simple guide"
    echo "9) EASY REVERSE endpoint (normally on IRAN; asks only CDN_HOSTNAME)"
    echo "10) ADVANCED direct/reverse profile (ports/SOCKS/TUN/all)"
    echo "0) Return/exit"
    echo
    IFS= read -r -p "Choose [0-10]: " choice
    case "$choice" in
      1) install_server_interactive; pause_menu ;;
      2) show_iran_command_interactive; pause_menu ;;
      3) remove_instance_interactive; pause_menu ;;
      4) list_instances; pause_menu ;;
      5)
        ensure_dependencies client
        echo "Run this test on the IRAN server."
        prompt_required "CDN_HOSTNAME (example: xhttp.example.com)" domain
        prompt_required "CLEAN_CLOUDFLARE_IP (not Iran IP, not foreign IP)" ip
        prompt_default "EDGE_PORT" "443" edge_port
        test_clean_ip "${domain,,}" "$ip" "$edge_port" || true
        pause_menu
        ;;
      6) update_core; pause_menu ;;
      7) update_manager; pause_menu ;;
      8) show_simple_guide; echo; cloudflare_checklist; pause_menu ;;
      9) install_reverse_server_interactive; pause_menu ;;
      10) install_server_advanced_interactive; pause_menu ;;
      0|q|quit|exit) return 0 ;;
      *) warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
Independent XHTTP CDN Manager ${SCRIPT_VERSION}

Usage:
  xhttp-cdn-manager                 Open interactive menu
  xhttp-cdn-manager status          List only XHTTP CDN instances
  xhttp-cdn-manager peer-command    Show the saved/rebuilt peer command
  xhttp-cdn-manager iran-command    Compatibility alias for peer-command
  xhttp-cdn-manager reverse-server  Easy reverse endpoint (one hostname input)
  xhttp-cdn-manager remove          Delete one installation with a numbered choice
  xhttp-cdn-manager test-edge DOMAIN CLEAN_IP [EDGE_PORT]
  xhttp-cdn-manager update-core     Update only ${BIN}
  xhttp-cdn-manager checklist       Show Cloudflare requirements
  xhttp-cdn-manager guide           Show the easy two-step setup guide
  xhttp-cdn-manager easy-client     Automatic Iran install from the foreign command
  xhttp-cdn-manager easy-reverse-client  Automatic reverse peer install
  xhttp-cdn-manager advanced-server Show direct/reverse ports/SOCKS/TUN/all settings
  xhttp-cdn-manager advanced-client Manual peer install with an XHC1/XHC2 code
  xhttp-cdn-manager watchdog SERVICE Run one health check/restart
  xhttp-cdn-manager --version

The interactive installer creates either a direct or reverse XHTTP endpoint.
Its peer supports TCP/UDP/both port mappings, private SOCKS, full IPv4 TUN, or
all profiles together. The endpoint can obtain and renew Let's Encrypt
through a locally entered Cloudflare DNS API token, generate a self-signed
origin certificate automatically, or reuse an existing certificate. It never
edits existing transport configurations.
EOF
}

main() {
  local command="${1:-menu}" setup_code
  case "$command" in
    menu) require_root; main_menu ;;
    status) require_root; list_instances ;;
    iran-command|peer-command) [[ $# -le 2 ]] || { usage >&2; exit 2; }; show_iran_command_interactive "${2:-}" ;;
    remove) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; remove_instance_interactive ;;
    test-edge)
      [[ $# -ge 3 && $# -le 4 ]] || { usage >&2; exit 2; }
      ensure_dependencies client
      test_clean_ip "${2,,}" "$3" "${4:-443}"
      ;;
    update-core) update_core ;;
    checklist) cloudflare_checklist ;;
    guide) show_simple_guide; echo; cloudflare_checklist ;;
    advanced-server) install_server_advanced_interactive ;;
    advanced-client) install_client_interactive ;;
    reverse-server|easy-reverse-server) install_reverse_server_interactive ;;
    easy-client|--easy-client)
      [[ $# -le 2 ]] || die "Use the complete automatic command printed by the foreign server."
      setup_code="${2:-${XHTTP_CDN_SETUP_CODE:-}}"
      install_client_easy_interactive "$setup_code"
      ;;
    easy-reverse-client|reverse-client)
      [[ $# -le 2 ]] || die "Use the complete automatic command printed by the reverse endpoint."
      setup_code="${2:-${XHTTP_CDN_SETUP_CODE:-}}"
      install_reverse_client_interactive "$setup_code"
      ;;
    watchdog)
      [[ $# -eq 2 && "$2" == xhttp-cdn-* ]] || die "Usage: xhttp-cdn-manager watchdog xhttp-cdn-ROLE-INSTANCE"
      systemctl is-active --quiet "$2" || systemctl restart "$2"
      ;;
    -h|--help|help) usage ;;
    --version|version) echo "xhttp-cdn-manager ${SCRIPT_VERSION}" ;;
    *) usage >&2; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
