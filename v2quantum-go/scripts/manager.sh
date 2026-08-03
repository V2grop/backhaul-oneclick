#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

BIN="${V2QUANTUM_BIN:-/usr/local/bin/v2quantum}"
INSTALLER="${V2QUANTUM_INSTALLER:-/usr/local/sbin/v2quantum-installer}"
CONFIG_DIR="${V2QUANTUM_CONFIG_DIR:-/etc/v2quantum}"
STATE_DIR="${V2QUANTUM_STATE_DIR:-/var/lib/v2quantum}"
SYSTEMCTL="${V2QUANTUM_SYSTEMCTL:-systemctl}"
JOURNALCTL="${V2QUANTUM_JOURNALCTL:-journalctl}"
SS="${V2QUANTUM_SS:-ss}"

if (( EUID != 0 )); then
  echo "Run v2quantum-manager as root." >&2
  exit 1
fi
if [[ ! -x "$BIN" ]]; then
  echo "V2Quantum is not installed at $BIN." >&2
  exit 1
fi
install -d -m750 "$CONFIG_DIR" "$STATE_DIR/backups"

green=$'\033[0;32m'
yellow=$'\033[1;33m'
red=$'\033[0;31m'
cyan=$'\033[0;36m'
reset=$'\033[0m'
ok() { printf '%s[OK]%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$yellow" "$reset" "$*"; }
error() { printf '%s[ERROR]%s %s\n' "$red" "$reset" "$*" >&2; }

prompt_default() {
  local message="$1" default="$2" answer
  printf '%s [%s]: ' "$message" "$default" >&2
  IFS= read -r answer
  printf '%s' "${answer:-$default}"
}

confirm() {
  local message="$1" answer
  printf '%s [y/N]: ' "$message" >&2
  IFS= read -r answer
  answer="${answer,,}"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

safe_value() {
  [[ -n "$1" && "$1" != *'"'* && "$1" != *'\'* && "$1" != *'|'* && ! "$1" =~ [[:space:]] ]]
}

safe_instance() {
  [[ "$1" =~ ^[-A-Za-z0-9._]+$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_token() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{43,512}$ ]]
}

valid_ipv4() {
  local value="$1" part
  local parts=()
  [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a parts <<<"$value"
  (( ${#parts[@]} == 4 )) || return 1
  for part in "${parts[@]}"; do
    (( 10#$part >= 0 && 10#$part <= 255 )) || return 1
  done
}

detect_public_ipv4() {
  local detected=""
  if command -v ip >/dev/null 2>&1; then
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -n1)"
  fi
  if [[ -z "$detected" ]]; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${detected:-IRAN_IP}"
}

detect_interface() {
  local peer="$1" detected=""
  if command -v ip >/dev/null 2>&1 && valid_ipv4 "$peer"; then
    detected="$(ip -4 route get "$peer" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)"
  fi
  printf '%s' "${detected:-eth0}"
}

port_is_listening() {
  local proto="$1" port="$2" flag
  command -v "$SS" >/dev/null 2>&1 || return 1
  if [[ "$proto" == "udp" ]]; then flag="-Hlnu"; else flag="-Hlnt"; fi
  "$SS" "$flag" 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

find_free_port() {
  local proto="$1" candidate="$2"
  while (( candidate <= 65535 )); do
    if ! port_is_listening "$proto" "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

select_mode() {
  local choice
  echo "1) TCP         stable and firewall-friendly" >&2
  echo "2) Quantum UDP reliable low-overhead carrier (recommended)" >&2
  echo "3) Raw ICMP    experimental spoof/BIP carrier" >&2
  choice="$(prompt_default "Carrier" "2")"
  case "${choice,,}" in
    1|tcp) printf 'tcp' ;;
    2|quantum|udp|quantum_udp) printf 'quantum_udp' ;;
    3|raw|icmp|raw_icmp) printf 'raw_icmp' ;;
    *) error "Unknown carrier."; return 1 ;;
  esac
}

apply_profile() {
  PROFILE_NAME="$1"
  case "$PROFILE_NAME" in
    stable)
      POOL=2 KEEPALIVE=10 DIAL_TIMEOUT=8 RECONNECT_MIN=500 RECONNECT_MAX=15000 MAX_STREAMS=256 ;;
    balanced)
      POOL=4 KEEPALIVE=8 DIAL_TIMEOUT=6 RECONNECT_MIN=300 RECONNECT_MAX=10000 MAX_STREAMS=512 ;;
    max)
      POOL=8 KEEPALIVE=5 DIAL_TIMEOUT=5 RECONNECT_MIN=200 RECONNECT_MAX=8000 MAX_STREAMS=1024 ;;
    *) return 1 ;;
  esac
}

select_profile() {
  local choice
  echo "1) Stable    2 sessions" >&2
  echo "2) Balanced  4 sessions (recommended)" >&2
  echo "3) Max       8 sessions" >&2
  choice="$(prompt_default "Performance profile" "2")"
  case "${choice,,}" in
    1|stable) printf 'stable' ;;
    2|balanced|default) printf 'balanced' ;;
    3|max|maximum) printf 'max' ;;
    *) error "Unknown profile."; return 1 ;;
  esac
}

csv_ports() {
  local input="$1" item
  local -n output="$2"
  input="$(printf '%s' "$input" | tr -d '[:space:]')"
  IFS=',' read -r -a output <<<"$input"
  (( ${#output[@]} > 0 && ${#output[@]} <= 32 )) || return 1
  for item in "${output[@]}"; do
    valid_port "$item" || return 1
  done
}

csv_targets() {
  local input="$1" item
  local -n output="$2"
  input="$(printf '%s' "$input" | tr -d '[:space:]')"
  IFS=',' read -r -a output <<<"$input"
  (( ${#output[@]} > 0 && ${#output[@]} <= 32 )) || return 1
  for item in "${!output[@]}"; do
    if valid_port "${output[$item]}"; then
      output[$item]="127.0.0.1:${output[$item]}"
    fi
    safe_value "${output[$item]}" || return 1
    [[ "${output[$item]}" == *:* ]] || return 1
  done
}

base64url_encode() {
  base64 -w0 | tr '_-' '/+' | tr '/+' '_-' | tr -d '='
}

base64url_decode() {
  local value="$1" remainder
  value="$(printf '%s' "$value" | tr '_-' '/+')"
  remainder=$(( ${#value} % 4 ))
  if (( remainder == 2 )); then value+='=='; fi
  if (( remainder == 3 )); then value+='='; fi
  (( remainder != 1 )) || return 1
  printf '%s' "$value" | base64 -d 2>/dev/null
}

make_setup_code() {
  local token="$1" mode="$2" public_host="$3" carrier_port="$4" public_ports="$5" profile="$6" count="$7"
  printf 'V2Q1_%s' "$(printf '%s' "$token|$mode|$public_host|$carrier_port|$public_ports|$profile|$count" | base64url_encode)"
}

parse_setup_code() {
  local code="$1" decoded extra
  [[ "$code" == V2Q1_* ]] || return 1
  decoded="$(base64url_decode "${code#V2Q1_}")" || return 1
  IFS='|' read -r CODE_TOKEN CODE_MODE CODE_HOST CODE_PORT CODE_PUBLIC_PORTS CODE_PROFILE CODE_COUNT extra <<<"$decoded"
  [[ -z "$extra" ]] || return 1
  valid_token "$CODE_TOKEN" || return 1
  [[ "$CODE_MODE" == "tcp" || "$CODE_MODE" == "quantum_udp" ]] || return 1
  safe_value "$CODE_HOST" || return 1
  valid_port "$CODE_PORT" || return 1
  [[ "$CODE_COUNT" =~ ^[0-9]+$ ]] && (( CODE_COUNT >= 1 && CODE_COUNT <= 32 )) || return 1
  apply_profile "$CODE_PROFILE" || return 1
}

raw_block() {
  local local_ip peer_ip iface identifier mtu source_mode selected_source detected_local
  local spoof_source="" spoof_destination="" expected_peer_source allow=false value
  detected_local="$(detect_public_ipv4)"
  valid_ipv4 "$detected_local" || detected_local="192.0.2.10"
  local_ip="$(prompt_default "This server public IPv4" "$detected_local")"
  peer_ip="$(prompt_default "Peer public IPv4" "198.51.100.20")"
  valid_ipv4 "$local_ip" || { error "Invalid local IPv4."; return 1; }
  valid_ipv4 "$peer_ip" || { error "Invalid peer IPv4."; return 1; }
  iface="$(prompt_default "Network interface" "$(detect_interface "$peer_ip")")"
  identifier="$(prompt_default "Shared ICMP identifier" "22066")"
  mtu="$(prompt_default "Raw payload MTU" "1200")"
  for value in "$local_ip" "$peer_ip" "$iface" "$identifier" "$mtu"; do
    safe_value "$value" || { error "Unsafe raw input."; return 1; }
  done

  echo "1) Automatic safe scan - assigned local IPs, loss and RTT" >&2
  echo "2) Manual advanced entry - authorized source/BIP only" >&2
  echo "3) Real IP only - disable source and destination overrides" >&2
  source_mode="$(prompt_default "Raw source selection" "1")"
  case "${source_mode,,}" in
    1|auto|scan|scanner)
      echo >&2
      warn "The scanner tests only IPv4 addresses assigned to this server; it never scans third-party ranges." >&2
      if ! selected_source="$("$BIN" spoof-scan -peer "$peer_ip" -count 3 -timeout 2s -selected-only)"; then
        error "No assigned source IP passed the ICMP threshold. Nothing was configured."
        warn "Check peer ICMP/firewall, choose manual mode only with an authorized IP, or use Quantum UDP/TCP." >&2
        return 1
      fi
      valid_ipv4 "$selected_source" || { error "Scanner returned an invalid IPv4."; return 1; }
      spoof_source="$selected_source"
      expected_peer_source="$(prompt_default "Expected peer source IPv4 (peer scanner result)" "$peer_ip")"
      valid_ipv4 "$expected_peer_source" || { error "Invalid expected peer source IPv4."; return 1; }
      [[ "$spoof_source" == "$local_ip" ]] || allow=true
      ok "Verified local source selected: $spoof_source" >&2
      ;;
    2|manual|advanced)
      warn "Use only an IP assigned/routed to this server and explicitly authorized by its provider." >&2
      spoof_source="$(prompt_default "Authorized source IPv4" "$local_ip")"
      expected_peer_source="$(prompt_default "Expected peer source IPv4" "$peer_ip")"
      spoof_destination="$(prompt_default "Optional destination/BIP override (- disables)" "-")"
      [[ "$spoof_destination" == "-" ]] && spoof_destination=""
      valid_ipv4 "$spoof_source" || { error "Invalid source IPv4."; return 1; }
      valid_ipv4 "$expected_peer_source" || { error "Invalid expected peer source IPv4."; return 1; }
      [[ -z "$spoof_destination" ]] || valid_ipv4 "$spoof_destination" || { error "Invalid destination override IPv4."; return 1; }
      if [[ "$spoof_source" != "$local_ip" ]]; then
        confirm "Confirm this source is authorized and routed to this server" || return 1
        allow=true
      fi
      if [[ -n "$spoof_destination" ]]; then
        confirm "Confirm this destination/BIP is authorized and routed to the peer" || return 1
      fi
      ;;
    3|real|off|none|disable)
      expected_peer_source="$peer_ip"
      ok "Raw ICMP will use the two real server IPs without an override." >&2
      ;;
    *)
      error "Unknown raw source selection."
      return 1
      ;;
  esac

  printf '%s\n' \
    '    "raw": {' \
    "      \"local_ip\": \"$local_ip\"," \
    "      \"peer_ip\": \"$peer_ip\"," \
    "      \"interface\": \"$iface\"," \
    "      \"spoof_source_ip\": \"$spoof_source\"," \
    "      \"spoof_destination_ip\": \"$spoof_destination\"," \
    "      \"expected_peer_source_ip\": \"$expected_peer_source\"," \
    "      \"allow_unrouted_spoof\": $allow," \
    "      \"icmp_identifier\": $identifier," \
    "      \"payload_mtu\": $mtu," \
    '      "experimental_enabled": true' \
    '    }'
}

backup_instance() {
  local instance="$1" backup=""
  if [[ -f "$CONFIG_DIR/$instance.json" || -f "$CONFIG_DIR/$instance.env" ]]; then
    backup="$STATE_DIR/backups/$instance-$(date +%Y%m%d-%H%M%S)"
    install -d -m700 "$backup"
    [[ -f "$CONFIG_DIR/$instance.json" ]] && cp -a -- "$CONFIG_DIR/$instance.json" "$backup/"
    [[ -f "$CONFIG_DIR/$instance.env" ]] && cp -a -- "$CONFIG_DIR/$instance.env" "$backup/"
  fi
  printf '%s' "$backup"
}

write_instance() {
  local role="$1" instance="$2" mode="$3" token="$4" health_port="$5" carrier_value="$6" raw_json="$7"
  local -n values="$8"
  local config_tmp env_tmp backup="" i comma endpoint
  config_tmp="$(mktemp "$CONFIG_DIR/.${instance}.json.XXXXXX")"
  env_tmp="$(mktemp "$CONFIG_DIR/.${instance}.env.XXXXXX")"

  printf 'V2QUANTUM_PSK=%s\n' "$token" >"$env_tmp"
  chmod 600 "$env_tmp"
  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "role": "%s",\n' "$role"
    printf '  "node_name": "%s",\n' "$instance"
    printf '  "carrier": {\n'
    printf '    "mode": "%s",\n' "$mode"
    if [[ "$mode" == "raw_icmp" ]]; then
      printf '%s,\n' "$raw_json"
    elif [[ "$role" == "server" ]]; then
      printf '    "listen": "0.0.0.0:%s",\n' "$carrier_value"
    else
      printf '    "server": "%s",\n' "$carrier_value"
    fi
    printf '    "pool": %s,\n' "$POOL"
    printf '    "keepalive_seconds": %s,\n' "$KEEPALIVE"
    printf '    "dial_timeout_seconds": %s,\n' "$DIAL_TIMEOUT"
    printf '    "reconnect_min_millis": %s,\n' "$RECONNECT_MIN"
    printf '    "reconnect_max_millis": %s,\n' "$RECONNECT_MAX"
    printf '    "max_streams_per_session": %s\n' "$MAX_STREAMS"
    printf '  },\n'
    printf '  "security": {"psk_env": "V2QUANTUM_PSK"},\n'
    printf '  "mappings": [\n'
    for i in "${!values[@]}"; do
      comma=','
      (( i == ${#values[@]} - 1 )) && comma=''
      if [[ "$role" == "server" ]]; then
        endpoint="\"listen\": \"0.0.0.0:${values[$i]}\""
      else
        endpoint="\"target\": \"${values[$i]}\""
      fi
      printf '    {"name": "map-%s", "protocol": "tcp", %s}%s\n' "$((i + 1))" "$endpoint" "$comma"
    done
    printf '  ],\n'
    printf '  "health": {"listen": "127.0.0.1:%s", "allow_public_listen": false},\n' "$health_port"
    printf '  "logging": {"level": "info", "json": false}\n'
    printf '}\n'
  } >"$config_tmp"
  chmod 640 "$config_tmp"

  if ! V2QUANTUM_PSK="$token" "$BIN" check -config "$config_tmp"; then
    error "Configuration validation failed; nothing was changed."
    rm -f -- "$config_tmp" "$env_tmp"
    return 1
  fi

  backup="$(backup_instance "$instance")"
  install -m600 "$env_tmp" "$CONFIG_DIR/$instance.env"
  install -m640 "$config_tmp" "$CONFIG_DIR/$instance.json"
  if ! "$SYSTEMCTL" enable "v2quantum@$instance.service" >/dev/null || \
     ! "$SYSTEMCTL" restart "v2quantum@$instance.service" || \
     ! "$SYSTEMCTL" is-active --quiet "v2quantum@$instance.service"; then
    error "Service failed to start."
    "$JOURNALCTL" -u "v2quantum@$instance.service" -n 30 --no-pager || true
    if [[ -n "$backup" ]]; then
      if [[ -f "$backup/$instance.env" ]]; then
        install -m600 "$backup/$instance.env" "$CONFIG_DIR/$instance.env"
      else
        rm -f -- "$CONFIG_DIR/$instance.env"
      fi
      if [[ -f "$backup/$instance.json" ]]; then
        install -m640 "$backup/$instance.json" "$CONFIG_DIR/$instance.json"
      else
        rm -f -- "$CONFIG_DIR/$instance.json"
      fi
      "$SYSTEMCTL" restart "v2quantum@$instance.service" || true
      warn "Previous configuration restored from $backup"
    else
      rm -f -- "$CONFIG_DIR/$instance.json" "$CONFIG_DIR/$instance.env"
      "$SYSTEMCTL" disable --now "v2quantum@$instance.service" >/dev/null 2>&1 || true
      warn "The incomplete new instance was removed."
    fi
    rm -f -- "$config_tmp" "$env_tmp"
    return 1
  fi

  if [[ "$role" == "client" ]]; then
    if ! "$SYSTEMCTL" enable --now "v2quantum-watchdog@$instance.timer" >/dev/null; then
      warn "The watchdog timer could not be enabled; built-in reconnect remains active."
    fi
  else
    "$SYSTEMCTL" disable --now "v2quantum-watchdog@$instance.timer" >/dev/null 2>&1 || true
  fi
  [[ -n "$backup" ]] && ok "Previous configuration backed up at $backup"
  rm -f -- "$config_tmp" "$env_tmp"
  ok "v2quantum@$instance is active."
}

open_firewall_server() {
  local mode="$1" carrier_port="$2" item proto
  local -n ports_ref="$3"
  if [[ "$mode" == "quantum_udp" ]]; then proto="udp"; else proto="tcp"; fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    [[ "$carrier_port" != "0" ]] && ufw allow "$carrier_port/$proto" >/dev/null
    for item in "${ports_ref[@]}"; do ufw allow "$item/tcp" >/dev/null; done
    ok "UFW rules added."
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    [[ "$carrier_port" != "0" ]] && firewall-cmd --permanent --add-port="$carrier_port/$proto" >/dev/null
    for item in "${ports_ref[@]}"; do firewall-cmd --permanent --add-port="$item/tcp" >/dev/null; done
    firewall-cmd --reload >/dev/null
    ok "firewalld rules added."
  else
    if [[ "$carrier_port" == "0" ]]; then
      warn "No active UFW/firewalld detected. Allow ICMP and the public TCP mapping ports in your provider firewall if needed."
    else
      warn "No active UFW/firewalld detected. Open $carrier_port/$proto and the public TCP mapping ports in your provider firewall if needed."
    fi
  fi
}

configure_server() {
  local mode profile token public_host carrier_port proto public_input public_port health_port raw_json="" setup_code
  local public_ports=()
  mode="$(select_mode)"
  profile="$(select_profile)"
  apply_profile "$profile"
  token="$($BIN keygen)"
  valid_token "$token" || { error "Token generation failed."; return 1; }

  public_input="$(prompt_default "Public TCP port(s), comma-separated" "$(find_free_port tcp 2445)")"
  csv_ports "$public_input" public_ports || { error "Invalid public port list."; return 1; }
  for public_port in "${public_ports[@]}"; do
    if port_is_listening tcp "$public_port"; then
      confirm "Public port $public_port/tcp is already listening. Continue anyway?" || return 1
    fi
  done
  health_port="$(find_free_port tcp 19090)"

  if [[ "$mode" == "raw_icmp" ]]; then
    apply_profile stable
    POOL=1
    raw_json="$(raw_block)"
    carrier_port="0"
    public_host="$(prompt_default "Iran public IPv4 shown to the outside operator" "$(detect_public_ipv4)")"
  else
    [[ "$mode" == "quantum_udp" ]] && proto="udp" || proto="tcp"
    carrier_port="$(prompt_default "Carrier port" "$(find_free_port "$proto" 8890)")"
    valid_port "$carrier_port" || { error "Invalid carrier port."; return 1; }
    if port_is_listening "$proto" "$carrier_port"; then
      confirm "Port $carrier_port/$proto is already listening. Continue anyway?" || return 1
    fi
    public_host="$(prompt_default "Iran public IPv4 or hostname" "$(detect_public_ipv4)")"
  fi
  safe_value "$public_host" || { error "Invalid public host."; return 1; }

  write_instance server iran "$mode" "$token" "$health_port" "$carrier_port" "$raw_json" public_ports
  open_firewall_server "$mode" "$carrier_port" public_ports
  if [[ "$mode" != "raw_icmp" ]]; then
    setup_code="$(make_setup_code "$token" "$mode" "$public_host" "$carrier_port" \
      "$(IFS=,; echo "${public_ports[*]}")" "$profile" "${#public_ports[@]}")"
    echo
    printf '%sCOPY THIS ONE SETUP CODE TO THE OUTSIDE SERVER:%s\n' "$cyan" "$reset"
    printf '%s\n' "$setup_code"
  else
    echo
    printf '%sCOPY THIS PSK TO THE OUTSIDE RAW CONFIG:%s\n%s\n' "$cyan" "$reset" "$token"
  fi
}

configure_client() {
  local input mode token server_endpoint profile target_input health_port raw_json="" count
  local targets=()
  printf 'Paste Iran setup code (V2Q1_...) or a raw PSK: ' >&2
  IFS= read -r input
  if [[ "$input" == V2Q1_* ]]; then
    parse_setup_code "$input" || { error "Invalid setup code."; return 1; }
    token="$CODE_TOKEN"
    mode="$CODE_MODE"
    server_endpoint="$CODE_HOST:$CODE_PORT"
    profile="$CODE_PROFILE"
    count="$CODE_COUNT"
    apply_profile "$profile"
    if (( count == 1 )); then
      target_input="$(prompt_default "Outside local target" "127.0.0.1:2444")"
    else
      target_input="$(prompt_default "Outside targets ($count items, comma-separated)" "$CODE_PUBLIC_PORTS")"
    fi
  else
    valid_token "$input" || { error "Invalid token."; return 1; }
    token="$input"
    mode="$(select_mode)"
    profile="$(select_profile)"
    apply_profile "$profile"
    count="$(prompt_default "Number of mappings" "1")"
    [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 && count <= 32 )) || { error "Invalid mapping count."; return 1; }
    if [[ "$mode" == "raw_icmp" ]]; then
      apply_profile stable
      POOL=1
      raw_json="$(raw_block)"
      server_endpoint="raw"
    else
      server_endpoint="$(prompt_default "Iran carrier address" "IRAN_IP:8890")"
      safe_value "$server_endpoint" && [[ "$server_endpoint" == *:* ]] || { error "Invalid Iran endpoint."; return 1; }
    fi
    target_input="$(prompt_default "Outside target(s), comma-separated" "127.0.0.1:2444")"
  fi

  csv_targets "$target_input" targets || { error "Invalid target list."; return 1; }
  (( ${#targets[@]} == count )) || { error "Expected $count target(s), received ${#targets[@]}."; return 1; }
  health_port="$(find_free_port tcp 19090)"
  write_instance client outside "$mode" "$token" "$health_port" "$server_endpoint" "$raw_json" targets
  ok "Automatic reconnect and the health watchdog are enabled."
}

pick_instance() {
  local default="iran"
  [[ -f "$CONFIG_DIR/outside.json" && ! -f "$CONFIG_DIR/iran.json" ]] && default="outside"
  prompt_default "Instance name" "$default"
}

load_instance_env() {
  local instance="$1"
  if [[ -r "$CONFIG_DIR/$instance.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_DIR/$instance.env"
    set +a
  fi
}

show_status() {
  local instance
  instance="$(pick_instance)"
  safe_instance "$instance" || { error "Invalid instance."; return 1; }
  "$SYSTEMCTL" --no-pager --full status "v2quantum@$instance.service" || true
  load_instance_env "$instance"
  "$BIN" healthcheck -config "$CONFIG_DIR/$instance.json" -timeout 5s || true
}

diagnostics() {
  local instance
  instance="$(pick_instance)"
  safe_instance "$instance" || { error "Invalid instance."; return 1; }
  load_instance_env "$instance"
  echo "===== VERSION ====="
  "$BIN" version
  echo "===== CONFIG ====="
  "$BIN" check -config "$CONFIG_DIR/$instance.json" || true
  echo "===== SERVICE ====="
  "$SYSTEMCTL" is-active "v2quantum@$instance.service" || true
  echo "===== HEALTH ====="
  "$BIN" healthcheck -config "$CONFIG_DIR/$instance.json" -timeout 5s || true
  echo "===== SOCKETS ====="
  "$SS" -lntup 2>/dev/null | grep -E 'v2quantum|:244[0-9]|:889[0-9]|:1909[0-9]' || true
  echo "===== LAST LOGS ====="
  "$JOURNALCTL" -u "v2quantum@$instance.service" -n 50 --no-pager || true
}

delete_instance() {
  local instance backup
  instance="$(pick_instance)"
  safe_instance "$instance" || { error "Invalid instance."; return 1; }
  confirm "Delete tunnel instance $instance?" || { echo "Cancelled."; return 0; }
  backup="$(backup_instance "$instance")"
  "$SYSTEMCTL" disable --now "v2quantum-watchdog@$instance.timer" 2>/dev/null || true
  "$SYSTEMCTL" disable --now "v2quantum@$instance.service" 2>/dev/null || true
  rm -f -- "$CONFIG_DIR/$instance.json" "$CONFIG_DIR/$instance.env"
  ok "Instance deleted. Backup: ${backup:-none}"
}

while true; do
  echo
  echo "========== V2Quantum One-Click Manager =========="
  echo "1) Configure Iran server + generate setup code"
  echo "2) Configure outside server from setup code"
  echo "3) Status and health"
  echo "4) Follow logs"
  echo "5) Restart instance"
  echo "6) Full diagnostics"
  echo "7) Raw spoof preflight"
  echo "8) Update core and manager"
  echo "9) Delete tunnel instance"
  echo "10) Uninstall V2Quantum program"
  echo "0) Exit"
  choice="$(prompt_default "Choice" "1")"
  case "${choice,,}" in
    1|iran|server) configure_server ;;
    2|outside|client|kharej) configure_client ;;
    3|status) show_status ;;
    4|logs)
      instance="$(pick_instance)"
      safe_instance "$instance" || { error "Invalid instance."; continue; }
      "$JOURNALCTL" -fu "v2quantum@$instance.service"
      ;;
    5|restart)
      instance="$(pick_instance)"
      safe_instance "$instance" || { error "Invalid instance."; continue; }
      "$SYSTEMCTL" restart "v2quantum@$instance.service"
      ;;
    6|diagnostics|diag) diagnostics ;;
    7|spoof|preflight)
      instance="$(pick_instance)"
      safe_instance "$instance" || { error "Invalid instance."; continue; }
      load_instance_env "$instance"
      "$BIN" spoof-check -config "$CONFIG_DIR/$instance.json"
      ;;
    8|update)
      [[ -x "$INSTALLER" ]] || { error "Installer not found at $INSTALLER"; continue; }
      "$INSTALLER" --update --no-menu
      ;;
    9|delete|remove) delete_instance ;;
    10|uninstall)
      [[ -x "$INSTALLER" ]] || { error "Installer not found at $INSTALLER"; continue; }
      exec "$INSTALLER" --uninstall
      ;;
    0|q|quit|exit) exit 0 ;;
    *) error "Unknown choice." ;;
  esac
done
