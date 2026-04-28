#!/usr/bin/env bash
# =============================================================================
# admin-all-projects.sh
#
# Assigns the admin user the 'member' and 'admin' roles on every project,
# excluding built-in service projects (admin, service, Default).
#
# Usage:
#   bash /root/admin-all-projects.sh
# =============================================================================

set -euo pipefail

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

[[ $EUID -eq 0 ]] || die "Must be run as root"

OPENRC=/etc/kolla/admin-openrc.sh
[[ -f "$OPENRC" ]] || die "$OPENRC not found — run setup-openstack.sh first"
source "$OPENRC"

SKIP_PROJECTS="admin service Default"

banner "Assigning admin to all projects"

mapfile -t PROJECTS < <(openstack project list -f value -c Name)

for project in "${PROJECTS[@]}"; do
  if echo "$SKIP_PROJECTS" | grep -qw "$project"; then
    warn "Skipping built-in project '$project'"
    continue
  fi

  log "Project: $project"
  openstack role add --project "$project" --user admin admin  2>/dev/null \
    && ok "  admin role assigned" \
    || warn "  admin role already assigned"
  openstack role add --project "$project" --user admin member 2>/dev/null \
    && ok "  member role assigned" \
    || warn "  member role already assigned"
done

banner "Done"
openstack role assignment list --user admin --names
