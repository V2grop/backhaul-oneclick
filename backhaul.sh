#!/usr/bin/env bash

# Backhaul v2 Manager
# Clean-room manager for backhaul_premium_v2.
# It does not contact or use the legacy licensing/download servers.

set -o pipefail
umask 077

SCRIPT_VERSION="2.1.0"
GITHUB_REPO="V2grop/backhaul-oneclick"
GITHUB_BRANCH="main"
CORE_ASSET="backhaul_premium_v2"
CORE_DIR="/root/backhaul-core"
CORE_BIN="${CORE_DIR}/${CORE_ASSET}"
SERVICE_DIR="/etc/systemd/system"
SERVICE_PREFIX="backhaul-v2"
CORE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/${CORE_ASSET}"
CERT_DIR="${CORE_DIR}/cert_files"
CERT_FILE="${CERT_DIR}/v2-cert.crt"
KEY_FILE="${CERT_DIR}/v2-cert.key"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()    { printf '%s[i]%s %s\n' "$CYAN" "$RESET" "$*"; }
ok()      { printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error()   { printf '%s[خطا]%s %s\n' "$RED" "$RESET" "$*" >&2; }

pause() {
    printf '\n'
    read -r -p "برای ادامه Enter را بزنید..." _
}

require_root() {
    if (( EUID != 0 )); then
        error "این منو باید با کاربر root اجرا شود."
        exit 1
    fi
}

require_commands() {
    local cmd missing=0
    for cmd in curl systemctl timeout awk sed grep mktemp install od; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "دستور لازم نصب نیست: $cmd"
            missing=1
        fi
    done
    (( missing == 0 )) || exit 1
}

ask() {
    local variable="$1"
    local label="$2"
    local default="${3-}"
    local answer

    if [[ -n "$default" ]]; then
        read -r -p "$label [$default]: " answer
        printf -v "$variable" '%s' "${answer:-$default}"
    else
        read -r -p "$label: " answer
        printf -v "$variable" '%s' "$answer"
    fi
}

ask_bool() {
    local variable="$1"
    local label="$2"
    local default="${3:-y}"
    local answer

    while true; do
        read -r -p "$label [y/n، پیش‌فرض: $default]: " answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) printf -v "$variable" '%s' "true"; return 0 ;;
            n|no)  printf -v "$variable" '%s' "false"; return 0 ;;
            *) error "فقط y یا n وارد کنید." ;;
        esac
    done
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

ask_port() {
    local variable="$1"
    local label="$2"
    local default="$3"
    local value

    while true; do
        ask value "$label" "$default"
        if valid_port "$value"; then
            printf -v "$variable" '%s' "$value"
            return 0
        fi
        error "پورت باید عددی بین 1 تا 65535 باشد."
    done
}

valid_endpoint() {
    local endpoint="$1"
    local port="${endpoint##*:}"

    valid_port "$port" || return 1
    [[ "$endpoint" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):[0-9]+$ ]]
}

ask_endpoint() {
    local variable="$1"
    local label="$2"
    local value

    while true; do
        ask value "$label"
        if valid_endpoint "$value"; then
            printf -v "$variable" '%s' "$value"
            return 0
        fi
        error "فرمت درست: IP:PORT یا DOMAIN:PORT یا [IPv6]:PORT"
    done
}

valid_bind() {
    local bind="$1"
    local port="${bind##*:}"

    if valid_port "$bind"; then
        return 0
    fi
    if [[ "$bind" =~ ^:[0-9]+$ ]]; then
        valid_port "${bind#:}"
        return
    fi
    valid_endpoint "$bind"
}

ask_bind() {
    local variable="$1"
    local value

    while true; do
        ask value "آدرس Bind یا پورت تونل" "8443"
        if valid_bind "$value"; then
            [[ "$value" =~ ^[0-9]+$ ]] && value=":$value"
            printf -v "$variable" '%s' "$value"
            return 0
        fi
        error "نمونه‌های معتبر: 8443 یا :8443 یا 0.0.0.0:8443"
    done
}

valid_cidr() {
    local cidr="$1"
    local ip mask a b c d

    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    ip="${cidr%/*}"
    mask="${cidr#*/}"
    IFS='.' read -r a b c d <<< "$ip"
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
    (( 10#$mask >= 1 && 10#$mask <= 32 ))
}

ask_cidr() {
    local variable="$1"
    local label="$2"
    local default="$3"
    local value

    while true; do
        ask value "$label" "$default"
        if valid_cidr "$value"; then
            printf -v "$variable" '%s' "$value"
            return 0
        fi
        error "CIDR معتبر وارد کنید؛ نمونه: 10.10.10.1/24"
    done
}

trim_spaces() {
    local value="$1"
    value="${value//[[:space:]]/}"
    printf '%s' "$value"
}

validate_mapping_item() {
    local item="$1"
    local first second target

    if [[ "$item" =~ ^([0-9]+)$ ]]; then
        valid_port "${BASH_REMATCH[1]}"
    elif [[ "$item" =~ ^([0-9]+)=([0-9]+)$ ]]; then
        valid_port "${BASH_REMATCH[1]}" && valid_port "${BASH_REMATCH[2]}"
    elif [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        first="${BASH_REMATCH[1]}"
        second="${BASH_REMATCH[2]}"
        valid_port "$first" && valid_port "$second" && (( 10#$first <= 10#$second ))
    elif [[ "$item" =~ ^([0-9]+)-([0-9]+):([0-9]+)$ ]]; then
        first="${BASH_REMATCH[1]}"
        second="${BASH_REMATCH[2]}"
        target="${BASH_REMATCH[3]}"
        valid_port "$first" && valid_port "$second" && valid_port "$target" &&
            (( 10#$first <= 10#$second ))
    else
        return 1
    fi
}

ask_port_mappings() {
    local variable="$1"
    local value item
    local -a items

    printf '%s\n' "${CYAN}فرمت‌ها:${RESET} 443 | 443=5000 | 443-600 | 443-600:5201"
    while true; do
        ask value "پورت‌ها با کاما جدا شوند؛ نمونه 443,2053=443"
        value="$(trim_spaces "$value")"
        [[ -n "$value" ]] || {
            error "حداقل یک پورت وارد کنید."
            continue
        }

        IFS=',' read -r -a items <<< "$value"
        for item in "${items[@]}"; do
            if ! validate_mapping_item "$item"; then
                error "نگاشت پورت نامعتبر است: $item"
                continue 2
            fi
        done

        printf -v "$variable" '%s' "$value"
        return 0
    done
}

toml_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    printf '%s' "$value"
}

core_version() {
    if [[ -x "$CORE_BIN" ]]; then
        "$CORE_BIN" -v 2>/dev/null || printf 'نامشخص'
    else
        printf 'نصب نیست'
    fi
}

download_core() {
    local restart_services="${1:-false}"
    local tmp magic version stamp service
    local -a active_services=()

    if [[ "$(uname -m)" != "x86_64" ]]; then
        error "فایل ${CORE_ASSET} ریپو برای x86_64 است؛ معماری فعلی: $(uname -m)"
        return 1
    fi

    mkdir -p "$CORE_DIR"
    tmp="$(mktemp "${CORE_DIR}/.${CORE_ASSET}.XXXXXX")" || return 1

    info "دریافت هسته از GitHub خودت..."
    if ! curl -fL --retry 3 --connect-timeout 15 \
        -o "$tmp" "${CORE_URL}?cb=$(date +%s)"; then
        error "دانلود هسته ناموفق بود."
        rm -f "$tmp"
        return 1
    fi

    magic="$(od -An -t x1 -N4 "$tmp" | tr -d ' \n')"
    if [[ "$magic" != "7f454c46" ]]; then
        error "فایل دریافتی ELF معتبر نیست؛ جایگزینی انجام نشد."
        rm -f "$tmp"
        return 1
    fi

    chmod 0755 "$tmp"
    version="$("$tmp" -v 2>/dev/null)" || {
        error "هستهٔ دریافتی اجرا نشد؛ جایگزینی انجام نشد."
        rm -f "$tmp"
        return 1
    }
    if [[ "$version" != v2.* ]]; then
        error "نسخهٔ دریافتی v2 نیست: $version"
        rm -f "$tmp"
        return 1
    fi

    if [[ -e "$CORE_BIN" ]]; then
        stamp="$(date +%Y%m%d-%H%M%S)"
        install -m 0755 "$CORE_BIN" "${CORE_BIN}.backup-${stamp}"
        info "نسخه قبلی پشتیبان‌گیری شد: ${CORE_BIN}.backup-${stamp}"
    fi

    install -m 0755 "$tmp" "$CORE_BIN"
    rm -f "$tmp"
    ok "هسته نصب شد: $version"

    if [[ "$restart_services" == "true" ]]; then
        while IFS= read -r service; do
            [[ -n "$service" ]] && active_services+=("$service")
        done < <(systemctl list-unit-files "${SERVICE_PREFIX}-*.service" \
            --no-legend 2>/dev/null | awk '{print $1}')

        for service in "${active_services[@]}"; do
            systemctl restart "$service" || warn "راه‌اندازی مجدد ناموفق: $service"
        done
        ((${#active_services[@]} > 0)) && ok "سرویس‌های v2 دوباره راه‌اندازی شدند."
    fi
}

ensure_core() {
    if [[ ! -x "$CORE_BIN" ]]; then
        warn "هستهٔ v2 در مسیر $CORE_BIN پیدا نشد."
        download_core false || return 1
    fi
}

choose_role() {
    printf '\n%sنقش این سرور:%s\n' "$BOLD" "$RESET"
    printf '  %s1)%s ایران (Server / Listener)\n' "$GREEN" "$RESET"
    printf '  %s2)%s خارج (Client / Dialer)\n' "$MAGENTA" "$RESET"
    while true; do
        read -r -p "انتخاب [1-2]: " choice
        case "$choice" in
            1) cfg_role="server"; cfg_location="iran"; return 0 ;;
            2) cfg_role="client"; cfg_location="kharej"; return 0 ;;
            *) error "گزینه نامعتبر است." ;;
        esac
    done
}

choose_transport() {
    local -a transports=(tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls tun)
    local i

    printf '\n%sنوع انتقال:%s\n' "$BOLD" "$RESET"
    for ((i=0; i<${#transports[@]}; i++)); do
        printf '  %2d) %s\n' "$((i + 1))" "${transports[$i]}"
    done

    while true; do
        read -r -p "انتخاب [1-${#transports[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
            (( choice >= 1 && choice <= ${#transports[@]} )); then
            cfg_transport="${transports[$((choice - 1))]}"
            return 0
        fi
        error "گزینه نامعتبر است."
    done
}

reset_config_values() {
    cfg_role=""
    cfg_location=""
    cfg_transport=""
    cfg_bind_addr=""
    cfg_remote_addr=""
    cfg_edge_ip=""
    cfg_token=""
    cfg_nodelay="true"
    cfg_keepalive_period="40"
    cfg_accept_udp=""
    cfg_proxy_protocol=""
    cfg_connection_pool=""
    cfg_heartbeat_interval="10"
    cfg_heartbeat_timeout="25"
    cfg_mux_version=""
    cfg_mux_concurrency=""
    cfg_tls_sni=""
    cfg_tls_cert=""
    cfg_tls_key=""
    cfg_tun_encapsulation=""
    cfg_tun_name=""
    cfg_tun_local_addr=""
    cfg_tun_remote_addr=""
    cfg_tun_health_port=""
    cfg_tun_mtu=""
    cfg_ipx_mode=""
    cfg_ipx_profile=""
    cfg_ipx_listen_ip=""
    cfg_ipx_dst_ip=""
    cfg_ipx_interface=""
    cfg_ipx_icmp_type=""
    cfg_ipx_icmp_code=""
    cfg_enable_encryption=""
    cfg_algorithm=""
    cfg_psk=""
    cfg_kdf_iterations=""
    cfg_forwarder=""
    cfg_auto_tuning="true"
    cfg_tuning_profile="balanced"
    cfg_workers="0"
    cfg_channel_size="4096"
    cfg_tcp_mss="0"
    cfg_so_rcvbuf="0"
    cfg_so_sndbuf="0"
    cfg_buffer_profile="balanced"
    cfg_read_timeout="120"
    cfg_batch_size=""
    cfg_log_level="info"
    cfg_ports_mapping=""
}

prompt_transport_settings() {
    printf '\n%sتنظیمات پایه%s\n' "$BLUE" "$RESET"
    if [[ "$cfg_tun_encapsulation" == "ipx" ]]; then
        cfg_nodelay=""
        cfg_keepalive_period=""
    else
        ask_bool cfg_nodelay "TCP_NODELAY فعال باشد؟" "y"
    fi

    if [[ "$cfg_role" == "server" ]]; then
        if [[ "$cfg_transport" == "tcp" && "$cfg_tun_encapsulation" != "ipx" ]]; then
            ask_bool cfg_accept_udp "UDP روی TCP پذیرفته شود؟" "n"
        fi
        if [[ "$cfg_tun_encapsulation" == "ipx" ]]; then
            cfg_proxy_protocol=""
        else
            case "$cfg_transport" in
                tun|ws) cfg_proxy_protocol="" ;;
                *) ask_bool cfg_proxy_protocol "Proxy Protocol فعال باشد؟" "n" ;;
            esac
        fi
    elif [[ "$cfg_transport" != "tun" && "$cfg_tun_encapsulation" != "ipx" ]]; then
        ask_port cfg_connection_pool "تعداد Connection Pool" "8"
    fi
}

prompt_connection_settings() {
    [[ "$cfg_tun_encapsulation" == "ipx" ]] && return 0

    printf '\n%sتنظیم اتصال%s\n' "$BLUE" "$RESET"
    if [[ "$cfg_role" == "server" ]]; then
        ask_bind cfg_bind_addr
    else
        ask_endpoint cfg_remote_addr "آدرس سرور ایران"
        case "$cfg_transport" in
            ws|wss|wsmux|wssmux|xwsmux)
                ask cfg_edge_ip "Edge IP/Domain (اختیاری)"
                ;;
        esac
    fi
}

prompt_tun_settings() {
    local default_local default_remote

    [[ "$cfg_transport" == "tun" ]] || return 0
    printf '\n%sتنظیمات TUN%s\n' "$BLUE" "$RESET"
    printf '  1) tcp\n'
    printf '  2) ipx  (ICMP/IPIP/UDP/TCP/GRE/BIP)\n'
    while true; do
        read -r -p "Encapsulation [1-2]: " choice
        case "$choice" in
            1|tcp) cfg_tun_encapsulation="tcp"; break ;;
            2|ipx) cfg_tun_encapsulation="ipx"; break ;;
            *) error "فقط tcp یا ipx را انتخاب کنید." ;;
        esac
    done

    ask cfg_tun_name "نام دستگاه TUN" "backhaul"
    if [[ ! "$cfg_tun_name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        error "نام TUN نامعتبر است."
        return 1
    fi

    if [[ "$cfg_role" == "server" ]]; then
        default_local="10.10.10.1/24"
        default_remote="10.10.10.2/24"
    else
        default_local="10.10.10.2/24"
        default_remote="10.10.10.1/24"
    fi

    ask_cidr cfg_tun_local_addr "آدرس Local TUN" "$default_local"
    ask_cidr cfg_tun_remote_addr "آدرس Remote TUN" "$default_remote"
    ask_port cfg_tun_health_port "Health Port" "1234"
    if [[ "$cfg_tun_encapsulation" == "ipx" ]]; then
        ask cfg_tun_mtu "MTU" "1320"
    else
        ask cfg_tun_mtu "MTU" "1500"
    fi
    [[ "$cfg_tun_mtu" =~ ^[0-9]+$ ]] &&
        (( cfg_tun_mtu >= 576 && cfg_tun_mtu <= 9000 )) || {
        error "MTU باید بین 576 و 9000 باشد."
        return 1
    }
}

prompt_ipx_settings() {
    local default_ip default_interface
    local -a profiles=(icmp ipip udp tcp gre bip)
    local i

    [[ "$cfg_tun_encapsulation" == "ipx" ]] || return 0
    printf '\n%sتنظیمات IPX%s\n' "$BLUE" "$RESET"
    printf '%sپروفایل‌های موجود:%s\n' "$MAGENTA" "$RESET"
    for ((i=0; i<${#profiles[@]}; i++)); do
        printf '  %d) %s\n' "$((i + 1))" "${profiles[$i]}"
    done

    while true; do
        read -r -p "Profile [1-6، پیش‌فرض: tcp]: " choice
        choice="${choice:-tcp}"
        case "$choice" in
            1|icmp) cfg_ipx_profile="icmp"; break ;;
            2|ipip) cfg_ipx_profile="ipip"; break ;;
            3|udp)  cfg_ipx_profile="udp"; break ;;
            4|tcp)  cfg_ipx_profile="tcp"; break ;;
            5|gre)  cfg_ipx_profile="gre"; break ;;
            6|bip)  cfg_ipx_profile="bip"; break ;;
            *) error "پروفایل IPX نامعتبر است." ;;
        esac
    done

    cfg_ipx_mode="$cfg_role"
    default_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    while true; do
        ask cfg_ipx_listen_ip "IP عمومی/محلی همین سرور برای Listen" "$default_ip"
        [[ -n "$cfg_ipx_listen_ip" ]] && break
        error "Listen IP نمی‌تواند خالی باشد."
    done
    while true; do
        ask cfg_ipx_dst_ip "IP سرور مقابل (Destination IP)"
        [[ -n "$cfg_ipx_dst_ip" ]] && break
        error "Destination IP نمی‌تواند خالی باشد."
    done

    if command -v ip >/dev/null 2>&1; then
        default_interface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
    else
        default_interface=""
    fi
    while true; do
        ask cfg_ipx_interface "کارت شبکه" "$default_interface"
        [[ "$cfg_ipx_interface" =~ ^[A-Za-z0-9_.:-]+$ ]] && break
        error "نام کارت شبکه نامعتبر است؛ نمونه: eth0"
    done

    if [[ "$cfg_ipx_profile" == "icmp" ]]; then
        ask cfg_ipx_icmp_type "ICMP Type" "0"
        ask cfg_ipx_icmp_code "ICMP Code" "0"
        [[ "$cfg_ipx_icmp_type" =~ ^[0-9]+$ ]] &&
            (( cfg_ipx_icmp_type >= 0 && cfg_ipx_icmp_type <= 255 )) || {
            error "ICMP Type باید بین 0 و 255 باشد."
            return 1
        }
        [[ "$cfg_ipx_icmp_code" =~ ^[0-9]+$ ]] &&
            (( cfg_ipx_icmp_code >= 0 && cfg_ipx_icmp_code <= 255 )) || {
            error "ICMP Code باید بین 0 و 255 باشد."
            return 1
        }
    fi
}

prompt_security_settings() {
    printf '\n%sامنیت%s\n' "$BLUE" "$RESET"

    if [[ "$cfg_tun_encapsulation" == "ipx" ]]; then
        ask_bool cfg_enable_encryption "رمزنگاری IPX فعال باشد؟" "y"
        if [[ "$cfg_enable_encryption" == "true" ]]; then
            printf 'Algorithm: aes-256-gcm | chacha20-poly1305 | aes-128-gcm\n'
            while true; do
                ask cfg_algorithm "Algorithm" "aes-256-gcm"
                case "$cfg_algorithm" in
                    aes-256-gcm|chacha20-poly1305|aes-128-gcm) break ;;
                    *) error "Algorithm نامعتبر است." ;;
                esac
            done
            while true; do
                ask cfg_psk "PSK مشترک دو سرور (Base64)"
                [[ -n "$cfg_psk" ]] && break
                error "PSK نمی‌تواند خالی باشد."
            done
            ask cfg_kdf_iterations "KDF Iterations" "100000"
            [[ "$cfg_kdf_iterations" =~ ^[0-9]+$ ]] &&
                (( cfg_kdf_iterations > 0 )) || {
                error "KDF Iterations باید عدد مثبت باشد."
                return 1
            }
        fi
        cfg_token=""
        return 0
    fi

    while true; do
        ask cfg_token "توکن مشترک دو سرور"
        [[ -n "$cfg_token" ]] && return 0
        error "توکن نمی‌تواند خالی باشد."
    done
}

prompt_mux_settings() {
    [[ "$cfg_transport" == *mux ]] || return 0
    printf '\n%sتنظیمات Mux%s\n' "$BLUE" "$RESET"
    ask cfg_mux_version "Mux Version" "2"
    [[ "$cfg_mux_version" == "1" || "$cfg_mux_version" == "2" ]] || {
        error "Mux Version فقط 1 یا 2 است."
        return 1
    }
    ask_port cfg_mux_concurrency "Mux Concurrency" "8"
}

prompt_tls_settings() {
    local generate

    case "$cfg_transport" in
        anytls|wss|wssmux) ;;
        *) return 0 ;;
    esac

    printf '\n%sتنظیمات TLS%s\n' "$BLUE" "$RESET"
    if [[ "$cfg_role" == "client" ]]; then
        ask cfg_tls_sni "SNI دامنه" "www.digikala.com"
        return 0
    fi

    mkdir -p "$CERT_DIR"
    if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
        ask_bool generate "گواهی Self-Signed ساخته شود؟" "y"
        if [[ "$generate" == "true" ]]; then
            if ! command -v openssl >/dev/null 2>&1; then
                error "openssl نصب نیست."
                return 1
            fi
            openssl req -newkey ec \
                -pkeyopt ec_paramgen_curve:prime256v1 \
                -nodes -x509 -days 365 -sha256 \
                -keyout "$KEY_FILE" -out "$CERT_FILE" \
                -subj "/CN=backhaul.local" >/dev/null 2>&1 || {
                error "ساخت گواهی TLS ناموفق بود."
                return 1
            }
            chmod 0600 "$KEY_FILE"
            ok "گواهی TLS ساخته شد."
        fi
    fi

    ask cfg_tls_cert "مسیر Certificate" "$CERT_FILE"
    ask cfg_tls_key "مسیر Private Key" "$KEY_FILE"
    [[ -s "$cfg_tls_cert" && -s "$cfg_tls_key" ]] || {
        error "فایل Certificate یا Key پیدا نشد."
        return 1
    }
}

prompt_tuning_settings() {
    local advanced

    printf '\n%sبهینه‌سازی%s\n' "$BLUE" "$RESET"
    ask_bool advanced "تنظیمات پیشرفته را تغییر می‌دهید؟" "n"
    [[ "$advanced" == "true" ]] || {
        [[ "$cfg_transport" == "tun" ]] && cfg_channel_size="10000"
        [[ "$cfg_tun_encapsulation" == "ipx" ]] && {
            cfg_batch_size="2048"
            cfg_so_rcvbuf=""
            cfg_tcp_mss=""
            cfg_buffer_profile=""
            cfg_read_timeout=""
        }
        return 0
    }

    ask_bool cfg_auto_tuning "Auto Tuning فعال باشد؟" "y"
    ask cfg_tuning_profile "پروفایل Kernel (balanced/fast/latency/resource)" "balanced"
    case "$cfg_tuning_profile" in
        balanced|fast|latency|resource) ;;
        *) error "پروفایل Kernel نامعتبر است."; return 1 ;;
    esac

    ask cfg_workers "Workers (صفر یعنی خودکار)" "0"
    [[ "$cfg_workers" =~ ^[0-9]+$ ]] || {
        error "Workers باید عدد باشد."
        return 1
    }
    ask cfg_channel_size "Channel Size" "${cfg_channel_size}"
    [[ "$cfg_channel_size" =~ ^[0-9]+$ ]] || {
        error "Channel Size باید عدد باشد."
        return 1
    }

    if [[ "$cfg_tun_encapsulation" == "ipx" ]]; then
        ask cfg_batch_size "Batch Size" "2048"
        ask cfg_so_sndbuf "SO_SNDBUF (صفر یعنی خودکار)" "0"
        [[ "$cfg_batch_size" =~ ^[0-9]+$ && "$cfg_so_sndbuf" =~ ^[0-9]+$ ]] || {
            error "Batch Size و SO_SNDBUF باید عدد باشند."
            return 1
        }
        cfg_so_rcvbuf=""
        cfg_tcp_mss=""
        cfg_buffer_profile=""
        cfg_read_timeout=""
    else
        ask cfg_buffer_profile \
            "Buffer Profile (balanced/low_cpu/ultra_low_cpu/extreme_low_cpu/low_memory)" \
            "balanced"
        case "$cfg_buffer_profile" in
            balanced|low_cpu|ultra_low_cpu|extreme_low_cpu|low_memory) ;;
            *) error "Buffer Profile نامعتبر است."; return 1 ;;
        esac
    fi
}

prompt_logging_settings() {
    ask cfg_log_level "Log Level (panic/fatal/error/warn/info/debug/trace)" "info"
    case "$cfg_log_level" in
        panic|fatal|error|warn|info|debug|trace) ;;
        *) error "Log Level نامعتبر است."; return 1 ;;
    esac
}

prompt_ports_settings() {
    [[ "$cfg_role" == "server" ]] || return 0

    printf '\n%sنگاشت پورت%s\n' "$BLUE" "$RESET"
    if [[ "$cfg_transport" == "tun" ]]; then
        ask cfg_forwarder "Forwarder (backhaul/iptables)" "backhaul"
        case "$cfg_forwarder" in
            backhaul|iptables) ;;
            *) error "Forwarder نامعتبر است."; return 1 ;;
        esac
    fi
    ask_port_mappings cfg_ports_mapping
}

write_ports_array() {
    local mapping="$1"
    local item
    local -a items

    printf 'mapping = [\n'
    IFS=',' read -r -a items <<< "$mapping"
    for item in "${items[@]}"; do
        printf '    "%s",\n' "$item"
    done
    printf ']\n'
}

generate_config() {
    local output="$1"

    {
        if [[ "$cfg_tun_encapsulation" == "ipx" ]]; then
            :
        elif [[ "$cfg_role" == "server" ]]; then
            printf '[listener]\n'
            printf 'bind_addr = "%s"\n\n' "$(toml_escape "$cfg_bind_addr")"
        else
            printf '[dialer]\n'
            printf 'remote_addr = "%s"\n' "$(toml_escape "$cfg_remote_addr")"
            [[ -n "$cfg_edge_ip" ]] &&
                printf 'edge_ip = "%s"\n' "$(toml_escape "$cfg_edge_ip")"
            printf 'dial_timeout = 10\n'
            printf 'retry_interval = 3\n\n'
        fi

        printf '[transport]\n'
        printf 'type = "%s"\n' "$cfg_transport"
        [[ -n "$cfg_nodelay" ]] &&
            printf 'nodelay = %s\n' "$cfg_nodelay"
        [[ -n "$cfg_keepalive_period" ]] &&
            printf 'keepalive_period = %s\n' "$cfg_keepalive_period"
        [[ -n "$cfg_accept_udp" ]] &&
            printf 'accept_udp = %s\n' "$cfg_accept_udp"
        [[ -n "$cfg_proxy_protocol" ]] &&
            printf 'proxy_protocol = %s\n' "$cfg_proxy_protocol"
        [[ -n "$cfg_connection_pool" ]] &&
            printf 'connection_pool = %s\n' "$cfg_connection_pool"
        printf 'heartbeat_interval = %s\n' "$cfg_heartbeat_interval"
        printf 'heartbeat_timeout = %s\n\n' "$cfg_heartbeat_timeout"

        if [[ "$cfg_transport" == "tun" ]]; then
            printf '[tun]\n'
            printf 'encapsulation = "%s"\n' "$cfg_tun_encapsulation"
            printf 'name = "%s"\n' "$(toml_escape "$cfg_tun_name")"
            printf 'local_addr = "%s"\n' "$cfg_tun_local_addr"
            printf 'remote_addr = "%s"\n' "$cfg_tun_remote_addr"
            printf 'health_port = %s\n' "$cfg_tun_health_port"
            printf 'mtu = %s\n\n' "$cfg_tun_mtu"
        fi

        if [[ "$cfg_tun_encapsulation" == "ipx" ]]; then
            printf '[ipx]\n'
            printf 'mode = "%s"\n' "$cfg_ipx_mode"
            printf 'profile = "%s"\n' "$cfg_ipx_profile"
            printf 'listen_ip = "%s"\n' "$(toml_escape "$cfg_ipx_listen_ip")"
            printf 'dst_ip = "%s"\n' "$(toml_escape "$cfg_ipx_dst_ip")"
            printf 'interface = "%s"\n' "$(toml_escape "$cfg_ipx_interface")"
            [[ -n "$cfg_ipx_icmp_type" ]] &&
                printf 'icmp_type = %s\n' "$cfg_ipx_icmp_type"
            [[ -n "$cfg_ipx_icmp_code" ]] &&
                printf 'icmp_code = %s\n' "$cfg_ipx_icmp_code"
            printf '\n'
        fi

        if [[ "$cfg_transport" == *mux ]]; then
            printf '[mux]\n'
            printf 'mux_version = %s\n' "$cfg_mux_version"
            printf 'mux_framesize = 32768\n'
            printf 'mux_recievebuffer = 4194304\n'
            printf 'mux_streambuffer = 2097152\n'
            printf 'mux_concurrency = %s\n\n' "$cfg_mux_concurrency"
        fi

        printf '[security]\n'
        if [[ "$cfg_tun_encapsulation" == "ipx" ]]; then
            printf 'enable_encryption = %s\n' "$cfg_enable_encryption"
            if [[ "$cfg_enable_encryption" == "true" ]]; then
                printf 'algorithm = "%s"\n' "$cfg_algorithm"
                printf 'psk = "%s"\n' "$(toml_escape "$cfg_psk")"
                printf 'kdf_iterations = %s\n' "$cfg_kdf_iterations"
            fi
            printf '\n'
        else
            printf 'token = "%s"\n\n' "$(toml_escape "$cfg_token")"
        fi

        if [[ -n "$cfg_tls_sni" || -n "$cfg_tls_cert" ]]; then
            printf '[tls]\n'
            [[ -n "$cfg_tls_sni" ]] &&
                printf 'sni = "%s"\n' "$(toml_escape "$cfg_tls_sni")"
            [[ -n "$cfg_tls_cert" ]] &&
                printf 'tls_cert = "%s"\n' "$(toml_escape "$cfg_tls_cert")"
            [[ -n "$cfg_tls_key" ]] &&
                printf 'tls_key = "%s"\n' "$(toml_escape "$cfg_tls_key")"
            printf '\n'
        fi

        printf '[tuning]\n'
        printf 'auto_tuning = %s\n' "$cfg_auto_tuning"
        printf 'tuning_profile = "%s"\n' "$cfg_tuning_profile"
        printf 'workers = %s\n' "$cfg_workers"
        printf 'channel_size = %s\n' "$cfg_channel_size"
        [[ -n "$cfg_tcp_mss" ]] &&
            printf 'tcp_mss = %s\n' "$cfg_tcp_mss"
        [[ -n "$cfg_so_rcvbuf" ]] &&
            printf 'so_rcvbuf = %s\n' "$cfg_so_rcvbuf"
        [[ -n "$cfg_so_sndbuf" ]] &&
            printf 'so_sndbuf = %s\n' "$cfg_so_sndbuf"
        [[ -n "$cfg_batch_size" ]] &&
            printf 'batch_size = %s\n' "$cfg_batch_size"
        [[ -n "$cfg_buffer_profile" ]] &&
            printf 'buffer_profile = "%s"\n' "$cfg_buffer_profile"
        [[ -n "$cfg_read_timeout" ]] &&
            printf 'read_timeout = %s\n' "$cfg_read_timeout"
        printf '\n'

        printf '[logging]\n'
        printf 'log_level = "%s"\n' "$cfg_log_level"

        if [[ "$cfg_role" == "server" ]]; then
            printf '\n[ports]\n'
            [[ -n "$cfg_forwarder" ]] &&
                printf 'forwarder = "%s"\n' "$cfg_forwarder"
            write_ports_array "$cfg_ports_mapping"
        fi
    } > "$output"
}

config_has_parser_error() {
    local log="$1"
    grep -Eqi \
        'failed to load configuration|neither server nor client|toml|cannot decode|unknown field|invalid configuration' \
        "$log"
}

validate_generated_config() {
    local config="$1"
    local log rc

    log="$(mktemp)"
    timeout -k 1 2 "$CORE_BIN" -c "$config" >"$log" 2>&1
    rc=$?

    if config_has_parser_error "$log"; then
        error "هسته کانفیگ ساخته‌شده را رد کرد:"
        sed -n '1,30p' "$log" >&2
        rm -f "$log"
        return 1
    fi

    # A valid config normally keeps running until timeout (124). It can also
    # stop for an environmental reason such as an occupied port; parsing still
    # succeeded and systemd will expose that exact runtime error.
    if (( rc != 0 && rc != 124 )); then
        warn "قالب کانفیگ معتبر است؛ بررسی نهایی پس از اجرای سرویس انجام می‌شود."
    fi
    rm -f "$log"
}

service_name_for() {
    local location="$1"
    local port="$2"
    printf '%s-%s%s.service' "$SERVICE_PREFIX" "$location" "$port"
}

create_service() {
    local location="$1"
    local port="$2"
    local config="$3"
    local service service_file

    service="$(service_name_for "$location" "$port")"
    service_file="${SERVICE_DIR}/${service}"

    {
        printf '[Unit]\n'
        printf 'Description=Backhaul v2 %s tunnel port %s\n' "$location" "$port"
        printf 'Wants=network-online.target\n'
        printf 'After=network-online.target\n\n'
        printf '[Service]\n'
        printf 'Type=simple\n'
        printf 'User=root\n'
        printf 'ExecStart=%s -c %s\n' "$CORE_BIN" "$config"
        printf 'Restart=on-failure\n'
        printf 'RestartSec=3\n'
        printf 'LimitNOFILE=1048576\n'
        printf 'LimitMEMLOCK=infinity\n'
        printf 'TasksMax=infinity\n'
        printf 'StandardOutput=journal\n'
        printf 'StandardError=journal\n\n'
        printf '[Install]\n'
        printf 'WantedBy=multi-user.target\n'
    } > "$service_file"

    systemctl daemon-reload
    systemctl enable "$service" >/dev/null 2>&1
    systemctl restart "$service"
    sleep 2

    if systemctl is-active --quiet "$service"; then
        ok "تونل فعال شد: $service"
        return 0
    fi

    error "سرویس ساخته شد ولی بالا نیامد: $service"
    journalctl -u "$service" -n 25 --no-pager -o cat
    return 1
}

configure_tunnel() {
    local tunnel_port config_file temp_config backup_stamp

    ensure_core || {
        pause
        return
    }
    reset_config_values
    clear
    printf '%s%sساخت تونل جدید با هسته v2%s\n' "$BOLD" "$CYAN" "$RESET"

    choose_role
    choose_transport
    prompt_tun_settings || { pause; return; }
    prompt_ipx_settings || { pause; return; }
    prompt_transport_settings || { pause; return; }
    prompt_connection_settings
    prompt_security_settings || { pause; return; }
    prompt_mux_settings || { pause; return; }
    prompt_tls_settings || { pause; return; }
    prompt_tuning_settings || { pause; return; }
    prompt_logging_settings || { pause; return; }
    prompt_ports_settings || { pause; return; }

    if [[ "$cfg_tun_encapsulation" == "ipx" ]]; then
        tunnel_port="$cfg_tun_health_port"
    elif [[ "$cfg_role" == "server" ]]; then
        tunnel_port="${cfg_bind_addr##*:}"
    else
        tunnel_port="${cfg_remote_addr##*:}"
    fi
    [[ -n "$tunnel_port" ]] || tunnel_port="$cfg_tun_health_port"

    config_file="${CORE_DIR}/v2-${cfg_location}${tunnel_port}.toml"
    temp_config="$(mktemp "${CORE_DIR}/.v2-config.XXXXXX")" || {
        error "ساخت فایل موقت ناموفق بود."
        pause
        return
    }
    generate_config "$temp_config"

    info "اعتبارسنجی کانفیگ با $(core_version)..."
    if ! validate_generated_config "$temp_config"; then
        rm -f "$temp_config"
        pause
        return
    fi

    if [[ -e "$config_file" ]]; then
        backup_stamp="$(date +%Y%m%d-%H%M%S)"
        install -m 0600 "$config_file" "${config_file}.backup-${backup_stamp}"
        info "از کانفیگ قبلی پشتیبان گرفته شد."
    fi
    install -m 0600 "$temp_config" "$config_file"
    rm -f "$temp_config"

    create_service "$cfg_location" "$tunnel_port" "$config_file"
    printf '\n%sمسیر کانفیگ:%s %s\n' "$CYAN" "$RESET" "$config_file"
    pause
}

list_configs() {
    local path
    shopt -s nullglob
    for path in "$CORE_DIR"/v2-iran*.toml "$CORE_DIR"/v2-kharej*.toml; do
        printf '%s\n' "$path"
    done
    shopt -u nullglob
}

config_service_name() {
    local config="$1"
    local base="${config##*/}"
    base="${base%.toml}"
    base="${base#v2-}"
    printf '%s-%s.service' "$SERVICE_PREFIX" "$base"
}

status_label() {
    local service="$1"
    if systemctl is-active --quiet "$service"; then
        printf '%sفعال%s' "$GREEN" "$RESET"
    else
        printf '%sخاموش/خطا%s' "$RED" "$RESET"
    fi
}

show_all_statuses() {
    local config service found=0

    clear
    printf '%s%sوضعیت تونل‌های Backhaul v2%s\n\n' "$BOLD" "$CYAN" "$RESET"
    while IFS= read -r config; do
        found=1
        service="$(config_service_name "$config")"
        printf '  %-38s %s\n' "$service" "$(status_label "$service")"
    done < <(list_configs)

    (( found == 1 )) || warn "هیچ کانفیگ v2 ساخته نشده است."
    pause
}

select_config() {
    local config i=1 choice
    local -a configs=()

    while IFS= read -r config; do
        configs+=("$config")
    done < <(list_configs)

    if ((${#configs[@]} == 0)); then
        warn "هیچ تونل v2 وجود ندارد."
        return 1
    fi

    printf '\n%sتونل‌ها:%s\n' "$BOLD" "$RESET"
    for config in "${configs[@]}"; do
        printf '  %d) %-28s %s\n' "$i" "${config##*/}" \
            "$(status_label "$(config_service_name "$config")")"
        ((i++))
    done
    printf '  0) بازگشت\n'

    while true; do
        read -r -p "انتخاب: " choice
        [[ "$choice" == "0" ]] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
            (( choice >= 1 && choice <= ${#configs[@]} )); then
            SELECTED_CONFIG="${configs[$((choice - 1))]}"
            return 0
        fi
        error "گزینه نامعتبر است."
    done
}

remove_selected_tunnel() {
    local config="$1"
    local service service_file confirm backup_dir stamp

    service="$(config_service_name "$config")"
    service_file="${SERVICE_DIR}/${service}"
    read -r -p "حذف ${service}؟ برای تأیید DELETE بنویسید: " confirm
    [[ "$confirm" == "DELETE" ]] || {
        warn "لغو شد."
        return 0
    }

    systemctl disable --now "$service" >/dev/null 2>&1 || true
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="${CORE_DIR}/removed-v2/${stamp}"
    mkdir -p "$backup_dir"
    [[ -e "$config" ]] && install -m 0600 "$config" "$backup_dir/${config##*/}"
    [[ -e "$service_file" ]] && install -m 0644 "$service_file" "$backup_dir/$service"
    rm -f "$config" "$service_file"
    systemctl daemon-reload
    systemctl reset-failed "$service" >/dev/null 2>&1 || true
    ok "تونل حذف شد. نسخه بازیابی: $backup_dir"
}

manage_tunnel() {
    local service choice

    clear
    select_config || { pause; return; }
    service="$(config_service_name "$SELECTED_CONFIG")"

    while true; do
        clear
        printf '%sمدیریت %s%s\n\n' "$CYAN" "$service" "$RESET"
        printf '  1) Restart\n'
        printf '  2) Status\n'
        printf '  3) Logs (آخرین 100 خط)\n'
        printf '  4) نمایش کانفیگ\n'
        printf '  %s5) حذف تونل%s\n' "$RED" "$RESET"
        printf '  0) بازگشت\n'
        read -r -p "انتخاب: " choice

        case "$choice" in
            1)
                systemctl restart "$service" &&
                    ok "سرویس Restart شد." || error "Restart ناموفق بود."
                pause
                ;;
            2)
                systemctl status "$service" --no-pager || true
                pause
                ;;
            3)
                journalctl -u "$service" -n 100 --no-pager -o cat
                pause
                ;;
            4)
                sed -n '1,240p' "$SELECTED_CONFIG"
                pause
                ;;
            5)
                remove_selected_tunnel "$SELECTED_CONFIG"
                pause
                return
                ;;
            0) return ;;
            *) error "گزینه نامعتبر است."; sleep 1 ;;
        esac
    done
}

diagnostics() {
    local service

    clear
    printf '%s%sعیب‌یابی Backhaul v2%s\n\n' "$BOLD" "$CYAN" "$RESET"
    printf 'Core path: %s\n' "$CORE_BIN"
    printf 'Core version: %s\n' "$(core_version)"
    printf 'Architecture: %s\n' "$(uname -m)"
    printf 'Config directory: %s\n\n' "$CORE_DIR"

    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        printf '%s\n' "----- $service -----"
        systemctl is-active "$service" 2>/dev/null || true
        journalctl -u "$service" -n 12 --no-pager -o cat 2>/dev/null || true
        printf '\n'
    done < <(systemctl list-unit-files "${SERVICE_PREFIX}-*.service" \
        --no-legend 2>/dev/null | awk '{print $1}')
    pause
}

remove_core() {
    local config confirm

    if config="$(list_configs)" && [[ -n "$config" ]]; then
        error "اول تونل‌های v2 را از بخش مدیریت حذف کنید."
        pause
        return
    fi

    read -r -p "حذف فایل هستهٔ v2؟ برای تأیید REMOVE بنویسید: " confirm
    [[ "$confirm" == "REMOVE" ]] || {
        warn "لغو شد."
        pause
        return
    }

    if [[ -e "$CORE_BIN" ]]; then
        install -m 0755 "$CORE_BIN" "${CORE_BIN}.removed-$(date +%Y%m%d-%H%M%S)"
        rm -f "$CORE_BIN"
        ok "هسته حذف شد؛ یک نسخه پشتیبان کنار آن نگه داشته شد."
    else
        warn "هسته نصب نبود."
    fi
    pause
}

show_header() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    clear
    printf '%s%s\n' "$CYAN" "╔══════════════════════════════════════════╗"
    printf '║          BACKHAUL v2 MANAGER             ║\n'
    printf '╚══════════════════════════════════════════╝%s\n' "$RESET"
    printf 'نسخه منو: %s | هسته: %s\n' "$SCRIPT_VERSION" "$(core_version)"
    printf 'IP سرور: %s\n' "${ip:-نامشخص}"
    printf '%s\n\n' "────────────────────────────────────────────"
}

main_menu() {
    local choice

    while true; do
        show_header
        printf '  %s1)%s ساخت تونل جدید\n' "$GREEN" "$RESET"
        printf '  %s2)%s مدیریت تونل‌ها\n' "$MAGENTA" "$RESET"
        printf '  %s3)%s وضعیت همه تونل‌ها\n' "$CYAN" "$RESET"
        printf '  4) نصب/آپدیت هسته backhaul_premium_v2\n'
        printf '  5) عیب‌یابی\n'
        printf '  %s6)%s حذف هسته v2\n' "$RED" "$RESET"
        printf '  0) خروج\n\n'
        read -r -p "انتخاب [0-6]: " choice

        case "$choice" in
            1) configure_tunnel ;;
            2) manage_tunnel ;;
            3) show_all_statuses ;;
            4)
                download_core true
                pause
                ;;
            5) diagnostics ;;
            6) remove_core ;;
            0) exit 0 ;;
            *) error "گزینه نامعتبر است."; sleep 1 ;;
        esac
    done
}

trap 'printf "\n"; warn "عملیات متوقف شد."; exit 130' INT TERM
require_root
require_commands
mkdir -p "$CORE_DIR" "$CERT_DIR"
main_menu
