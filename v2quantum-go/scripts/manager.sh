#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

BIN="${V2QUANTUM_BIN:-/usr/local/bin/v2quantum}"
INSTALLER="${V2QUANTUM_INSTALLER:-/usr/local/sbin/v2quantum-installer}"
CONFIG_DIR="${V2QUANTUM_CONFIG_DIR:-/etc/v2quantum}"
STATE_DIR="${V2QUANTUM_STATE_DIR:-/var/lib/v2quantum}"
RUN_DIR="${V2QUANTUM_RUN_DIR:-/run}"
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

apply_fusion_profile() {
  PROFILE_NAME="$1"
  case "$PROFILE_NAME" in
    stable)
      POOL=1 KEEPALIVE=8 DIAL_TIMEOUT=7 RECONNECT_MIN=500 RECONNECT_MAX=12000 MAX_STREAMS=512
      FUSION_QUANTUM_POOL=1 FUSION_WEBSOCKET_POOL=1 FUSION_TCP_POOL=1
      FUSION_UNAVAILABLE=30 FUSION_RECOVERY_HOLD=20 FUSION_REPLAY_BYTES=$((4 << 20))
      ;;
    balanced)
      POOL=1 KEEPALIVE=5 DIAL_TIMEOUT=5 RECONNECT_MIN=300 RECONNECT_MAX=8000 MAX_STREAMS=1024
      FUSION_QUANTUM_POOL=2 FUSION_WEBSOCKET_POOL=2 FUSION_TCP_POOL=1
      FUSION_UNAVAILABLE=20 FUSION_RECOVERY_HOLD=15 FUSION_REPLAY_BYTES=$((8 << 20))
      ;;
    max)
      POOL=1 KEEPALIVE=3 DIAL_TIMEOUT=4 RECONNECT_MIN=200 RECONNECT_MAX=5000 MAX_STREAMS=2048
      FUSION_QUANTUM_POOL=3 FUSION_WEBSOCKET_POOL=2 FUSION_TCP_POOL=2
      FUSION_UNAVAILABLE=15 FUSION_RECOVERY_HOLD=10 FUSION_REPLAY_BYTES=$((16 << 20))
      ;;
    *) return 1 ;;
  esac
}

select_fusion_profile() {
  local choice
  echo "1) Stable    low resource use, conservative recovery" >&2
  echo "2) Balanced  hot Quantum + WebSocket standby (recommended)" >&2
  echo "3) Max       more hot paths and a larger replay window" >&2
  choice="$(prompt_default "FusionMux profile" "2")"
  case "${choice,,}" in
    1|stable) printf 'stable' ;;
    2|balanced|default) printf 'balanced' ;;
    3|max|maximum) printf 'max' ;;
    *) error "Unknown FusionMux profile."; return 1 ;;
  esac
}

csv_ports() {
  local input="$1" item
  local -n output="$2"
  local -A seen=()
  input="$(printf '%s' "$input" | tr -d '[:space:]')"
  IFS=',' read -r -a output <<<"$input"
  (( ${#output[@]} > 0 && ${#output[@]} <= 32 )) || return 1
  for item in "${output[@]}"; do
    valid_port "$item" || return 1
    [[ -z "${seen[$item]:-}" ]] || return 1
    seen[$item]=1
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

valid_endpoint() {
  local value="$1" host port
  safe_value "$value" || return 1
  [[ "$value" == *:* ]] || return 1
  host="${value%:*}"
  port="${value##*:}"
  [[ -n "$host" ]] && valid_port "$port"
}

valid_host() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]]
}

valid_ws_path() {
  local value="$1"
  safe_value "$value" && [[ "$value" == /* && ${#value} -le 128 && "$value" != *'?'* && "$value" != *'#'* ]]
}

make_fusion_setup_code() {
  local token="$1" public_host="$2" quantum_port="$3" ws_endpoint="$4" ws_host="$5"
  local ws_tls="$6" ws_path="$7" tcp_port="$8" public_ports="$9" profile="${10}"
  local count="${11}" label="${12}"
  printf 'V2F1_%s' "$(printf '%s' "$token|$public_host|$quantum_port|$ws_endpoint|$ws_host|$ws_tls|$ws_path|$tcp_port|$public_ports|$profile|$count|$label" | base64url_encode)"
}

parse_fusion_setup_code() {
  local code="$1" decoded extra
  [[ "$code" == V2F1_* ]] || return 1
  decoded="$(base64url_decode "${code#V2F1_}")" || return 1
  IFS='|' read -r FUSION_CODE_TOKEN FUSION_CODE_HOST FUSION_CODE_QUANTUM_PORT \
    FUSION_CODE_WS_ENDPOINT FUSION_CODE_WS_HOST FUSION_CODE_WS_TLS FUSION_CODE_WS_PATH \
    FUSION_CODE_TCP_PORT FUSION_CODE_PUBLIC_PORTS FUSION_CODE_PROFILE FUSION_CODE_COUNT \
    FUSION_CODE_LABEL extra <<<"$decoded"
  [[ -z "$extra" ]] || return 1
  valid_token "$FUSION_CODE_TOKEN" || return 1
  valid_host "$FUSION_CODE_HOST" || return 1
  valid_port "$FUSION_CODE_QUANTUM_PORT" || return 1
  valid_endpoint "$FUSION_CODE_WS_ENDPOINT" || return 1
  [[ "$FUSION_CODE_WS_HOST" == "-" ]] || valid_host "$FUSION_CODE_WS_HOST" || return 1
  [[ "$FUSION_CODE_WS_TLS" == "0" || "$FUSION_CODE_WS_TLS" == "1" ]] || return 1
  valid_ws_path "$FUSION_CODE_WS_PATH" || return 1
  valid_port "$FUSION_CODE_TCP_PORT" || return 1
  [[ "$FUSION_CODE_COUNT" =~ ^[0-9]+$ ]] && (( FUSION_CODE_COUNT >= 1 && FUSION_CODE_COUNT <= 32 )) || return 1
  safe_label "$FUSION_CODE_LABEL" || return 1
  apply_fusion_profile "$FUSION_CODE_PROFILE" || return 1
  local decoded_ports=()
  csv_ports "$FUSION_CODE_PUBLIC_PORTS" decoded_ports || return 1
  (( ${#decoded_ports[@]} == FUSION_CODE_COUNT ))
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
  if [[ -f "$CONFIG_DIR/$instance.json" || -f "$CONFIG_DIR/$instance.env" ]]; then
    backup="$STATE_DIR/backups/$instance-$(date +%Y%m%d-%H%M%S)"
    install -d -m700 "$backup"
    [[ -f "$CONFIG_DIR/$instance.json" ]] && cp -a -- "$CONFIG_DIR/$instance.json" "$backup/"
    [[ -f "$CONFIG_DIR/$instance.env" ]] && cp -a -- "$CONFIG_DIR/$instance.env" "$backup/"
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

write_fusion_instance() {
  local role="$1" instance="$2" token="$3" health_port="$4"
  local quantum_value="$5" websocket_value="$6" websocket_host="$7" websocket_tls="$8"
  local websocket_path="$9" tcp_value="${10}"
  local -n values="${11}"
  local config_tmp env_tmp i comma endpoint ws_host_json="" ws_sni_json=""
  config_tmp="$(mktemp "$CONFIG_DIR/.${instance}.json.XXXXXX")"
  env_tmp="$(mktemp "$CONFIG_DIR/.${instance}.env.XXXXXX")"

  printf 'V2QUANTUM_PSK=%s\n' "$token" >"$env_tmp"
  chmod 600 "$env_tmp"
  if [[ "$websocket_host" != "-" ]]; then
    ws_host_json=", \"host\": \"$websocket_host\""
    [[ "$websocket_tls" == "true" ]] && ws_sni_json=", \"server_name\": \"$websocket_host\""
  fi
  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "role": "%s",\n' "$role"
    printf '  "node_name": "%s",\n' "$instance"
    printf '  "carrier": {\n'
    printf '    "mode": "fusion",\n'
    printf '    "pool": 1,\n'
    printf '    "keepalive_seconds": %s,\n' "$KEEPALIVE"
    printf '    "dial_timeout_seconds": %s,\n' "$DIAL_TIMEOUT"
    printf '    "reconnect_min_millis": %s,\n' "$RECONNECT_MIN"
    printf '    "reconnect_max_millis": %s,\n' "$RECONNECT_MAX"
    printf '    "max_streams_per_session": %s,\n' "$MAX_STREAMS"
    printf '    "fusion": {\n'
    printf '      "policy": "failover",\n'
    printf '      "unavailable_timeout_seconds": %s,\n' "$FUSION_UNAVAILABLE"
    printf '      "recovery_hold_seconds": %s,\n' "$FUSION_RECOVERY_HOLD"
    printf '      "replay_buffer_bytes": %s,\n' "$FUSION_REPLAY_BYTES"
    printf '      "paths": [\n'
    if [[ "$role" == "server" ]]; then
      printf '        {"name": "quantum", "mode": "quantum_udp", "listen": "0.0.0.0:%s", "priority": 10, "pool": %s, "quantum": {"profile": "%s", "auto_tune": true}},\n' \
        "$quantum_value" "$FUSION_QUANTUM_POOL" "$PROFILE_NAME"
      printf '        {"name": "websocket", "mode": "websocket", "listen": "0.0.0.0:%s", "priority": 20, "pool": %s, "websocket": {"path": "%s"}},\n' \
        "$websocket_value" "$FUSION_WEBSOCKET_POOL" "$websocket_path"
      printf '        {"name": "tcp", "mode": "tcp", "listen": "0.0.0.0:%s", "priority": 30, "pool": %s}\n' \
        "$tcp_value" "$FUSION_TCP_POOL"
    else
      printf '        {"name": "quantum", "mode": "quantum_udp", "server": "%s", "priority": 10, "pool": %s, "quantum": {"profile": "%s", "auto_tune": true}},\n' \
        "$quantum_value" "$FUSION_QUANTUM_POOL" "$PROFILE_NAME"
      printf '        {"name": "websocket", "mode": "websocket", "server": "%s", "priority": 20, "pool": %s, "websocket": {"path": "%s", "tls": %s%s%s, "insecure_skip_verify": false}},\n' \
        "$websocket_value" "$FUSION_WEBSOCKET_POOL" "$websocket_path" "$websocket_tls" "$ws_host_json" "$ws_sni_json"
      printf '        {"name": "tcp", "mode": "tcp", "server": "%s", "priority": 30, "pool": %s}\n' \
        "$tcp_value" "$FUSION_TCP_POOL"
    fi
    printf '      ]\n'
    printf '    }\n'
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

open_firewall_fusion() {
  local quantum_port="$1" websocket_port="$2" tcp_port="$3" item
  local -n ports_ref="$4"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "$quantum_port/udp" >/dev/null
    ufw allow "$websocket_port/tcp" >/dev/null
    ufw allow "$tcp_port/tcp" >/dev/null
    for item in "${ports_ref[@]}"; do ufw allow "$item/tcp" >/dev/null; done
    ok "UFW rules added for all FusionMux paths."
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$quantum_port/udp" >/dev/null
    firewall-cmd --permanent --add-port="$websocket_port/tcp" >/dev/null
    firewall-cmd --permanent --add-port="$tcp_port/tcp" >/dev/null
    for item in "${ports_ref[@]}"; do firewall-cmd --permanent --add-port="$item/tcp" >/dev/null; done
    firewall-cmd --reload >/dev/null
    ok "firewalld rules added for all FusionMux paths."
  else
    warn "No active UFW/firewalld detected. Allow UDP $quantum_port, TCP $websocket_port/$tcp_port, and the public mapping ports in the provider firewall."
  fi
}

configure_fusion_server() {
  local profile token public_host public_input public_port health_port instance label setup_code
  local quantum_port websocket_port tcp_port ws_mode ws_endpoint ws_host ws_tls ws_path domain
  local public_ports=()

  echo
  printf '%sFusionMux Pro: Quantum primary + WebSocket standby + TCP fallback%s\n' "$cyan" "$reset"
  echo "All three paths stay connected. Existing TCP streams resume on the next path after a failure."
  profile="$(select_fusion_profile)" || return 1
  apply_fusion_profile "$profile"
  token="$($BIN keygen)"
  valid_token "$token" || { error "Token generation failed."; return 1; }

  public_input="$(prompt_default "Public TCP port(s), comma-separated" "$(find_free_port tcp 2445)")"
  csv_ports "$public_input" public_ports || { error "Invalid public port list."; return 1; }
  for public_port in "${public_ports[@]}"; do
    if port_is_listening tcp "$public_port"; then
      confirm "Public port $public_port/tcp is already listening. Continue anyway?" || return 1
    fi
  done

  public_host="$(prompt_default "Iran public IPv4 or hostname" "$(detect_public_ipv4)")"
  valid_host "$public_host" || { error "Enter an IPv4 address or hostname without a port."; return 1; }
  quantum_port="$(prompt_default "Quantum UDP port (primary)" "$(find_free_port udp 8890)")"
  valid_port "$quantum_port" || { error "Invalid Quantum port."; return 1; }
  tcp_port="$(prompt_default "Direct TCP port (last fallback)" "$(find_free_port tcp 8892)")"
  valid_port "$tcp_port" || { error "Invalid TCP fallback port."; return 1; }

  echo "1) Direct WebSocket - no CDN configuration required" >&2
  echo "2) Cloudflare/WSS - requires your domain to route the edge endpoint to this origin port" >&2
  ws_mode="$(prompt_default "WebSocket path type" "1")"
  ws_path="$(prompt_default "WebSocket URL path" "/v2q-fusion")"
  valid_ws_path "$ws_path" || { error "Invalid WebSocket path."; return 1; }
  case "${ws_mode,,}" in
    1|direct|ws)
      websocket_port="$(prompt_default "Direct WebSocket TCP port" "$(find_free_port tcp 8891)")"
      valid_port "$websocket_port" || { error "Invalid WebSocket port."; return 1; }
      ws_endpoint="$public_host:$websocket_port"
      ws_host="-"
      ws_tls=0
      ;;
    2|cloudflare|cdn|wss)
      domain="$(prompt_default "Cloudflare hostname (orange-cloud DNS)" "tunnel.example.com")"
      valid_host "$domain" || { error "Invalid Cloudflare hostname."; return 1; }
      ws_endpoint="$(prompt_default "Public Cloudflare WSS endpoint" "$domain:443")"
      valid_endpoint "$ws_endpoint" || { error "Invalid Cloudflare endpoint."; return 1; }
      websocket_port="$(prompt_default "Origin WebSocket listen port" "$(find_free_port tcp 8080)")"
      valid_port "$websocket_port" || { error "Invalid origin WebSocket port."; return 1; }
      ws_host="$domain"
      ws_tls=1
      warn "Cloudflare must forward $ws_endpoint$ws_path to this server on TCP $websocket_port. The V2Quantum origin listener is plain WebSocket; TLS terminates at Cloudflare or your reverse proxy."
      ;;
    *) error "Unknown WebSocket path type."; return 1 ;;
  esac

  [[ "$quantum_port" != "$tcp_port" && "$quantum_port" != "$websocket_port" && "$tcp_port" != "$websocket_port" ]] || {
    error "Quantum, WebSocket and TCP carrier ports must be different."
    return 1
  }
  for public_port in "${public_ports[@]}"; do
    if [[ "$public_port" == "$websocket_port" || "$public_port" == "$tcp_port" ]]; then
      error "Public mapping port $public_port conflicts with a FusionMux TCP carrier port."
      return 1
    fi
  done
  if port_is_listening udp "$quantum_port"; then
    confirm "Port $quantum_port/udp is already listening. Continue anyway?" || return 1
  fi
  if port_is_listening tcp "$websocket_port"; then
    confirm "Port $websocket_port/tcp is already listening. Continue anyway?" || return 1
  fi
  if port_is_listening tcp "$tcp_port"; then
    confirm "Port $tcp_port/tcp is already listening. Continue anyway?" || return 1
  fi

  health_port="$(find_free_port tcp 19090)"
  instance="$(new_instance iran "fusion-${public_ports[0]}")"
  label="${instance#iran-}"
  write_fusion_instance server "$instance" "$token" "$health_port" "$quantum_port" \
    "$websocket_port" "$ws_host" false "$ws_path" "$tcp_port" public_ports || return 1
  open_firewall_fusion "$quantum_port" "$websocket_port" "$tcp_port" public_ports
  setup_code="$(make_fusion_setup_code "$token" "$public_host" "$quantum_port" "$ws_endpoint" \
    "$ws_host" "$ws_tls" "$ws_path" "$tcp_port" "$(IFS=,; echo "${public_ports[*]}")" \
    "$profile" "${#public_ports[@]}" "$label")"

  echo
  printf '%sCOPY THIS FUSION SETUP CODE TO THE OUTSIDE SERVER:%s\n' "$cyan" "$reset"
  printf '%s\n' "$setup_code"
  echo "Priority: Quantum(10) -> WebSocket(20) -> TCP(30)."
}

configure_fusion_client() {
  local input token profile target_input health_port instance label_hint ws_tls_bool
  local quantum_endpoint tcp_endpoint
  local targets=()

  printf 'Paste the V2F1_ setup code from Iran: ' >&2
  IFS= read -r input
  parse_fusion_setup_code "$input" || { error "Invalid FusionMux setup code."; return 1; }
  token="$FUSION_CODE_TOKEN"
  profile="$FUSION_CODE_PROFILE"
  apply_fusion_profile "$profile"
  quantum_endpoint="$FUSION_CODE_HOST:$FUSION_CODE_QUANTUM_PORT"
  tcp_endpoint="$FUSION_CODE_HOST:$FUSION_CODE_TCP_PORT"
  label_hint="$FUSION_CODE_LABEL"
  [[ "$FUSION_CODE_WS_TLS" == "1" ]] && ws_tls_bool=true || ws_tls_bool=false

  if (( FUSION_CODE_COUNT == 1 )); then
    target_input="$(prompt_default "Outside local target" "127.0.0.1:2444")"
  else
    target_input="$(prompt_default "Outside targets ($FUSION_CODE_COUNT items, comma-separated)" "$FUSION_CODE_PUBLIC_PORTS")"
  fi
  csv_targets "$target_input" targets || { error "Invalid target list."; return 1; }
  (( ${#targets[@]} == FUSION_CODE_COUNT )) || {
    error "Expected $FUSION_CODE_COUNT target(s), received ${#targets[@]}."
    return 1
  }

  health_port="$(find_free_port tcp 19090)"
  instance="$(new_instance outside "$label_hint")"
  write_fusion_instance client "$instance" "$token" "$health_port" "$quantum_endpoint" \
    "$FUSION_CODE_WS_ENDPOINT" "$FUSION_CODE_WS_HOST" "$ws_tls_bool" \
    "$FUSION_CODE_WS_PATH" "$tcp_endpoint" targets || return 1
  ok "FusionMux is active with hot paths, stream replay, reconnect and watchdog recovery."
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

	write_instance server "$instance" "$mode" "$token" "$health_port" "$carrier_port" "$raw_json" public_ports || return 1
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
	write_instance client "$instance" "$mode" "$token" "$health_port" "$server_endpoint" "$raw_json" targets || return 1
	ok "Automatic reconnect and the health watchdog are enabled."
}

configure_tun_server() {
  local mode profile token public_host carrier_port proto health_port instance label
  local server_cidr client_cidr server_ip client_ip mtu routes_input setup_code
  local routes=()

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

  health_port="$(find_free_port tcp 19090)"
  instance="$(new_instance iran "tun-${mode}-${carrier_port}")"
  label="${instance#iran-}"
  write_tun_instance server "$instance" "$mode" "$token" "$health_port" "$carrier_port" \
    "$server_cidr" "$client_ip" "$mtu" routes || return 1
  open_firewall_carrier "$mode" "$carrier_port"
  setup_code="$(make_tun_setup_code "$token" "$mode" "$public_host" "$carrier_port" "$profile" \
    "$label" "$server_cidr" "$client_cidr" "$mtu")"

  echo
  printf '%sCOPY THIS TUN SETUP CODE TO THE OUTSIDE SERVER:%s\n' "$cyan" "$reset"
  printf '%s\n' "$setup_code"
  echo "After both sides start, test: ping -c 3 $client_ip"
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
    "$client_cidr" "$server_ip" "$mtu" routes || return 1
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
    [[ "$carrier" == "fusion" ]] && kind="FusionMux"
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
  "$SYSTEMCTL" disable --now "v2quantum@$instance.service" 2>/dev/null || true
  "$SYSTEMCTL" reset-failed "v2quantum@$instance.service" "v2quantum-watchdog@$instance.service" 2>/dev/null || true
  rm -f -- "$CONFIG_DIR/$instance.json" "$CONFIG_DIR/$instance.env" \
    "$RUN_DIR/v2quantum-watchdog-$instance.failures"
  while IFS= read -r backup_path; do
    [[ -n "$backup_path" ]] || continue
    rm -rf -- "$backup_path"
  done < <(find "$STATE_DIR/backups" -mindepth 1 -maxdepth 1 -type d -name "$instance-*" -print 2>/dev/null)
  ok "Instance $instance was completely removed. Other tunnels were not touched."
}

fusion_menu() {
  local choice instance
  while true; do
    echo
    echo "================ FusionMux Pro ================"
    echo "Quantum UDP primary + WebSocket/WSS standby + TCP fallback"
    echo "1) Create Iran FusionMux + generate V2F1 setup code"
    echo "2) Create outside FusionMux from V2F1 setup code"
    echo "3) List all V2Quantum instances"
    echo "4) Status/health of one instance"
    echo "5) Follow one tunnel log"
    echo "6) Restart one tunnel"
    echo "7) Delete one instance completely"
    echo "0) Return"
    choice="$(prompt_default "Choice" "1")"
    case "${choice,,}" in
      1|iran|server) configure_fusion_server || warn "FusionMux Iran setup was not completed." ;;
      2|outside|client|kharej) configure_fusion_client || warn "FusionMux outside setup was not completed." ;;
      3|list) list_instances ;;
      4|status) show_status ;;
      5|logs)
        instance="$(pick_instance)" || continue
        safe_instance "$instance" || { error "Invalid instance."; continue; }
        "$JOURNALCTL" -fu "v2quantum@$instance.service"
        ;;
      6|restart)
        instance="$(pick_instance)" || continue
        safe_instance "$instance" || { error "Invalid instance."; continue; }
        "$SYSTEMCTL" restart "v2quantum@$instance.service"
        ;;
      7|delete|remove) delete_instance ;;
      0|back|q|quit|exit) return 0 ;;
      *) error "Unknown choice." ;;
    esac
  done
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
    echo "0) Return"
    choice="$(prompt_default "Choice" "1")"
    case "${choice,,}" in
      1|iran|server) configure_tun_server || warn "TUN server setup was not completed." ;;
      2|outside|client|kharej) configure_tun_client || warn "TUN client setup was not completed." ;;
      3|list) list_instances ;;
      4|status) show_status ;;
      5|delete|remove) delete_instance ;;
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
  v2quantum-manager --fusion Open only the FusionMux Pro manager
  v2quantum-manager --tun    Open only the independent L3 TUN manager
  v2quantum-manager --list   List configured instances
EOF
}

case "${1:-}" in
  --fusion) fusion_menu; exit 0 ;;
  --tun) tun_menu; exit 0 ;;
  --list) list_instances; exit 0 ;;
  -h|--help) manager_usage; exit 0 ;;
  "") ;;
  *) error "Unknown option: $1"; manager_usage >&2; exit 2 ;;
esac

while true; do
  echo
  echo "================ V2Quantum Manager ================"
  echo "Recommended"
  echo "  F) FusionMux Pro - Quantum + WebSocket/WSS + TCP failover"
  echo "Reverse ports"
  echo "  1) Iran single-carrier server + V2Q3 setup code"
  echo "  2) Outside single-carrier server from V2Q setup code"
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
  choice="$(prompt_default "Choice" "F")"
  case "${choice,,}" in
    f|fusion|fusionmux) fusion_menu ;;
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
