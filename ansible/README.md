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
- VM disk: 50 GB qcow2 (thin-provisioned, backed by base image); controller gets 150 GB
- VM RAM: 12 GB, 2 vCPUs each; controller gets 20 GB
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

# 6. Base OpenStack prep on all VMs (chrony NTP, /etc/hosts, SELinux off)
ansible-playbook playbooks/06-os-base.yml

# 7. Install kolla-ansible on controller-vm, deploy kolla config, set up SSH
#    keys between controller-vm and compute nodes, create dummy0 interface
ansible-playbook playbooks/07-kolla-prep.yml

# Teardown: destroy and delete all VMs
ansible-playbook playbooks/99-rm-vms.yml
```

### Step 8 — OpenStack Deploy (run from controller-vm)

After `07-kolla-prep.yml` completes, SSH into controller-vm:

```bash
ssh -J root@100.68.102.106 rocky@172.16.102.1
```

All `kolla-ansible` commands below are run as root (or via `sudo`) on controller-vm.
The inventory and config live in `/etc/kolla/` (deployed by playbook 07).

---

#### 8.1 Bootstrap servers

Installs Docker, configures Docker daemon, creates the `kolla` system user, and ensures
Python dependencies are present on **every node** (controller + all 9 compute nodes).

```bash
kolla-ansible bootstrap-servers -i /etc/kolla/multinode 
```

Expected outcome: all nodes report `changed` or `ok`, no failures.
Docker will be running on every VM after this step.

Verify on controller-vm:
```bash
docker info | grep "Server Version"
# SSH to a compute node and check the same
ssh compute-vm-1 "sudo docker info | grep 'Server Version'"
```

---

#### 8.2 Pre-flight checks

Validates the full configuration before any service is started. Catches missing interfaces,
wrong MTU, insufficient RAM/disk, Docker issues, etc.

```bash
kolla-ansible prechecks -i /etc/kolla/multinode 
```

Expected outcome: all tasks `ok`. Any `FAILED` task must be fixed before proceeding.

Common issues and fixes:

| Error | Fix |
|-------|-----|
| `dummy0 not found` | Re-run `07-kolla-prep.yml` or `sudo modprobe dummy && sudo ip link add dummy0 type dummy && sudo ip link set dummy0 up` |
| `Docker not running` | `sudo systemctl start docker` on the failing node |
| `NTP not in sync` | Wait for chrony to sync: `chronyc tracking` on each node |
| `Not enough disk space` | kolla needs ~20 GB free on `/var/lib/docker` |

---

#### 8.3 Deploy

Pulls container images and starts all OpenStack services. This is the long step — expect
20–40 minutes depending on download speed.

Services deployed in order: MariaDB → RabbitMQ → Memcached → Keystone → Glance →
Placement → Nova → Neutron → Horizon.

```bash
kolla-ansible  deploy -i /etc/kolla/multinode
```

To watch progress on a specific node in another terminal:
```bash
ssh compute-vm-1 "sudo docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

If a specific service fails, you can redeploy only that service:
```bash
kolla-ansible -i /etc/kolla/multinode deploy --tags nova
kolla-ansible -i /etc/kolla/multinode deploy --tags neutron
```

---

#### 8.4 Post-deploy

Writes `/etc/kolla/admin-openrc.sh`, runs DB migrations, and performs other
one-time initialization tasks.

```bash
kolla-ansible -i /etc/kolla/multinode post-deploy
```

---

#### 8.5 Verify the deployment

```bash
# Load admin credentials
source /etc/kolla/admin-openrc.sh

# Check Keystone is responding
openstack token issue

# List services
openstack service list

# Check compute nodes registered with Nova
openstack compute service list

# Check Neutron agents on all nodes
openstack network agent list
```

Expected `openstack compute service list` output — one `nova-conductor`, `nova-scheduler`
and `nova-api` on controller-vm, plus `nova-compute` on all 9 compute nodes:

```
+----+------------------+--------------+----------+---------+
| ID | Binary           | Host         | Zone     | State   |
+----+------------------+--------------+----------+---------+
| .. | nova-conductor   | controller-vm| internal | up      |
| .. | nova-scheduler   | controller-vm| internal | up      |
| .. | nova-compute     | compute-vm-1 | nova     | up      |
| .. | nova-compute     | compute-vm-2 | nova     | up      |
| ...                                                       |
+----+------------------+--------------+----------+---------+
```

---

#### 8.6 Post-deploy network setup (one-time)

Create the flat provider network (backed by `br-ex` / `dummy0`) and a tenant network:

```bash
source /etc/kolla/admin-openrc.sh

# Provider / external network (flat, shared)
openstack network create \
  --share \
  --provider-physical-network physnet1 \
  --provider-network-type flat \
  external

openstack subnet create \
  --network external \
  --subnet-range 192.168.200.0/24 \
  --gateway 192.168.200.1 \
  --dns-nameserver 1.1.1.1 \
  --allocation-pool start=192.168.200.100,end=192.168.200.200 \
  external-subnet

# Tenant / private network for instances
openstack network create private
openstack subnet create \
  --network private \
  --subnet-range 10.0.0.0/24 \
  --dns-nameserver 1.1.1.1 \
  private-subnet

# Router connecting tenant net to external
openstack router create router1
openstack router set router1 --external-gateway external
openstack router add subnet router1 private-subnet
```

Upload a test image (CirrOS — tiny ~15 MB test image):
```bash
wget https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
openstack image create \
  --disk-format qcow2 \
  --container-format bare \
  --public \
  --file cirros-0.6.2-x86_64-disk.img \
  cirros-0.6.2

openstack image list
```

Launch a test instance:
```bash
openstack flavor create --ram 512 --disk 1 --vcpus 1 m1.tiny
openstack keypair create --public-key ~/.ssh/id_ed25519.pub mykey

openstack server create \
  --flavor m1.tiny \
  --image cirros-0.6.2 \
  --network private \
  --key-name mykey \
  test-vm

# Watch it boot
openstack server list
openstack console log show test-vm
```

---

#### 8.7 Horizon (dashboard)

Horizon is available at `http://172.16.102.1` after deploy.

To access it from your workstation, forward the port through the bastion:
```bash
ssh -L 8080:172.16.102.1:80 root@100.68.102.106 -N
```

Then open `http://localhost:8080` in your browser.

- **Domain**: `Default`
- **User**: `admin`
- **Password**: value of `keystone_admin_pass` in `inventory/group_vars/all.yml`

---

#### 8.8 Useful day-2 commands

```bash
# Check all container health on controller-vm
sudo docker ps --format "table {{.Names}}\t{{.Status}}"

# Tail logs for a specific service
sudo docker logs -f keystone
sudo docker logs -f nova_compute   # on a compute node

# Restart a single service
sudo docker restart nova_api

# Re-run just the reconfigure step (after editing globals.yml)
kolla-ansible -i /etc/kolla/multinode reconfigure

# Full redeploy of one service
kolla-ansible -i /etc/kolla/multinode deploy --tags keystone

# Pull fresh images and redeploy everything (upgrade)
kolla-ansible -i /etc/kolla/multinode pull
kolla-ansible -i /etc/kolla/multinode deploy
```

---

## Roles

| Role         | Purpose                                                                 |
|--------------|-------------------------------------------------------------------------|
| `wireguard`  | Generate keys, render full-mesh WireGuard config, verify connectivity   |
| `os_chrony`  | Install and configure chronyd; controller serves NTP to compute VMs     |
| `os_hosts`   | Populate `/etc/hosts` with all OpenStack VM names and IPs               |
| `os_base`    | Upgrade packages, disable SELinux/firewalld (pre-kolla system prep)     |

## Kolla-Ansible Configuration (`kolla/`)

| File           | Purpose                                                              |
|----------------|----------------------------------------------------------------------|
| `globals.yml`  | Kolla global config: release, network interfaces, enabled services   |
| `multinode`    | Kolla inventory: control=controller-vm, compute=compute-vm-{1..9}   |

**Key globals decisions:**

| Setting                        | Value                  | Reason                                           |
|-------------------------------|------------------------|--------------------------------------------------|
| `network_interface`           | enp1s0                 | Single NIC per VM (WireGuard-bridged)            |
| `neutron_external_interface`  | dummy0                 | No real uplink in nested lab — dummy module      |
| `kolla_internal_vip_address`  | 172.16.102.1           | Controller's own IP; no HAProxy/keepalived       |
| `enable_haproxy`              | no                     | Single controller, no HA                         |
| `neutron_plugin_agent`        | openvswitch            | OVS with VXLAN tenant overlay                    |
| `nova_compute_virt_type`      | kvm                    | host-passthrough enables nested KVM              |

---

## Current State

**Infrastructure — complete:**
- WireGuard mesh is up between all 5 physical hosts
- libvirt is installed and running on all hypervisors
- `virbr-wg` bridge and routing are configured
- 10 VMs are created and booted with correct IPs, routing, and SSH access
- Base OpenStack preparation (chrony NTP, `/etc/hosts`, SELinux off, firewalld masked) is done on all VMs

**OpenStack — pending kolla-ansible deploy (steps 7–8 above):**
- [ ] `07-kolla-prep.yml` — install kolla-ansible on controller-vm, SSH keys, dummy0
- [ ] `bootstrap-servers` — Docker on all nodes
- [ ] `prechecks` — validate config
- [ ] `deploy` — start all OpenStack containers
- [ ] `post-deploy` — write openrc, init DB

> **Before running `07-kolla-prep.yml`:** replace the `changeme` passwords in
> `inventory/group_vars/all.yml`. The `keystone_admin_pass` value is injected
> into kolla's `passwords.yml` by the playbook.

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
