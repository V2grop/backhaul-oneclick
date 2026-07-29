#!/usr/bin/env bash
# Activates the uploaded core named "backhaul_premium (1)" safely.
# Existing TOML configs, certificates and systemd unit files are preserved.

set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/root/backhaul-core}"
NEW_CORE="${NEW_CORE:-${INSTALL_DIR}/backhaul_premium (1)}"
ACTIVE_CORE="${ACTIVE_CORE:-${INSTALL_DIR}/backhaul_premium}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_CORE="${ACTIVE_CORE}.backup-${STAMP}"

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo -i"
[[ -d "$INSTALL_DIR" ]] || die "Directory not found: $INSTALL_DIR"
[[ -f "$NEW_CORE" ]] || die "New core not found: $NEW_CORE"
[[ -s "$NEW_CORE" ]] || die "New core is empty: $NEW_CORE"

chmod 700 "$NEW_CORE"
if ! "$NEW_CORE" -v >/dev/null 2>&1; then
  die "'backhaul_premium (1)' cannot run as a Backhaul core. Nothing was changed."
fi

if [[ -f "$ACTIVE_CORE" ]]; then
  cp -a "$ACTIVE_CORE" "$BACKUP_CORE"
  echo "Previous core backed up to: $BACKUP_CORE"
fi

# Copy rather than rename: the uploaded '(1)' file remains available for auditing.
install -m 700 "$NEW_CORE" "$ACTIVE_CORE"
echo "New core is active: $($ACTIVE_CORE -v 2>/dev/null || true)"

systemctl daemon-reload
mapfile -t SERVICES < <(systemctl list-unit-files --type=service --no-legend 'backhaul-*.service' 2>/dev/null | awk '{print $1}')

if [[ "${#SERVICES[@]}" -eq 0 ]]; then
  echo "No Backhaul systemd service was found. Core was replaced but no service was restarted."
  exit 0
fi

for service in "${SERVICES[@]}"; do
  systemctl restart "$service"
  if systemctl is-active --quiet "$service"; then
    echo "Active: $service"
  else
    cp -af "$BACKUP_CORE" "$ACTIVE_CORE"
    systemctl restart "$service" || true
    die "$service failed. Previous core was restored: $BACKUP_CORE"
  fi
done

echo "Done. All existing .toml files, port mappings and cert_files remain unchanged."
