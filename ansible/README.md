# luni-cloudstack — Ansible Setup

This repo provisions a multi-host OpenStack cluster on top of KVM VMs, connected via a WireGuard mesh VPN. Everything runs on bare-metal Rocky Linux hosts.

---

## Physical Infrastructure

Five bare-metal hosts act as hypervisors (KVM/libvirt). They are in different networks and are connected via a WireGuard full-mesh VPN. The local hosts (main-hp, hp-01, hp-02) run Ubuntu/Debian; the Hetzner servers (main-1, main-2) run Rocky Linux 10. All playbooks handle both OS families via `ansible_os_family` conditionals.

| Host      | Tailscale IP         | WireGuard IP    | Public/LAN IP        | OS           |
|-----------|----------------------|-----------------|----------------------|--------------|
| main-hp   | 100.68.102.106       | 172.16.100.1    | 192.168.0.60 (LAN)   | Ubuntu       |
| hp-01     | 100.93.75.19         | 172.16.100.2    | 192.168.0.50 (LAN)   | Ubuntu       |
| hp-02     | 100.124.102.103      | 172.16.100.3    | 192.168.0.55 (LAN)   | Ubuntu       |
| main-1    | 100.95.122.45        | 172.16.100.4    | 78.46.68.166 (Hetzner)  | Rocky 10  |
| main-2    | 100.115.189.79       | 172.16.100.5    | 188.40.66.241 (Hetzner) | Rocky 10  |

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
- VM DNS: defaults to `1.1.1.1`; Hetzner hosts use `213.133.100.100` (Hetzner blocks external DNS at the network level). Controlled by `vm_dns` per-host variable in inventory

---

## Networking Design

VMs use `/32` addresses. Each hypervisor host:
1. Has a `virbr-wg` Linux bridge (no physical ports, MTU 1420). On Debian this is created via `/etc/network/interfaces`; on Rocky via a dedicated systemd service (`virbr-wg-setup.service`) to avoid NetworkManager conflicts with libvirt bridge ports.
2. VMs attach to this bridge as their sole NIC (`ens2`).
3. The VM's default gateway is the host's WireGuard IP (`172.16.100.x`) set as an on-link route.
4. The host has `/32` routes for its own VMs pointing to `virbr-wg`, and `/32` routes for remote VMs pointing via the WireGuard peer IP.
5. NAT: VM-to-VM and VM-to-WireGuard traffic is **not** masqueraded; internet-bound traffic is masqueraded. On Debian hosts this uses iptables-persistent; on Rocky hosts this uses firewalld direct rules.

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

# 6. Harden Hetzner hosts (firewalld, fail2ban, SSH hardening)
ansible-playbook playbooks/10-hardening.yml

# 7. Base OpenStack prep on all VMs (chrony NTP, /etc/hosts, SELinux off)
ansible-playbook playbooks/06-os-base.yml

# 8. Install kolla-ansible on controller-vm, deploy kolla config, set up SSH
#    keys between controller-vm and compute nodes, set up neutron external interface
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

> **Automated path:** `07-kolla-prep.yml` copies `/root/setup-openstack.sh` to controller-vm.
> This script runs all four kolla steps and the day-1 setup (network, flavors, image) in one go.
> It is idempotent — safe to re-run after a failed attempt.
> ```bash
> sudo bash /root/setup-openstack.sh
> # Re-run only the day-1 OpenStack setup (skip kolla):
> sudo bash /root/setup-openstack.sh --skip-kolla
> ```
> The manual steps below explain each phase in detail if you need to debug or run selectively.

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
| `ens6 not found` (controller) | Re-run `07-kolla-prep.yml` to hot-plug the second NIC |
| `dummy0 not found` (compute) | Re-run `07-kolla-prep.yml` or `sudo modprobe dummy && sudo ip link add dummy0 type dummy && sudo ip link set dummy0 up` |
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

#### 8.6 Post-deploy one-time admin setup (run once as admin)

This sets up the shared infrastructure that all projects will use: the provider network,
a standard set of flavors, and a public test image. Run these immediately after `post-deploy`.

```bash
source /etc/kolla/admin-openrc.sh
```

**Provider / external network** (flat, backed by `br-ex` → `ens6` on controller):

```bash
openstack network create \
  --share \
  --external \
  --provider-physical-network physnet1 \
  --provider-network-type flat \
  external

openstack subnet create \
  --network external \
  --subnet-range 172.16.102.0/24 \
  --no-dhcp \
  --gateway 172.16.102.1 \
  --allocation-pool start=172.16.102.128,end=172.16.102.250 \
  external-subnet
```

> **Floating IP reachability:** Floating IPs are allocated from the `172.16.102.128/25`
> range. All hypervisor hosts already have a route for `172.16.102.128/25` pointing
> to the controller VM's host (set up by `03-bridges.yml`), so floating IPs are
> reachable from any host on the WireGuard mesh without extra routing.

**Standard flavors:**

```bash
openstack flavor create --id 1 --ram 512   --disk 5   --vcpus 1 m1.tiny
openstack flavor create --id 2 --ram 2048  --disk 20  --vcpus 1 m1.small
openstack flavor create --id 3 --ram 4096  --disk 40  --vcpus 2 m1.medium
openstack flavor create --id 4 --ram 8192  --disk 80  --vcpus 4 m1.large
openstack flavor create --id 5 --ram 16384 --disk 160 --vcpus 8 m1.xlarge
```

**Public test image** (CirrOS — 15 MB, useful for quick smoke tests):

```bash
curl -L -o /tmp/cirros-0.6.2-x86_64-disk.img \
  https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img

openstack image create \
  --disk-format qcow2 \
  --container-format bare \
  --public \
  --file /tmp/cirros-0.6.2-x86_64-disk.img \
  cirros-0.6.2
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

#### 8.8 Kolla container operations

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

## Day 2: Running Your First Workload

All commands below assume you are SSH'd into **controller-vm** (`172.16.102.1`).
Everything from step 9 onward is day-2 OpenStack operation — no kolla or Ansible involved.

```bash
ssh -J root@100.68.102.106 rocky@172.16.102.1
source /etc/kolla/admin-openrc.sh
```

---

### Step 9 — Create a Project and User

OpenStack multi-tenancy is built around **projects** (tenants). Each team or workload
gets its own project with isolated networks and quotas.

```bash
# Create a project
openstack project create --description "My first project" myproject

# Create a user and assign it to the project
openstack user create --password changeme --project myproject myuser
openstack role add --project myproject --user myuser member

# Optional: give the user admin rights within the project only
# openstack role add --project myproject --user myuser admin
```

Generate a project-scoped openrc for day-to-day use (avoid running everything as admin):

```bash
cat > ~/myproject-openrc.sh <<'EOF'
export OS_AUTH_URL=http://172.16.102.1:5000
export OS_PROJECT_NAME=myproject
export OS_USERNAME=myuser
export OS_PASSWORD=changeme
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

source ~/myproject-openrc.sh
```

**Set project quotas** (as admin — do this before users start consuming resources):

```bash
source /etc/kolla/admin-openrc.sh

openstack quota set \
  --instances 20 \
  --cores 40 \
  --ram 81920 \
  --floating-ips 10 \
  --networks 5 \
  --subnets 10 \
  --routers 3 \
  --secgroups 20 \
  --secgroup-rules 100 \
  myproject
```

Verify:
```bash
openstack quota show myproject
```

---

### Step 10 — Set Up Networks

Each project gets its own private (tenant) network. Tenant networks use VXLAN overlay
(`neutron_tenant_network_types: vxlan`), so they are fully isolated between projects.

Switch to the project user:
```bash
source ~/myproject-openrc.sh
```

**Create tenant network and subnet:**

```bash
openstack network create private

openstack subnet create \
  --network private \
  --subnet-range 10.0.0.0/24 \
  --gateway 10.0.0.1 \
  --dns-nameserver 213.133.100.100 \
  private-subnet
```

**Create a router and connect it to the external (provider) network:**

```bash
openstack router create router1

# Set the external gateway (admin operation — project users need the 'external' network to be shared)
openstack router set router1 --external-gateway external

# Plug the tenant subnet into the router
openstack router add subnet router1 private-subnet
```

Verify connectivity paths:
```bash
openstack network list
openstack subnet list
openstack router show router1
```

The router gets a floating IP from the external pool (`172.16.102.128-250`). Instances on
`private` can reach the internet via SNAT through this router. Floating IPs from the
external pool can be assigned to individual instances for inbound access.

---

### Step 11 — Security Groups

By default, the `default` security group blocks all **inbound** traffic. Add rules to allow
SSH and ICMP before launching instances.

```bash
# Allow SSH inbound from anywhere
openstack security group rule create \
  --proto tcp \
  --dst-port 22 \
  --remote-ip 0.0.0.0/0 \
  default

# Allow ICMP (ping) inbound from anywhere
openstack security group rule create \
  --proto icmp \
  --remote-ip 0.0.0.0/0 \
  default
```

For a stricter setup, create a dedicated security group:

```bash
openstack security group create web --description "Allow HTTP/S and SSH"

openstack security group rule create --proto tcp --dst-port 22    --remote-ip 0.0.0.0/0 web
openstack security group rule create --proto tcp --dst-port 80    --remote-ip 0.0.0.0/0 web
openstack security group rule create --proto tcp --dst-port 443   --remote-ip 0.0.0.0/0 web
openstack security group rule create --proto icmp                 --remote-ip 0.0.0.0/0 web

openstack security group rule list web
```

---

### Step 12 — Add a Keypair

Instances are accessed via SSH key injection (cloud-init). Upload your public key:

```bash
# From your workstation public key (if already on controller-vm)
openstack keypair create --public-key ~/.ssh/id_ed25519.pub mykey

# Or generate a new keypair and save the private key locally
openstack keypair create mykey > ~/mykey.pem
chmod 600 ~/mykey.pem
```

List registered keypairs:
```bash
openstack keypair list
```

---

### Step 13 — Upload an Image

CirrOS is fine for smoke tests. For real workloads upload a Rocky Linux or Ubuntu image.

**Rocky Linux 10 (GenericCloud):**

```bash
# Download on controller-vm
curl -L -o /tmp/Rocky-10-GenericCloud.qcow2 \
  https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2

openstack image create \
  --disk-format qcow2 \
  --container-format bare \
  --public \
  --property os_type=linux \
  --file /tmp/Rocky-10-GenericCloud.qcow2 \
  rocky-10
```

**Ubuntu 24.04 LTS (Noble):**

```bash
curl -L -o /tmp/ubuntu-24.04-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

openstack image create \
  --disk-format qcow2 \
  --container-format bare \
  --public \
  --property os_type=linux \
  --file /tmp/ubuntu-24.04-server-cloudimg-amd64.img \
  ubuntu-24.04
```

Verify:
```bash
openstack image list
```

Images are stored on the controller-vm under `/var/lib/docker/volumes/` (Glance uses the
local file backend; `glance_backend_file: yes` in `globals.yml`).

---

### Step 14 — Launch an Instance

With network, security group, keypair, and image ready:

```bash
openstack server create \
  --flavor m1.small \
  --image rocky-10 \
  --network private \
  --security-group default \
  --key-name mykey \
  --wait \
  my-vm
```

Monitor the build:
```bash
openstack server list
openstack server show my-vm

# Tail the cloud-init console log (useful for boot debugging)
openstack console log show my-vm
```

Expected `openstack server list` output once booted:
```
+------+-------+--------+---------------------------+---------+----------+
| ID   | Name  | Status | Networks                  | Image   | Flavor   |
+------+-------+--------+---------------------------+---------+----------+
| ...  | my-vm | ACTIVE | private=10.0.0.X          | rocky-10| m1.small |
+------+-------+--------+---------------------------+---------+----------+
```

---

### Step 15 — Allocate and Assign a Floating IP

The private IP (`10.0.0.x`) is only reachable inside the Neutron tenant network.
Assign a floating IP from the external pool to reach the VM from outside:

```bash
# Allocate a floating IP from the external pool
openstack floating ip create external

# Associate it with the instance
openstack floating ip list   # note the floating IP address

openstack server add floating ip my-vm <FLOATING_IP>
```

Verify:
```bash
openstack server show my-vm | grep addresses
# addresses: private=10.0.0.X, 172.16.102.Y
```

---

### Step 16 — Access the VM

**Option A — from controller-vm via the floating IP** (always works, no extra routing):

```bash
# Add route to floating IP range on controller-vm if not already reachable
# (Usually works directly from controller-vm via OVS br-ex)
ssh -i ~/mykey.pem rocky@172.16.102.Y
# or for Ubuntu:
ssh -i ~/mykey.pem ubuntu@172.16.102.Y
```

**Option B — from your workstation** (requires the static route from step 8.6):

```bash
# Add once on workstation
sudo ip route add 172.16.102.128/25 via 172.16.102.1

# Then SSH directly (jump through bastion, then route to floating IP)
ssh -J root@100.68.102.106 rocky@172.16.102.Y
```

**Option C — browser console** (no SSH needed, good for debugging):

```bash
openstack console url show --novnc my-vm
# Returns a URL — open in browser after forwarding port 6080:
# ssh -L 6080:172.16.102.1:6080 root@100.68.102.106 -N
```

---

### Step 17 — Common VM Operations

```bash
# Stop and start
openstack server stop my-vm
openstack server start my-vm

# Reboot (graceful)
openstack server reboot my-vm
# Hard reboot
openstack server reboot --hard my-vm

# Resize to a larger flavor (cold resize — instance must be stopped)
openstack server stop my-vm
openstack server resize --flavor m1.medium my-vm
# Wait for VERIFY_RESIZE status, then confirm:
openstack server resize confirm my-vm

# Take a snapshot (creates a Glance image from the running disk)
openstack server image create --name my-vm-snapshot my-vm

# Delete
openstack server delete my-vm
```

**Manage floating IPs:**

```bash
# Detach floating IP
openstack server remove floating ip my-vm 172.16.102.Y

# Release it back to the pool
openstack floating ip delete 172.16.102.Y

# List all allocated floating IPs (admin view)
source /etc/kolla/admin-openrc.sh
openstack floating ip list --all-projects
```

---

### Step 18 — Verify Compute Scheduling

Check which hypervisor (compute node) an instance landed on:

```bash
source /etc/kolla/admin-openrc.sh
openstack server show my-vm -f json | jq '."OS-EXT-SRV-ATTR:host"'
```

View resource usage per compute node:

```bash
openstack host list
openstack hypervisor list
openstack hypervisor show compute-vm-1
```

Check placement:
```bash
openstack resource provider list
openstack resource provider inventory list <UUID>
```

---

### Step 19 — Multi-Instance Deployment Pattern

To spin up several identical instances:

```bash
openstack server create \
  --flavor m1.small \
  --image rocky-10 \
  --network private \
  --security-group default \
  --key-name mykey \
  --min 3 \
  --max 3 \
  --wait \
  worker

# Results in worker-1, worker-2, worker-3
openstack server list --name worker
```

Assign floating IPs to each:
```bash
for vm in $(openstack server list --name worker -f value -c Name); do
  fip=$(openstack floating ip create external -f value -c floating_ip_address)
  openstack server add floating ip "$vm" "$fip"
  echo "$vm -> $fip"
done
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
| `network_interface`           | ens2                   | Single NIC per VM (WireGuard-bridged)            |
| `neutron_external_interface`  | ens6                   | Second NIC on controller (virbr-wg); dummy0 on compute |
| `kolla_internal_vip_address`  | 172.16.102.1           | Controller's own IP; no HAProxy/keepalived       |
| `enable_haproxy`              | no                     | Single controller, no HA                         |
| `neutron_plugin_agent`        | openvswitch            | OVS with VXLAN tenant overlay                    |
| `nova_compute_virt_type`      | kvm                    | host-passthrough enables nested KVM              |

---

## Current State

**Infrastructure — complete:**
- WireGuard mesh is up between all 5 physical hosts
- libvirt is installed and running on all hypervisors (cross-distro: Debian + Rocky)
- `virbr-wg` bridge and routing are configured
- VMs are created and booted with correct IPs, routing, and SSH access
- main-1 and main-2 hardened with firewalld, fail2ban, SSH hardening (`10-hardening.yml`)
- Base OpenStack preparation (chrony NTP, `/etc/hosts`, SELinux off) is done on all VMs

**OpenStack — deployed:**
- kolla-ansible deployed on controller-vm with all services running
- Day-1 setup complete: external network (`172.16.102.128-250`), flavors, CirrOS image
- Horizon available at `http://172.16.102.1`

> **Note:** Replace the `changeme` passwords in `inventory/group_vars/all.yml`
> before deploying. The `keystone_admin_pass` value is injected into kolla's
> `passwords.yml` by the playbook.

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
| `vm_dns`             | Per-host DNS servers for VMs (default: `1.1.1.1`)|
| `bastion_host`       | SSH jump host IP for VM access                   |
| `keystone_db_pass`   | MariaDB password for Keystone (changeme)         |
| `rabbit_pass`        | RabbitMQ password (changeme)                     |
| `keystone_admin_pass`| OpenStack admin user password (changeme)         |
| *(+ other OS passes)*| Glance, Placement, Nova, Neutron service passwords|
