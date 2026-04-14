# WireGuard Full Mesh — CloudStack Management Network

Deploys a WireGuard full mesh across 5 nodes using `172.16.100.0/24`.
Tailscale IPs are used as WireGuard endpoints so Network1 nodes
(not reachable from the internet) can still form direct tunnels.

## Node map

| Host     | Tailscale IP      | WireGuard IP   | Location  |
|----------|-------------------|----------------|-----------|
| hp-01    | 100.93.75.19      | 172.16.100.1   | Network1  |
| hp-02    | 100.124.102.103   | 172.16.100.2   | Network1  |
| main-hp  | 100.68.102.106    | 172.16.100.3   | Network1  |
| main-1   | 100.117.99.12     | 172.16.100.4   | Hetzner   |
| main-2   | 100.99.132.72     | 172.16.100.5   | Hetzner   |

## Prerequisites

- Ansible >= 2.14 on your control machine
- `community.general` collection: `ansible-galaxy collection install community.general`
- SSH access to all hosts via Tailscale IPs (already in `ansible.cfg`)
- WireGuard package available (`wireguard` on Ubuntu)

## Usage

### Check interface/port availability first
```bash
# On each host — see what wg interfaces already exist
ansible wireguard_mesh -m shell -a "ip link show | grep wg"

# Check which ports are in use
ansible wireguard_mesh -m shell -a "ss -ulnp | grep -E '518'"
```

Adjust `wg_interface` and `wg_port` in `group_vars/wireguard_mesh.yml` if needed.

### Deploy
```bash
ansible-playbook site.yml
```

The playbook runs `serial: 1` on first run so public keys are collected
before peer configs are rendered. Subsequent runs are idempotent and
can run in parallel (remove `serial: 1` from `site.yml` if desired).

### Verify manually
```bash
# On any host
wg show wg1

# Ping the full mesh from one node
for ip in 172.16.100.{1..5}; do ping -c1 -W1 $ip && echo "$ip OK" || echo "$ip FAIL"; done
```

### Teardown
```bash
ansible wireguard_mesh -m systemd -a "name=wg-quick@wg1 state=stopped enabled=false" --become
ansible wireguard_mesh -m file -a "path=/etc/wireguard/wg1.conf state=absent" --become
```

## Notes

- `PersistentKeepalive = 25` is set on all peers to maintain NAT state
  for the Network1 nodes that can't accept inbound connections
- Private keys are generated on each host and never leave the node
- The playbook is fully idempotent — re-running won't rotate keys
