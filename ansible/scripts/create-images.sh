#!/usr/bin/env bash
# =============================================================================
# create-images.sh
#
# Downloads and uploads standard cloud images to Glance.
# Idempotent — skips images that already exist by name.
#
# Usage:
#   bash /root/create-images.sh [--images debian,ubuntu24,rocky9,rocky10]
#
# Options:
#   --images  <list>   Comma-separated list of images to upload (default: all)
#                      Valid values: debian, ubuntu24, rocky9, rocky10
#   --tmp     <dir>    Temporary download directory (default: /tmp/images)
#   --keep             Keep downloaded files after upload
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
BLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLU}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GRN}[OK]${NC} $*"; }
warn() { echo -e "${YLW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

banner() {
  echo ""
  echo -e "${BLD}${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLD}${BLU}  $*${NC}"
  echo -e "${BLD}${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── Defaults ──────────────────────────────────────────────────────────────────
IMAGES_ARG="debian,ubuntu24,rocky9,rocky10"
TMP_DIR="/tmp/images"
KEEP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --images) IMAGES_ARG="$2"; shift 2 ;;
    --tmp)    TMP_DIR="$2";    shift 2 ;;
    --keep)   KEEP=true;       shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Must be run as root"

OPENRC=/etc/kolla/admin-openrc.sh
[[ -f "$OPENRC" ]] || die "$OPENRC not found — run setup-openstack.sh first"
source "$OPENRC"

mkdir -p "$TMP_DIR"

# ── Image catalogue ───────────────────────────────────────────────────────────
# Format per image:  name | url | filename | disk_format | min_disk | min_ram | os_distro | os_version

declare -A IMAGE_NAME
declare -A IMAGE_URL
declare -A IMAGE_FILE
declare -A IMAGE_FORMAT
declare -A IMAGE_MIN_DISK
declare -A IMAGE_MIN_RAM
declare -A IMAGE_OS_DISTRO
declare -A IMAGE_OS_VERSION

IMAGE_NAME[debian]="debian-12"
IMAGE_URL[debian]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
IMAGE_FILE[debian]="debian-12-genericcloud-amd64.qcow2"
IMAGE_FORMAT[debian]="qcow2"
IMAGE_MIN_DISK[debian]="8"
IMAGE_MIN_RAM[debian]="512"
IMAGE_OS_DISTRO[debian]="debian"
IMAGE_OS_VERSION[debian]="12"

IMAGE_NAME[ubuntu24]="ubuntu-24.04"
IMAGE_URL[ubuntu24]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_FILE[ubuntu24]="noble-server-cloudimg-amd64.img"
IMAGE_FORMAT[ubuntu24]="qcow2"
IMAGE_MIN_DISK[ubuntu24]="8"
IMAGE_MIN_RAM[ubuntu24]="512"
IMAGE_OS_DISTRO[ubuntu24]="ubuntu"
IMAGE_OS_VERSION[ubuntu24]="24.04"

IMAGE_NAME[rocky9]="rocky-9"
IMAGE_URL[rocky9]="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
IMAGE_FILE[rocky9]="Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
IMAGE_FORMAT[rocky9]="qcow2"
IMAGE_MIN_DISK[rocky9]="10"
IMAGE_MIN_RAM[rocky9]="512"
IMAGE_OS_DISTRO[rocky9]="rocky"
IMAGE_OS_VERSION[rocky9]="9"

IMAGE_NAME[rocky10]="rocky-10"
IMAGE_URL[rocky10]="https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
IMAGE_FILE[rocky10]="Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
IMAGE_FORMAT[rocky10]="qcow2"
IMAGE_MIN_DISK[rocky10]="10"
IMAGE_MIN_RAM[rocky10]="512"
IMAGE_OS_DISTRO[rocky10]="rocky"
IMAGE_OS_VERSION[rocky10]="10"

# ── Upload function ───────────────────────────────────────────────────────────
upload_image() {
  local key="$1"
  local name="${IMAGE_NAME[$key]}"
  local url="${IMAGE_URL[$key]}"
  local file="$TMP_DIR/${IMAGE_FILE[$key]}"
  local fmt="${IMAGE_FORMAT[$key]}"
  local min_disk="${IMAGE_MIN_DISK[$key]}"
  local min_ram="${IMAGE_MIN_RAM[$key]}"
  local os_distro="${IMAGE_OS_DISTRO[$key]}"
  local os_version="${IMAGE_OS_VERSION[$key]}"

  banner "$name"

  if openstack image show "$name" &>/dev/null; then
    warn "Image '$name' already exists — skipping"
    return
  fi

  if [[ -f "$file" ]]; then
    log "Found cached download at $file — skipping download"
  else
    log "Downloading $name..."
    curl -fsSL --progress-bar -o "$file" "$url"
    ok "Downloaded $(du -sh "$file" | cut -f1)"
  fi

  log "Uploading '$name' to Glance..."
  openstack image create \
    --disk-format   "$fmt" \
    --container-format bare \
    --min-disk      "$min_disk" \
    --min-ram       "$min_ram" \
    --property      os_distro="$os_distro" \
    --property      os_version="$os_version" \
    --property      hw_disk_bus=virtio \
    --property      hw_vif_model=virtio \
    --public \
    --file          "$file" \
    "$name"

  ok "Image '$name' uploaded"

  if [[ "$KEEP" == "false" ]]; then
    rm -f "$file"
    log "Removed local file $file"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
IFS=',' read -ra SELECTED <<< "$IMAGES_ARG"

for key in "${SELECTED[@]}"; do
  key="${key// /}"
  [[ -n "${IMAGE_NAME[$key]+x}" ]] || die "Unknown image '$key'. Valid: debian, ubuntu24, rocky9, rocky10"
  upload_image "$key"
done

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Images"
openstack image list
