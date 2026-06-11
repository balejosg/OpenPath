# WEDU Captive Portal Lab -- Gateway VM Provisioning

> Status: maintained
> Applies to: OpenPath WEDU captive portal lab gateway (Proxmox VM 121)
> Last verified: 2026-06-11
> Source of truth: `docs/testing/wedu-captive-portal-lab-provisioning.md`

This document describes the persistent network configuration of the WEDU
captive portal lab gateway VM (VM 121 `wedu-captive-gateway`) and the
belt-and-braces units that guard it against cloud-init flushes.

## Topology

- Proxmox VM 121 `wedu-captive-gateway`, 1 GB RAM.
- `eth1` carries two addresses on `10.77.0.0/24`:
  - `10.77.0.1/24` -- portal address, gateway IP, DHCP server listen address,
    and the resolver that must return NXDOMAIN for the portal host.
  - `10.77.0.53/24` -- dedicated network DNS resolver (`dnsmasq-wedu-net`),
    the address DHCP option 6 hands to clients.

This split (portal address != dedicated DNS) reproduces the production school
network failure mode: only the DHCP-offered DNS (`10.77.0.53`) resolves the
portal host (`nce.wedu.comunidad.madrid`); the gateway address itself
(`10.77.0.1`) returns NXDOMAIN for that host.

## Root Cause of Historical IP Flushes

cloud-init regenerates `50-cloud-init.yaml` on each boot. That file lists only
`10.77.0.1/24` for `eth1`. Netplan replaces per-interface address lists across
files rather than merging them, so without a higher-priority file the dedicated
resolver address `10.77.0.53/24` is silently dropped after a reboot.

## Persistent IP Configuration

`/etc/netplan/60-wedu-lab.yaml` wins lexicographically over
`50-cloud-init.yaml` and restates both addresses so the full list is preserved
after cloud-init regeneration.

```yaml
network:
  version: 2
  ethernets:
    eth1:
      addresses:
        - '10.77.0.1/24'
        - '10.77.0.53/24'
      nameservers:
        addresses:
          - 1.1.1.1
        search:
          - local
```

Note: `10.77.0.1/24` must appear in the `60-` file even though it is also in
`50-cloud-init.yaml`. Netplan replaces the entire address list for an interface
from the highest-priority file that defines it; omitting `.1` here would drop
the portal address.

## Belt-and-Braces Systemd Units

Two units guard the address independently of netplan:

### `wedu-lab-network.service`

A oneshot service that runs `/usr/local/sbin/wedu-lab-network` (an `ip addr
replace` script) after `network-online.target`. It ensures `10.77.0.53/24` is
present even if netplan did not apply the `60-` file.

```ini
[Unit]
Description=WEDU lab network interface setup
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wedu-lab-network
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
```

### `dnsmasq-wedu-net.service`

The dedicated network DNS resolver. It binds on `10.77.0.53` and answers
`nce.wedu.comunidad.madrid -> 10.77.0.1`. It requires
`wedu-lab-network.service` and must start before `wedu-captive-portal.service`.

```ini
[Unit]
Description=WEDU lab dedicated network DNS resolver (10.77.0.53)
After=wedu-lab-network.service network-online.target
Wants=network-online.target
Requires=wedu-lab-network.service
Before=wedu-captive-portal.service
[Service]
Type=simple
ExecStartPre=/usr/sbin/dnsmasq --test --conf-file=/etc/dnsmasq-wedu-net.conf
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/dnsmasq-wedu-net.conf --pid-file=/run/dnsmasq-wedu-net.pid
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
```

A drop-in at `dnsmasq-wedu-net.service.d/self-heal.conf` adds a second
`ExecStartPre` call to the network setup script so the address is present even
when the service restarts mid-session:

```ini
[Service]
ExecStartPre=/usr/local/sbin/wedu-lab-network
```

## Verification Recipe

Run these from inside VM 121 (via Proxmox QGA or SSH):

```bash
# Dedicated resolver must resolve the portal host to 10.77.0.1
dig @10.77.0.53 nce.wedu.comunidad.madrid +short
# Expected: 10.77.0.1

# Gateway address must return NXDOMAIN for the portal host
dig @10.77.0.1 nce.wedu.comunidad.madrid
# Expected: status: NXDOMAIN
```

Reboot-survival was verified on 2026-06-11 (healthcheck run 27342509146 green).

## Monitoring

The WEDU Gateway Healthcheck workflow (`wedu-gateway-healthcheck.yml`) runs
hourly (cron `7 * * * *`) and as a blocking preflight inside
`scripts/run-wedu-captive-portal-lab-ci.sh`. If the preflight fails, the full
lab exits immediately with:

```
dedicated resolver not answering: gateway preflight failed
```

To recover: run the WEDU Gateway Healthcheck workflow manually
(`workflow_dispatch`) to confirm the failure mode, then re-apply the netplan
config and restart the units on VM 121:

```bash
netplan apply
systemctl restart wedu-lab-network dnsmasq-wedu-net
```

Verify with the recipe above before re-running the lab.
