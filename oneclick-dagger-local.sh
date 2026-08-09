#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# This adapter never downloads or redistributes Dagger. It verifies a bundle
# already supplied by the server owner, then runs that bundle's original
# setup.sh without modifying it.
SCRIPT_VERSION="1.0.0"
DEFAULT_SETUP_SHA256="1f8893c74381bc84b73bdc1f68dadc2f8f39c1ce5b66402d71f77f5394535ad3"
DEFAULT_BINARY_SHA256="ac19385f703c9db5bf3bb50c66fe874f53478d307f31f3fc6defc74c49ffddbc"

SETUP_PATH="${DAGGER_SETUP_PATH:-}"
BINARY_PATH="${DAGGER_BINARY_PATH:-}"
EXPECTED_SETUP_SHA256="${DAGGER_EXPECTED_SETUP_SHA256:-$DEFAULT_SETUP_SHA256}"
EXPECTED_BINARY_SHA256="${DAGGER_EXPECTED_BINARY_SHA256:-$DEFAULT_BINARY_SHA256}"
INSTALLED_BINARY="${DAGGER_INSTALLED_BINARY:-/usr/local/bin/DaggerConnect}"
SKIP_ROOT_CHECK="${DAGGER_LOCAL_SKIP_ROOT_CHECK:-0}"
AUTO_FEED_BINARY="${DAGGER_AUTO_FEED_BINARY:-1}"
ASSUME_YES=false
CHECK_ONLY=false
TMP_DIR=""

green=$'\033[0;32m'
yellow=$'\033[1;33m'
red=$'\033[0;31m'
reset=$'\033[0m'

ok() { printf '%s[OK]%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$yellow" "$reset" "$*"; }
die() { printf '%s[ERROR]%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/dagger-local.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Dagger External/Local Adapter

Usage:
  oneclick-dagger-local.sh [options]

Options:
  --setup PATH       Local original setup.sh path
  --binary PATH      Local Dagger binary path
  --check-only       Verify both files and exit without root or execution
  -y, --yes          Skip the final execution confirmation
  -h, --help         Show this help
  --version          Show adapter version

Environment overrides:
  DAGGER_SETUP_PATH
  DAGGER_BINARY_PATH
  DAGGER_EXPECTED_SETUP_SHA256
  DAGGER_EXPECTED_BINARY_SHA256

The Dagger binary and setup script are not included in this repository. This
adapter copies verified local files to a private temporary directory and runs
the setup copy unchanged. Dagger remains a separate third-party engine.
EOF
}

confirm() {
  local prompt="$1" answer
  [[ "$ASSUME_YES" == true ]] && return 0
  printf '%s [y/N]: ' "$prompt" >&2
  IFS= read -r answer
  answer="${answer,,}"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

prompt_path() {
  local label="$1" value=""
  while [[ -z "$value" ]]; do
    printf '%s: ' "$label" >&2
    IFS= read -r value
    value="${value%\"}"
    value="${value#\"}"
  done
  printf '%s' "$value"
}

valid_sha256() {
  [[ "$1" =~ ^[[:xdigit:]]{64}$ ]]
}

verify_file() {
  local path="$1" expected="${2,,}" label="$3" actual
  [[ -f "$path" && -r "$path" ]] || die "$label is not a readable regular file: $path"
  actual="$(sha256sum -- "$path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    printf '%s[ERROR]%s %s checksum mismatch.\n' "$red" "$reset" "$label" >&2
    printf 'Expected: %s\nActual:   %s\n' "$expected" "$actual" >&2
    exit 1
  }
  ok "$label checksum verified: $actual"
}

while (( $# > 0 )); do
  case "$1" in
    --setup)
      (( $# >= 2 )) || die "--setup requires a path."
      SETUP_PATH="$2"
      shift
      ;;
    --setup=*) SETUP_PATH="${1#*=}" ;;
    --binary)
      (( $# >= 2 )) || die "--binary requires a path."
      BINARY_PATH="$2"
      shift
      ;;
    --binary=*) BINARY_PATH="${1#*=}" ;;
    --check-only) CHECK_ONLY=true ;;
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "dagger-local-adapter $SCRIPT_VERSION"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."
valid_sha256 "$EXPECTED_SETUP_SHA256" || die "Invalid expected setup SHA256."
valid_sha256 "$EXPECTED_BINARY_SHA256" || die "Invalid expected binary SHA256."

[[ -n "$SETUP_PATH" ]] || SETUP_PATH="$(prompt_path "Local original setup.sh path")"
[[ -n "$BINARY_PATH" ]] || BINARY_PATH="$(prompt_path "Local Dagger binary path")"
SETUP_PATH="$(readlink -f -- "$SETUP_PATH" 2>/dev/null || printf '%s' "$SETUP_PATH")"
BINARY_PATH="$(readlink -f -- "$BINARY_PATH" 2>/dev/null || printf '%s' "$BINARY_PATH")"

verify_file "$SETUP_PATH" "$EXPECTED_SETUP_SHA256" "Dagger setup.sh"
verify_file "$BINARY_PATH" "$EXPECTED_BINARY_SHA256" "Dagger binary"

if [[ "$CHECK_ONLY" == true ]]; then
  ok "Local Dagger bundle is verified. Nothing was installed or executed."
  exit 0
fi

if [[ "$SKIP_ROOT_CHECK" != "1" && ${EUID:-$(id -u)} -ne 0 ]]; then
  die "Run as root: sudo -i"
fi

warn "This is a third-party engine and is not part of Backhaul or V2Quantum."
warn "The original setup's System Optimizer changes global sysctl/qdisc settings."
warn "Do not select that optimizer if other tunnel engines must remain unaffected."
confirm "Run the verified original Dagger setup now?" || {
  echo "Cancelled."
  exit 0
}

TMP_DIR="$(mktemp -d -t dagger-local.XXXXXX)"
install -m700 -- "$SETUP_PATH" "$TMP_DIR/setup.sh"
install -m700 -- "$BINARY_PATH" "$TMP_DIR/DaggerConnect3.2.patched"
verify_file "$TMP_DIR/setup.sh" "$EXPECTED_SETUP_SHA256" "Staged setup.sh"
verify_file "$TMP_DIR/DaggerConnect3.2.patched" "$EXPECTED_BINARY_SHA256" "Staged Dagger binary"

export DAGGER_VERIFIED_BINARY_PATH="$TMP_DIR/DaggerConnect3.2.patched"
if [[ "$AUTO_FEED_BINARY" == "1" && ! -f "$INSTALLED_BINARY" ]]; then
  ok "The verified binary path will be supplied automatically to the original setup."
  set +e
  { printf '%s\n' "$DAGGER_VERIFIED_BINARY_PATH"; cat; } | bash "$TMP_DIR/setup.sh"
  setup_status="${PIPESTATUS[1]}"
  set -e
  exit "$setup_status"
fi

bash "$TMP_DIR/setup.sh"
