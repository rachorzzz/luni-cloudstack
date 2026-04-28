#!/usr/bin/env bash
# =============================================================================
# create-project.sh
#
# Creates a fully operational OpenStack project: user, network, router,
# security groups, quotas, and an openrc file ready to deploy VMs.
#
# Usage:
#   bash /root/create-project.sh --project <name> [options]
#
# Options:
#   --project   <name>         Project name (required)
#   --user      <name>         Username (default: <project>-user)
#   --password  <pass>         User password (default: auto-generated)
#   --subnet    <cidr>         Private subnet CIDR (default: 10.0.0.0/24)
#   --dns       <ip>           DNS server for subnet (default: 1.1.1.1)
#   --quotas                   Set generous default quotas (on by default)
#   --no-quotas                Skip quota configuration
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
PROJECT=""
USERNAME=""
PASSWORD=""
SUBNET_CIDR="10.0.0.0/24"
DNS="1.1.1.1"
SET_QUOTAS=true

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)   PROJECT="$2";     shift 2 ;;
    --user)      USERNAME="$2";    shift 2 ;;
    --password)  PASSWORD="$2";    shift 2 ;;
    --subnet)    SUBNET_CIDR="$2"; shift 2 ;;
    --dns)       DNS="$2";         shift 2 ;;
    --no-quotas) SET_QUOTAS=false; shift ;;
    --quotas)    SET_QUOTAS=true;  shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$PROJECT" ]] || die "Usage: $0 --project <name> [--user <name>] [--password <pass>] [--subnet <cidr>]"
[[ $EUID -eq 0 ]]   || die "Must be run as root"

USERNAME="${USERNAME:-${PROJECT}-user}"
PASSWORD="${PASSWORD:-$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)}"

OPENRC=/etc/kolla/admin-openrc.sh
[[ -f "$OPENRC" ]] || die "$OPENRC not found — run setup-openstack.sh first"
source "$OPENRC"

NETWORK_NAME="${PROJECT}-net"
SUBNET_NAME="${PROJECT}-subnet"
ROUTER_NAME="${PROJECT}-router"
SECGROUP_NAME="default"
GATEWAY_IP="${SUBNET_CIDR%.*}.1"
OPENRC_OUT="/root/${PROJECT}-openrc.sh"

banner "Creating project: $PROJECT"

# ── Project ───────────────────────────────────────────────────────────────────
log "Creating project '$PROJECT'..."
if openstack project show "$PROJECT" &>/dev/null; then
  warn "Project '$PROJECT' already exists — skipping"
else
  openstack project create \
    --description "Project $PROJECT" \
    --enable \
    "$PROJECT"
  ok "Project '$PROJECT' created"
fi

PROJECT_ID=$(openstack project show -f value -c id "$PROJECT")

# ── User ──────────────────────────────────────────────────────────────────────
log "Creating user '$USERNAME'..."
if openstack user show "$USERNAME" &>/dev/null; then
  warn "User '$USERNAME' already exists — skipping"
else
  openstack user create \
    --project "$PROJECT" \
    --password "$PASSWORD" \
    --enable \
    "$USERNAME"
  ok "User '$USERNAME' created"
fi

# ── Roles ─────────────────────────────────────────────────────────────────────
log "Assigning roles..."
openstack role add --project "$PROJECT" --user "$USERNAME" member  2>/dev/null || warn "Role 'member' already assigned"
openstack role add --project "$PROJECT" --user "$USERNAME" reader  2>/dev/null || warn "Role 'reader' already assigned"
ok "Roles assigned"

# ── Network ───────────────────────────────────────────────────────────────────
banner "Networking"

log "Creating private network '$NETWORK_NAME'..."
if openstack network show "$NETWORK_NAME" &>/dev/null; then
  warn "Network '$NETWORK_NAME' already exists — skipping"
else
  openstack network create \
    --project "$PROJECT" \
    --enable \
    "$NETWORK_NAME"
  ok "Network '$NETWORK_NAME' created"
fi

log "Creating subnet '$SUBNET_NAME' ($SUBNET_CIDR)..."
if openstack subnet show "$SUBNET_NAME" &>/dev/null; then
  warn "Subnet '$SUBNET_NAME' already exists — skipping"
else
  openstack subnet create \
    --project "$PROJECT" \
    --network "$NETWORK_NAME" \
    --subnet-range "$SUBNET_CIDR" \
    --gateway "$GATEWAY_IP" \
    --dns-nameserver "$DNS" \
    --ip-version 4 \
    "$SUBNET_NAME"
  ok "Subnet '$SUBNET_NAME' created ($SUBNET_CIDR, gw $GATEWAY_IP)"
fi

# ── Router ────────────────────────────────────────────────────────────────────
log "Creating router '$ROUTER_NAME'..."
if openstack router show "$ROUTER_NAME" &>/dev/null; then
  warn "Router '$ROUTER_NAME' already exists — skipping"
else
  openstack router create \
    --project "$PROJECT" \
    "$ROUTER_NAME"

  openstack router set \
    --external-gateway external \
    "$ROUTER_NAME"

  openstack router add subnet \
    "$ROUTER_NAME" \
    "$SUBNET_NAME"

  ok "Router '$ROUTER_NAME' created with external gateway and subnet attached"
fi

# ── Security group ────────────────────────────────────────────────────────────
banner "Security groups"

# Get the default security group for this project
DEFAULT_SG_ID=$(openstack security group list \
  --project "$PROJECT" \
  -f value -c ID -c Name | grep " default$" | awk '{print $1}' || true)

if [[ -z "$DEFAULT_SG_ID" ]]; then
  warn "Could not find default security group for project — skipping sg rules"
else
  log "Configuring default security group ($DEFAULT_SG_ID)..."

  # Allow ICMP in
  openstack security group rule create \
    --protocol icmp \
    --ingress \
    --remote-ip 0.0.0.0/0 \
    "$DEFAULT_SG_ID" &>/dev/null \
    && ok "ICMP ingress allowed" \
    || warn "ICMP ingress rule already exists"

  # Allow SSH in
  openstack security group rule create \
    --protocol tcp \
    --dst-port 22 \
    --ingress \
    --remote-ip 0.0.0.0/0 \
    "$DEFAULT_SG_ID" &>/dev/null \
    && ok "SSH (22) ingress allowed" \
    || warn "SSH ingress rule already exists"

  # Allow all internal traffic
  openstack security group rule create \
    --protocol any \
    --ingress \
    --remote-group "$DEFAULT_SG_ID" \
    "$DEFAULT_SG_ID" &>/dev/null \
    && ok "Intra-group traffic allowed" \
    || warn "Intra-group rule already exists"
fi

# ── Quotas ────────────────────────────────────────────────────────────────────
if [[ "$SET_QUOTAS" == "true" ]]; then
  banner "Quotas"
  log "Setting quotas for project '$PROJECT'..."
  openstack quota set \
    --instances 50 \
    --cores 200 \
    --ram 409600 \
    --floating-ips 50 \
    --networks 10 \
    --subnets 10 \
    --routers 10 \
    --secgroups 20 \
    --secgroup-rules 200 \
    --ports 200 \
    "$PROJECT"
  ok "Quotas set"
fi

# ── openrc ────────────────────────────────────────────────────────────────────
banner "openrc"

log "Writing $OPENRC_OUT..."
cat > "$OPENRC_OUT" <<EOF
# openrc for project: $PROJECT
# User: $USERNAME
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

export OS_AUTH_URL=http://172.16.102.1:5000/v3
export OS_PROJECT_NAME="$PROJECT"
export OS_USERNAME="$USERNAME"
export OS_PASSWORD="$PASSWORD"
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
chmod 600 "$OPENRC_OUT"
ok "Written to $OPENRC_OUT"

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Done — $PROJECT"

echo ""
echo -e "  ${BLD}Project:${NC}   $PROJECT"
echo -e "  ${BLD}User:${NC}      $USERNAME"
echo -e "  ${BLD}Password:${NC}  $PASSWORD"
echo -e "  ${BLD}Network:${NC}   $NETWORK_NAME ($SUBNET_CIDR)"
echo -e "  ${BLD}Router:${NC}    $ROUTER_NAME → external"
echo -e "  ${BLD}openrc:${NC}    $OPENRC_OUT"
echo ""
echo -e "  To use:  ${BLD}source $OPENRC_OUT${NC}"
echo ""
