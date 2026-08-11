#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Independent XHTTP/CDN direct forwarder.
#
# This manager deliberately does not reuse or modify an existing Xray, X-UI,
# Backhaul, V2Quantum, Realm, Nginx server block, or systemd service.  It keeps
# its own Xray binary, JSON configurations, units, and Nginx snippets.

SCRIPT_VERSION="1.3.0"
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
  CLEAN_CLOUDFLARE_IP     = آی‌پی تمیز کلودفلر که فقط روی سرور ایران وارد می‌شود

Important / مهم:
  - Cloudflare DNS: CDN_HOSTNAME -> FOREIGN_SERVER_IP with Proxy ON (orange cloud).
  - Do not put IRAN_SERVER_IP or CLEAN_CLOUDFLARE_IP in that DNS record.
  - IRAN_SERVER_IP does not need Cloudflare Proxy.
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

show_client_install_guide() {
  cat <<'EOF'
============================================================
ADVANCED IRAN INSTALL / نصب دستی و پیشرفتهٔ ایران
============================================================
Run this option only on the IRAN server.

Normally, do not use this advanced command. Copy the WHOLE easy-install command printed by
the FOREIGN server and paste it on Iran. It asks only the clean IP and mapping.

This manual screen needs:
  1. XHC1_SETUP_CODE copied from the FOREIGN server.
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
  IRAN_SERVER_IP:2444 -> CLEAN_CLOUDFLARE_IP:443
  -> xhttp.example.com -> FOREIGN_SERVER_IP -> 127.0.0.1:8444
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
MAPPING_LISTEN_PORTS=()
MAPPING_TARGET_PORTS=()

parse_mappings() {
  local raw="${1//[[:space:]]/}" item listen_port target_port seen=,
  local -a items
  MAPPING_ITEMS=()
  MAPPING_LISTEN_PORTS=()
  MAPPING_TARGET_PORTS=()
  [[ -n "$raw" ]] || return 1
  IFS=',' read -r -a items <<<"$raw"
  for item in "${items[@]}"; do
    if [[ "$item" =~ ^([0-9]{1,5})=([0-9]{1,5})$ ]]; then
      listen_port="${BASH_REMATCH[1]}"
      target_port="${BASH_REMATCH[2]}"
    elif [[ "$item" =~ ^[0-9]{1,5}$ ]]; then
      listen_port="$item"
      target_port="$item"
    else
      return 1
    fi
    validate_port "$listen_port" && validate_port "$target_port" || return 1
    [[ "$seen" != *",${listen_port},"* ]] || return 1
    seen+="${listen_port},"
    MAPPING_ITEMS+=("${listen_port}=${target_port}")
    MAPPING_LISTEN_PORTS+=("$listen_port")
    MAPPING_TARGET_PORTS+=("$target_port")
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

make_iran_easy_command() {
  local setup_code="$1" url separator='?'
  [[ "$SELF_URL" == *\?* ]] && separator='&'
  url="${SELF_URL}${separator}cb=$(date +%s)"
  printf 'XHTTP_CDN_SETUP_CODE=%q XHTTP_CDN_REPO=%q XHTTP_CDN_REF=%q bash <(curl -fsSL --ipv4 %q) easy-client' \
    "$setup_code" "$REPO" "$REF" "$url"
}

iran_command_file() {
  local name="$1"
  printf '%s/iran-install-%s.txt' "$CONFIG_DIR" "$name"
}

save_iran_easy_command() {
  local command_file setup_code
  command_file="$(iran_command_file "$INSTANCE")"
  setup_code="$(make_setup_code)"
  mkdir -p "$CONFIG_DIR"
  make_iran_easy_command "$setup_code" >"$command_file"
  printf '\n' >>"$command_file"
  chmod 600 "$command_file"
}

load_server_pairing_values() {
  local name="$1" config nginx_config
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

  validate_domain "$DOMAIN" || die "Could not recover a valid CDN hostname for '${name}'."
  validate_uuid "$UUID" || die "Recovered UUID for '${name}' is invalid."
  validate_xhttp_path "$XHTTP_PATH" || die "Recovered XHTTP path for '${name}' is invalid."
  validate_mode "$XHTTP_MODE" || die "Recovered XHTTP mode for '${name}' is invalid."
}

print_iran_easy_command() {
  local name="$1" command_file
  load_server_pairing_values "$name"
  save_iran_easy_command
  command_file="$(iran_command_file "$INSTANCE")"
  echo
  printf '%sCOPY THIS ONE COMPLETE COMMAND TO THE IRAN SERVER:%s\n' "$C_BOLD" "$C_RESET"
  cat "$command_file"
  echo
  echo "On Iran it asks only: CLEAN_CLOUDFLARE_IP and PORT_MAPPING."
  echo "If this screen is lost, choose menu option 2 to show the command again."
}

parse_setup_code() {
  local code="$1" payload version parsed_domain parsed_uuid parsed_path parsed_port parsed_mode extra
  [[ "$code" == XHC1_* ]] || return 1
  payload="$(base64url_decode "${code#XHC1_}")" || return 1
  IFS='|' read -r version parsed_domain parsed_uuid parsed_path parsed_port parsed_mode extra <<<"$payload"
  [[ "$version" == "1" && -z "${extra:-}" ]] || return 1
  validate_domain "$parsed_domain" || return 1
  validate_uuid "$parsed_uuid" || return 1
  validate_xhttp_path "$parsed_path" || return 1
  [[ "$parsed_port" == "443" ]] || return 1
  validate_mode "$parsed_mode" || return 1
  DOMAIN="$parsed_domain"
  UUID="$parsed_uuid"
  XHTTP_PATH="$parsed_path"
  EDGE_PORT="$parsed_port"
  XHTTP_MODE="$parsed_mode"
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

write_server_config() {
  local destination="$1"
  jq -n \
    --arg instance "$INSTANCE" \
    --arg uuid "$UUID" \
    --arg path "$XHTTP_PATH" \
    --arg mode "$XHTTP_MODE" \
    --argjson port "$ORIGIN_PORT" \
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
          xhttpSettings: {path: $path, mode: $mode}
        }
      }],
      outbounds: [{tag: "direct", protocol: "freedom"}]
    }' >"$destination"
}

write_client_config() {
  local destination="$1" inbounds='[]' tags='[]' i listen_port target_port tag
  for i in "${!MAPPING_LISTEN_PORTS[@]}"; do
    listen_port="${MAPPING_LISTEN_PORTS[$i]}"
    target_port="${MAPPING_TARGET_PORTS[$i]}"
    tag="xhttp-map-${listen_port}-${target_port}"
    inbounds="$(jq -c \
      --arg tag "$tag" \
      --arg listen "$BIND_ADDRESS" \
      --arg target "$TARGET_HOST" \
      --argjson listen_port "$listen_port" \
      --argjson target_port "$target_port" \
      '. + [{
        tag: $tag,
        listen: $listen,
        port: $listen_port,
        protocol: "dokodemo-door",
        settings: {address: $target, port: $target_port, network: "tcp"}
      }]' <<<"$inbounds")"
    tags="$(jq -c --arg tag "$tag" '. + [$tag]' <<<"$tags")"
  done

  jq -n \
    --argjson inbounds "$inbounds" \
    --argjson tags "$tags" \
    --arg instance "$INSTANCE" \
    --arg clean_ip "$CLEAN_IP" \
    --arg domain "$DOMAIN" \
    --arg uuid "$UUID" \
    --arg path "$XHTTP_PATH" \
    --arg mode "$XHTTP_MODE" \
    '{
      log: {loglevel: "warning"},
      inbounds: $inbounds,
      outbounds: [{
        tag: "xhttp-cdn-out",
        protocol: "vless",
        settings: {
          vnext: [{
            address: $clean_ip,
            port: 443,
            users: [{id: $uuid, encryption: "none"}]
          }]
        },
        streamSettings: {
          network: "xhttp",
          security: "tls",
          tlsSettings: {
            serverName: $domain,
            allowInsecure: false,
            fingerprint: "chrome",
            alpn: ["h2"]
          },
          xhttpSettings: {
            host: $domain,
            path: $path,
            mode: $mode
          }
        }
      }],
      routing: {
        domainStrategy: "AsIs",
        rules: [{type: "field", inboundTag: $tags, outboundTag: "xhttp-cdn-out"}]
      }
    }' >"$destination"
}

write_unit() {
  local destination="$1" role="$2" name="$3" config="$4"
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
ExecStart=${BIN} run -config ${config}
Restart=always
RestartSec=2
TimeoutStopSec=15
KillMode=mixed
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_config() {
  local destination="$1"
  cat >"$destination" <<EOF
# Managed only by xhttp-cdn-manager for instance: ${INSTANCE}
# A dedicated, previously unused hostname is required. Existing server blocks
# are never edited by this manager.
server {
    # Ubuntu 22.04/24.04 package compatibility (Nginx 1.18/1.24).
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:XHTTP_CDN:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    location ^~ ${XHTTP_PATH} {
        client_max_body_size 0;
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
  output="$(ss -H -ltnp "sport = :${port}" 2>/dev/null || true)"
  [[ -z "$output" ]] && return 0
  if [[ -n "$ignored_service" ]]; then
    owner_pid="$(systemctl show -p MainPID --value "$ignored_service" 2>/dev/null || true)"
    if [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] && grep -Fq "pid=${owner_pid}," <<<"$output"; then
      return 0
    fi
  fi
  warn "TCP port ${port} is already listening:"
  printf '%s\n' "$output"
  return 1
}

test_clean_ip() {
  local domain="$1" ip="$2" status remote
  validate_domain "$domain" || die "Invalid domain: $domain"
  validate_ipv4 "$ip" || die "Invalid Cloudflare IPv4 address: $ip"
  info "Testing TLS/H2 route ${ip}:443 with SNI/Host ${domain}..."
  local result
  if ! result="$(curl -sS --ipv4 --http2 --connect-timeout 10 --max-time 20 \
      --resolve "${domain}:443:${ip}" -o /dev/null \
      -w '%{http_code}|%{remote_ip}' "https://${domain}/" 2>&1)"; then
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
  validate_ipv4 "$CLEAN_IP" || die "Clean IP must be a valid Cloudflare IPv4 address."
  validate_bind_address "$BIND_ADDRESS" || die "Invalid local bind IPv4 address."
  validate_target_host "$TARGET_HOST" || die "Invalid foreign target host."
  ((${#MAPPING_ITEMS[@]} > 0)) || die "At least one TCP mapping is required."
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
  install_self
}

install_server_values() {
  local temp_config temp_unit temp_nginx previous_nginx
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
    if [[ -e "$previous_nginx" ]]; then
      install -o root -g root -m 644 "$previous_nginx" "$NGINX_CONFIG"
    else
      rm -f -- "$NGINX_CONFIG"
    fi
    nginx -t >/dev/null 2>&1 || true
    die "Nginx rejected the isolated snippet. The previous state was restored."
  fi
  install -o root -g "$SERVICE_USER" -m 640 "$temp_config" "$CONFIG"
  install -o root -g root -m 644 "$temp_unit" "$UNIT"
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  systemctl restart "$SERVICE"
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  sleep 1
  systemctl is-active --quiet "$SERVICE" || {
    journalctl -u "$SERVICE" -n 80 --no-pager -o cat || true
    die "The XHTTP CDN server service did not become active."
  }

  ok "Independent XHTTP CDN endpoint is active."
  echo "Service      : $SERVICE"
  echo "Xray origin  : 127.0.0.1:${ORIGIN_PORT}"
  echo "CDN hostname : $DOMAIN"
  echo "XHTTP path   : $XHTTP_PATH"
  echo "Certificate  : $CERT_MODE"
  echo "Cloudflare DNS: ${DOMAIN} -> FOREIGN_SERVER_IP (this server, Proxied ON)"
  echo
  cloudflare_checklist
  print_iran_easy_command "$INSTANCE"
}

print_client_route_summary() {
  local i listen_port target_port
  echo "Users connect : IRAN_SERVER_IP (public IP of this server)"
  echo "Clean edge   : CLEAN_CLOUDFLARE_IP=${CLEAN_IP}:443"
  echo "CDN hostname : $DOMAIN"
  for i in "${!MAPPING_LISTEN_PORTS[@]}"; do
    listen_port="${MAPPING_LISTEN_PORTS[$i]}"
    target_port="${MAPPING_TARGET_PORTS[$i]}"
    echo "Route         : IRAN_SERVER_IP:${listen_port} -> ${CLEAN_IP}:443 -> ${DOMAIN} -> ${TARGET_HOST}:${target_port}"
  done
}

install_client_values() {
  local temp_config temp_unit i
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

  ensure_tmp_dir
  temp_config="${TMP_DIR}/client.json"
  temp_unit="${TMP_DIR}/client.service"
  write_client_config "$temp_config"
  write_unit "$temp_unit" client "$INSTANCE" "$CONFIG"
  validate_xray_config "$temp_config" || die "Xray rejected the generated client configuration."

  backup_file "$CONFIG"
  backup_file "$UNIT"
  install -o root -g "$SERVICE_USER" -m 640 "$temp_config" "$CONFIG"
  install -o root -g root -m 644 "$temp_unit" "$UNIT"
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  systemctl restart "$SERVICE"
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE"; then
    journalctl -u "$SERVICE" -n 80 --no-pager -o cat || true
    die "The XHTTP CDN client service did not become active."
  fi

  ok "Independent Iran-side XHTTP CDN forwarder is active."
  echo "Service     : $SERVICE"
  print_client_route_summary
  echo
  test_clean_ip "$DOMAIN" "$CLEAN_IP" || warn "The service is installed, but this clean IP is not currently reachable from this server."
}

collect_server_easy_values() {
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

  prompt_required "[1/1] DOMAIN / دامنه کلودفلر (example: xhttp.example.com)" DOMAIN
  DOMAIN="${DOMAIN,,}"
  ok "All private XHTTP settings were generated automatically."
}

collect_server_advanced_values() {
  local suggested_uuid suggested_path default_cert default_key cert_choice
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
  prompt_default "[1/5] INSTANCE_NAME (Enter is recommended)" "cf1" INSTANCE
  prompt_required "[2/5] XHC1_SETUP_CODE copied from the FOREIGN server" setup_code
  parse_setup_code "$setup_code" || die "Invalid or damaged XHC1 setup code."
  prompt_required "[3/5] CLEAN_CLOUDFLARE_IP (not Iran IP, not foreign IP)" CLEAN_IP
  prompt_default "[4/5] IRAN_BIND_ADDRESS (0.0.0.0 lets users reach this server)" "0.0.0.0" BIND_ADDRESS
  prompt_default "[5/5] FOREIGN_TARGET_HOST (usually 127.0.0.1)" "127.0.0.1" TARGET_HOST
  echo
  echo "Port mapping / نگاشت پورت: IRAN_PORT=FOREIGN_SERVICE_PORT"
  echo "Example: 2444=8444 means users connect to IRAN_SERVER_IP:2444"
  echo "         and traffic reaches 127.0.0.1:8444 on the FOREIGN server."
  prompt_required "TCP_PORT_MAPPINGS (example: 2444=8444 or 2444=8444,2083=2083)" mappings
  parse_mappings "$mappings" || die "Invalid mappings. Use IRAN_PORT=FOREIGN_SERVICE_PORT, separated by commas."
}

collect_client_easy_values() {
  local setup_code="$1" mappings
  [[ -n "$setup_code" ]] || die "The automatic Iran command is missing its private pairing data."
  parse_setup_code "$setup_code" || die "The automatic Iran command is invalid or damaged. Copy the whole command again."
  INSTANCE="cf1"
  BIND_ADDRESS="0.0.0.0"
  TARGET_HOST="127.0.0.1"

  ok "Foreign settings received automatically; no setup code entry is needed."
  prompt_required "[1/2] CLEAN_CLOUDFLARE_IP (not Iran IP, not foreign IP)" CLEAN_IP
  echo
  echo "Port mapping: IRAN_PORT=FOREIGN_SERVICE_PORT"
  echo "Example: 2444=8444"
  prompt_required "[2/2] PORT_MAPPING" mappings
  parse_mappings "$mappings" || die "Invalid mapping. Example: 2444=8444 or 2444=8444,2083=2083."
}

install_server_interactive() {
  show_server_install_guide
  collect_server_easy_values
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
  logo
  echo "EASY IRAN INSTALL / نصب آسان ایران"
  echo "Private foreign settings are already inside the copied command."
  echo
  collect_client_easy_values "$setup_code"
  prepare_install client
  install_client_values
}

cloudflare_checklist() {
  local ssl_mode="Full (strict)"
  [[ "${CERT_MODE:-letsencrypt}" == "self-signed" ]] && ssl_mode="Full"
  cat <<EOF
Cloudflare requirements:
  1. Create A for CDN_HOSTNAME -> FOREIGN_SERVER_IP.
  2. Enable Proxy (orange cloud).
  3. Set SSL/TLS mode to ${ssl_mode}.
  4. Enable Network -> gRPC.
  5. Allow TCP/443 to Nginx on the foreign server.
  6. On Iran, enter CLEAN_CLOUDFLARE_IP; SNI/Host stays CDN_HOSTNAME.
  7. Users connect to IRAN_SERVER_IP:IRAN_PORT; Iran stays DNS-only/direct.

This profile uses TLS/H2 + XHTTP auto (stream-up through Cloudflare). If the
CDN path is incompatible, create the instance with packet-up mode. XHTTP uses
its native XMUX; mux.cool is intentionally not enabled.
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
  local role="$1" name="$2" service config unit nginx_config command_file
  service_paths "$role" "$name"
  service="$SERVICE"
  config="$CONFIG"
  unit="$UNIT"
  nginx_config="$NGINX_CONFIG"
  command_file="$(iran_command_file "$name")"

  systemctl disable --now "$service" 2>/dev/null || true
  rm -f -- "$unit" "$config"
  if [[ "$role" == "server" ]]; then
    rm -f -- "$nginx_config" "$command_file" \
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
  done < <(systemctl list-unit-files --type=service --no-legend 'xhttp-cdn-*.service' 2>/dev/null | awk '{sub(/\.service$/, "", $1); print $1}')
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
  local choice domain ip
  while true; do
    clear 2>/dev/null || true
    logo
    echo "1) EASY install on FOREIGN server (asks only domain)"
    echo "2) Show/copy the IRAN install command"
    echo "3) Delete an XHTTP CDN installation"
    echo "4) Show status"
    echo "5) Test CLEAN_CLOUDFLARE_IP on the IRAN server"
    echo "6) Update the isolated Xray core"
    echo "7) Update this XHTTP CDN manager"
    echo "8) Show the simple guide"
    echo "0) Return/exit"
    echo
    IFS= read -r -p "Choose [0-8]: " choice
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
        test_clean_ip "${domain,,}" "$ip" || true
        pause_menu
        ;;
      6) update_core; pause_menu ;;
      7) update_manager; pause_menu ;;
      8) show_simple_guide; echo; cloudflare_checklist; pause_menu ;;
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
  xhttp-cdn-manager iran-command    Show the saved/rebuilt Iran command
  xhttp-cdn-manager remove          Delete one installation with a numbered choice
  xhttp-cdn-manager test-edge DOMAIN CLEAN_IP
  xhttp-cdn-manager update-core     Update only ${BIN}
  xhttp-cdn-manager checklist       Show Cloudflare requirements
  xhttp-cdn-manager guide           Show the easy two-step setup guide
  xhttp-cdn-manager easy-client     Automatic Iran install from the foreign command
  xhttp-cdn-manager advanced-server Show all optional foreign settings
  xhttp-cdn-manager advanced-client Manual Iran install with an XHC1 code
  xhttp-cdn-manager --version

The interactive installer creates a foreign XHTTP endpoint or an Iran-side
TCP port forwarder. The foreign installer can obtain and renew Let's Encrypt
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
    iran-command) [[ $# -le 2 ]] || { usage >&2; exit 2; }; show_iran_command_interactive "${2:-}" ;;
    remove) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; remove_instance_interactive ;;
    test-edge)
      [[ $# -eq 3 ]] || { usage >&2; exit 2; }
      ensure_dependencies client
      test_clean_ip "${2,,}" "$3"
      ;;
    update-core) update_core ;;
    checklist) cloudflare_checklist ;;
    guide) show_simple_guide; echo; cloudflare_checklist ;;
    advanced-server) install_server_advanced_interactive ;;
    advanced-client) install_client_interactive ;;
    easy-client|--easy-client)
      [[ $# -le 2 ]] || die "Use the complete automatic command printed by the foreign server."
      setup_code="${2:-${XHTTP_CDN_SETUP_CODE:-}}"
      install_client_easy_interactive "$setup_code"
      ;;
    -h|--help|help) usage ;;
    --version|version) echo "xhttp-cdn-manager ${SCRIPT_VERSION}" ;;
    *) usage >&2; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
