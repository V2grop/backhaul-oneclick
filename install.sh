#!/usr/bin/env bash
set -Eeuo pipefail

# فقط این مقدار را یک‌بار با نام کاربری و نام ریپوی خودت عوض کن.
GITHUB_REPO="V2grop/backhaul-oneclick"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/${BRANCH}"

BASE_DIR="/root/backhaul-core"
BIN_PATH="${BASE_DIR}/backhaul_premium"
INSTALLER_PATH="/root/backhaul_easy_installer.sh"

# هش فایل‌هایی که در این بسته تحویل شده‌اند.
BIN_SHA256="a57a8e0c4216e7971718104b5c9744a056d110411179fff789933caff0c53428"
INSTALLER_SHA256="2d958092a05501a924e3d8eb7fb3498fea8db8454388287316867d096563dd8b"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "این نصب‌کننده باید با root اجرا شود: sudo -i"
[[ "$GITHUB_REPO" != "YOUR_GITHUB_USERNAME/YOUR_REPOSITORY" ]] || \
  fail "داخل install.sh مقدار GITHUB_REPO را با username/repository خودت عوض کن."
command -v curl >/dev/null 2>&1 || fail "curl نصب نیست. روی Ubuntu/Debian: apt update && apt install -y curl"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum روی سیستم پیدا نشد."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

printf '[1/4] Downloading core...\n'
curl -fL --retry 3 --connect-timeout 15 \
  -o "$TMP_DIR/backhaul_premium" \
  "$RAW_BASE/backhaul_premium"

printf '[2/4] Downloading installer...\n'
curl -fL --retry 3 --connect-timeout 15 \
  -o "$TMP_DIR/backhaul_easy_installer.sh" \
  "$RAW_BASE/backhaul_easy_installer.sh"

printf '[3/4] Verifying checksums...\n'
echo "${BIN_SHA256}  $TMP_DIR/backhaul_premium" | sha256sum -c -
echo "${INSTALLER_SHA256}  $TMP_DIR/backhaul_easy_installer.sh" | sha256sum -c -

printf '[4/4] Installing files...\n'
mkdir -p "$BASE_DIR"
install -o root -g root -m 700 "$TMP_DIR/backhaul_premium" "$BIN_PATH"
install -o root -g root -m 700 "$TMP_DIR/backhaul_easy_installer.sh" "$INSTALLER_PATH"

printf '\nFiles installed successfully.\n'
printf 'Core: %s\n' "$BIN_PATH"
printf 'Installer: %s\n\n' "$INSTALLER_PATH"

exec bash "$INSTALLER_PATH" "$@"
