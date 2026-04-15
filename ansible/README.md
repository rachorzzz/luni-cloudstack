# homelab-ansible

Ansible project for CloudStack homelab deployment across 5 nodes.
Covers WireGuard mesh networking and full CloudStack IaaS setup.

## Infrastructure

| Host    | Tailscale IP      | WireGuard IP   | Location | Role                          |
|---------|-------------------|----------------|----------|-------------------------------|
| hp-01   | 100.93.75.19      | 172.16.100.1   | Network1 | KVM agent — nfs-cluster       |
| hp-02   | 100.124.102.103   | 172.16.100.2   | Network1 | KVM agent — nfs-cluster       |
| main-hp | 100.68.102.106    | 172.16.100.3   | Network1 | Management + NFS + KVM agent  |
| main-1  | 100.117.99.12     | 172.16.100.4   | Hetzner  | KVM agent — local-cluster     |
| main-2  | 100.99.132.72     | 172.16.100.5   | Hetzner  | KVM agent — local-cluster     |

## CloudStack architecture

```
Zone: homelab
└── Pod: main
    ├── Cluster: nfs-cluster          (live migration enabled)
    │   ├── Primary: NFS from main-hp (172.16.100.3:/export/primary)
    │   ├── hp-01
    │   └── hp-02
    │
    └── Cluster: local-cluster
        ├── Primary: local disk per host
        ├── main-hp
        ├── main-1
        └── main-2

Secondary storage (zone-wide):
    └── NFS from main-hp (172.16.100.3:/export/secondary)
```

## Prerequisites

```bash
ansible-galaxy collection install \
  community.general \
  community.mysql \
  ansible.posix
```

## Deployment order

### Step 1 — WireGuard mesh (already done)
```bash
ansible-playbook wireguard.yml
```

### Step 2 — Foundation (NFS + MySQL + Management server)
```bash
ansible-playbook phase1_foundation.yml
```
When complete, verify the UI at http://172.16.100.3:8080/client
Login: admin / password — change this immediately.

### Step 3 — First compute host
```bash
ansible-playbook phase2_first_agent.yml
```
Then in the CloudStack UI, complete zone setup manually:
1. Infrastructure > Zones > Add Zone
   - Type: Advanced
   - Name: homelab
   - DNS: 8.8.8.8 / 8.8.4.4
   - Internal DNS: 172.16.100.3
2. Add Pod (use your LAN range for guest traffic)
3. Add Cluster: local-cluster, hypervisor: KVM
4. Add host: 172.16.100.3 (main-hp)
5. Add primary storage: local
6. Add secondary storage: NFS 172.16.100.3:/export/secondary
7. Wait for system VMs to start (~10 min)

### Step 4 — Remaining compute hosts
```bash
ansible-playbook phase3_remaining_agents.yml
```
Then in the UI:
- Add Cluster: nfs-cluster, hypervisor: KVM
- Add hp-01 and hp-02 to nfs-cluster
- Add primary storage: NFS 172.16.100.3:/export/primary
- Add main-1 and main-2 to local-cluster

## Key variables

- group_vars/all.yml          — versions, IPs, NFS paths
- roles/mysql/defaults/main.yml       — DB passwords (change before running)
- roles/nfs_server/defaults/main.yml  — export sizes

## Useful commands

```bash
# Check all agents
ansible cloudstack_agents -m shell -a "systemctl status cloudstack-agent" --become

# Check NFS mounts
ansible nfs_cluster -m shell -a "mount | grep nfs"

# Tail management log
ansible cloudstack_management -m shell \
  -a "tail -50 /var/log/cloudstack/management/management-server.log" --become
```
