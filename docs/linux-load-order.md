# Linux Runtime Library Load Order

> Status: maintained
> Applies to: OpenPath Linux agent
> Last verified: 2026-05-16
> Source of truth: `linux/lib/common.sh`, `linux/lib/dns.sh`, `linux/scripts/runtime/openpath-update.sh`

The Linux runtime starts from `linux/scripts/runtime/openpath-update.sh`. The
installed script sources `linux/lib/common.sh`, acquires the runtime lock, then
calls `load_libraries`.

`load_libraries` validates required helper files first, then sources these
entrypoint libraries in order:

1. `apt.sh`
2. `dns.sh`
3. `firewall.sh`
4. `browser.sh`
5. `services.sh`
6. `rollback.sh`

`dns.sh` is the DNS entrypoint. It sources `common.sh` if the protected-domain
helpers are not already available, then loads:

1. `dns-validation.sh`
2. `dns-runtime.sh`
3. `dns-dnsmasq.sh`

This means dnsmasq rendering can rely on validation and runtime DNS helpers
being available. Shared upstream DNS validation belongs in `dns-runtime.sh` or
`common-connectivity.sh`; dnsmasq writers should call those helpers before
writing resolver IPs into generated configs.

`openpath-update.sh` separately sources:

1. `openpath-update-whitelist.sh`
2. `openpath-update-runtime.sh`

Those update helpers run after the core libraries are loaded, so they may use
DNS, firewall, browser, and rollback functions without re-sourcing those modules.
