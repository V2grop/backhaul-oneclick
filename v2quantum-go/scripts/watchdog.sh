#!/usr/bin/env bash
set -Eeuo pipefail

INSTANCE="${1:-}"
BIN="${V2QUANTUM_BIN:-/usr/local/bin/v2quantum}"
CONFIG_DIR="${V2QUANTUM_CONFIG_DIR:-/etc/v2quantum}"
SYSTEMCTL="${V2QUANTUM_SYSTEMCTL:-systemctl}"
LOGGER="${V2QUANTUM_LOGGER:-logger}"
THRESHOLD="${V2QUANTUM_WATCHDOG_THRESHOLD:-3}"
RUN_DIR="${V2QUANTUM_RUN_DIR:-/run}"

if [[ ! "$INSTANCE" =~ ^[-A-Za-z0-9._]+$ ]]; then
  echo "Invalid instance name." >&2
  exit 2
fi
if [[ ! "$THRESHOLD" =~ ^[1-9][0-9]*$ ]] || (( THRESHOLD > 20 )); then
  echo "Invalid watchdog threshold." >&2
  exit 2
fi

CONFIG="$CONFIG_DIR/$INSTANCE.json"
STATE="$RUN_DIR/v2quantum-watchdog-$INSTANCE.failures"

if [[ ! -x "$BIN" || ! -r "$CONFIG" ]]; then
  exit 0
fi
install -d -m755 "$RUN_DIR"

if "$BIN" healthcheck -config "$CONFIG" -timeout 5s >/dev/null 2>&1; then
  printf '0\n' >"$STATE"
  exit 0
fi

COUNT="$(cat "$STATE" 2>/dev/null || printf '0')"
[[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
COUNT=$((COUNT + 1))
printf '%s\n' "$COUNT" >"$STATE"

if (( COUNT < THRESHOLD )); then
  exit 0
fi

"$LOGGER" -t v2quantum-watchdog \
  "Restarting v2quantum@$INSTANCE after $COUNT consecutive failed health checks"
"$SYSTEMCTL" restart "v2quantum@$INSTANCE.service"
printf '0\n' >"$STATE"
