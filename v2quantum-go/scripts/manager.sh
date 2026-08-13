#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

MANAGER_VERSION="0.3.1"
if [[ "${1:-}" == "--version" ]]; then
  echo "v2quantum-manager $MANAGER_VERSION"
  exit 0
fi

BIN="${V2QUANTUM_BIN:-/usr/local/bin/v2quantum}"
INSTALLER="${V2QUANTUM_INSTALLER:-/usr/local/sbin/v2quantum-installer}"
CONFIG_DIR="${V2QUANTUM_CONFIG_DIR:-/etc/v2quantum}"
STATE_DIR="${V2QUANTUM_STATE_DIR:-/var/lib/v2quantum}"
RUN_DIR="${V2QUANTUM_RUN_DIR:-/run}"
SYSTEMCTL="${V2QUANTUM_SYSTEMCTL:-systemctl}"
JOURNALCTL="${V2QUANTUM_JOURNALCTL:-journalctl}"
SS="${V2QUANTUM_SS:-ss}"
SYSCTL="${V2QUANTUM_SYSCTL:-sysctl}"
SYSCTL_CONFIG="${V2QUANTUM_SYSCTL_CONFIG:-/etc/sysctl.d/90-v2quantum-udp.conf}"
HOST_TUNING="${V2QUANTUM_HOST_TUNING:-1}"

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
	[[ "$1" =~ ^[-A-Za-z0-9._]+$ && ${#1} -le 64 ]]
}

safe_label() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$ ]]
}

instance_exists() {
	local instance="$1"
	[[ -e "$CONFIG_DIR/$instance.json" || -e "$CONFIG_DIR/$instance.env" ]]
}

unique_label() {
	local role="$1" base="$2" candidate="$2" suffix=2
	while instance_exists "$role-$candidate"; do
		candidate="${base}-${suffix}"
		suffix=$((suffix + 1))
	done
	printf '%s' "$candidate"
}

new_instance() {
	local role="$1" suggested="$2" label instance
	suggested="$(unique_label "$role" "$suggested")"
	while true; do
		label="$(prompt_default "Tunnel name" "$suggested")"
		safe_label "$label" || {
			error "Use 1-40 letters, numbers, dot, underscore or dash; start with a letter or number."
			continue
		}
		instance="$role-$label"
		if instance_exists "$instance"; then
			error "Instance $instance already exists. Choose another name; existing tunnels are never overwritten here."
			suggested="$(unique_label "$role" "$label")"
			continue
		fi
		printf '%s' "$instance"
		return 0
	done
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

valid_cidr() {
  local value="$1" address prefix
  [[ "$value" == */* ]] || return 1
  address="${value%/*}"
  prefix="${value##*/}"
  valid_ipv4 "$address" && [[ "$prefix" =~ ^[0-9]+$ ]] && (( 10#$prefix >= 0 && 10#$prefix <= 32 ))
}

csv_routes() {
  local input="$1" item
  local -n output="$2"
  output=()
  input="$(printf '%s' "$input" | tr -d '[:space:]')"
  [[ -z "$input" || "$input" == "-" ]] && return 0
  IFS=',' read -r -a output <<<"$input"
  (( ${#output[@]} <= 32 )) || return 1
  for item in "${output[@]}"; do
    valid_cidr "$item" || return 1
    [[ "$item" != "0.0.0.0/0" ]] || {
      error "A default route can loop the carrier. Enter only specific remote subnets."
      return 1
    }
  done
}

tun_device_name() {
  local instance="$1" digest
  digest="$(printf '%s' "$instance" | sha256sum | awk '{print substr($1,1,8)}')"
  printf 'v2q%s' "$digest"
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

detect_public_interface() {
  local detected=""
  if command -v ip >/dev/null 2>&1; then
    detected="$(ip -4 route show default 2>/dev/null | awk '/ dev / {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
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
		if ! port_is_listening "$proto" "$candidate" &&
			! grep -RqsE --include='*.json' ":[[:space:]]*${candidate}(\"|$)|:${candidate}\"" "$CONFIG_DIR" 2>/dev/null; then
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
  echo "2) Quantum v2  adaptive UDP + SACK/FEC (recommended)" >&2
  echo "3) Raw ICMP    experimental spoof/BIP carrier" >&2
  choice="$(prompt_default "Carrier" "2")"
  case "${choice,,}" in
    1|tcp) printf 'tcp' ;;
    2|quantum|udp|quantum_udp) printf 'quantum_udp' ;;
    3|raw|icmp|raw_icmp) printf 'raw_icmp' ;;
    *) error "Unknown carrier."; return 1 ;;
  esac
}

select_tun_mode() {
  local choice
  echo "1) TCP         maximum compatibility" >&2
  echo "2) Quantum v2  adaptive UDP + SACK/FEC (recommended)" >&2
  choice="$(prompt_default "TUN carrier" "2")"
  case "${choice,,}" in
    1|tcp) printf 'tcp' ;;
    2|quantum|udp|quantum_udp) printf 'quantum_udp' ;;
    *) error "TUN supports only TCP or Quantum UDP."; return 1 ;;
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
  echo "1) Stable    2 sessions, 6+2 multi-loss FEC" >&2
  echo "2) Balanced  4 sessions, 8+2 adaptive SACK/FEC (recommended)" >&2
  echo "3) Max       8 sessions, 10+1 FEC and larger window" >&2
  choice="$(prompt_default "Performance profile" "2")"
  case "${choice,,}" in
    1|stable) printf 'stable' ;;
    2|balanced|default) printf 'balanced' ;;
    3|max|maximum) printf 'max' ;;
    *) error "Unknown profile."; return 1 ;;
  esac
}

select_tun_profile() {
  local choice
  echo "1) Stable recovery     6+2 multi-loss FEC, conservative reconnect" >&2
  echo "2) Balanced recovery   8+2 adaptive SACK/FEC (recommended)" >&2
  echo "3) Fast recovery       10+1 FEC, larger window, fastest reconnect" >&2
  choice="$(prompt_default "Recovery profile" "2")"
  case "${choice,,}" in
    1|stable) printf 'stable' ;;
    2|balanced|default) printf 'balanced' ;;
    3|max|fast|maximum) printf 'max' ;;
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

csv_port_mappings() {
  local input="$1" item public_port target_port
  local -n output="$2"
  local -A seen=()
  output=()
  input="$(printf '%s' "$input" | tr -d '[:space:]')"
  [[ -z "$input" || "$input" == "-" ]] && return 0
  IFS=',' read -r -a output <<<"$input"
  (( ${#output[@]} <= 32 )) || return 1
  for item in "${!output[@]}"; do
    if [[ "${output[$item]}" =~ ^([0-9]+)=([0-9]+)$ ]]; then
      public_port="${BASH_REMATCH[1]}"
      target_port="${BASH_REMATCH[2]}"
    elif valid_port "${output[$item]}"; then
      public_port="${output[$item]}"
      target_port="$public_port"
    else
      return 1
    fi
    valid_port "$public_port" && valid_port "$target_port" || return 1
    [[ -z "${seen[$public_port]:-}" ]] || return 1
    seen[$public_port]=1
    output[$item]="$public_port=$target_port"
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
	local token="$1" mode="$2" public_host="$3" carrier_port="$4" public_ports="$5" profile="$6" count="$7" label="$8"
	printf 'V2Q3_%s' "$(printf '%s' "$token|$mode|$public_host|$carrier_port|$public_ports|$profile|$count|$label" | base64url_encode)"
}

parse_setup_code() {
	local code="$1" decoded extra prefix
	case "$code" in
		V2Q1_*) prefix="V2Q1_" ;;
		V2Q2_*) prefix="V2Q2_" ;;
		V2Q3_*) prefix="V2Q3_" ;;
		*) return 1 ;;
	esac
	decoded="$(base64url_decode "${code#${prefix}}")" || return 1
	if [[ "$prefix" == "V2Q2_" || "$prefix" == "V2Q3_" ]]; then
		IFS='|' read -r CODE_TOKEN CODE_MODE CODE_HOST CODE_PORT CODE_PUBLIC_PORTS CODE_PROFILE CODE_COUNT CODE_LABEL extra <<<"$decoded"
		[[ -z "$extra" ]] || return 1
		safe_label "$CODE_LABEL" || return 1
	else
		IFS='|' read -r CODE_TOKEN CODE_MODE CODE_HOST CODE_PORT CODE_PUBLIC_PORTS CODE_PROFILE CODE_COUNT extra <<<"$decoded"
		[[ -z "$extra" ]] || return 1
		CODE_LABEL=""
	fi
	valid_token "$CODE_TOKEN" || return 1
  [[ "$CODE_MODE" == "tcp" || "$CODE_MODE" == "quantum_udp" ]] || return 1
  safe_value "$CODE_HOST" || return 1
  valid_port "$CODE_PORT" || return 1
  [[ "$CODE_COUNT" =~ ^[0-9]+$ ]] && (( CODE_COUNT >= 1 && CODE_COUNT <= 32 )) || return 1
	apply_profile "$CODE_PROFILE" || return 1
}

make_tun_setup_code() {
  local token="$1" mode="$2" public_host="$3" carrier_port="$4" profile="$5" label="$6"
  local server_cidr="$7" client_cidr="$8" mtu="$9"
	printf 'V2T2_%s' "$(printf '%s' "$token|$mode|$public_host|$carrier_port|$profile|$label|$server_cidr|$client_cidr|$mtu" | base64url_encode)"
}

parse_tun_setup_code() {
  local code="$1" decoded extra
	if [[ "$code" == V2T2_* ]]; then
		decoded="$(base64url_decode "${code#V2T2_}")" || return 1
	elif [[ "$code" == V2T1_* ]]; then
		decoded="$(base64url_decode "${code#V2T1_}")" || return 1
	else
		return 1
	fi
  IFS='|' read -r TUN_CODE_TOKEN TUN_CODE_MODE TUN_CODE_HOST TUN_CODE_PORT \
    TUN_CODE_PROFILE TUN_CODE_LABEL TUN_CODE_SERVER_CIDR TUN_CODE_CLIENT_CIDR \
    TUN_CODE_MTU extra <<<"$decoded"
  [[ -z "$extra" ]] || return 1
  valid_token "$TUN_CODE_TOKEN" || return 1
  [[ "$TUN_CODE_MODE" == "tcp" || "$TUN_CODE_MODE" == "quantum_udp" ]] || return 1
  safe_value "$TUN_CODE_HOST" || return 1
  valid_port "$TUN_CODE_PORT" || return 1
  apply_profile "$TUN_CODE_PROFILE" || return 1
  safe_label "$TUN_CODE_LABEL" || return 1
  valid_cidr "$TUN_CODE_SERVER_CIDR" || return 1
  valid_cidr "$TUN_CODE_CLIENT_CIDR" || return 1
  [[ "$TUN_CODE_MTU" =~ ^[0-9]+$ ]] && (( TUN_CODE_MTU >= 576 && TUN_CODE_MTU <= 9000 )) || return 1
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
  if [[ -f "$CONFIG_DIR/$instance.json" || -f "$CONFIG_DIR/$instance.env" || -f "$CONFIG_DIR/$instance.portmap" ]]; then
    backup="$STATE_DIR/backups/$instance-$(date +%Y%m%d-%H%M%S)"
    install -d -m700 "$backup"
    [[ -f "$CONFIG_DIR/$instance.json" ]] && cp -a -- "$CONFIG_DIR/$instance.json" "$backup/"
    [[ -f "$CONFIG_DIR/$instance.env" ]] && cp -a -- "$CONFIG_DIR/$instance.env" "$backup/"
    [[ -f "$CONFIG_DIR/$instance.portmap" ]] && cp -a -- "$CONFIG_DIR/$instance.portmap" "$backup/"
  fi
  printf '%s' "$backup"
}

activate_instance() {
  local role="$1" instance="$2" token="$3" config_tmp="$4" env_tmp="$5" backup=""
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

write_instance() {
  local role="$1" instance="$2" mode="$3" token="$4" health_port="$5" carrier_value="$6" raw_json="$7"
  local -n values="$8"
  local config_tmp env_tmp i comma endpoint
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
		printf '    "max_streams_per_session": %s' "$MAX_STREAMS"
		if [[ "$mode" == "quantum_udp" ]]; then
			printf ',\n'
			printf '    "quantum": {"profile": "%s", "auto_tune": true}\n' "$PROFILE_NAME"
		else
			printf '\n'
		fi
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

  activate_instance "$role" "$instance" "$token" "$config_tmp" "$env_tmp"
}

write_tun_instance() {
  local role="$1" instance="$2" mode="$3" token="$4" health_port="$5" carrier_value="$6"
  local local_cidr="$7" peer_ip="$8" mtu="$9"
  local -n routes_ref="${10}"
  local config_tmp env_tmp device route i comma
  config_tmp="$(mktemp "$CONFIG_DIR/.${instance}.json.XXXXXX")"
  env_tmp="$(mktemp "$CONFIG_DIR/.${instance}.env.XXXXXX")"
  device="$(tun_device_name "$instance")"

  printf 'V2QUANTUM_PSK=%s\n' "$token" >"$env_tmp"
  chmod 600 "$env_tmp"
  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "role": "%s",\n' "$role"
    printf '  "node_name": "%s",\n' "$instance"
    printf '  "carrier": {\n'
    printf '    "mode": "%s",\n' "$mode"
    if [[ "$role" == "server" ]]; then
      printf '    "listen": "0.0.0.0:%s",\n' "$carrier_value"
    else
      printf '    "server": "%s",\n' "$carrier_value"
    fi
    printf '    "pool": 1,\n'
    printf '    "keepalive_seconds": %s,\n' "$KEEPALIVE"
    printf '    "dial_timeout_seconds": %s,\n' "$DIAL_TIMEOUT"
    printf '    "reconnect_min_millis": %s,\n' "$RECONNECT_MIN"
    printf '    "reconnect_max_millis": %s,\n' "$RECONNECT_MAX"
		printf '    "max_streams_per_session": %s' "$MAX_STREAMS"
		if [[ "$mode" == "quantum_udp" ]]; then
			printf ',\n'
			printf '    "quantum": {"profile": "%s", "auto_tune": true}\n' "$PROFILE_NAME"
		else
			printf '\n'
		fi
    printf '  },\n'
    printf '  "security": {"psk_env": "V2QUANTUM_PSK"},\n'
    printf '  "mappings": [],\n'
    printf '  "tun": {\n'
    printf '    "enabled": true,\n'
    printf '    "name": "%s",\n' "$device"
    printf '    "local_address": "%s",\n' "$local_cidr"
    printf '    "peer_address": "%s",\n' "$peer_ip"
    printf '    "mtu": %s,\n' "$mtu"
    printf '    "routes": ['
    for i in "${!routes_ref[@]}"; do
      comma=','
      (( i == ${#routes_ref[@]} - 1 )) && comma=''
      route="${routes_ref[$i]}"
      printf '"%s"%s' "$route" "$comma"
    done
    printf ']\n'
    printf '  },\n'
    printf '  "health": {"listen": "127.0.0.1:%s", "allow_public_listen": false},\n' "$health_port"
    printf '  "logging": {"level": "info", "json": false}\n'
    printf '}\n'
  } >"$config_tmp"
  chmod 640 "$config_tmp"

  activate_instance "$role" "$instance" "$token" "$config_tmp" "$env_tmp"
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

open_firewall_carrier() {
  local mode="$1" carrier_port="$2" proto
  [[ "$mode" == "quantum_udp" ]] && proto="udp" || proto="tcp"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "$carrier_port/$proto" >/dev/null
    ok "UFW rule added for $carrier_port/$proto."
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$carrier_port/$proto" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "firewalld rule added for $carrier_port/$proto."
  else
    warn "No active UFW/firewalld detected. Open $carrier_port/$proto in the provider firewall."
  fi
}

sysctl_at_least() {
  local key="$1" minimum="$2" current
  current="$("$SYSCTL" -n "$key" 2>/dev/null || true)"
  [[ "$current" =~ ^[0-9]+$ ]] || return 1
  if (( current > minimum )); then
    printf '%s' "$current"
  else
    printf '%s' "$minimum"
  fi
}

apply_tun_host_tuning() {
  local config_parent config_tmp key value wrote=false
  [[ "$HOST_TUNING" != "0" ]] || return 0
  command -v "$SYSCTL" >/dev/null 2>&1 || {
    warn "sysctl is unavailable; skipped optional UDP buffer tuning."
    return 0
  }
  config_parent="$(dirname -- "$SYSCTL_CONFIG")"
  if ! install -d -m755 "$config_parent" || \
     ! config_tmp="$(mktemp "$config_parent/.v2quantum-sysctl.XXXXXX")"; then
    warn "Could not prepare the optional host-tuning file; TUN setup will continue unchanged."
    return 0
  fi
  if ! {
    echo "# Managed by V2Quantum. Existing higher kernel limits are preserved."
    for key in \
      net.core.rmem_max:33554432 \
      net.core.wmem_max:33554432 \
      net.core.netdev_max_backlog:16384 \
      net.ipv4.udp_rmem_min:262144 \
      net.ipv4.udp_wmem_min:262144; do
      value="$(sysctl_at_least "${key%%:*}" "${key#*:}" || true)"
      if [[ -n "$value" ]]; then
        printf '%s = %s\n' "${key%%:*}" "$value"
        wrote=true
      fi
    done
    echo "net.ipv4.ip_forward = 1"
  } >"$config_tmp"; then
    rm -f -- "$config_tmp"
    warn "Could not write optional host tuning; TUN setup will continue unchanged."
    return 0
  fi
  if [[ "$wrote" != true ]]; then
    warn "Kernel UDP buffer keys were unavailable; only IPv4 forwarding was enabled."
  fi
  if ! install -m644 "$config_tmp" "$SYSCTL_CONFIG"; then
    rm -f -- "$config_tmp"
    warn "Could not install optional host tuning; TUN setup will continue unchanged."
    return 0
  fi
  rm -f -- "$config_tmp"
  if "$SYSCTL" -q -p "$SYSCTL_CONFIG" >/dev/null; then
    ok "Applied safe UDP socket-buffer tuning (no carrier/profile change)."
  else
    warn "Saved host tuning at $SYSCTL_CONFIG, but some values could not be applied now."
  fi
}

open_firewall_port_mappings() {
  local mapping public_port failed=false
  local -n mappings_ref="$1"
  (( ${#mappings_ref[@]} > 0 )) || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    for mapping in "${mappings_ref[@]}"; do
      public_port="${mapping%%=*}"
      ufw allow "$public_port/tcp" >/dev/null || failed=true
    done
    [[ "$failed" == false ]] && ok "UFW rules added for the Iran TCP forwarding port(s)." || \
      warn "Could not add every UFW rule; check the Iran TCP port manually."
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for mapping in "${mappings_ref[@]}"; do
      public_port="${mapping%%=*}"
      firewall-cmd --permanent --add-port="$public_port/tcp" >/dev/null || failed=true
    done
    firewall-cmd --reload >/dev/null || failed=true
    [[ "$failed" == false ]] && ok "firewalld rules added for the Iran TCP forwarding port(s)." || \
      warn "Could not add every firewalld rule; check the Iran TCP port manually."
  else
    warn "No active UFW/firewalld detected. Allow the Iran TCP forwarding port(s) in the provider firewall."
  fi
  return 0
}

portmap_port_owner() {
  local public_port="$1" excluded_instance="${2:-}" file instance
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    instance="${file##*/}"
    instance="${instance%.portmap}"
    [[ "$instance" != "$excluded_instance" ]] || continue
    if grep -q "^MAP=${public_port}=" "$file"; then
      printf '%s' "$instance"
      return 0
    fi
  done < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.portmap' -print 2>/dev/null | LC_ALL=C sort)
  return 1
}

prompt_tun_port_mappings() {
  local default_value="$1" output_name="$2" excluded_instance="${3:-}" input mapping public_port owner
  local -n output="$output_name"
  input="$(prompt_default "User TCP port (443 = Iran 443 to outside 443; - disables)" "$default_value")"
  csv_port_mappings "$input" "$output_name" || {
    error "Use 443 for the same port, IRAN_PORT=OUTSIDE_PORT for a different port, or - to disable."
    return 1
  }
  for mapping in "${output[@]}"; do
    public_port="${mapping%%=*}"
    owner="$(portmap_port_owner "$public_port" "$excluded_instance" || true)"
    if [[ -n "$owner" ]]; then
      error "Iran TCP $public_port is already forwarded by $owner. Choose another port or change that instance first."
      return 1
    fi
    if port_is_listening tcp "$public_port"; then
      warn "Iran TCP $public_port already has a local listener. The manager will not stop or alter it."
      confirm "Forward external TCP $public_port through this TUN anyway?" || return 1
    fi
  done
}

portmap_config_tmp() {
  local instance="$1" local_ip="$2" peer_ip="$3" public_interface="$4"
  local -n mappings_ref="$5"
  local config_tmp mapping
  config_tmp="$(mktemp "$CONFIG_DIR/.${instance}.portmap.XXXXXX")"
  {
    echo "VERSION=1"
    printf 'DEVICE=%s\n' "$(tun_device_name "$instance")"
    printf 'LOCAL_IP=%s\n' "$local_ip"
    printf 'PEER_IP=%s\n' "$peer_ip"
    printf 'PUBLIC_INTERFACE=%s\n' "$public_interface"
    for mapping in "${mappings_ref[@]}"; do
      printf 'MAP=%s\n' "$mapping"
    done
  } >"$config_tmp"
  chmod 600 "$config_tmp"
  printf '%s' "$config_tmp"
}

disable_tun_portmap() {
  local instance="$1"
  "$SYSTEMCTL" disable --now "v2quantum-portmap@$instance.service" >/dev/null 2>&1 || true
  rm -f -- "$CONFIG_DIR/$instance.portmap"
  ok "TCP forwarding is disabled for $instance; the TUN itself was not changed."
}

activate_tun_portmap() {
  local instance="$1" local_ip="$2" peer_ip="$3" public_interface="$4"
  local mappings_name="$5"
  local -n mappings_ref="$mappings_name"
  local config_tmp old_tmp="" destination="$CONFIG_DIR/$instance.portmap"
  (( ${#mappings_ref[@]} > 0 )) || {
    disable_tun_portmap "$instance"
    return 0
  }

  config_tmp="$(portmap_config_tmp "$instance" "$local_ip" "$peer_ip" "$public_interface" "$mappings_name")"
  if [[ -f "$destination" ]]; then
    old_tmp="$(mktemp "$CONFIG_DIR/.${instance}.portmap.previous.XXXXXX")"
    cp -a -- "$destination" "$old_tmp"
  fi

  # Stop first so ExecStop reads the old mapping and removes only its exact rules.
  "$SYSTEMCTL" stop "v2quantum-portmap@$instance.service" >/dev/null 2>&1 || true
  install -m600 "$config_tmp" "$destination"
  rm -f -- "$config_tmp"

  # UFW/firewalld reloads may rebuild their tables, so do that before the
  # per-instance service inserts its exact DNAT/SNAT/FORWARD/MSS rules.
  open_firewall_port_mappings "$mappings_name"

  if "$SYSTEMCTL" enable "v2quantum-portmap@$instance.service" >/dev/null && \
     "$SYSTEMCTL" restart "v2quantum-portmap@$instance.service" && \
     "$SYSTEMCTL" is-active --quiet "v2quantum-portmap@$instance.service"; then
    rm -f -- "$old_tmp"
    ok "TCP forwarding is active: IRAN_IP:${mappings_ref[0]%%=*} -> $peer_ip:${mappings_ref[0]#*=}."
    (( ${#mappings_ref[@]} == 1 )) || ok "Configured ${#mappings_ref[@]} TCP forwarding rules."
    for mapping in "${mappings_ref[@]}"; do
      echo "Outside listener must be 0.0.0.0:${mapping#*=} or $peer_ip:${mapping#*=} (not 127.0.0.1 only)."
    done
    return 0
  fi

  error "The TUN stayed active, but its TCP forwarding service failed."
  "$JOURNALCTL" -u "v2quantum-portmap@$instance.service" -n 30 --no-pager || true
  "$SYSTEMCTL" stop "v2quantum-portmap@$instance.service" >/dev/null 2>&1 || true
  if [[ -n "$old_tmp" ]]; then
    install -m600 "$old_tmp" "$destination"
    rm -f -- "$old_tmp"
    "$SYSTEMCTL" restart "v2quantum-portmap@$instance.service" >/dev/null 2>&1 || true
    warn "Previous TCP forwarding configuration was restored."
  else
    rm -f -- "$destination"
    "$SYSTEMCTL" disable "v2quantum-portmap@$instance.service" >/dev/null 2>&1 || true
  fi
  return 1
}

existing_portmap_value() {
  local instance="$1" value="" mapping
  while IFS= read -r mapping; do
    [[ "$mapping" =~ ^[0-9]+=[0-9]+$ ]] || continue
    [[ -z "$value" ]] || value+=','
    value+="$mapping"
  done < <(sed -n 's/^MAP=//p' "$CONFIG_DIR/$instance.portmap" 2>/dev/null)
  printf '%s' "${value:-443}"
}

configure_existing_tun_portmap() {
  local instance config role device local_cidr local_ip peer_ip public_interface default_value
  local mappings=()
  instance="$(pick_instance)" || return 1
  config="$CONFIG_DIR/$instance.json"
  role="$(sed -n 's/.*"role"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1)"
  [[ "$role" == "server" ]] && grep -q '"tun"[[:space:]]*:' "$config" || {
    error "Choose an Iran L3-TUN instance (role=server)."
    return 1
  }
  device="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | tail -n1)"
  local_cidr="$(sed -n 's/.*"local_address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1)"
  peer_ip="$(sed -n 's/.*"peer_address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1)"
  local_ip="${local_cidr%/*}"
  [[ "$device" == "$(tun_device_name "$instance")" ]] && valid_ipv4 "$local_ip" && valid_ipv4 "$peer_ip" || {
    error "Could not read valid TUN addresses from $config."
    return 1
  }
  default_value="$(existing_portmap_value "$instance")"
  prompt_tun_port_mappings "$default_value" mappings "$instance" || return 1
  if (( ${#mappings[@]} == 0 )); then
    disable_tun_portmap "$instance"
    return 0
  fi
  public_interface="$(detect_public_interface)"
  apply_tun_host_tuning
  activate_tun_portmap "$instance" "$local_ip" "$peer_ip" "$public_interface" mappings
}

configure_server() {
	local mode profile token public_host carrier_port proto public_input public_port health_port raw_json="" setup_code instance label
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
	if [[ "$mode" == "raw_icmp" ]]; then
		instance="$(new_instance iran "raw-${public_ports[0]}")"
	else
		instance="$(new_instance iran "${mode}-${carrier_port}")"
	fi
	label="${instance#iran-}"

	write_instance server "$instance" "$mode" "$token" "$health_port" "$carrier_port" "$raw_json" public_ports
	open_firewall_server "$mode" "$carrier_port" public_ports
	if [[ "$mode" != "raw_icmp" ]]; then
		setup_code="$(make_setup_code "$token" "$mode" "$public_host" "$carrier_port" \
			"$(IFS=,; echo "${public_ports[*]}")" "$profile" "${#public_ports[@]}" "$label")"
		echo
		printf '%sCOPY THIS ONE SETUP CODE TO THE OUTSIDE SERVER:%s\n' "$cyan" "$reset"
    printf '%s\n' "$setup_code"
  else
    echo
    printf '%sCOPY THIS PSK TO THE OUTSIDE RAW CONFIG:%s\n%s\n' "$cyan" "$reset" "$token"
  fi
}

configure_client() {
	local input mode token server_endpoint profile target_input health_port raw_json="" count instance label_hint
	local targets=()
	printf 'Paste Iran setup code (V2Q3_/V2Q2_/V2Q1_...) or a raw PSK: ' >&2
	IFS= read -r input
	if [[ "$input" == V2Q1_* || "$input" == V2Q2_* || "$input" == V2Q3_* ]]; then
		parse_setup_code "$input" || { error "Invalid setup code."; return 1; }
    token="$CODE_TOKEN"
    mode="$CODE_MODE"
    server_endpoint="$CODE_HOST:$CODE_PORT"
    profile="$CODE_PROFILE"
		count="$CODE_COUNT"
		label_hint="${CODE_LABEL:-${mode}-${CODE_PORT}}"
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
			label_hint="raw"
		else
      server_endpoint="$(prompt_default "Iran carrier address" "IRAN_IP:8890")"
			safe_value "$server_endpoint" && [[ "$server_endpoint" == *:* ]] || { error "Invalid Iran endpoint."; return 1; }
			label_hint="${mode}-${server_endpoint##*:}"
    fi
    target_input="$(prompt_default "Outside target(s), comma-separated" "127.0.0.1:2444")"
  fi

  csv_targets "$target_input" targets || { error "Invalid target list."; return 1; }
	(( ${#targets[@]} == count )) || { error "Expected $count target(s), received ${#targets[@]}."; return 1; }
	health_port="$(find_free_port tcp 19090)"
	instance="$(new_instance outside "$label_hint")"
	write_instance client "$instance" "$mode" "$token" "$health_port" "$server_endpoint" "$raw_json" targets
	ok "Automatic reconnect and the health watchdog are enabled."
}

configure_tun_server() {
  local mode profile token public_host carrier_port proto health_port instance label
  local server_cidr client_cidr server_ip client_ip mtu routes_input setup_code public_interface mapping
  local routes=()
  local port_mappings=()

  echo
  echo "L3 TUN creates a private point-to-point IP link. It is separate from Raw/Spoof."
  mode="$(select_tun_mode)"
  profile="$(select_tun_profile)"
  apply_profile "$profile"
  POOL=1
  token="$($BIN keygen)"
  valid_token "$token" || { error "Token generation failed."; return 1; }

  [[ "$mode" == "quantum_udp" ]] && proto="udp" || proto="tcp"
  carrier_port="$(prompt_default "Carrier port" "$(find_free_port "$proto" 8900)")"
  valid_port "$carrier_port" || { error "Invalid carrier port."; return 1; }
  if port_is_listening "$proto" "$carrier_port"; then
    confirm "Port $carrier_port/$proto is already listening. Continue anyway?" || return 1
  fi
  public_host="$(prompt_default "Iran public IPv4 or hostname" "$(detect_public_ipv4)")"
  safe_value "$public_host" || { error "Invalid public host."; return 1; }

  server_cidr="$(prompt_default "Iran private TUN address" "10.77.0.1/30")"
  client_cidr="$(prompt_default "Outside private TUN address" "10.77.0.2/30")"
  valid_cidr "$server_cidr" || { error "Invalid Iran TUN CIDR."; return 1; }
  valid_cidr "$client_cidr" || { error "Invalid outside TUN CIDR."; return 1; }
  server_ip="${server_cidr%/*}"
  client_ip="${client_cidr%/*}"
  [[ "$server_ip" != "$client_ip" ]] || { error "The two TUN addresses must differ."; return 1; }
  mtu="$(prompt_default "TUN MTU" "1280")"
  [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu >= 576 && mtu <= 9000 )) || { error "MTU must be 576-9000."; return 1; }
  routes_input="$(prompt_default "Specific networks behind outside to route via TUN (- for none)" "-")"
  csv_routes "$routes_input" routes || { error "Invalid route list."; return 1; }
  prompt_tun_port_mappings "443" port_mappings || return 1

  health_port="$(find_free_port tcp 19090)"
  instance="$(new_instance iran "tun-${mode}-${carrier_port}")"
  label="${instance#iran-}"
  write_tun_instance server "$instance" "$mode" "$token" "$health_port" "$carrier_port" \
    "$server_cidr" "$client_ip" "$mtu" routes
  apply_tun_host_tuning
  open_firewall_carrier "$mode" "$carrier_port"
  if (( ${#port_mappings[@]} > 0 )); then
    public_interface="$(detect_public_interface)"
    if ! activate_tun_portmap "$instance" "$server_ip" "$client_ip" "$public_interface" port_mappings; then
      warn "Use TUN menu option 6 to retry the TCP forward without recreating the TUN."
    fi
  fi
  setup_code="$(make_tun_setup_code "$token" "$mode" "$public_host" "$carrier_port" "$profile" \
    "$label" "$server_cidr" "$client_cidr" "$mtu")"

  echo
  printf '%sCOPY THIS TUN SETUP CODE TO THE OUTSIDE SERVER:%s\n' "$cyan" "$reset"
  printf '%s\n' "$setup_code"
  echo "After both sides start, test: ping -c 3 $client_ip"
  for mapping in "${port_mappings[@]}"; do
    echo "User traffic: $public_host:${mapping%%=*} -> outside TUN $client_ip:${mapping#*=} (TCP)"
  done
}

configure_tun_client() {
  local input mode token server_endpoint profile health_port instance label_hint
  local server_cidr client_cidr server_ip client_ip mtu routes_input
  local routes=()

	printf 'Paste the V2T2_ (or legacy V2T1_) setup code from Iran: ' >&2
  IFS= read -r input
  parse_tun_setup_code "$input" || { error "Invalid TUN setup code."; return 1; }
  token="$TUN_CODE_TOKEN"
  mode="$TUN_CODE_MODE"
  server_endpoint="$TUN_CODE_HOST:$TUN_CODE_PORT"
  profile="$TUN_CODE_PROFILE"
  label_hint="$TUN_CODE_LABEL"
  server_cidr="$TUN_CODE_SERVER_CIDR"
  client_cidr="$TUN_CODE_CLIENT_CIDR"
  mtu="$TUN_CODE_MTU"
  server_ip="${server_cidr%/*}"
  client_ip="${client_cidr%/*}"
  apply_profile "$profile"
  POOL=1

  routes_input="$(prompt_default "Specific networks behind Iran to route via TUN (- for none)" "-")"
  csv_routes "$routes_input" routes || { error "Invalid route list."; return 1; }
  health_port="$(find_free_port tcp 19090)"
  instance="$(new_instance outside "$label_hint")"
  write_tun_instance client "$instance" "$mode" "$token" "$health_port" "$server_endpoint" \
    "$client_cidr" "$server_ip" "$mtu" routes
  apply_tun_host_tuning
  ok "TUN is active with reconnect and watchdog recovery."
  echo "Test the Iran side: ping -c 3 $server_ip"
}

pick_instance() {
  local input index
  local instances=()
  mapfile -t instances < <(
    find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null \
      | sed 's/\.json$//' | LC_ALL=C sort
  )
  (( ${#instances[@]} > 0 )) || { error "No tunnel instance is configured."; return 1; }
  list_instances >&2
  input="$(prompt_default "Tunnel number or exact name" "1")"
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    index=$((10#$input - 1))
    (( index >= 0 && index < ${#instances[@]} )) || { error "Tunnel number is out of range."; return 1; }
    printf '%s' "${instances[$index]}"
    return 0
  fi
  safe_instance "$input" && [[ -f "$CONFIG_DIR/$input.json" ]] || {
    error "Unknown tunnel instance."
    return 1
  }
  printf '%s' "$input"
}

list_instances() {
  local file instance role carrier kind state index=0
  printf '%-4s %-34s %-8s %-12s %-9s %s\n' "No." "Instance" "Role" "Type" "Carrier" "State"
  printf '%-4s %-34s %-8s %-12s %-9s %s\n' "---" "--------" "----" "----" "-------" "-----"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    instance="${file##*/}"
    instance="${instance%.json}"
    role="$(sed -n 's/.*"role"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n1)"
    carrier="$(sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n1)"
    kind="ports"
    grep -q '"tun"[[:space:]]*:' "$file" && kind="L3-TUN"
    state="$("$SYSTEMCTL" is-active "v2quantum@$instance.service" 2>/dev/null || true)"
    index=$((index + 1))
    printf '%-4s %-34s %-8s %-12s %-9s %s\n' "$index" "$instance" "${role:-?}" "$kind" "${carrier:-?}" "${state:-unknown}"
  done < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort)
  (( index > 0 )) || warn "No tunnel instance is configured."
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
  instance="$(pick_instance)" || return 1
  safe_instance "$instance" || { error "Invalid instance."; return 1; }
  "$SYSTEMCTL" --no-pager --full status "v2quantum@$instance.service" || true
  if [[ -f "$CONFIG_DIR/$instance.portmap" ]]; then
    "$SYSTEMCTL" --no-pager --full status "v2quantum-portmap@$instance.service" || true
  fi
  load_instance_env "$instance"
  "$BIN" healthcheck -config "$CONFIG_DIR/$instance.json" -timeout 5s || true
}

diagnostics() {
  local instance
  instance="$(pick_instance)" || return 1
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
  local instance backup_path
  instance="$(pick_instance)" || return 1
  safe_instance "$instance" || { error "Invalid instance."; return 1; }
  confirm "Permanently delete $instance and its config, token, watchdog state and per-instance backups?" || { echo "Cancelled."; return 0; }
  "$SYSTEMCTL" disable --now "v2quantum-watchdog@$instance.timer" 2>/dev/null || true
  "$SYSTEMCTL" disable --now "v2quantum-portmap@$instance.service" 2>/dev/null || true
  "$SYSTEMCTL" disable --now "v2quantum@$instance.service" 2>/dev/null || true
  "$SYSTEMCTL" reset-failed "v2quantum@$instance.service" "v2quantum-watchdog@$instance.service" \
    "v2quantum-portmap@$instance.service" 2>/dev/null || true
  rm -f -- "$CONFIG_DIR/$instance.json" "$CONFIG_DIR/$instance.env" "$CONFIG_DIR/$instance.portmap" \
    "$RUN_DIR/v2quantum-watchdog-$instance.failures"
  while IFS= read -r backup_path; do
    [[ -n "$backup_path" ]] || continue
    rm -rf -- "$backup_path"
  done < <(find "$STATE_DIR/backups" -mindepth 1 -maxdepth 1 -type d -name "$instance-*" -print 2>/dev/null)
  ok "Instance $instance was completely removed. Other tunnels were not touched."
}

tun_menu() {
  local choice instance
  while true; do
    echo
    echo "================ V2Quantum L3 TUN ================"
    echo "1) Create Iran TUN + generate V2T2 setup code"
    echo "2) Create outside TUN from V2T2/V2T1 setup code"
    echo "3) List all V2Quantum instances"
    echo "4) Status/health of one instance"
    echo "5) Delete one instance completely"
    echo "6) Add/change Iran TUN TCP forward (for port 443, enter 443)"
    echo "0) Return"
    choice="$(prompt_default "Choice" "1")"
    case "${choice,,}" in
      1|iran|server) configure_tun_server || warn "TUN server setup was not completed." ;;
      2|outside|client|kharej) configure_tun_client || warn "TUN client setup was not completed." ;;
      3|list) list_instances ;;
      4|status) show_status ;;
      5|delete|remove) delete_instance ;;
      6|forward|portmap) configure_existing_tun_portmap || warn "TCP forwarding was not changed." ;;
      0|back|q|quit|exit) return 0 ;;
      *) error "Unknown choice." ;;
    esac
  done
}

manager_usage() {
  cat <<'EOF'
V2Quantum Manager

Usage:
  v2quantum-manager          Open the full manager
  v2quantum-manager --tun    Open only the independent L3 TUN manager
  v2quantum-manager --list   List configured instances
EOF
}

case "${1:-}" in
  --tun) tun_menu; exit 0 ;;
  --list) list_instances; exit 0 ;;
  -h|--help) manager_usage; exit 0 ;;
  "") ;;
  *) error "Unknown option: $1"; manager_usage >&2; exit 2 ;;
esac

while true; do
  echo
  echo "================ V2Quantum Manager ================"
  echo "Reverse ports"
  echo "  1) Iran server + V2Q3 setup code"
  echo "  2) Outside server from V2Q3/V2Q2/V2Q1 code"
  echo "Layer 3"
  echo "  3) L3 TUN manager (independent TCP/Quantum carrier)"
  echo "Instances"
  echo "  4) List all tunnels"
  echo "  5) Status and health"
  echo "  6) Follow logs"
  echo "  7) Restart one tunnel"
  echo "  8) Full diagnostics"
  echo "Maintenance"
  echo "  9) Delete one tunnel completely"
  echo " 10) Raw spoof preflight (existing feature)"
  echo " 11) Update core and manager"
  echo " 12) Uninstall V2Quantum program"
  echo "0) Exit"
  choice="$(prompt_default "Choice" "1")"
  case "${choice,,}" in
    1|iran|server) configure_server || warn "Iran setup was not completed." ;;
    2|outside|client|kharej) configure_client || warn "Outside setup was not completed." ;;
    3|tun) tun_menu ;;
    4|list) list_instances ;;
    5|status) show_status ;;
    6|logs)
      instance="$(pick_instance)" || continue
      safe_instance "$instance" || { error "Invalid instance."; continue; }
      "$JOURNALCTL" -fu "v2quantum@$instance.service"
      ;;
    7|restart)
      instance="$(pick_instance)" || continue
      safe_instance "$instance" || { error "Invalid instance."; continue; }
      "$SYSTEMCTL" restart "v2quantum@$instance.service"
      ;;
    8|diagnostics|diag) diagnostics ;;
    9|delete|remove) delete_instance ;;
    10|spoof|preflight)
      instance="$(pick_instance)" || continue
      safe_instance "$instance" || { error "Invalid instance."; continue; }
      load_instance_env "$instance"
      "$BIN" spoof-check -config "$CONFIG_DIR/$instance.json"
      ;;
    11|update)
      [[ -x "$INSTALLER" ]] || { error "Installer not found at $INSTALLER"; continue; }
      "$INSTALLER" --update --no-menu
      ;;
    12|uninstall)
      [[ -x "$INSTALLER" ]] || { error "Installer not found at $INSTALLER"; continue; }
      exec "$INSTALLER" --uninstall
      ;;
    0|q|quit|exit) exit 0 ;;
    *) error "Unknown choice." ;;
  esac
done
