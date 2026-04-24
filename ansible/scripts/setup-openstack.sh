#!/usr/bin/env bash
# =============================================================================
# setup-openstack.sh
#
# Runs the full kolla-ansible deployment sequence and then does the one-time
# day-1 OpenStack setup: provider network, standard flavors, CirrOS image.
#
# Idempotent — safe to re-run after a failed or partial run.
# Must be run as root on controller-vm.
#
# Usage:
#   bash /root/setup-openstack.sh
#   bash /root/setup-openstack.sh --skip-kolla   # skip to day-1 setup only
# =============================================================================

set -euo pipefail

# ── CLI flags ──────────────────────────────────────────────────────────────────
SKIP_KOLLA=false
for arg in "$@"; do
  case "$arg" in
    --skip-kolla) SKIP_KOLLA=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

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

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Must be run as root"

KOLLA_INVENTORY=/etc/kolla/multinode
OPENRC=/etc/kolla/admin-openrc.sh

[[ -f "$KOLLA_INVENTORY" ]] || die "Kolla inventory not found at $KOLLA_INVENTORY — run 07-kolla-prep.yml first"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1 — kolla-ansible deployment
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$SKIP_KOLLA" == "true" ]]; then
  warn "--skip-kolla set — skipping bootstrap/prechecks/deploy/post-deploy"
else
  banner "Step 1/4 — Bootstrap servers"
  log "Installing Docker and kolla deps on all nodes..."
  kolla-ansible bootstrap-servers -i "$KOLLA_INVENTORY"
  ok "Bootstrap complete"

  banner "Step 2/4 — Prechecks"
  log "Validating configuration across all nodes..."
  kolla-ansible prechecks -i "$KOLLA_INVENTORY"
  ok "Prechecks passed"

  banner "Step 3/4 — Deploy OpenStack"
  log "Pulling images and starting services — this takes 20-40 minutes..."
  kolla-ansible deploy -i "$KOLLA_INVENTORY"
  ok "Deploy complete"

  banner "Step 4/4 — Post-deploy"
  log "Running DB migrations and writing admin-openrc.sh..."
  kolla-ansible post-deploy -i "$KOLLA_INVENTORY"
  ok "Post-deploy complete"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2 — Day-1 OpenStack setup
# ══════════════════════════════════════════════════════════════════════════════

banner "Day-1 OpenStack setup"

[[ -f "$OPENRC" ]] || die "$OPENRC not found — post-deploy must have failed"
# shellcheck source=/dev/null
source "$OPENRC"

# Verify Keystone is responding before doing anything
log "Verifying Keystone..."
openstack token issue -f value -c id > /dev/null || die "Keystone is not responding"
ok "Keystone OK"

# ── Provider / external network ───────────────────────────────────────────────
log "Checking external network..."
if openstack network show external &>/dev/null; then
  warn "Network 'external' already exists — skipping"
else
  log "Creating flat provider network 'external' (physnet1 → br-ex → dummy0)"
  openstack network create \
    --share \
    --external \
    --provider-physical-network physnet1 \
    --provider-network-type flat \
    external

  openstack subnet create \
    --network external \
    --subnet-range 192.168.200.0/24 \
    --no-dhcp \
    --gateway 192.168.200.1 \
    --allocation-pool start=192.168.200.100,end=192.168.200.200 \
    external-subnet

  ok "External network + subnet created (192.168.200.100-200)"
fi

# ── Standard flavors ──────────────────────────────────────────────────────────
log "Creating standard flavors..."

# name | ram (MB) | disk (GB) | vcpus | id
FLAVORS=(
  "m1.tiny   |  512 |  5  | 1 | 1"
  "m1.small  | 2048 | 20  | 1 | 2"
  "m1.medium | 4096 | 40  | 2 | 3"
  "m1.large  | 8192 | 80  | 4 | 4"
  "m1.xlarge |16384 | 160 | 8 | 5"
)

for entry in "${FLAVORS[@]}"; do
  IFS='|' read -r name ram disk vcpus id <<< "$entry"
  name="${name// /}"; ram="${ram// /}"; disk="${disk// /}"; vcpus="${vcpus// /}"; id="${id// /}"
  if openstack flavor show "$name" &>/dev/null; then
    warn "Flavor '$name' already exists — skipping"
  else
    openstack flavor create \
      --id    "$id" \
      --ram   "$ram" \
      --disk  "$disk" \
      --vcpus "$vcpus" \
      "$name"
    ok "Flavor $name created (${vcpus} vCPU, ${ram} MB RAM, ${disk} GB disk)"
  fi
done

# ── CirrOS image ──────────────────────────────────────────────────────────────
CIRROS_NAME="cirros-0.6.2"
CIRROS_URL="https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img"
CIRROS_TMP="/tmp/cirros-0.6.2-x86_64-disk.img"

log "Checking CirrOS image..."
if openstack image show "$CIRROS_NAME" &>/dev/null; then
  warn "Image '$CIRROS_NAME' already exists — skipping"
else
  log "Downloading CirrOS 0.6.2 (~15 MB)..."
  curl -fsSL --progress-bar -o "$CIRROS_TMP" "$CIRROS_URL"

  openstack image create \
    --disk-format qcow2 \
    --container-format bare \
    --public \
    --file "$CIRROS_TMP" \
    "$CIRROS_NAME"

  rm -f "$CIRROS_TMP"
  ok "CirrOS image uploaded"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════

banner "Deployment complete"

echo ""
echo -e "  ${BLD}Keystone API:${NC}  http://172.16.102.1:5000"
echo -e "  ${BLD}Horizon:${NC}       http://172.16.102.1"
echo -e "  ${BLD}Admin creds:${NC}   source /etc/kolla/admin-openrc.sh"
echo ""
echo -e "${BLD}Services:${NC}"
openstack service list

echo ""
echo -e "${BLD}Compute nodes:${NC}"
openstack compute service list

echo ""
echo -e "${BLD}Network agents:${NC}"
openstack network agent list

echo ""
echo -e "${BLD}Images:${NC}"
openstack image list

echo ""
echo -e "${BLD}Flavors:${NC}"
openstack flavor list

echo ""
ok "Ready. See /root/setup-openstack.sh --skip-kolla to re-run only the day-1 setup."
