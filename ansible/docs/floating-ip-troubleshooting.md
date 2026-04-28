# Floating IP Connectivity Troubleshooting

## Problem: OpenStack floating IPs unreachable

Floating IPs (172.16.102.128-250) were allocated and associated to VMs but couldn't be pinged from any host.

## Root causes (3 layers)

### 1. br-ex had no real L2 connectivity

`neutron_external_interface: dummy0` means br-ex is connected to a dummy interface with no real network path. ARP requests for floating IPs never reached the Neutron router namespace.

**Fix:** Hot-plugged a second NIC (`ens6`) on the controller VM, attached to `virbr-wg` bridge on the hypervisor. Replaced `dummy0` with `ens6` in br-ex:
```bash
# On controller VM
docker exec openvswitch_vswitchd ovs-vsctl --may-exist add-port br-ex ens6
docker exec openvswitch_vswitchd ovs-vsctl --if-exists del-port br-ex dummy0
```

After this, ARP for floating IPs resolved (the router namespace's qg interface replied). But ICMP still failed.

### 2. Controller VM had IP forwarding disabled

The Neutron router namespace routes reply traffic via its default gateway (`172.16.102.1` = the controller VM's ens2). The reply arrives on ens2 and needs to be forwarded back to the original sender. With `net.ipv4.ip_forward=0`, replies were silently dropped.

**Diagnosis:** tcpdump on virbr-wg showed ICMP replies arriving (dst MAC = controller's ens2 MAC, not the sender's MAC), but ping reported 100% loss. The bridge forwarded replies to the controller VM instead of the sender.

**Fix:**
```bash
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
```

After this, floating IPs worked from main-hp but not from remote WireGuard hosts.

### 3. WireGuard AllowedIPs missing floating IP range

The WireGuard config only listed individual VM IPs (`172.16.102.x/32`) in AllowedIPs. The floating IP range `172.16.102.128/25` was not included for the main-hp peer, so WireGuard dropped the traffic with "Required key not available".

**Fix:** Added `172.16.102.128/25` to AllowedIPs for main-hp's peer on all hosts:
```bash
wg set wg5 peer <main-hp-pubkey> allowed-ips 172.16.100.1/32,172.16.102.1/32,172.16.102.2/32,172.16.102.11/32,172.16.102.128/25
```

Updated `roles/wireguard/templates/wg_interface.conf.j2` to add this automatically for the peer hosting the controller VM.

## Traffic flow (working state)

```
sender → wg5 → main-hp wg5 → virbr-wg → vnet15 → ens6 → br-ex → br-int → qg (router ns)
  → DNAT to private IP → VXLAN to compute node → VM
  → reply: VM → VXLAN → qr → SNAT → qg → br-ex → ens6 → virbr-wg → vnet13 → ens2
  → controller VM forwards → ens2 → virbr-wg → wg5 → sender
```

## Files changed

- `kolla/globals.yml`: `neutron_external_interface: "ens6"`
- `playbooks/07-kolla-prep.yml`: hot-plugs second NIC on controller, enables ip_forward
- `roles/wireguard/templates/wg_interface.conf.j2`: adds `172.16.102.128/25` to controller host peer
