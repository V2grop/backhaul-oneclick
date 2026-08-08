#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

INSTALLER_VERSION="0.3.0"
OVERRIDE_REPO="${V2QUANTUM_REPO:-}"
OVERRIDE_REF="${V2QUANTUM_REF:-}"
OVERRIDE_VERSION="${V2QUANTUM_VERSION:-}"
if [[ -r /etc/v2quantum/install.env ]]; then
  # shellcheck disable=SC1091
  source /etc/v2quantum/install.env
fi
[[ -n "$OVERRIDE_REPO" ]] && V2QUANTUM_REPO="$OVERRIDE_REPO"
[[ -n "$OVERRIDE_REF" ]] && V2QUANTUM_REF="$OVERRIDE_REF"
[[ -n "$OVERRIDE_VERSION" ]] && V2QUANTUM_VERSION="$OVERRIDE_VERSION"
REPO="${V2QUANTUM_REPO:-V2grop/backhaul-oneclick}"
REF="${V2QUANTUM_REF:-main}"
CORE_VERSION="${V2QUANTUM_VERSION:-0.3.0}"
GO_VERSION="1.26.5"
ACTION="install"
OPEN_MENU=true
ASSUME_YES=false
PURGE=false
FORCE_SOURCE="${V2QUANTUM_FORCE_SOURCE:-0}"
ALLOW_SOURCE="${V2QUANTUM_ALLOW_SOURCE_BUILD:-0}"
[[ "$FORCE_SOURCE" == "1" ]] && ALLOW_SOURCE=1

usage() {
  cat <<'EOF'
V2Quantum One-Click Installer

Usage:
  v2quantum-installer [--install|--update|--uninstall] [options]

Options:
  --no-menu       Do not open the manager after installation
  --source        Developer mode: build from the selected GitHub ref
  --release-only  Never download a Go toolchain or build on this server
  --purge         With --uninstall, also remove tunnel configuration
  -y, --yes       Accept uninstall confirmation
  -h, --help      Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --install) ACTION="install" ;;
    --update) ACTION="update"; OPEN_MENU=false ;;
    --uninstall) ACTION="uninstall"; OPEN_MENU=false ;;
    --no-menu) OPEN_MENU=false ;;
    --source) FORCE_SOURCE=1; ALLOW_SOURCE=1 ;;
    --release-only) FORCE_SOURCE=0; ALLOW_SOURCE=0 ;;
    --purge) PURGE=true ;;
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "v2quantum-installer $INSTALLER_VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if (( EUID != 0 )); then
  echo "Run this installer as root." >&2
  exit 1
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid V2QUANTUM_REPO." >&2
  exit 2
fi
if [[ ! "$REF" =~ ^[-A-Za-z0-9._/]+$ || "$REF" == /* || "$REF" == *..* ]]; then
  echo "Invalid V2QUANTUM_REF." >&2
  exit 2
fi

green=$'\033[0;32m'
yellow=$'\033[1;33m'
red=$'\033[0;31m'
reset=$'\033[0m'
ok() { printf '%s[OK]%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$yellow" "$reset" "$*"; }
die() { printf '%s[ERROR]%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

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

uninstall_all() {
  if ! confirm "Uninstall V2Quantum program files?"; then
    echo "Cancelled."
    return 0
  fi

  while IFS= read -r instance; do
    [[ -n "$instance" ]] || continue
    systemctl disable --now "v2quantum-watchdog@$instance.timer" 2>/dev/null || true
    systemctl disable --now "v2quantum@$instance.service" 2>/dev/null || true
  done < <(find /etc/v2quantum -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//')

  rm -f -- \
    /usr/local/bin/v2quantum \
    /usr/local/sbin/v2quantum-manager \
    /usr/local/sbin/v2quantum-installer \
    /usr/local/libexec/v2quantum-watchdog \
    /etc/systemd/system/v2quantum@.service \
    /etc/systemd/system/v2quantum-watchdog@.service \
    /etc/systemd/system/v2quantum-watchdog@.timer
  systemctl daemon-reload

  if [[ "$PURGE" == true && -d /etc/v2quantum ]]; then
    BACKUP="/var/lib/v2quantum/backups/purge-$(date +%Y%m%d-%H%M%S)"
    install -d -m700 "$BACKUP"
    cp -a -- /etc/v2quantum/. "$BACKUP/"
    find /etc/v2quantum -mindepth 1 -maxdepth 1 -type f -delete
    ok "Configuration backup: $BACKUP"
  fi
  ok "V2Quantum program files removed. Backhaul/WSMUX were not touched."
}

if [[ "$ACTION" == "uninstall" ]]; then
  uninstall_all
  exit 0
fi

install_dependencies() {
  local missing=false
  for command_name in curl tar sha256sum install awk sed grep mktemp systemctl ip; do
    command -v "$command_name" >/dev/null 2>&1 || missing=true
  done
  [[ "$missing" == false ]] && return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar coreutils iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates tar coreutils iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates tar coreutils iproute
  else
    die "Install curl, ca-certificates, tar, coreutils, iproute2 and systemd first."
  fi
}

install_dependencies

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    ARCH="amd64"
    GO_SHA256="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    GO_SHA256="fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49"
    ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

TMP_DIR="$(mktemp -d -t v2quantum-oneclick.XXXXXX)"
cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/v2quantum-oneclick.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

download() {
  local url="$1" destination="$2"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 --ipv4 \
    -o "$destination" "$url"
}

release_install() {
  local base="https://github.com/$REPO/releases/latest/download"
  local payload="$TMP_DIR/release"
  local selected="$payload/SHA256SUMS.selected"
  local asset
  local assets=(
    "v2quantum-linux-$ARCH"
    "v2quantum-manager"
    "v2quantum-installer"
    "v2quantum-watchdog"
    "v2quantum@.service"
    "v2quantum-watchdog@.service"
    "v2quantum-watchdog@.timer"
  )
  mkdir -p "$payload"
  download "$base/SHA256SUMS" "$payload/SHA256SUMS" || return 1
  : >"$selected"
  for asset in "${assets[@]}"; do
    local checksum_line
    download "$base/$asset" "$payload/$asset" || return 1
    checksum_line="$(grep -F "  $asset" "$payload/SHA256SUMS" | head -n1)"
    [[ -n "$checksum_line" ]] || return 1
    printf '%s\n' "$checksum_line" >>"$selected"
  done
  [[ "$(wc -l <"$selected")" -eq "${#assets[@]}" ]] || return 1
  (cd -- "$payload" && sha256sum -c SHA256SUMS.selected) || return 1
  chmod 755 "$payload/v2quantum-linux-$ARCH"
  local release_version
  release_version="$("$payload/v2quantum-linux-$ARCH" version 2>/dev/null || true)"
  if [[ "$release_version" != "v2quantum-go $CORE_VERSION" ]]; then
    warn "Latest release is ${release_version:-unusable}; this manager requires v2quantum-go $CORE_VERSION."
    return 1
  fi

  local backup="/var/lib/v2quantum/backups/release-$(date +%Y%m%d-%H%M%S)"
  local backup_created=false target
  for target in /usr/local/bin/v2quantum /usr/local/sbin/v2quantum-manager \
    /usr/local/sbin/v2quantum-installer /usr/local/libexec/v2quantum-watchdog \
    /etc/systemd/system/v2quantum@.service \
    /etc/systemd/system/v2quantum-watchdog@.service \
    /etc/systemd/system/v2quantum-watchdog@.timer; do
    if [[ -f "$target" ]]; then
      if [[ "$backup_created" == false ]]; then
        install -d -m700 "$backup"
        backup_created=true
      fi
      cp -a -- "$target" "$backup/$(basename -- "$target")"
    fi
  done

  install -Dm755 "$payload/v2quantum-linux-$ARCH" /usr/local/bin/v2quantum
  install -Dm755 "$payload/v2quantum-manager" /usr/local/sbin/v2quantum-manager
  install -Dm755 "$payload/v2quantum-installer" /usr/local/sbin/v2quantum-installer
  install -Dm755 "$payload/v2quantum-watchdog" /usr/local/libexec/v2quantum-watchdog
  install -Dm644 "$payload/v2quantum@.service" /etc/systemd/system/v2quantum@.service
  install -Dm644 "$payload/v2quantum-watchdog@.service" /etc/systemd/system/v2quantum-watchdog@.service
  install -Dm644 "$payload/v2quantum-watchdog@.timer" /etc/systemd/system/v2quantum-watchdog@.timer
  install -d -m750 /etc/v2quantum /var/lib/v2quantum/backups
  return 0
}

go_is_usable() {
  command -v go >/dev/null 2>&1 || return 1
  local version
  version="$(go env GOVERSION 2>/dev/null || true)"
  [[ "$version" =~ ^go([2-9]|1\.2[6-9]|1\.[3-9][0-9])([.].*)?$ ]]
}

source_install() {
  local archive="$TMP_DIR/source.tar.gz"
  local source="$TMP_DIR/source"
  local go_bin="" go_dir=""
  mkdir -p "$source"
  download "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" "$archive"
  tar -xzf "$archive" -C "$source" --strip-components=1
  [[ -f "$source/v2quantum-go/go.mod" ]] || die "V2Quantum source was not found in ref $REF."

  if go_is_usable; then
    go_bin="$(command -v go)"
  else
    warn "A temporary verified Go $GO_VERSION toolchain is required for this source build."
    local go_url verified=false
    local go_urls=()
    [[ -n "${V2QUANTUM_GO_URL:-}" ]] && go_urls+=("$V2QUANTUM_GO_URL")
    go_urls+=(
      "https://mirrors.aliyun.com/golang/go$GO_VERSION.linux-$ARCH.tar.gz"
      "https://golang.google.cn/dl/go$GO_VERSION.linux-$ARCH.tar.gz"
      "https://go.dev/dl/go$GO_VERSION.linux-$ARCH.tar.gz"
      "https://dl.google.com/go/go$GO_VERSION.linux-$ARCH.tar.gz"
      "https://storage.googleapis.com/golang/go$GO_VERSION.linux-$ARCH.tar.gz"
    )
    for go_url in "${go_urls[@]}"; do
      rm -f -- "$TMP_DIR/go.tar.gz"
      echo "Trying verified Go toolchain source: $go_url"
      if download "$go_url" "$TMP_DIR/go.tar.gz" && \
        printf '%s  %s\n' "$GO_SHA256" "$TMP_DIR/go.tar.gz" | sha256sum -c -; then
        verified=true
        break
      fi
      warn "This Go download source failed; trying the next verified source."
    done
    [[ "$verified" == true ]] || die "Could not download a verified Go $GO_VERSION toolchain. Use a published V2Quantum release or set V2QUANTUM_GO_URL to another authorized mirror."
    tar -xzf "$TMP_DIR/go.tar.gz" -C "$TMP_DIR"
    go_bin="$TMP_DIR/go/bin/go"
  fi
  go_dir="$(dirname -- "$go_bin")"
  PATH="$go_dir:$PATH" \
    V2QUANTUM_VERSION="$CORE_VERSION" \
    bash "$source/v2quantum-go/scripts/install.sh"
}

INSTALLED_FROM="source:$REF"
if [[ "$FORCE_SOURCE" != "1" && "$REF" == "main" ]]; then
  echo "Checking for a verified V2Quantum release..."
  if release_install; then
    INSTALLED_FROM="release:latest"
  elif [[ "$ALLOW_SOURCE" == "1" ]]; then
    warn "No complete release is available; using the explicitly enabled source build from ref $REF."
    source_install
  else
    die "No complete V2Quantum release is published yet. Normal server installation is release-only and will not download Go. The maintainer must publish a release; developers may opt in with --source."
  fi
elif [[ "$ALLOW_SOURCE" == "1" ]]; then
  source_install
else
  die "Ref $REF has no release asset. Source builds are disabled by default; use --source only for a temporary developer test."
fi

install -d -m750 /etc/v2quantum
{
  printf 'V2QUANTUM_REPO=%q\n' "$REPO"
  printf 'V2QUANTUM_REF=%q\n' "$REF"
  printf 'V2QUANTUM_VERSION=%q\n' "$CORE_VERSION"
  printf 'V2QUANTUM_INSTALLED_FROM=%q\n' "$INSTALLED_FROM"
} >/etc/v2quantum/install.env
chmod 640 /etc/v2quantum/install.env

systemctl daemon-reload
while IFS= read -r service; do
  [[ -n "$service" ]] || continue
  systemctl try-restart "$service" || true
done < <(systemctl list-units --type=service --state=active 'v2quantum@*.service' \
  --no-legend 2>/dev/null | awk '{print $1}')

ok "V2Quantum installed from $INSTALLED_FROM"
/usr/local/bin/v2quantum version
if [[ "$OPEN_MENU" == true ]]; then
  if [[ "${V2QUANTUM_MANAGER_MODE:-}" == "tun" ]]; then
    exec /usr/local/sbin/v2quantum-manager --tun
  fi
  exec /usr/local/sbin/v2quantum-manager
fi
