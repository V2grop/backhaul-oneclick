#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Universal launcher only. Each tunnel engine keeps its own files and services.
SCRIPT_VERSION="1.2.0"
REPO="${TUNNEL_MANAGER_REPO:-V2grop/backhaul-oneclick}"
REF="${TUNNEL_MANAGER_REF:-main}"
RAW_BASE="${TUNNEL_MANAGER_RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${REF}}"

BACKHAUL_URL="${TUNNEL_MANAGER_BACKHAUL_URL:-${RAW_BASE}/oneclick-v3-en.sh}"
XWSMUX_MAX_PINNED_REF="${TUNNEL_MANAGER_XWSMUX_MAX_PINNED_REF:-db3b8b99eb966ddd2a8a77eee77e8c0abd157c94}"
XWSMUX_MAX_URL="${TUNNEL_MANAGER_XWSMUX_MAX_URL:-${RAW_BASE}/oneclick-xwsmux-max.sh}"
XWSMUX_MAX_FALLBACK_URL="${TUNNEL_MANAGER_XWSMUX_MAX_FALLBACK_URL:-https://raw.githubusercontent.com/${REPO}/${XWSMUX_MAX_PINNED_REF}/oneclick-xwsmux-max.sh}"
V2QUANTUM_URL="${TUNNEL_MANAGER_V2QUANTUM_URL:-${RAW_BASE}/v2quantum-oneclick.sh}"
XHTTP_CDN_URL="${TUNNEL_MANAGER_XHTTP_CDN_URL:-${RAW_BASE}/oneclick-xhttp-cdn.sh}"
REALM_URL="${TUNNEL_MANAGER_REALM_URL:-https://raw.githubusercontent.com/Sir-Adnan/Realm-Tunnel-Manager/main/realm.sh}"
SELF_URL="${TUNNEL_MANAGER_SELF_URL:-${RAW_BASE}/oneclick-universal.sh}"

CURL_BIN="${TUNNEL_MANAGER_CURL:-curl}"
SYSTEMCTL_BIN="${TUNNEL_MANAGER_SYSTEMCTL:-systemctl}"
SS_BIN="${TUNNEL_MANAGER_SS:-ss}"
SHORTCUT="${TUNNEL_MANAGER_SHORTCUT:-/usr/local/sbin/tunnel-manager}"
REALM_COMMAND="${TUNNEL_MANAGER_REALM_COMMAND:-/usr/local/bin/irealm}"
V2QUANTUM_MANAGER_COMMAND="${TUNNEL_MANAGER_V2QUANTUM_COMMAND:-/usr/local/sbin/v2quantum-manager}"
XHTTP_CDN_MANAGER_COMMAND="${TUNNEL_MANAGER_XHTTP_CDN_COMMAND:-/usr/local/sbin/xhttp-cdn-manager}"
SKIP_ROOT_CHECK="${TUNNEL_MANAGER_SKIP_ROOT_CHECK:-0}"
ASSUME_YES=false
ACTION="menu"
TMP_DIR=""

green=$'\033[0;32m'
yellow=$'\033[1;33m'
red=$'\033[0;31m'
cyan=$'\033[0;36m'
reset=$'\033[0m'

ok() { printf '%s[OK]%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$yellow" "$reset" "$*"; }
error() { printf '%s[ERROR]%s %s\n' "$red" "$reset" "$*" >&2; }

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/tunnel-manager.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Universal Tunnel Manager

Usage:
  tunnel-manager                     Open the unified menu
  tunnel-manager --backhaul          Backhaul: TCP/MUX/WS/TLS/TUN
  tunnel-manager --xwsmux-max        Optimized XWSMUX/Cloudflare profile
  tunnel-manager --v2quantum         Independent TCP/Quantum/Raw manager
  tunnel-manager --tun               Independent encrypted layer-3 TUN manager
  tunnel-manager --xhttp-cdn         Independent CDN XHTTP/Clean-IP manager
  tunnel-manager --realm             Realm TCP/UDP port forward manager
  tunnel-manager --status            Unified service diagnostics
  tunnel-manager --capabilities      Show engines and limitations
  tunnel-manager --install-shortcut  Install/update tunnel-manager command
  tunnel-manager --remove-shortcut   Remove only the launcher command

Global options:
  -y, --yes       Accept a safe launcher confirmation
  -h, --help      Show this help
  --version       Show launcher version

Environment overrides for forks/testing:
  TUNNEL_MANAGER_REPO=owner/repository
  TUNNEL_MANAGER_REF=branch-or-tag
EOF
}

capabilities() {
  cat <<'EOF'
================ Included tunnel managers ================

1) Backhaul (existing opaque core; kept unchanged)
   tcp, tcpmux, xtcpmux, ws, wss, wsmux, wssmux, xwsmux
   and anytls. Its unverified legacy TUN profile is not advertised here.

2) XWSMUX Max (existing optimized Backhaul profile)
   Cloudflare WebSocket mux, token authentication, watchdog,
   systemd recovery, TCP tuning, backup and automatic rollback.

3) V2Quantum (independent open-source Go core)
   tcp, quantum_udp and experimental raw_icmp carriers, encrypted
   multiplexing, automatic Iran setup code, reconnect, watchdog,
   health checks, assigned-IP ICMP scanning, and controlled manual
   Raw source/BIP fields. It also provides a separate working L3 TUN
   over TCP or Quantum UDP with V2T1 setup codes and per-tunnel devices.
   quantum_udp is the carrier; user mappings are currently TCP.

4) Realm Tunnel Manager (external open-source project)
   Optional direct layer-4 TCP/UDP port forwarding.

5) XHTTP CDN (independent official Xray core)
   Direct TCP port mappings from Iran through Cloudflare XHTTP. The client
   connects to a user-supplied clean Cloudflare IPv4 while TLS SNI and HTTP
   Host remain the proxied hostname. It supports automatic Let's Encrypt via
   a restricted Cloudflare DNS token, automatic self-signed origin TLS, or an
   existing certificate. It uses isolated files and services and never changes
   an existing Xray, X-UI, Backhaul or V2Quantum transport.

Pengu and Dagger licensed binaries are not bundled or required by this
launcher. Raw spoof/BIP works only when both the route and provider policy
permit it; the program cannot bypass provider anti-spoofing.
EOF
}

confirm() {
  local prompt="$1" answer
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  printf '%s [y/N]: ' "$prompt" >&2
  IFS= read -r answer
  answer="${answer,,}"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

require_root() {
  if [[ "$SKIP_ROOT_CHECK" != "1" && ${EUID:-$(id -u)} -ne 0 ]]; then
    error "Run as root: sudo -i"
    exit 1
  fi
}

validate_settings() {
  [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
    error "Invalid TUNNEL_MANAGER_REPO."
    exit 2
  }
  [[ "$REF" =~ ^[-A-Za-z0-9._/]+$ && "$REF" != /* && "$REF" != *..* ]] || {
    error "Invalid TUNNEL_MANAGER_REF."
    exit 2
  }
  command -v "$CURL_BIN" >/dev/null 2>&1 || {
    error "curl is required. Install curl and ca-certificates first."
    exit 1
  }
}

ensure_tmp_dir() {
  if [[ -z "$TMP_DIR" ]]; then
    TMP_DIR="$(mktemp -d -t tunnel-manager.XXXXXX)"
  fi
}

download_script() {
  local url="$1" label="$2" destination
  ensure_tmp_dir
  destination="$(mktemp "$TMP_DIR/${label}.XXXXXX.sh")"
  if ! "$CURL_BIN" -fsSL --ipv4 --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 300 -o "$destination" "$url"; then
    error "Could not download $label."
    return 1
  fi
  if ! bash -n "$destination"; then
    error "Downloaded $label failed the shell syntax check."
    return 1
  fi
  chmod 700 "$destination"
  printf '%s' "$destination"
}

run_plain_script() {
  local url="$1" label="$2" script
  shift 2
  script="$(download_script "$url" "$label")" || return 1
  bash "$script" "$@"
}

run_backhaul() {
  echo
  printf '%sBackhaul full manager%s\n' "$cyan" "$reset"
  echo "Layer-4 transports: tcp/tcpmux/xtcpmux/ws/wss/wsmux/wssmux/xwsmux/anytls"
  echo "The existing Backhaul core and working WSMUX services are preserved."
  echo
  run_plain_script "$BACKHAUL_URL" backhaul
}

run_xwsmux_max() {
  local script
  echo
  printf '%sXWSMUX Max manager%s\n' "$cyan" "$reset"
  echo "Dedicated low-jitter Cloudflare profile with token, watchdog and rollback."
  echo
  if script="$(download_script "$XWSMUX_MAX_URL" xwsmux-max)"; then
    bash "$script"
    return
  fi
  warn "Selected XWSMUX Max download failed; trying the last verified fallback."
  script="$(download_script "$XWSMUX_MAX_FALLBACK_URL" xwsmux-max-fallback)" || return 1
  bash "$script"
}

run_xhttp_cdn() {
  local script
  echo
  printf '%sXHTTP CDN / Clean-IP manager%s\n' "$cyan" "$reset"
  echo "Independent Xray core, configs and services; existing transports are preserved."
  echo
  if [[ -x "$XHTTP_CDN_MANAGER_COMMAND" ]]; then
    "$XHTTP_CDN_MANAGER_COMMAND"
    return
  fi
  script="$(download_script "$XHTTP_CDN_URL" xhttp-cdn)" || return 1
  env \
    XHTTP_CDN_REPO="$REPO" \
    XHTTP_CDN_REF="$REF" \
    XHTTP_CDN_SELF_URL="$XHTTP_CDN_URL" \
    bash "$script"
}

backhaul_menu() {
  local choice
  while true; do
    clear 2>/dev/null || true
    echo "===================================================="
    echo "                  Backhaul family"
    echo "===================================================="
    echo "1) Standard Backhaul - layer-4 transports"
    echo "2) XWSMUX Max - optimized Cloudflare profile"
    echo "3) V2TUN - independent encrypted layer-3 tunnel"
    echo "0) Return to universal menu"
    echo
    IFS= read -r -p "Choose [0-3]: " choice
    case "${choice,,}" in
      1|standard|backhaul) run_backhaul || warn "Backhaul manager exited with an error."; pause_menu ;;
      2|xwsmux|max) run_xwsmux_max || warn "XWSMUX Max manager exited with an error."; pause_menu ;;
      3|tun|v2tun) run_v2tun || warn "V2TUN manager exited with an error."; pause_menu ;;
      0|back|return|q|quit) return 0 ;;
      *) warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

run_v2quantum() {
  local manager_mode="${1:-all}"
  echo
  if [[ "$manager_mode" == "tun" ]]; then
    printf '%sV2TUN independent layer-3 manager%s\n' "$cyan" "$reset"
    echo "Encrypted point-to-point TUN over TCP or Quantum UDP."
  else
    printf '%sV2Quantum independent manager%s\n' "$cyan" "$reset"
    echo "Modes: TCP, Quantum UDP carrier, and experimental Raw ICMP spoof/BIP."
  fi
  echo "This engine has no Pengu/Dagger/Backhaul license dependency."
  echo
  if [[ -x "$V2QUANTUM_MANAGER_COMMAND" ]]; then
    if [[ "$manager_mode" == "tun" ]]; then
      "$V2QUANTUM_MANAGER_COMMAND" --tun
    else
      "$V2QUANTUM_MANAGER_COMMAND"
    fi
    return
  fi

  local script allow_source
  script="$(download_script "$V2QUANTUM_URL" v2quantum)" || return 1
  allow_source="${V2QUANTUM_ALLOW_SOURCE_BUILD:-0}"
  if [[ "$REF" != "main" && -z "${V2QUANTUM_ALLOW_SOURCE_BUILD+x}" ]]; then
    # A PR branch has no release asset yet; verified temporary source build is expected.
    allow_source=1
  fi
  env \
    V2QUANTUM_REPO="$REPO" \
    V2QUANTUM_REF="$REF" \
    V2QUANTUM_ALLOW_SOURCE_BUILD="$allow_source" \
    V2QUANTUM_MANAGER_MODE="$manager_mode" \
    bash "$script"
}

run_v2tun() {
  run_v2quantum tun
}

run_realm() {
  echo
  printf '%sRealm TCP/UDP Port Forward%s\n' "$cyan" "$reset"
  if [[ -x "$REALM_COMMAND" ]]; then
    "$REALM_COMMAND"
    return
  fi
  echo "Realm is an optional external open-source manager from Sir-Adnan."
  confirm "Download and open the official Realm installer?" || {
    echo "Cancelled."
    return 0
  }
  run_plain_script "$REALM_URL" realm
}

show_status() {
  echo "================ Tunnel services ================"
  if command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
    "$SYSTEMCTL_BIN" list-units --all --type=service --no-legend --no-pager \
      'backhaul-*.service' 'v2quantum@*.service' 'xhttp-cdn-*.service' 'realm.service' 2>/dev/null || true
    "$SYSTEMCTL_BIN" list-units --all --type=timer --no-legend --no-pager \
      'backhaul-*.timer' 'v2quantum-watchdog@*.timer' 2>/dev/null || true
  else
    warn "systemctl is unavailable."
  fi

  echo
  echo "================ Installed engines ================"
  [[ -x /root/backhaul-core/backhaul_premium ]] \
    && /root/backhaul-core/backhaul_premium -v 2>/dev/null \
    || echo "Backhaul: not installed"
  [[ -x /usr/local/bin/v2quantum ]] \
    && /usr/local/bin/v2quantum version 2>/dev/null \
    || echo "V2Quantum: not installed"
  [[ -x /opt/xhttp-cdn/bin/xray ]] \
    && /opt/xhttp-cdn/bin/xray version 2>/dev/null | head -n1 \
    || echo "XHTTP CDN isolated Xray: not installed"
  [[ -x /usr/local/bin/realm ]] \
    && /usr/local/bin/realm --version 2>/dev/null \
    || echo "Realm: not installed"

  echo
  echo "================ Tunnel listeners ================"
  if command -v "$SS_BIN" >/dev/null 2>&1; then
    "$SS_BIN" -H -lntup 2>/dev/null \
      | grep -Ei 'backhaul|v2quantum|realm' \
      || echo "No process-tagged tunnel listener was found."
  else
    warn "ss is unavailable; install iproute2 for listener diagnostics."
  fi
}

install_shortcut() {
  local script
  script="$(download_script "$SELF_URL" universal)" || return 1
  install -Dm755 "$script" "$SHORTCUT"
  ok "Launcher installed: $SHORTCUT"
  echo "Next time run: tunnel-manager"
}

remove_shortcut() {
  if [[ ! -e "$SHORTCUT" ]]; then
    warn "Launcher shortcut is not installed at $SHORTCUT."
    return 0
  fi
  confirm "Remove only the universal launcher shortcut?" || {
    echo "Cancelled."
    return 0
  }
  rm -f -- "$SHORTCUT"
  ok "Launcher shortcut removed. No tunnel, config or core was deleted."
}

pause_menu() {
  echo
  IFS= read -r -p "Press Enter to return to the universal menu..." _
}

menu() {
  local choice
  while true; do
    clear 2>/dev/null || true
    echo "===================================================="
    echo "        Universal Tunnel Manager v$SCRIPT_VERSION"
    echo "===================================================="
    echo "1) Backhaul family - Standard / XWSMUX Max / TUN"
    echo "2) V2Quantum - TCP / Quantum / Raw spoof-BIP"
    echo "3) Realm - TCP/UDP port forwarding"
    echo "4) Unified status and diagnostics"
    echo "5) Install/update tunnel-manager shortcut"
    echo "6) Remove only the launcher shortcut"
    echo "7) Capabilities and important limitations"
    echo "8) XHTTP CDN - independent Clean-IP direct forwarder"
    echo "0) Exit"
    echo
    IFS= read -r -p "Choose [0-8]: " choice
    case "${choice,,}" in
      1|backhaul) backhaul_menu ;;
      2|v2quantum|quantum) run_v2quantum || warn "V2Quantum manager exited with an error."; pause_menu ;;
      3|realm|forward) run_realm || warn "Realm manager exited with an error."; pause_menu ;;
      4|status|diag) show_status; pause_menu ;;
      5|install|update) install_shortcut; pause_menu ;;
      6|remove|uninstall) remove_shortcut; pause_menu ;;
      7|info|capabilities) capabilities; pause_menu ;;
      8|xhttp|xhttp-cdn|cdn) run_xhttp_cdn || warn "XHTTP CDN manager exited with an error."; pause_menu ;;
      0|q|quit|exit) exit 0 ;;
      *) warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

while (( $# > 0 )); do
  case "$1" in
    --backhaul) ACTION="backhaul" ;;
    --xwsmux-max) ACTION="xwsmux-max" ;;
    --v2quantum) ACTION="v2quantum" ;;
    --tun) ACTION="tun" ;;
    --xhttp-cdn) ACTION="xhttp-cdn" ;;
    --realm) ACTION="realm" ;;
    --status) ACTION="status" ;;
    --capabilities) ACTION="capabilities" ;;
    --install-shortcut) ACTION="install-shortcut" ;;
    --remove-shortcut) ACTION="remove-shortcut" ;;
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "tunnel-manager $SCRIPT_VERSION"; exit 0 ;;
    *) error "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

require_root
validate_settings
case "$ACTION" in
  menu) menu ;;
  backhaul) run_backhaul ;;
  xwsmux-max) run_xwsmux_max ;;
  v2quantum) run_v2quantum ;;
  tun) run_v2tun ;;
  xhttp-cdn) run_xhttp_cdn ;;
  realm) run_realm ;;
  status) show_status ;;
  capabilities) capabilities ;;
  install-shortcut) install_shortcut ;;
  remove-shortcut) remove_shortcut ;;
esac
