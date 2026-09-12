#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${V2QUANTUM_CONFIG_DIR:-/etc/v2quantum}"
IPTABLES="${V2QUANTUM_IPTABLES:-iptables}"
IP="${V2QUANTUM_IP:-ip}"
SYSCTL="${V2QUANTUM_SYSCTL:-sysctl}"

usage() {
  echo "Usage: v2quantum-portmap apply|remove INSTANCE" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
ACTION="$1"
INSTANCE="$2"
[[ "$ACTION" == "apply" || "$ACTION" == "remove" ]] || usage
[[ "$INSTANCE" =~ ^[-A-Za-z0-9._]+$ && ${#INSTANCE} -le 64 ]] || {
  echo "Invalid V2Quantum instance name." >&2
  exit 2
}

CONFIG="$CONFIG_DIR/$INSTANCE.portmap"
[[ -r "$CONFIG" ]] || {
  echo "Port-forward configuration not found: $CONFIG" >&2
  exit 1
}

VERSION=""
DEVICE=""
LOCAL_IP=""
PEER_IP=""
PUBLIC_INTERFACE=""
MAPS=()

while IFS='=' read -r key value; do
  [[ -n "$key" && "$key" != \#* ]] || continue
  case "$key" in
    VERSION) VERSION="$value" ;;
    DEVICE) DEVICE="$value" ;;
    LOCAL_IP) LOCAL_IP="$value" ;;
    PEER_IP) PEER_IP="$value" ;;
    PUBLIC_INTERFACE) PUBLIC_INTERFACE="$value" ;;
    MAP) MAPS+=("$value") ;;
    *)
      echo "Unknown key in $CONFIG: $key" >&2
      exit 1
      ;;
  esac
done <"$CONFIG"

valid_ipv4() {
  local address="$1" part
  local parts=()
  [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a parts <<<"$address"
  for part in "${parts[@]}"; do
    (( 10#$part >= 0 && 10#$part <= 255 )) || return 1
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

[[ "$VERSION" == "1" ]] || { echo "Unsupported port-forward config version." >&2; exit 1; }
[[ "$DEVICE" =~ ^[-A-Za-z0-9._]{1,15}$ ]] || { echo "Invalid TUN device." >&2; exit 1; }
[[ "$PUBLIC_INTERFACE" =~ ^[-A-Za-z0-9._:]{1,32}$ ]] || { echo "Invalid public interface." >&2; exit 1; }
valid_ipv4 "$LOCAL_IP" || { echo "Invalid local TUN IPv4." >&2; exit 1; }
valid_ipv4 "$PEER_IP" || { echo "Invalid peer TUN IPv4." >&2; exit 1; }
(( ${#MAPS[@]} > 0 && ${#MAPS[@]} <= 32 )) || { echo "No valid TCP port forward is configured." >&2; exit 1; }

declare -A SEEN_PORTS=()
for mapping in "${MAPS[@]}"; do
  [[ "$mapping" =~ ^([0-9]+)=([0-9]+)$ ]] || { echo "Invalid port mapping: $mapping" >&2; exit 1; }
  public_port="${BASH_REMATCH[1]}"
  target_port="${BASH_REMATCH[2]}"
  valid_port "$public_port" && valid_port "$target_port" || { echo "Invalid port mapping: $mapping" >&2; exit 1; }
  [[ -z "${SEEN_PORTS[$public_port]:-}" ]] || { echo "Duplicate Iran TCP port: $public_port" >&2; exit 1; }
  SEEN_PORTS[$public_port]=1
done

add_rule() {
  local table="$1" chain="$2"
  shift 2
  if ! "$IPTABLES" -w 5 -t "$table" -C "$chain" "$@" 2>/dev/null; then
    "$IPTABLES" -w 5 -t "$table" -I "$chain" 1 "$@"
  fi
}

remove_rule() {
  local table="$1" chain="$2"
  shift 2
  while "$IPTABLES" -w 5 -t "$table" -C "$chain" "$@" 2>/dev/null; do
    "$IPTABLES" -w 5 -t "$table" -D "$chain" "$@" || break
  done
}

apply_mapping() {
  local public_port="$1" target_port="$2" tag="v2q:$INSTANCE:$public_port:$target_port"
  add_rule nat PREROUTING \
    -i "$PUBLIC_INTERFACE" -p tcp --dport "$public_port" \
    -m comment --comment "$tag:dnat" \
    -j DNAT --to-destination "$PEER_IP:$target_port"
  add_rule nat POSTROUTING \
    -o "$DEVICE" -p tcp -d "$PEER_IP" --dport "$target_port" \
    -m comment --comment "$tag:snat" \
    -j SNAT --to-source "$LOCAL_IP"
  add_rule filter FORWARD \
    -i "$PUBLIC_INTERFACE" -o "$DEVICE" -p tcp -d "$PEER_IP" --dport "$target_port" \
    -m conntrack --ctstate NEW,ESTABLISHED \
    -m comment --comment "$tag:forward" -j ACCEPT
  add_rule filter FORWARD \
    -i "$DEVICE" -o "$PUBLIC_INTERFACE" -p tcp -s "$PEER_IP" --sport "$target_port" \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -m comment --comment "$tag:return" -j ACCEPT
  add_rule mangle FORWARD \
    -i "$PUBLIC_INTERFACE" -o "$DEVICE" -p tcp -d "$PEER_IP" --dport "$target_port" \
    --tcp-flags SYN,RST SYN \
    -m comment --comment "$tag:mss" -j TCPMSS --clamp-mss-to-pmtu
}

remove_mapping() {
  local public_port="$1" target_port="$2" tag="v2q:$INSTANCE:$public_port:$target_port"
  remove_rule mangle FORWARD \
    -i "$PUBLIC_INTERFACE" -o "$DEVICE" -p tcp -d "$PEER_IP" --dport "$target_port" \
    --tcp-flags SYN,RST SYN \
    -m comment --comment "$tag:mss" -j TCPMSS --clamp-mss-to-pmtu
  remove_rule filter FORWARD \
    -i "$DEVICE" -o "$PUBLIC_INTERFACE" -p tcp -s "$PEER_IP" --sport "$target_port" \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -m comment --comment "$tag:return" -j ACCEPT
  remove_rule filter FORWARD \
    -i "$PUBLIC_INTERFACE" -o "$DEVICE" -p tcp -d "$PEER_IP" --dport "$target_port" \
    -m conntrack --ctstate NEW,ESTABLISHED \
    -m comment --comment "$tag:forward" -j ACCEPT
  remove_rule nat POSTROUTING \
    -o "$DEVICE" -p tcp -d "$PEER_IP" --dport "$target_port" \
    -m comment --comment "$tag:snat" \
    -j SNAT --to-source "$LOCAL_IP"
  remove_rule nat PREROUTING \
    -i "$PUBLIC_INTERFACE" -p tcp --dport "$public_port" \
    -m comment --comment "$tag:dnat" \
    -j DNAT --to-destination "$PEER_IP:$target_port"
}

rollback_apply() {
  local status=$? mapping public_port target_port
  trap - ERR
  set +e
  for mapping in "${MAPS[@]}"; do
    public_port="${mapping%%=*}"
    target_port="${mapping#*=}"
    remove_mapping "$public_port" "$target_port"
  done
  exit "$status"
}

if [[ "$ACTION" == "apply" ]]; then
  trap rollback_apply ERR
  for _ in {1..50}; do
    "$IP" link show dev "$DEVICE" >/dev/null 2>&1 && break
    sleep 0.2
  done
  "$IP" link show dev "$DEVICE" >/dev/null 2>&1 || {
    echo "TUN device $DEVICE did not become ready." >&2
    exit 1
  }
  "$SYSCTL" -q -w net.ipv4.ip_forward=1
fi

for mapping in "${MAPS[@]}"; do
  public_port="${mapping%%=*}"
  target_port="${mapping#*=}"
  if [[ "$ACTION" == "apply" ]]; then
    apply_mapping "$public_port" "$target_port"
  else
    remove_mapping "$public_port" "$target_port"
  fi
done

trap - ERR
