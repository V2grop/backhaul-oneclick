#!/usr/bin/env bash
set -Eeuo pipefail

# Backhaul Premium + DaggerConnect Quantum Manager v3.2.0 English
# Correct mode schema for backhaul_premium v1.4.0:
#   Server => [server]
#   Client => [client]
# Supports: tcp, tcpmux, xtcpmux, ws, wss, wsmux, wssmux, xwsmux, anytls, tun

SCRIPT_VERSION="v3.2.0"
GITHUB_REPO="V2grop/backhaul-oneclick"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/${BRANCH}"
CORE_SHA256="a57a8e0c4216e7971718104b5c9744a056d110411179fff789933caff0c53428"
DAGGER_SETUP_URL="https://raw.githubusercontent.com/itsFLoKi/DaggerConnect/main/setup.sh"

BASE_DIR="/root/backhaul-core"
BIN="${BASE_DIR}/backhaul_premium"
SELF_PATH="/root/backhaul_manager_v3_en_quantum.sh"
CERT_DIR="${BASE_DIR}/cert_files"
CERT_FILE="${CERT_DIR}/cert.crt"
KEY_FILE="${CERT_DIR}/cert.key"
SERVICE_DIR="/etc/systemd/system"

DEFAULT_POOL=8
DEFAULT_KEEPALIVE=40
DEFAULT_HEARTBEAT=10
DEFAULT_CHANNEL_SIZE=2048
DEFAULT_MUX_VERSION=2
DEFAULT_FRAME_SIZE=32768
DEFAULT_RECV_BUFFER=4194304
DEFAULT_STREAM_BUFFER=65536
DEFAULT_LOG_LEVEL="info"

C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_BOLD='\033[1m'

info() { echo -e "${C_CYAN}[i]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
die()  { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root: sudo -i"
}

pause() {
  echo
  read -r -p "Press Enter to continue..." _
}

prompt_default() {
  local prompt="$1" default="$2" out_var="$3" value
  read -r -p "${prompt} [${default}]: " value
  printf -v "$out_var" '%s' "${value:-$default}"
}

prompt_optional() {
  local prompt="$1" out_var="$2" value
  read -r -p "${prompt} (press Enter to skip): " value
  printf -v "$out_var" '%s' "$value"
}

prompt_yes_no() {
  local prompt="$1" default="$2" out_var="$3" value suffix
  [[ "$default" == "true" ]] && suffix="Y/n" || suffix="y/N"
  read -r -p "${prompt} [${suffix}]: " value
  value="${value,,}"
  if [[ -z "$value" ]]; then
    printf -v "$out_var" '%s' "$default"
  elif [[ "$value" =~ ^(y|yes|1|true)$ ]]; then
    printf -v "$out_var" '%s' "true"
  else
    printf -v "$out_var" '%s' "false"
  fi
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

validate_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 ))
}

ensure_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
  if ((${#missing[@]})); then
    info "Installing dependencies: ${missing[*]}"
    apt-get update -y >/dev/null
    apt-get install -y "${missing[@]}" >/dev/null
  fi
}

ensure_binary() {
  mkdir -p "$BASE_DIR" "$CERT_DIR"
  if [[ ! -f "$BIN" ]]; then
    info "Backhaul core not found. Downloading it from your GitHub repository..."
    local tmp_core
    tmp_core="$(mktemp)"
    curl -fL --retry 3 --connect-timeout 15 \
      -o "$tmp_core" "${RAW_BASE}/backhaul_premium?cb=$(date +%s)" \
      || { rm -f "$tmp_core"; die "Backhaul core download failed."; }
    echo "${CORE_SHA256}  $tmp_core" | sha256sum -c - >/dev/null \
      || { rm -f "$tmp_core"; die "Backhaul core checksum verification failed."; }
    install -o root -g root -m 700 "$tmp_core" "$BIN"
    rm -f "$tmp_core"
  fi
  chown root:root "$BIN"
  chmod 700 "$BIN"
  [[ -x "$BIN" ]] || die "Core binary is not executable: $BIN"
}

logo() {
  echo -e "${C_BLUE}${C_BOLD}"
  cat <<'EOF'
 ____    _    ____ _  ___   _    _   _ _
| __ )  / \  / ___| |/ / | | |  / \ | | | |
|  _ \ / _ \| |   | ' /| |_| | / _ \| | | |
| |_) / ___ \ |___| . \|  _  |/ ___ \| |_| |
|____/_/   \_\____|_|\_\_| |_/_/   \_\___/
EOF
  echo -e "${C_RESET}${C_GREEN}Lightning-fast reverse tunneling solution${C_RESET}"
}

server_summary() {
  local ip version
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  version="$($BIN -v 2>/dev/null || echo unknown)"
  echo -e "${C_YELLOW}Script Version:${C_RESET} $SCRIPT_VERSION"
  echo -e "${C_YELLOW}Core Version:${C_RESET}   $version"
  echo -e "${C_YELLOW}IP Address:${C_RESET}      ${ip:-unknown}"
  echo
}

is_mux_transport() {
  [[ "$1" =~ ^(tcpmux|xtcpmux|wsmux|wssmux|xwsmux)$ ]]
}

is_web_transport() {
  [[ "$1" =~ ^(ws|wss|wsmux|wssmux|xwsmux)$ ]]
}

is_tls_transport() {
  [[ "$1" =~ ^(wss|wssmux|anytls)$ ]]
}

choose_role() {
  echo -e "${C_CYAN}=== Server Role ===${C_RESET}"
  echo "1) Server (Iran side)"
  echo "2) Client (remote side)"
  local c
  read -r -p "Select [1/2]: " c
  case "$c" in
    1|server|iran) ROLE="server" ;;
    2|client|kharej) ROLE="client" ;;
    *) die "Invalid role selection." ;;
  esac
}

choose_transport() {
  echo
  echo -e "${C_CYAN}=== Transport Configuration ===${C_RESET}"
  echo " 1) tcp"
  echo " 2) tcpmux"
  echo " 3) xtcpmux"
  echo " 4) ws"
  echo " 5) wss"
  echo " 6) wsmux"
  echo " 7) wssmux"
  echo " 8) xwsmux"
  echo " 9) anytls"
  echo "10) tun"
  local c
  read -r -p "Select transport [1-10]: " c
  case "$c" in
    1|tcp) TRANSPORT="tcp" ;;
    2|tcpmux) TRANSPORT="tcpmux" ;;
    3|xtcpmux) TRANSPORT="xtcpmux" ;;
    4|ws) TRANSPORT="ws" ;;
    5|wss) TRANSPORT="wss" ;;
    6|wsmux) TRANSPORT="wsmux" ;;
    7|wssmux) TRANSPORT="wssmux" ;;
    8|xwsmux) TRANSPORT="xwsmux" ;;
    9|anytls) TRANSPORT="anytls" ;;
    10|tun) TRANSPORT="tun" ;;
    *) die "Invalid transport." ;;
  esac
}

normalize_bind() {
  local value="$1"
  if validate_port "$value"; then
    printf '0.0.0.0:%s' "$value"
  elif [[ "$value" == :* ]]; then
    printf '0.0.0.0%s' "$value"
  else
    printf '%s' "$value"
  fi
}

extract_port() {
  local addr="$1"
  printf '%s' "${addr##*:}"
}

validate_port_mapping_item() {
  local x="$1" a b c
  [[ "$x" =~ ^[0-9]{1,5}$ ]] && validate_port "$x" && return 0
  if [[ "$x" =~ ^([0-9]{1,5})=([0-9]{1,5})$ ]]; then
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
    validate_port "$a" && validate_port "$b" && return 0
  fi
  if [[ "$x" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
    validate_port "$a" && validate_port "$b" && return 0
  fi
  if [[ "$x" =~ ^([0-9]{1,5})-([0-9]{1,5}):([0-9]{1,5})$ ]]; then
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"
    validate_port "$a" && validate_port "$b" && validate_port "$c" && return 0
  fi
  return 1
}

normalize_ports() {
  local raw="${1// /}"
  PORT_ITEMS=()
  [[ -n "$raw" ]] || return 0
  IFS=',' read -r -a PORT_ITEMS <<< "$raw"
  local item
  for item in "${PORT_ITEMS[@]}"; do
    validate_port_mapping_item "$item" || die "Invalid port mapping: $item"
  done
}

generate_certificate() {
  mkdir -p "$CERT_DIR"
  if [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then
    return
  fi
  local cn="${TLS_SNI:-backhaul.local}"
  info "Generating a self-signed TLS certificate in $CERT_DIR"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes -x509 -days 3650 -sha256 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -subj "/CN=${cn}" >/dev/null 2>&1
  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
}

collect_common_settings() {
  NODELAY="true"
  POOL="$DEFAULT_POOL"
  KEEPALIVE="$DEFAULT_KEEPALIVE"
  HEARTBEAT="$DEFAULT_HEARTBEAT"
  CHANNEL_SIZE="$DEFAULT_CHANNEL_SIZE"
  MUX_VERSION="$DEFAULT_MUX_VERSION"
  MUX_CON="$DEFAULT_POOL"
  FRAME_SIZE="$DEFAULT_FRAME_SIZE"
  RECV_BUFFER="$DEFAULT_RECV_BUFFER"
  STREAM_BUFFER="$DEFAULT_STREAM_BUFFER"
  LOG_LEVEL="$DEFAULT_LOG_LEVEL"
  TOKEN=""
  EDGE_IP=""
  TLS_SNI=""
  ACCEPT_UDP="false"
  PROXY_PROTOCOL="false"

  echo
  echo -e "${C_CYAN}=== Basic Settings ===${C_RESET}"
  prompt_yes_no "Enable TCP_NODELAY" "true" NODELAY
  if [[ "$ROLE" == "client" && "$TRANSPORT" != "tun" ]]; then
    prompt_default "Connection Pool" "$DEFAULT_POOL" POOL
    validate_positive_int "$POOL" || die "Invalid connection pool."
  fi
  prompt_optional "Security token (leave blank for no token)" TOKEN
  prompt_default "Keepalive" "$DEFAULT_KEEPALIVE" KEEPALIVE
  prompt_default "Log Level" "$DEFAULT_LOG_LEVEL" LOG_LEVEL

  if [[ "$ROLE" == "server" && "$TRANSPORT" == "tcp" ]]; then
    prompt_yes_no "Forward UDP over TCP" "false" ACCEPT_UDP
  fi
  if [[ "$ROLE" == "server" && "$TRANSPORT" =~ ^(tcp|tcpmux|xtcpmux|wsmux|wssmux|xwsmux)$ ]]; then
    prompt_yes_no "Proxy Protocol" "false" PROXY_PROTOCOL
  fi

  if is_mux_transport "$TRANSPORT"; then
    echo
    echo -e "${C_CYAN}=== Mux Settings ===${C_RESET}"
    prompt_default "Mux Version" "$DEFAULT_MUX_VERSION" MUX_VERSION
    if [[ "$ROLE" == "server" ]]; then
      prompt_default "Mux Concurrency" "$DEFAULT_POOL" MUX_CON
    fi
    prompt_default "Mux Stream Buffer" "$DEFAULT_STREAM_BUFFER" STREAM_BUFFER
  fi
}

collect_connection_settings() {
  echo
  echo -e "${C_CYAN}=== Connection Configuration ===${C_RESET}"
  if [[ "$ROLE" == "server" ]]; then
    local bind
    prompt_default "Bind address or tunnel port" "8443" bind
    BIND_ADDR="$(normalize_bind "$bind")"
    TUNNEL_PORT="$(extract_port "$BIND_ADDR")"
    validate_port "$TUNNEL_PORT" || die "Invalid tunnel port."
  else
    read -r -p "Server address [IP:Port or Domain:Port]: " REMOTE_ADDR
    [[ "$REMOTE_ADDR" == *:* ]] || die "Address must include a port, for example vip.example.com:2095"
    TUNNEL_PORT="$(extract_port "$REMOTE_ADDR")"
    validate_port "$TUNNEL_PORT" || die "Invalid tunnel port."
    if is_web_transport "$TRANSPORT"; then
      prompt_optional "Edge IP/Domain" EDGE_IP
    fi
  fi
}

collect_tls_settings() {
  is_tls_transport "$TRANSPORT" || return 0
  echo
  echo -e "${C_CYAN}=== TLS Configuration ===${C_RESET}"
  if [[ "$TRANSPORT" == "anytls" ]]; then
    prompt_default "SNI" "www.digikala.com" TLS_SNI
  elif [[ "$ROLE" == "client" ]]; then
    prompt_optional "Optional TLS SNI" TLS_SNI
  fi
  if [[ "$ROLE" == "server" ]]; then
    generate_certificate
    TLS_CERT="$CERT_FILE"
    TLS_KEY="$KEY_FILE"
    prompt_default "TLS Certificate Path" "$CERT_FILE" TLS_CERT
    prompt_default "TLS Key Path" "$KEY_FILE" TLS_KEY
  fi
}

collect_tun_settings() {
  [[ "$TRANSPORT" == "tun" ]] || return 0
  echo
  echo -e "${C_CYAN}=== TUN Configuration ===${C_RESET}"
  TUN_ENCAPSULATION="tcp"
  prompt_default "TUN Encapsulation" "tcp" TUN_ENCAPSULATION
  [[ "$TUN_ENCAPSULATION" =~ ^(tcp|ipx)$ ]] || die "Encapsulation must be tcp or ipx."
  prompt_default "TUN Device Name" "backhaul" TUN_NAME
  if [[ "$ROLE" == "server" ]]; then
    prompt_default "TUN Local Address" "10.10.10.1/24" TUN_LOCAL_ADDR
    prompt_default "TUN Remote Address" "10.10.10.2/24" TUN_REMOTE_ADDR
  else
    prompt_default "TUN Local Address" "10.10.10.2/24" TUN_LOCAL_ADDR
    prompt_default "TUN Remote Address" "10.10.10.1/24" TUN_REMOTE_ADDR
  fi
  prompt_default "Health Port" "1234" TUN_HEALTH_PORT
  validate_port "$TUN_HEALTH_PORT" || die "Invalid health port."
  if [[ "$TUN_ENCAPSULATION" == "ipx" ]]; then
    prompt_default "MTU" "1320" TUN_MTU
  else
    prompt_default "MTU" "1500" TUN_MTU
  fi
}

collect_ports() {
  PORTS_RAW=""
  [[ "$ROLE" == "server" ]] || return 0
  echo
  echo -e "${C_CYAN}=== Port Mapping Configuration ===${C_RESET}"
  echo "Formats: 443 | 2444=443 | 443-600 | 443-600:5201"
  read -r -p "Ports separated by commas: " PORTS_RAW
  if [[ "$TRANSPORT" != "tun" && -z "${PORTS_RAW// /}" ]]; then
    die "At least one forwarded port is required."
  fi
  normalize_ports "$PORTS_RAW"
}

role_paths() {
  if [[ "$ROLE" == "server" ]]; then
    CONFIG="${BASE_DIR}/iran${TUNNEL_PORT}.toml"
    SERVICE="backhaul-iran${TUNNEL_PORT}"
    DESCRIPTION="Backhaul Iran ${TRANSPORT} Port ${TUNNEL_PORT}"
  else
    CONFIG="${BASE_DIR}/kharej${TUNNEL_PORT}.toml"
    SERVICE="backhaul-kharej${TUNNEL_PORT}"
    DESCRIPTION="Backhaul Kharej ${TRANSPORT} Port ${TUNNEL_PORT}"
  fi
  UNIT="${SERVICE_DIR}/${SERVICE}.service"
}

backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${f}.bak-${stamp}"
  info "Backup: ${f}.bak-${stamp}"
}

write_server_config() {
  {
    echo '[server]'
    echo "bind_addr = \"${BIND_ADDR}\""
    echo "transport = \"${TRANSPORT}\""
    [[ -n "$TOKEN" ]] && echo "token = \"${TOKEN}\""
    echo "keepalive_period = ${KEEPALIVE}"
    echo "nodelay = ${NODELAY}"
    echo "heartbeat = ${HEARTBEAT}"
    echo "channel_size = ${CHANNEL_SIZE}"
    [[ "$ACCEPT_UDP" == "true" ]] && echo 'accept_udp = true'
    [[ "$PROXY_PROTOCOL" == "true" ]] && echo 'proxy_protocol = true'
    if is_mux_transport "$TRANSPORT"; then
      echo "mux_con = ${MUX_CON}"
      echo "mux_version = ${MUX_VERSION}"
      echo "mux_framesize = ${FRAME_SIZE}"
      echo "mux_recievebuffer = ${RECV_BUFFER}"
      echo "mux_streambuffer = ${STREAM_BUFFER}"
    fi
    if is_tls_transport "$TRANSPORT"; then
      [[ -n "${TLS_SNI:-}" ]] && echo "sni = \"${TLS_SNI}\""
      echo "tls_cert = \"${TLS_CERT}\""
      echo "tls_key = \"${TLS_KEY}\""
    fi
    echo "log_level = \"${LOG_LEVEL}\""
    echo 'ports = ['
    local item
    for item in "${PORT_ITEMS[@]:-}"; do
      [[ -n "$item" ]] && echo "  \"${item}\","
    done
    echo ']'
    if [[ "$TRANSPORT" == "tun" ]]; then
      echo
      echo '[tun]'
      echo "encapsulation = \"${TUN_ENCAPSULATION}\""
      echo "name = \"${TUN_NAME}\""
      echo "local_addr = \"${TUN_LOCAL_ADDR}\""
      echo "remote_addr = \"${TUN_REMOTE_ADDR}\""
      echo "health_port = ${TUN_HEALTH_PORT}"
      echo "mtu = ${TUN_MTU}"
    fi
  } > "$CONFIG"
}

write_client_config() {
  {
    echo '[client]'
    echo "remote_addr = \"${REMOTE_ADDR}\""
    [[ -n "$EDGE_IP" ]] && echo "edge_ip = \"${EDGE_IP}\""
    echo "transport = \"${TRANSPORT}\""
    [[ -n "$TOKEN" ]] && echo "token = \"${TOKEN}\""
    [[ "$TRANSPORT" != "tun" ]] && echo "connection_pool = ${POOL}"
    echo "keepalive_period = ${KEEPALIVE}"
    echo 'dial_timeout = 10'
    echo 'retry_interval = 3'
    echo "nodelay = ${NODELAY}"
    if is_mux_transport "$TRANSPORT"; then
      echo "mux_version = ${MUX_VERSION}"
      echo "mux_framesize = ${FRAME_SIZE}"
      echo "mux_recievebuffer = ${RECV_BUFFER}"
      echo "mux_streambuffer = ${STREAM_BUFFER}"
    fi
    if is_tls_transport "$TRANSPORT" && [[ -n "${TLS_SNI:-}" ]]; then
      echo "sni = \"${TLS_SNI}\""
    fi
    echo "log_level = \"${LOG_LEVEL}\""
    if [[ "$TRANSPORT" == "tun" ]]; then
      echo
      echo '[tun]'
      echo "encapsulation = \"${TUN_ENCAPSULATION}\""
      echo "name = \"${TUN_NAME}\""
      echo "local_addr = \"${TUN_LOCAL_ADDR}\""
      echo "remote_addr = \"${TUN_REMOTE_ADDR}\""
      echo "health_port = ${TUN_HEALTH_PORT}"
      echo "mtu = ${TUN_MTU}"
    fi
  } > "$CONFIG"
}

write_unit() {
  local cap_lines=""
  if [[ "$TRANSPORT" == "tun" ]]; then
    cap_lines=$'AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW\nCapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW'
  fi
  cat > "$UNIT" <<EOF
[Unit]
Description=${DESCRIPTION}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${BASE_DIR}
ExecStart=${BIN} -c ${CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
${cap_lines}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

validate_generated_config() {
  local output rc
  set +e
  output="$(timeout -k 2 3 "$BIN" -c "$CONFIG" 2>&1)"
  rc=$?
  set -e
  if grep -Eqi 'FATAL|invalid transport|neither server nor client|toml|parse error|permission denied' <<< "$output"; then
    echo "$output"
    return 1
  fi
  # timeout=124 means the process stayed alive, which is acceptable for this preflight.
  [[ $rc -eq 0 || $rc -eq 124 || $rc -eq 143 ]] || true
  return 0
}

install_current_tunnel() {
  role_paths
  systemctl stop "$SERVICE" 2>/dev/null || true
  backup_file "$CONFIG"
  backup_file "$UNIT"

  if [[ "$ROLE" == "server" ]]; then
    write_server_config
  else
    write_client_config
  fi
  chmod 600 "$CONFIG"

  info "Validating generated configuration..."
  if ! validate_generated_config; then
    die "The core rejected the generated configuration. Existing backups were left unchanged."
  fi

  write_unit
  chmod 644 "$UNIT"
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  systemctl reset-failed "$SERVICE" 2>/dev/null || true
  systemctl restart "$SERVICE"
  sleep 3

  if systemctl is-active --quiet "$SERVICE"; then
    ok "Tunnel created and started successfully."
  else
    warn "Service did not become active. Recent logs:"
    journalctl -u "$SERVICE" -n 60 --no-pager -o cat || true
    return 1
  fi

  echo "Config    : $CONFIG"
  echo "Service   : $SERVICE"
  echo "Role      : $ROLE"
  echo "Transport : $TRANSPORT"
  echo "Tunnel    : $TUNNEL_PORT"
  echo
  journalctl -u "$SERVICE" -n 20 --no-pager -o cat || true
}

configure_new_tunnel() {
  clear 2>/dev/null || true
  logo
  choose_role
  choose_transport
  collect_connection_settings
  collect_common_settings
  collect_tls_settings
  collect_tun_settings
  collect_ports
  install_current_tunnel
  pause
}

list_tunnels() {
  TUNNEL_CONFIGS=()
  while IFS= read -r f; do TUNNEL_CONFIGS+=("$f"); done < <(
    find "$BASE_DIR" -maxdepth 1 -type f \( -name 'iran*.toml' -o -name 'kharej*.toml' \) | sort
  )
  if ((${#TUNNEL_CONFIGS[@]} == 0)); then
    warn "No tunnels found."
    return 1
  fi
  local i f role port transport status service
  for i in "${!TUNNEL_CONFIGS[@]}"; do
    f="${TUNNEL_CONFIGS[$i]}"
    if [[ "$(basename "$f")" == iran* ]]; then
      role="server"; service_role="iran"
    else
      role="client"; service_role="kharej"
    fi
    port="$(basename "$f" | grep -oE '[0-9]+' | tail -1)"
    transport="$(grep -m1 '^transport[[:space:]]*=' "$f" | cut -d'"' -f2)"
    service="backhaul-${service_role}${port}"
    status="$(systemctl is-active "$service" 2>/dev/null || true)"
    printf '%2d) %-7s port=%-5s transport=%-9s status=%s\n' "$((i+1))" "$role" "$port" "${transport:-?}" "$status"
  done
}

selected_tunnel_meta() {
  local f="$1" base
  base="$(basename "$f")"
  if [[ "$base" == iran* ]]; then SEL_ROLE="iran"; else SEL_ROLE="kharej"; fi
  SEL_PORT="$(grep -oE '[0-9]+' <<< "$base" | tail -1)"
  SEL_SERVICE="backhaul-${SEL_ROLE}${SEL_PORT}"
  SEL_UNIT="${SERVICE_DIR}/${SEL_SERVICE}.service"
}

find_units_for_config() {
  local config="$1" unit_file unit_name
  MATCHED_SERVICES=()

  # Expected service name from the current naming convention.
  MATCHED_SERVICES+=("$SEL_SERVICE")

  # Also discover renamed/legacy units by matching their ExecStart config path.
  while IFS= read -r unit_file; do
    [[ -f "$unit_file" ]] || continue
    if grep -Fq -- "$config" "$unit_file"; then
      unit_name="$(basename "$unit_file" .service)"
      MATCHED_SERVICES+=("$unit_name")
    fi
  done < <(find "$SERVICE_DIR" -maxdepth 1 -type f -name 'backhaul-*.service' -print 2>/dev/null)

  # Deduplicate the result.
  local -A seen=()
  local svc
  UNIQUE_SERVICES=()
  for svc in "${MATCHED_SERVICES[@]}"; do
    [[ -n "$svc" ]] || continue
    [[ -n "${seen[$svc]:-}" ]] && continue
    seen[$svc]=1
    UNIQUE_SERVICES+=("$svc")
  done
}

remove_tunnel() {
  local config="$1" confirm normalized svc unit_file
  selected_tunnel_meta "$config"

  echo
  read -r -p "Remove ${SEL_SERVICE} and ${config}? [y/N]: " confirm
  normalized="${confirm,,}"
  case "$normalized" in
    y|yes|remove|delete) ;;
    *) warn "Removal cancelled."; return 0 ;;
  esac

  find_units_for_config "$config"

  for svc in "${UNIQUE_SERVICES[@]}"; do
    systemctl stop "${svc}.service" 2>/dev/null || true
    systemctl disable "${svc}.service" 2>/dev/null || true
    systemctl kill --kill-who=all "${svc}.service" 2>/dev/null || true
    unit_file="${SERVICE_DIR}/${svc}.service"
    rm -f -- "$unit_file"
    rm -f -- "${unit_file}.bak-"* 2>/dev/null || true
  done

  # Remove the selected configuration and its backups.
  rm -f -- "$config"
  find "$BASE_DIR" -maxdepth 1 -type f \
    \( -name "$(basename "$config").bak-*" -o -name "$(basename "$config").script-backup*" \) \
    -delete 2>/dev/null || true

  systemctl daemon-reload
  for svc in "${UNIQUE_SERVICES[@]}"; do
    systemctl reset-failed "${svc}.service" 2>/dev/null || true
  done

  # Verify that both the config and unit files are gone.
  local failed=false
  [[ ! -e "$config" ]] || failed=true
  for svc in "${UNIQUE_SERVICES[@]}"; do
    [[ ! -e "${SERVICE_DIR}/${svc}.service" ]] || failed=true
  done

  if [[ "$failed" == "true" ]]; then
    warn "Removal was incomplete. Run the diagnostic command shown below:"
    echo "systemctl status ${SEL_SERVICE} --no-pager -l; ls -l ${config} ${SEL_UNIT}"
    return 1
  fi

  ok "Tunnel removed successfully."
  echo "Removed config : $config"
  printf 'Removed service: %s\n' "${UNIQUE_SERVICES[@]}"
  sleep 2
}

tunnel_management() {
  while true; do
    clear 2>/dev/null || true
    logo
    echo -e "${C_CYAN}=== Tunnel Management ===${C_RESET}"
    list_tunnels || { pause; return; }
    echo " 0) Back"
    local choice f action
    read -r -p "Select a tunnel: " choice
    [[ "$choice" == "0" ]] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Invalid selection"; sleep 1; continue; }
    (( choice >= 1 && choice <= ${#TUNNEL_CONFIGS[@]} )) || { warn "Invalid selection"; sleep 1; continue; }
    f="${TUNNEL_CONFIGS[$((choice-1))]}"
    selected_tunnel_meta "$f"
    echo
    echo "1) Status"
    echo "2) Restart"
    echo "3) Logs"
    echo "4) Show configuration"
    echo "5) Remove tunnel"
    echo "0) Back"
    read -r -p "Action: " action
    case "$action" in
      1) systemctl --no-pager --full status "$SEL_SERVICE" || true; pause ;;
      2) systemctl restart "$SEL_SERVICE"; sleep 2; systemctl --no-pager --full status "$SEL_SERVICE" || true; pause ;;
      3) journalctl -u "$SEL_SERVICE" -n 100 --no-pager -o cat; pause ;;
      4) cat "$f"; pause ;;
      5) remove_tunnel "$f" ;;
      0) ;;
      *) warn "Invalid action"; sleep 1 ;;
    esac
  done
}

check_tunnel_status() {
  clear 2>/dev/null || true
  logo
  echo -e "${C_CYAN}=== Tunnel Status ===${C_RESET}"
  list_tunnels || true
  echo
  echo -e "${C_YELLOW}Listening ports:${C_RESET}"
  ss -lntup 2>/dev/null | grep -E 'backhaul|LISTEN' | tail -40 || true
  pause
}

atomic_download() {
  local url="$1" dest="$2" mode="$3" tmp
  tmp="$(mktemp)"
  curl -fL --retry 3 --connect-timeout 15 -o "$tmp" "$url"
  install -o root -g root -m "$mode" "$tmp" "${dest}.new"
  mv -f "${dest}.new" "$dest"
  rm -f "$tmp"
}

update_core() {
  clear 2>/dev/null || true
  logo
  local backup="${BIN}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$BIN" "$backup"
  info "Core backup created: $backup"
  info "Downloading core from GitHub..."
  if ! atomic_download "${RAW_BASE}/backhaul_premium?cb=$(date +%s)" "$BIN" 700; then
    cp -a "$backup" "$BIN"
    die "Core download failed. The previous core was restored."
  fi
  chmod 700 "$BIN"
  if ! "$BIN" -v >/dev/null 2>&1; then
    cp -a "$backup" "$BIN"
    die "The downloaded core could not start. The previous core was restored."
  fi
  ok "Core updated: $($BIN -v 2>/dev/null || true)"
  while IFS= read -r svc; do
    [[ -n "$svc" ]] && systemctl restart "$svc" || true
  done < <(systemctl list-unit-files --type=service --no-legend 'backhaul-iran*.service' 'backhaul-kharej*.service' 2>/dev/null | awk '{sub(/\.service$/, "", $1); print $1}')
  pause
}

update_script() {
  clear 2>/dev/null || true
  logo
  info "Downloading the latest oneclick-v3-en-quantum.sh from GitHub..."
  local tmp
  tmp="$(mktemp)"
  curl -fL --retry 3 --connect-timeout 15 \
    -o "$tmp" "${RAW_BASE}/oneclick-v3-en-quantum.sh?cb=$(date +%s)"
  chmod 700 "$tmp"
  ok "Update downloaded. Starting the new installer."
  bash "$tmp"
  rm -f "$tmp"
  exit 0
}

remove_core() {
  clear 2>/dev/null || true
  logo
  warn "This removes all Backhaul services, configurations, certificates, and the core binary."
  local confirm
  read -r -p "Type REMOVE to confirm complete removal: " confirm
  [[ "$confirm" == "REMOVE" ]] || return
  local svc unit
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    svc="${unit%.service}"
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "${SERVICE_DIR}/${unit}"
  done < <(systemctl list-unit-files --type=service --no-legend 'backhaul-iran*.service' 'backhaul-kharej*.service' 2>/dev/null | awk '{print $1}')
  systemctl daemon-reload
  rm -rf "$BASE_DIR"
  rm -f "$SELF_PATH"
  ok "Backhaul removed."
  exit 0
}

usage() {
  cat <<EOF
Backhaul Premium + DaggerConnect Quantum Manager ${SCRIPT_VERSION}

Interactive menu:
  bash ${SELF_PATH}

Direct server example:
  bash ${SELF_PATH} install server --transport wsmux --tunnel-port 2095 --ports '2444=443' --pool 8

Direct client example:
  bash ${SELF_PATH} install client --transport wsmux --remote vip.example.com:2095 --pool 8
EOF
}

install_cli() {
  ROLE="${1:-}"; shift || true
  [[ "$ROLE" =~ ^(server|client)$ ]] || die "Role must be server or client."
  TRANSPORT="wsmux"
  TOKEN="" EDGE_IP="" POOL="$DEFAULT_POOL" NODELAY="true"
  KEEPALIVE="$DEFAULT_KEEPALIVE" HEARTBEAT="$DEFAULT_HEARTBEAT"
  CHANNEL_SIZE="$DEFAULT_CHANNEL_SIZE" MUX_VERSION="$DEFAULT_MUX_VERSION"
  MUX_CON="$DEFAULT_POOL" FRAME_SIZE="$DEFAULT_FRAME_SIZE"
  RECV_BUFFER="$DEFAULT_RECV_BUFFER" STREAM_BUFFER="$DEFAULT_STREAM_BUFFER"
  LOG_LEVEL="$DEFAULT_LOG_LEVEL" ACCEPT_UDP="false" PROXY_PROTOCOL="false"
  PORTS_RAW="" BIND_ADDR="" REMOTE_ADDR="" TLS_SNI=""
  while (($#)); do
    case "$1" in
      --transport) TRANSPORT="${2:-}"; shift 2 ;;
      --tunnel-port) TUNNEL_PORT="${2:-}"; BIND_ADDR="0.0.0.0:${2:-}"; shift 2 ;;
      --bind) BIND_ADDR="$(normalize_bind "${2:-}")"; TUNNEL_PORT="$(extract_port "$BIND_ADDR")"; shift 2 ;;
      --remote) REMOTE_ADDR="${2:-}"; TUNNEL_PORT="$(extract_port "$REMOTE_ADDR")"; shift 2 ;;
      --ports) PORTS_RAW="${2:-}"; shift 2 ;;
      --pool) POOL="${2:-}"; MUX_CON="$POOL"; shift 2 ;;
      --token) TOKEN="${2:-}"; shift 2 ;;
      --edge) EDGE_IP="${2:-}"; shift 2 ;;
      --stream-buffer) STREAM_BUFFER="${2:-}"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ "$TRANSPORT" =~ ^(tcp|tcpmux|xtcpmux|ws|wss|wsmux|wssmux|xwsmux|anytls|tun)$ ]] || die "Invalid transport."
  validate_port "${TUNNEL_PORT:-}" || die "Tunnel port is missing or invalid."
  if [[ "$ROLE" == "server" ]]; then
    [[ -n "$BIND_ADDR" ]] || BIND_ADDR="0.0.0.0:${TUNNEL_PORT}"
    normalize_ports "$PORTS_RAW"
    [[ "$TRANSPORT" == "tun" || ${#PORT_ITEMS[@]} -gt 0 ]] || die "--ports is required for server mode."
  else
    [[ -n "$REMOTE_ADDR" ]] || die "--remote is required for client mode."
  fi
  if is_tls_transport "$TRANSPORT"; then
    TLS_CERT="$CERT_FILE" TLS_KEY="$KEY_FILE"
    [[ "$ROLE" == "server" ]] && generate_certificate
  fi
  if [[ "$TRANSPORT" == "tun" ]]; then
    TUN_ENCAPSULATION="tcp" TUN_NAME="backhaul" TUN_HEALTH_PORT="1234" TUN_MTU="1500"
    if [[ "$ROLE" == "server" ]]; then
      TUN_LOCAL_ADDR="10.10.10.1/24" TUN_REMOTE_ADDR="10.10.10.2/24"
    else
      TUN_LOCAL_ADDR="10.10.10.2/24" TUN_REMOTE_ADDR="10.10.10.1/24"
    fi
  fi
  install_current_tunnel
}


run_daggerconnect_quantum() {
  clear 2>/dev/null || true
  logo
  echo -e "${C_MAGENTA}DaggerConnect Quantum${C_RESET}"
  echo
  warn "Quantum is not a Backhaul transport. It uses the separate DaggerConnect core and config format."
  echo "This option opens the official DaggerConnect installer/manager, where you can choose transport: quantum."
  echo
  local answer tmp
  read -r -p "Open the official DaggerConnect installer now? [Y/n]: " answer
  answer="${answer,,}"
  [[ -z "$answer" || "$answer" =~ ^(y|yes)$ ]] || return
  tmp="$(mktemp)"
  info "Downloading the official DaggerConnect setup script..."
  curl -fL --retry 3 --connect-timeout 15 \
    -o "$tmp" "${DAGGER_SETUP_URL}?cb=$(date +%s)" \
    || { rm -f "$tmp"; warn "DaggerConnect setup download failed."; pause; return; }
  chmod 700 "$tmp"
  bash "$tmp"
  rm -f "$tmp"
  pause
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    logo
    server_summary
    echo -e "${C_GREEN}1. Configure a new tunnel${C_RESET}"
    echo -e "${C_CYAN}2. Tunnel management${C_RESET}"
    echo -e "${C_CYAN}3. Check tunnel status${C_RESET}"
    echo -e "${C_GREEN}4. Update Backhaul Core${C_RESET}"
    echo -e "${C_GREEN}5. Update script${C_RESET}"
    echo -e "${C_RED}6. Remove Backhaul Core${C_RESET}"
    echo -e "${C_MAGENTA}7. DaggerConnect Quantum (separate engine)${C_RESET}"
    echo "0. Exit"
    echo
    local choice
    read -r -p "Enter your choice [0-7]: " choice
    case "$choice" in
      1) configure_new_tunnel ;;
      2) tunnel_management ;;
      3) check_tunnel_status ;;
      4) update_core ;;
      5) update_script ;;
      6) remove_core ;;
      7) run_daggerconnect_quantum ;;
      0) exit 0 ;;
      *) warn "Invalid selection"; sleep 1 ;;
    esac
  done
}

main() {
  require_root
  ensure_dependencies
  ensure_binary
  case "${1:-}" in
    "") main_menu ;;
    install) shift; install_cli "$@" ;;
    help|-h|--help) usage ;;
    *) die "Unknown command. Run without arguments to open the menu." ;;
  esac
}

main "$@"
