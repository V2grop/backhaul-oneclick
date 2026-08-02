#!/usr/bin/env bash
set -Eeuo pipefail

BIN="${V2QUANTUM_BIN:-/usr/local/bin/v2quantum}"
CONFIG_DIR="${V2QUANTUM_CONFIG_DIR:-/etc/v2quantum}"
SYSTEMCTL="${V2QUANTUM_SYSTEMCTL:-systemctl}"
JOURNALCTL="${V2QUANTUM_JOURNALCTL:-journalctl}"

if (( EUID != 0 )); then
  echo "Run v2quantum-manager as root." >&2
  exit 1
fi
if [[ ! -x "$BIN" ]]; then
  echo "V2Quantum is not installed at $BIN." >&2
  exit 1
fi
install -d -m750 "$CONFIG_DIR"

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
reset='\033[0m'

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
  [[ -n "$1" && "$1" != *'"'* && "$1" != *'\'* && ! "$1" =~ [[:space:]] ]]
}

safe_instance() {
  [[ "$1" =~ ^[-A-Za-z0-9._]+$ ]]
}

select_mode() {
  local choice
  echo "1) TCP       - stable production default" >&2
  echo "2) Quantum   - reliable multiplexed UDP" >&2
  echo "3) Raw ICMP  - experimental spoof/BIP carrier" >&2
  choice="$(prompt_default "Carrier" "2")"
  case "${choice,,}" in
    1|tcp) printf 'tcp' ;;
    2|quantum|udp|quantum_udp) printf 'quantum_udp' ;;
    3|raw|icmp|raw_icmp) printf 'raw_icmp' ;;
    *) echo "Unknown carrier." >&2; return 1 ;;
  esac
}

read_token() {
  local role="$1" token
  if [[ "$role" == "server" ]]; then
    token="$($BIN keygen)"
  else
    printf 'Paste the token generated on the Iran server: ' >&2
    IFS= read -r token
  fi
  if [[ ! "$token" =~ ^[A-Za-z0-9_-]{43,512}$ ]]; then
    echo "Invalid token format." >&2
    return 1
  fi
  printf '%s' "$token"
}

raw_block() {
  local local_ip peer_ip iface identifier mtu spoof_source spoof_destination allow=false
  local_ip="$(prompt_default "This server public IPv4" "192.0.2.10")"
  peer_ip="$(prompt_default "Peer public IPv4" "198.51.100.20")"
  iface="$(prompt_default "Network interface" "eth0")"
  identifier="$(prompt_default "Shared ICMP identifier (same on both)" "22066")"
  mtu="$(prompt_default "Raw payload MTU" "1200")"
  spoof_source="$(prompt_default "Optional routed spoof source IPv4 (- disables)" "-")"
  spoof_destination="$(prompt_default "Optional peer BIP/spoof destination IPv4 (- disables)" "-")"
  [[ "$spoof_source" == "-" ]] && spoof_source=""
  [[ "$spoof_destination" == "-" ]] && spoof_destination=""
  for value in "$local_ip" "$peer_ip" "$iface" "$identifier" "$mtu"; do
    safe_value "$value" || { echo "Unsafe input: $value" >&2; return 1; }
  done
  if [[ -n "$spoof_source" && "$spoof_source" != "$local_ip" ]]; then
    printf '%b' "${yellow}Only use an address routed to this host and authorized by your provider.${reset}\n" >&2
    confirm "Enable unrouted-source override?" || return 1
    allow=true
  fi
  printf '%s\n' \
    '    "raw": {' \
    "      \"local_ip\": \"$local_ip\"," \
    "      \"peer_ip\": \"$peer_ip\"," \
    "      \"interface\": \"$iface\"," \
    "      \"spoof_source_ip\": \"$spoof_source\"," \
    "      \"spoof_destination_ip\": \"$spoof_destination\"," \
    "      \"allow_unrouted_spoof\": $allow," \
    "      \"icmp_identifier\": $identifier," \
    "      \"payload_mtu\": $mtu," \
    '      "experimental_enabled": true' \
    '    }'
}

write_config() {
  local role="$1" instance="$2" mode="$3" token="$4"
  local mapping carrier_endpoint pool=4 carrier_json mapping_json config_file env_file
  config_file="$CONFIG_DIR/$instance.json"
  env_file="$CONFIG_DIR/$instance.env"

  if [[ "$role" == "server" ]]; then
    mapping="$(prompt_default "Public forwarded TCP port" "0.0.0.0:2444")"
    mapping_json="      \"listen\": \"$mapping\""
  else
    mapping="$(prompt_default "Outside local target" "127.0.0.1:2444")"
    mapping_json="      \"target\": \"$mapping\""
  fi
  safe_value "$mapping" || { echo "Unsafe mapping value." >&2; return 1; }

  case "$mode" in
    tcp|quantum_udp)
      if [[ "$role" == "server" ]]; then
        carrier_endpoint="$(prompt_default "Carrier listen address" "0.0.0.0:8880")"
        carrier_json="    \"listen\": \"$carrier_endpoint\","
      else
        carrier_endpoint="$(prompt_default "Iran carrier address" "IRAN_IP:8880")"
        carrier_json="    \"server\": \"$carrier_endpoint\","
      fi
      safe_value "$carrier_endpoint" || { echo "Unsafe carrier endpoint." >&2; return 1; }
      ;;
    raw_icmp)
      pool=1
      carrier_json="$(raw_block),"
      ;;
  esac

  install -m600 /dev/null "$env_file"
  printf 'V2QUANTUM_PSK=%s\n' "$token" >"$env_file"
  install -m640 /dev/null "$config_file"
  {
    printf '%s\n' '{'
    printf '  "version": 1,\n'
    printf '  "role": "%s",\n' "$role"
    printf '  "node_name": "%s",\n' "$instance"
    printf '  "carrier": {\n'
    printf '    "mode": "%s",\n' "$mode"
    printf '%s\n' "$carrier_json"
    printf '    "pool": %s,\n' "$pool"
    printf '    "keepalive_seconds": 10,\n'
    printf '    "dial_timeout_seconds": 8,\n'
    printf '    "reconnect_min_millis": 500,\n'
    printf '    "reconnect_max_millis": 15000,\n'
    printf '    "max_streams_per_session": 512\n'
    printf '  },\n'
    printf '  "security": {"psk_env": "V2QUANTUM_PSK"},\n'
    printf '  "mappings": [{\n'
    printf '      "name": "vless",\n'
    printf '      "protocol": "tcp",\n'
    printf '%s\n' "$mapping_json"
    printf '  }],\n'
    printf '  "health": {"listen": "127.0.0.1:9090", "allow_public_listen": false},\n'
    printf '  "logging": {"level": "info", "json": false}\n'
    printf '%s\n' '}'
  } >"$config_file"

  if ! V2QUANTUM_PSK="$token" "$BIN" check -config "$config_file"; then
    printf '%b' "${red}Configuration check failed; service was not changed.${reset}\n" >&2
    return 1
  fi
  "$SYSTEMCTL" enable --now "v2quantum@$instance.service"
  "$SYSTEMCTL" restart "v2quantum@$instance.service"
  printf '%b' "${green}v2quantum@$instance is installed and running.${reset}\n"
  if [[ "$role" == "server" ]]; then
    echo
    printf '%b' "${yellow}COPY THIS TOKEN TO THE OUTSIDE SERVER:${reset}\n"
    printf '%s\n' "$token"
  fi
}

configure_role() {
  local role="$1" instance mode token
  if [[ "$role" == "server" ]]; then
    instance="iran"
  else
    instance="outside"
  fi
  mode="$(select_mode)"
  token="$(read_token "$role")"
  write_config "$role" "$instance" "$mode" "$token"
}

pick_instance() {
  prompt_default "Instance name" "iran"
}

show_status() {
  local instance
  instance="$(pick_instance)"
  "$SYSTEMCTL" --no-pager --full status "v2quantum@$instance.service" || true
  if command -v curl >/dev/null 2>&1; then
    curl -fsS http://127.0.0.1:9090/healthz || true
    echo
  fi
}

delete_instance() {
  local instance
  instance="$(pick_instance)"
  safe_instance "$instance" || { echo "Unsafe instance name." >&2; return 1; }
  confirm "Delete tunnel instance $instance?" || { echo "Cancelled."; return; }
  "$SYSTEMCTL" disable --now "v2quantum@$instance.service" 2>/dev/null || true
  rm -f -- "$CONFIG_DIR/$instance.json" "$CONFIG_DIR/$instance.env"
  echo "Deleted instance $instance. The V2Quantum binary was kept."
}

while true; do
  echo
  echo "========== V2Quantum Manager =========="
  echo "1) Configure Iran server (auto-generate token)"
  echo "2) Configure outside client (paste token)"
  echo "3) Status and health"
  echo "4) Follow logs"
  echo "5) Restart instance"
  echo "6) Raw spoof preflight"
  echo "7) Delete instance"
  echo "0) Exit"
  choice="$(prompt_default "Choice" "1")"
  case "${choice,,}" in
    1|iran|server) configure_role server ;;
    2|outside|client|kharej) configure_role client ;;
    3|status) show_status ;;
    4|logs)
      instance="$(pick_instance)"
      "$JOURNALCTL" -fu "v2quantum@$instance.service"
      ;;
    5|restart)
      instance="$(pick_instance)"
      "$SYSTEMCTL" restart "v2quantum@$instance.service"
      ;;
    6|spoof|preflight)
      instance="$(pick_instance)"
      "$BIN" spoof-check -config "$CONFIG_DIR/$instance.json"
      ;;
    7|delete|remove|uninstall) delete_instance ;;
    0|q|quit|exit) exit 0 ;;
    *) echo "Unknown choice." >&2 ;;
  esac
done
