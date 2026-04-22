# luni-cloudstack — Ansible Setup

This repo provisions a multi-host OpenStack cluster on top of KVM VMs, connected via a WireGuard mesh VPN. Everything runs on bare-metal Rocky Linux hosts.

---

## Physical Infrastructure

Five bare-metal hosts act as hypervisors (KVM/libvirt). They are in different networks and are connected via a WireGuard full-mesh VPN.

| Host      | Tailscale/Public IP  | WireGuard IP    | Local LAN IP    |
|-----------|----------------------|-----------------|-----------------|
| main-hp   | 100.68.102.106       | 172.16.100.1    | 192.168.0.60    |
| hp-01     | 100.93.75.19         | 172.16.100.2    | 192.168.0.50    |
| hp-02     | 100.124.102.103      | 172.16.100.3    | 192.168.0.55    |
| main-1    | 100.117.99.12        | 172.16.100.4    | (direct)        |
| main-2    | 100.99.132.72        | 172.16.100.5    | (direct)        |

- WireGuard interface: `wg5`, port `51821`
- WireGuard mesh subnet: `172.16.100.0/24`
- Bastion/jump host for VM access: `main-hp` (100.68.102.106)

---

## VM Layer

Each physical host runs **2 KVM VMs** (Rocky Linux 10, cloud image), provisioned via cloud-init. 10 VMs total.

| VM Name      | VM IP         | Runs on  | OpenStack Role  |
|--------------|---------------|----------|-----------------|
| main-hp-vm1  | 172.16.102.1  | main-hp  | controller-vm   |
| main-hp-vm2  | 172.16.102.2  | main-hp  | compute-vm-1    |
| hp-01-vm1    | 172.16.102.3  | hp-01    | compute-vm-2    |
| hp-01-vm2    | 172.16.102.4  | hp-01    | compute-vm-3    |
| hp-02-vm1    | 172.16.102.5  | hp-02    | compute-vm-4    |
| hp-02-vm2    | 172.16.102.6  | hp-02    | compute-vm-5    |
| main-1-vm1   | 172.16.102.7  | main-1   | compute-vm-6    |
| main-1-vm2   | 172.16.102.8  | main-1   | compute-vm-7    |
| main-2-vm1   | 172.16.102.9  | main-2   | compute-vm-8    |
| main-2-vm2   | 172.16.102.10 | main-2   | compute-vm-9    |

- VM subnet: `172.16.102.0/24`
- VM disk: 50 GB qcow2 (thin-provisioned, backed by base image)
- VM RAM: 12 GB, 2 vCPUs each
- VM user: `rocky` / password set via `vm_password` in `group_vars/all.yml`

---

## Networking Design

VMs use `/32` addresses. Each hypervisor host:
1. Has a `virbr-wg` Linux bridge (no physical ports, MTU 1420).
2. VMs attach to this bridge as their sole NIC (`enp1s0`).
3. The VM's default gateway is the host's WireGuard IP (`172.16.100.x`) set as an on-link route.
4. The host has `/32` routes for its own VMs pointing to `virbr-wg`, and `/32` routes for remote VMs pointing via the WireGuard peer IP.
5. iptables: VM-to-VM and VM-to-WireGuard traffic is **not** masqueraded; internet-bound traffic is masqueraded.

This means VMs on different physical hosts can reach each other directly through the WireGuard mesh without NAT.

---

## OpenStack Layout (planned)

- **Controller**: `controller-vm` (172.16.102.1) — Keystone, Glance, Placement, Nova API, Neutron server, Horizon
- **Compute nodes**: `compute-vm-1` through `compute-vm-9` (172.16.102.2–.10) — Nova compute, Neutron agent

All VMs connect via SSH through the bastion host (`main-hp`) using `ProxyJump`.

---

## Playbook Sequence

Run playbooks in order:

```bash
# 1. Build WireGuard full-mesh between physical hosts
ansible-playbook playbooks/01-wireguard.yml

# 2. Install libvirt/QEMU on all hypervisor hosts
ansible-playbook playbooks/02-base.yml

# 3. Set up virbr-wg bridge, routing, and iptables on hypervisors
ansible-playbook playbooks/03-bridges.yml

# 4. Download Rocky Linux 10 cloud image on all hypervisors
ansible-playbook playbooks/04-cloud-image.yml

# 5. Create and boot VMs (cloud-init: user, network, hostname)
ansible-playbook playbooks/05-create-vms.yml

# 6. Base OpenStack prep on all VMs (chrony NTP, /etc/hosts)
ansible-playbook playbooks/06-os-base.yml

# Teardown: destroy and delete all VMs
ansible-playbook playbooks/99-rm-vms.yml
```

---

## Roles

| Role         | Purpose                                                                 |
|--------------|-------------------------------------------------------------------------|
| `wireguard`  | Generate keys, render full-mesh WireGuard config, verify connectivity   |
| `os_chrony`  | Install and configure chronyd; controller serves NTP to compute VMs     |
| `os_hosts`   | Populate `/etc/hosts` with all OpenStack VM names and IPs               |

---

## Current State

The infrastructure layer is complete and working:
- WireGuard mesh is up between all 5 physical hosts
- libvirt is installed and running on all hypervisors
- `virbr-wg` bridge and routing are configured
- 10 VMs are created and booted with correct IPs, routing, and SSH access
- Base OpenStack preparation (chrony, hosts) is done on all VMs

**Not yet done — OpenStack service installation:**
- Keystone (identity)
- Glance (image)
- Placement
- Nova (compute)
- Neutron (networking)
- Horizon (dashboard)

All service passwords are currently placeholder `changeme` values in `inventory/group_vars/all.yml` and must be set before deploying OpenStack services.

---

## Key Variables (`inventory/group_vars/all.yml`)

| Variable             | Description                                      |
|----------------------|--------------------------------------------------|
| `wg_interface`       | WireGuard interface name (`wg5`)                 |
| `wg_port`            | WireGuard listen port (`51821`)                  |
| `wg_subnet`          | WireGuard host subnet (`172.16.100.0/24`)        |
| `wg_vm_subnet`       | VM subnet (`172.16.102.0/24`)                    |
| `virbr_wg_name`      | Bridge name on hypervisors (`virbr-wg`)          |
| `virbr_wg_mtu`       | Bridge MTU (`1420`, matches WireGuard overhead)  |
| `vm_password`        | Password for the `rocky` user in all VMs         |
| `bastion_host`       | SSH jump host IP for VM access                   |
| `keystone_db_pass`   | MariaDB password for Keystone (changeme)         |
| `rabbit_pass`        | RabbitMQ password (changeme)                     |
| `keystone_admin_pass`| OpenStack admin user password (changeme)         |
| *(+ other OS passes)*| Glance, Placement, Nova, Neutron service passwords|
