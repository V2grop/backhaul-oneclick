#!/usr/bin/env bash
# Backhaul core switcher for V2grop/backhaul-oneclick.
# It downloads a selected core but always installs it as backhaul_premium,
# preserving the existing TOML configs, certificates and service units.

set -Eeuo pipefail

REPO="${REPO:-V2grop/backhaul-oneclick}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/root/backhaul-core}"
REMOTE_CORE_NAME="${REMOTE_CORE_NAME:-backhaul_premium_v2}"
ACTIVE_CORE_NAME="${ACTIVE_CORE_NAME:-backhaul_premium}"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${REMOTE_CORE_NAME}"
CORE_PATH="${INSTALL_DIR}/${ACTIVE_CORE_NAME}"
TMP_PATH="${INSTALL_DIR}/.${ACTIVE_CORE_NAME}.new.$$"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_PATH="${CORE_PATH}.backup-${STAMP}"

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

cleanup() {
  rm -f "$TMP_PATH"
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die "Run this script as root (use sudo -i first)."
command -v curl >/dev/null 2>&1 || die "curl is required. Install it with: apt update && apt install -y curl"
[[ -d "$INSTALL_DIR" ]] || die "Directory not found: $INSTALL_DIR"

echo "Downloading core: ${REPO}/${BRANCH}/${REMOTE_CORE_NAME}"
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 \
  "${RAW_URL}?cb=$(date +%s)" -o "$TMP_PATH"

[[ -s "$TMP_PATH" ]] || die "Downloaded file is empty."

# GitHub's 404/HTML response must never replace the working binary.
if head -c 512 "$TMP_PATH" | LC_ALL=C grep -Eqi '<!doctype html|404: not found|<html'; then
  die "GitHub did not return a binary. Upload the selected core with the exact name '${REMOTE_CORE_NAME}' to the repository root, then commit it."
fi

chmod 700 "$TMP_PATH"
if ! "$TMP_PATH" -v >/dev/null 2>&1; then
  die "The downloaded file could not run as a Backhaul core; the current core was not changed."
fi

if [[ -f "$CORE_PATH" ]]; then
  cp -a "$CORE_PATH" "$BACKUP_PATH"
  echo "Backup created: $BACKUP_PATH"
fi

mv -f "$TMP_PATH" "$CORE_PATH"
chmod 700 "$CORE_PATH"
echo "Core updated successfully: $($CORE_PATH -v 2>/dev/null || true)"

systemctl daemon-reload
mapfile -t SERVICES < <(systemctl list-unit-files --type=service --no-legend 'backhaul-*.service' 2>/dev/null | awk '{print $1}')

if [[ "${#SERVICES[@]}" -eq 0 ]]; then
  echo "No Backhaul systemd service was found. The core was updated, but no service was restarted."
  echo "If needed, start your current config manually from: $INSTALL_DIR"
  exit 0
fi

for service in "${SERVICES[@]}"; do
  systemctl restart "$service"
  systemctl is-active --quiet "$service" || die "$service did not start. Restore with: cp -af '$BACKUP_PATH' '$CORE_PATH'"
  echo "Active: $service"
done

echo "Done. TOML files, tokens, port mappings, and cert_files were left unchanged."
