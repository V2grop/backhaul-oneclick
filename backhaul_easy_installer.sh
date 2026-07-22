#!/usr/bin/env bash
set -Eeuo pipefail

# Backhaul Easy Installer
# Compatible with the flat TOML schema used by backhaul_premium:
#   Iran  -> [server]
#   Kharej -> [client]

BASE_DIR="/root/backhaul-core"
BIN="$BASE_DIR/backhaul_premium"
DEFAULT_POOL=8
DEFAULT_KEEPALIVE=40
DEFAULT_HEARTBEAT=10
DEFAULT_CHANNEL_SIZE=2048
DEFAULT_FRAME_SIZE=32768
DEFAULT_RECV_BUFFER=4194304
DEFAULT_STREAM_BUFFER=65536
DEFAULT_TRANSPORT="wsmux"

C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'

info() { echo -e "${C_CYAN}[i]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
die()  { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Backhaul Easy Installer

Interactive:
  bash backhaul_easy_installer.sh

One-command server (Iran):
  bash backhaul_easy_installer.sh install server \
    --tunnel-port 2095 --ports 2444 --pool 8

Port mapping example (Iran 2444 -> Kharej 443):
  bash backhaul_easy_installer.sh install server \
    --tunnel-port 2095 --ports '2444=443' --pool 8

One-command client (Kharej):
  bash backhaul_easy_installer.sh install client \
    --tunnel-port 2095 --remote vip.bpini.de:2095 --pool 8

Optional Cloudflare Edge IP on client:
  bash backhaul_easy_installer.sh install client \
    --tunnel-port 2095 --remote vip.bpini.de:2095 \
    --edge 1.1.1.1 --pool 8

Optional token (omit --token for no token):
  --token 'YOUR_TOKEN'

Status / logs / remove:
  bash backhaul_easy_installer.sh status server 2095
  bash backhaul_easy_installer.sh status client 2095
  bash backhaul_easy_installer.sh logs client 2095
  bash backhaul_easy_installer.sh remove client 2095
USAGE
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "این اسکریپت باید با root اجرا شود: sudo -i"
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || die "پورت نامعتبر است: $p"
  (( p >= 1 && p <= 65535 )) || die "پورت باید بین 1 تا 65535 باشد: $p"
}

ensure_binary() {
  mkdir -p "$BASE_DIR"
  [[ -f "$BIN" ]] || die "فایل هسته پیدا نشد: $BIN\nابتدا backhaul_premium را داخل $BASE_DIR قرار بده."
  chown root:root "$BIN"
  chmod 700 "$BIN"
  [[ -x "$BIN" ]] || die "هسته قابل اجرا نیست: $BIN"
  ok "مجوز اجرای هسته صحیح است."
}

role_names() {
  local role="$1" port="$2"
  case "$role" in
    server)
      CONFIG="$BASE_DIR/iran${port}.toml"
      SERVICE="backhaul-iran${port}"
      DESCRIPTION="Backhaul Iran Port ${port}"
      ;;
    client)
      CONFIG="$BASE_DIR/kharej${port}.toml"
      SERVICE="backhaul-kharej${port}"
      DESCRIPTION="Backhaul Kharej Port ${port}"
      ;;
    *) die "Role باید server یا client باشد." ;;
  esac
  UNIT="/etc/systemd/system/${SERVICE}.service"
}

backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "${f}.bak-${ts}"
    info "بکاپ ساخته شد: ${f}.bak-${ts}"
  fi
}

normalize_ports() {
  local raw="$1"
  raw="${raw// /}"
  [[ -n "$raw" ]] || die "حداقل یک پورت انتقالی لازم است."
  IFS=',' read -r -a PORT_ITEMS <<< "$raw"
  local item left right
  for item in "${PORT_ITEMS[@]}"; do
    [[ -n "$item" ]] || die "لیست پورت‌ها نامعتبر است."
    if [[ "$item" == *"="* ]]; then
      left="${item%%=*}"
      right="${item##*=}"
      validate_port "$left"
      validate_port "$right"
    else
      validate_port "$item"
    fi
  done
}

write_server_config() {
  local port="$1" ports="$2" pool="$3" token="$4" stream_buffer="$5"
  normalize_ports "$ports"

  {
    echo '[server]'
    echo "bind_addr = \"0.0.0.0:${port}\""
    echo "transport = \"${DEFAULT_TRANSPORT}\""
    [[ -n "$token" ]] && echo "token = \"${token}\""
    echo "keepalive_period = ${DEFAULT_KEEPALIVE}"
    echo 'nodelay = true'
    echo "heartbeat = ${DEFAULT_HEARTBEAT}"
    echo "channel_size = ${DEFAULT_CHANNEL_SIZE}"
    echo "mux_con = ${pool}"
    echo 'mux_version = 2'
    echo "mux_framesize = ${DEFAULT_FRAME_SIZE}"
    echo "mux_recievebuffer = ${DEFAULT_RECV_BUFFER}"
    echo "mux_streambuffer = ${stream_buffer}"
    echo 'log_level = "info"'
    echo
    echo 'ports = ['
    local item
    for item in "${PORT_ITEMS[@]}"; do
      echo "  \"${item}\","
    done
    echo ']'
  } > "$CONFIG"
}

write_client_config() {
  local port="$1" remote="$2" edge="$3" pool="$4" token="$5" stream_buffer="$6"
  [[ -n "$remote" ]] || die "آدرس ایران برای client لازم است."
  if [[ "$remote" != *:* ]]; then
    remote="${remote}:${port}"
  fi

  {
    echo '[client]'
    echo "remote_addr = \"${remote}\""
    [[ -n "$edge" ]] && echo "edge_ip = \"${edge}\""
    echo "transport = \"${DEFAULT_TRANSPORT}\""
    [[ -n "$token" ]] && echo "token = \"${token}\""
    echo "connection_pool = ${pool}"
    echo "keepalive_period = ${DEFAULT_KEEPALIVE}"
    echo 'dial_timeout = 10'
    echo 'retry_interval = 3'
    echo 'nodelay = true'
    echo 'mux_version = 2'
    echo "mux_framesize = ${DEFAULT_FRAME_SIZE}"
    echo "mux_recievebuffer = ${DEFAULT_RECV_BUFFER}"
    echo "mux_streambuffer = ${stream_buffer}"
    echo 'log_level = "info"'
  } > "$CONFIG"
}

write_unit() {
  cat > "$UNIT" <<EOF_UNIT
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

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

print_result() {
  local role="$1" port="$2"
  echo
  ok "نصب/به‌روزرسانی کامل شد."
  echo "Config : $CONFIG"
  echo "Service: $SERVICE"
  echo "Role   : $role"
  echo "Tunnel : $port"
  echo
  systemctl --no-pager --full status "$SERVICE" || true
  echo
  info "آخرین لاگ‌ها:"
  journalctl -u "$SERVICE" -n 25 --no-pager -o cat || true
}

install_tunnel() {
  local role="$1"; shift
  local tunnel_port="" ports="" remote="" edge="" token=""
  local pool="$DEFAULT_POOL" stream_buffer="$DEFAULT_STREAM_BUFFER"

  while (($#)); do
    case "$1" in
      --tunnel-port) tunnel_port="${2:-}"; shift 2 ;;
      --ports) ports="${2:-}"; shift 2 ;;
      --remote) remote="${2:-}"; shift 2 ;;
      --edge) edge="${2:-}"; shift 2 ;;
      --token) token="${2:-}"; shift 2 ;;
      --pool) pool="${2:-}"; shift 2 ;;
      --stream-buffer) stream_buffer="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "گزینه ناشناخته: $1" ;;
    esac
  done

  validate_port "$tunnel_port"
  [[ "$pool" =~ ^[0-9]+$ ]] && (( pool >= 1 && pool <= 128 )) || die "Pool باید بین 1 تا 128 باشد."
  [[ "$stream_buffer" =~ ^[0-9]+$ ]] && (( stream_buffer >= 4096 )) || die "stream-buffer نامعتبر است."

  role_names "$role" "$tunnel_port"
  ensure_binary

  systemctl stop "$SERVICE" 2>/dev/null || true
  backup_if_exists "$CONFIG"
  backup_if_exists "$UNIT"

  case "$role" in
    server)
      [[ -n "$ports" ]] || die "برای server گزینه --ports لازم است. مثال: --ports 2444 یا --ports '2444=443'"
      write_server_config "$tunnel_port" "$ports" "$pool" "$token" "$stream_buffer"
      ;;
    client)
      [[ -n "$remote" ]] || die "برای client گزینه --remote لازم است. مثال: --remote vip.example.com:2095"
      write_client_config "$tunnel_port" "$remote" "$edge" "$pool" "$token" "$stream_buffer"
      ;;
  esac

  chmod 600 "$CONFIG"
  write_unit
  chmod 644 "$UNIT"

  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  systemctl reset-failed "$SERVICE" 2>/dev/null || true
  systemctl restart "$SERVICE"
  sleep 3

  if ! systemctl is-active --quiet "$SERVICE"; then
    warn "سرویس active نشد. لاگ خطا:"
    journalctl -u "$SERVICE" -n 60 --no-pager -o cat || true
    exit 1
  fi

  print_result "$role" "$tunnel_port"
}

interactive_install() {
  echo ""
  echo "=== Backhaul Easy Installer ==="
  echo "1) ایران / Server"
  echo "2) خارج / Client"
  read -r -p "انتخاب [1/2]: " choice

  local role tunnel_port ports remote edge token pool stream_buffer
  case "$choice" in
    1|server|SERVER) role="server" ;;
    2|client|CLIENT) role="client" ;;
    *) die "انتخاب نامعتبر است." ;;
  esac

  read -r -p "پورت تونل (مثلاً 2095): " tunnel_port
  read -r -p "Pool [${DEFAULT_POOL}]: " pool
  pool="${pool:-$DEFAULT_POOL}"
  read -r -p "Token (برای بدون توکن Enter): " token
  read -r -p "Stream buffer [${DEFAULT_STREAM_BUFFER}]: " stream_buffer
  stream_buffer="${stream_buffer:-$DEFAULT_STREAM_BUFFER}"

  if [[ "$role" == "server" ]]; then
    read -r -p "پورت‌های انتقالی (مثلاً 2444 یا 2444=443 یا 2444,8443=443): " ports
    install_tunnel server --tunnel-port "$tunnel_port" --ports "$ports" --pool "$pool" --token "$token" --stream-buffer "$stream_buffer"
  else
    read -r -p "آدرس ایران (IP/Domain یا IP/Domain:Port): " remote
    read -r -p "Edge IP/Domain اختیاری (برای رد شدن Enter): " edge
    install_tunnel client --tunnel-port "$tunnel_port" --remote "$remote" --edge "$edge" --pool "$pool" --token "$token" --stream-buffer "$stream_buffer"
  fi
}

service_action() {
  local action="$1" role="$2" port="$3"
  validate_port "$port"
  role_names "$role" "$port"
  case "$action" in
    status)
      systemctl --no-pager --full status "$SERVICE" || true
      ;;
    logs)
      journalctl -u "$SERVICE" -n 100 --no-pager -o cat
      ;;
    remove)
      systemctl disable --now "$SERVICE" 2>/dev/null || true
      rm -f "$UNIT"
      systemctl daemon-reload
      systemctl reset-failed "$SERVICE" 2>/dev/null || true
      ok "سرویس حذف شد. فایل کانفیگ برای بکاپ باقی ماند: $CONFIG"
      ;;
  esac
}

main() {
  require_root
  local command="${1:-}"
  case "$command" in
    "") interactive_install ;;
    install)
      [[ $# -ge 2 ]] || die "Role مشخص نشده است. server یا client"
      local role="$2"; shift 2
      install_tunnel "$role" "$@"
      ;;
    status|logs|remove)
      [[ $# -eq 3 ]] || die "فرمت صحیح: $0 $command server|client PORT"
      service_action "$command" "$2" "$3"
      ;;
    -h|--help|help) usage ;;
    *) die "دستور ناشناخته: $command. برای راهنما: $0 --help" ;;
  esac
}

main "$@"
