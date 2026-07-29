#!/usr/bin/env bash

# One-command installer for Backhaul v2 Manager.
# Repository: V2grop/backhaul-oneclick

set -Eeuo pipefail
umask 077

REPOSITORY="V2grop/backhaul-oneclick"
BRANCH="main"
MANAGER_SOURCE="backhaul-v2.2.0-english.sh"
CORE_SOURCE="backhaul_premium_v2"
EXPECTED_MANAGER_VERSION="2.2.0"
EXPECTED_MANAGER_SHA256="9206684ff68c00807e6d48d9a4a8648658b0138780dfa16c38838eb0f30e3526"

INSTALL_DIR="/root/backhaul-core"
MANAGER_PATH="${INSTALL_DIR}/backhaul.sh"
CORE_PATH="${INSTALL_DIR}/backhaul_premium_v2"
SYSCTL_FILE="/etc/sysctl.d/99-backhaul-v2-forwarding.conf"

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
RESET=$'\033[0m'

ok()    { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; }

if (( EUID != 0 )); then
    error "Run this installer as root."
    exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
    error "This Backhaul v2 core is built for x86_64. Current architecture: $(uname -m)"
    exit 1
fi

install_package() {
    local package="$1"

    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$package"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$package"
    else
        error "No supported package manager was found. Install ${package} manually."
        return 1
    fi
}

if ! command -v curl >/dev/null 2>&1; then
    install_package curl
fi
if ! command -v iptables >/dev/null 2>&1; then
    install_package iptables
fi

for command_name in curl install sha256sum od sed grep mktemp sysctl cmp awk tr head; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "Required command is missing: $command_name"
        exit 1
    fi
done

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

download_repo_file() {
    local source_name="$1"
    local destination="$2"
    local cache_buster
    local primary_url fallback_url

    cache_buster="$(date +%s)"
    primary_url="https://raw.githubusercontent.com/${REPOSITORY}/${BRANCH}/${source_name}?cb=${cache_buster}"
    fallback_url="https://github.com/${REPOSITORY}/raw/refs/heads/${BRANCH}/${source_name}?cb=${cache_buster}"

    if curl -fL --retry 3 --connect-timeout 15 \
        -o "$destination" "$primary_url"; then
        return 0
    fi

    warn "Primary GitHub download failed; trying the fallback URL..."
    curl -fL --retry 3 --connect-timeout 15 \
        -o "$destination" "$fallback_url"
}

backup_existing() {
    local target="$1"
    local stamp="$2"

    [[ -e "$target" ]] || return 0
    install -m 0755 "$target" "${target}.backup-${stamp}"
    ok "Backup created: ${target}.backup-${stamp}"
}

mkdir -p "$INSTALL_DIR" "${INSTALL_DIR}/cert_files"

MANAGER_TEMP="${TEMP_DIR}/${MANAGER_SOURCE}"
CORE_TEMP="${TEMP_DIR}/${CORE_SOURCE}"
STAMP="$(date +%Y%m%d-%H%M%S)"

printf '\nDownloading Backhaul v2 manager...\n'
download_repo_file "$MANAGER_SOURCE" "$MANAGER_TEMP"
sed -i 's/\r$//' "$MANAGER_TEMP"

MANAGER_VERSION="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "$MANAGER_TEMP" | head -n1)"
if [[ "$MANAGER_VERSION" != "$EXPECTED_MANAGER_VERSION" ]]; then
    error "Wrong manager version downloaded: ${MANAGER_VERSION:-unknown}"
    exit 1
fi

MANAGER_SHA256="$(sha256sum "$MANAGER_TEMP" | awk '{print $1}')"
if [[ "$MANAGER_SHA256" != "$EXPECTED_MANAGER_SHA256" ]]; then
    error "Manager checksum mismatch."
    error "Expected: $EXPECTED_MANAGER_SHA256"
    error "Received: $MANAGER_SHA256"
    exit 1
fi

printf '\nDownloading Backhaul v2 core...\n'
download_repo_file "$CORE_SOURCE" "$CORE_TEMP"

CORE_MAGIC="$(od -An -t x1 -N4 "$CORE_TEMP" | tr -d ' \n')"
if [[ "$CORE_MAGIC" != "7f454c46" ]]; then
    error "The downloaded core is not a valid ELF binary."
    exit 1
fi

chmod 0755 "$CORE_TEMP"
CORE_VERSION="$("$CORE_TEMP" -v 2>/dev/null || true)"
if [[ "$CORE_VERSION" != v2.* ]]; then
    error "The downloaded binary is not a valid Backhaul v2 core."
    exit 1
fi

if [[ ! -e "$MANAGER_PATH" ]] || ! cmp -s "$MANAGER_TEMP" "$MANAGER_PATH"; then
    backup_existing "$MANAGER_PATH" "$STAMP"
    install -m 0755 "$MANAGER_TEMP" "$MANAGER_PATH"
fi

if [[ ! -e "$CORE_PATH" ]] || ! cmp -s "$CORE_TEMP" "$CORE_PATH"; then
    backup_existing "$CORE_PATH" "$STAMP"
    install -m 0755 "$CORE_TEMP" "$CORE_PATH"
fi

{
    printf 'net.ipv4.ip_forward=1\n'
    printf 'net.ipv6.conf.all.forwarding=1\n'
    printf 'net.ipv4.conf.all.rp_filter=0\n'
    printf 'net.ipv4.conf.default.rp_filter=0\n'
} > "$SYSCTL_FILE"
sysctl -p "$SYSCTL_FILE" >/dev/null

ok "Backhaul Manager: ${EXPECTED_MANAGER_VERSION}"
ok "Backhaul Core: ${CORE_VERSION}"
ok "Installed at: ${INSTALL_DIR}"
ok "iptables and kernel forwarding are ready."

if [[ "${1:-}" == "--no-run" ]]; then
    printf '\nRun the manager with:\n%s\n' "$MANAGER_PATH"
    exit 0
fi

printf '\nOpening Backhaul v2 Manager...\n\n'
exec "$MANAGER_PATH"
