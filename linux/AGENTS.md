# Linux AGENTS.md

Bash endpoint agent: `dnsmasq` DNS sinkhole, firewall enforcement, browser policy helpers, and systemd-managed update/health flows.

## Structure

Core modules live under `lib/`:

- `common.sh`: shared config, logging, and filesystem helpers
- `common-connectivity.sh`: single owner of the primary-DNS-upstream concept -- detection ladder, martian filter, persisted-file read/write (`persist_upstream_dns`/`read_persisted_upstream_dns`/`resolve_persisted_upstream_dns`), and the dnsmasq upstream resolv.conf render; the generated `dnsmasq-init-resolv.sh` boot script sources it and must never re-derive the upstream from the live network
- `dns.sh`: `dnsmasq` config generation and DNS runtime orchestration (upstream detection lives in `common-connectivity.sh`)
- `firewall.sh`: local DNS enforcement and bypass resistance
- `browser.sh` and browser policy helpers: Firefox/Chromium policy and extension staging
- `services.sh`: systemd services, timers, logrotate, dispatcher hooks
- `runtime-cli.sh`: command implementations behind `openpath`

Runtime entrypoints live under `scripts/runtime/`:

- `openpath-update.sh`
- `openpath-agent-update.sh`
- `openpath-self-update.sh`
- `dnsmasq-watchdog.sh`
- `captive-portal-detector.sh`
- `openpath-sse-listener.sh`
- `openpath-cmd.sh`

## Installation Paths

- library modules: `/usr/local/lib/openpath/lib/`
- runtime scripts: `/usr/local/bin/`
- operator config: `/etc/openpath/`
- state: `/var/lib/openpath/`
- logs: `/var/log/openpath.log`, `/var/log/captive-portal-detector.log`

## Conventions

- use `#!/bin/bash`
- use `set -eo pipefail` where the script owns command flow
- quote variables unless there is a deliberate shell-word-splitting need
- prefer `[[ ... ]]` for conditionals
- keep ShellCheck clean unless there is a narrow, justified exception

## Critical Contract

Order in generated `dnsmasq` config is critical:

```text
address=/#/192.0.2.1       # sinkhole IPv4 for non-allowed domains
address=/#/100::           # sinkhole IPv6 for non-allowed domains
server=/allowed.com/8.8.8.8
```

Reversing that order breaks whitelist enforcement.

The sinkhole addresses are the canonical `OPENPATH_DNS_SINKHOLE_IPV4` /
`OPENPATH_DNS_SINKHOLE_IPV6` defaults registered in `lib/defaults.conf`. The
emit-vs-RST decision for the IPv6 sinkhole is owned by
`lib/dns-firewall-contract.sh` (`ipv6_sinkhole_fail_closed`), consumed by both
`dns-dnsmasq.sh` and `firewall-rule-helpers.sh` -- never re-implement it inline.

## Testing

```bash
cd tests && bats *.bats
npm run test:installer:linux
npm run test:installer:apt
```

## Anti-Patterns

- direct edits to generated runtime files instead of fixing the generator
- bypassing `openpath-update.sh` when validating install/update flows
- unquoted variables or broad ShellCheck disables without justification
