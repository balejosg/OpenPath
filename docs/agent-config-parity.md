# Agent Config Parity

> Status: maintained
> Applies to: OpenPath repository (Linux and Windows endpoint agents)
> Last verified: 2026-06-12
> Source of truth: `docs/agent-config-parity.md`

Cross-platform reference for every tunable in the OpenPath endpoint agents.
The columns map each canonical concept to its concrete key on each platform.

---

## Update Cadence Alignment

Both platforms now use a **5-minute polling interval** as the fallback safety net.

**Decision rationale:**
SSE (Server-Sent Events) is the primary update trigger on both platforms - rules
are applied within seconds of a server-side change. The polling interval is only
a fallback that fires when the SSE connection is absent or has not delivered an
update recently. The original Linux default (5 min) was already correct. The
Windows default (15 min) was a legacy holdover with no documented rationale; it
was aligned to 5 minutes in this change to match Linux behaviour and tighten the
worst-case convergence window.

---

## Canonical Mapping Table

### Update Cadence

| Canonical name              | Purpose                                             | Default | Linux key (and env override)                                                                | Windows config.json key                                                                                                                   | Notes / aliases                                                                           |
| --------------------------- | --------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `update-interval-minutes`   | Fallback polling interval when SSE is absent        | **5**   | `TIMER_INTERVAL_MINUTES` / `OPENPATH_TIMER_INTERVAL` - defined in `linux/lib/defaults.conf` | `updateIntervalMinutes` - set in `windows/lib/install/Installer.Config.ps1`; runtime fallback in `windows/lib/internal/Common.Update.ps1` | SSE is the primary trigger; this is the safety-net timer only                             |
| `watchdog-interval-minutes` | How often the Windows watchdog scheduled task fires | 1       | N/A (Linux watchdog is event-driven via systemd, no polling interval)                       | `watchdogIntervalMinutes` - `windows/lib/install/Installer.Config.ps1`                                                                    | Linux equivalent is the `openpath-watchdog.service` systemd unit which triggers on-demand |

### Failure Semantics

| Canonical name            | Purpose                                                                 | Default     | Linux key (and env override)                                                               | Windows config.json key                                                                                         | Notes / aliases                                                                                                                  |
| ------------------------- | ----------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `failure-mode`            | Posture when all recovery attempts are exhausted                        | `protected` | `FAILURE_MODE` / `OPENPATH_FAILURE_MODE` - `linux/lib/defaults.conf`                       | `enableStaleFailsafe` (bool, `true`) + `staleWhitelistMaxAgeHours` - `windows/lib/install/Installer.Config.ps1` | Linux uses a string enum (`protected`/`open`); Windows models the same concept as a bool switch plus an age limit. See ADR 0011. |
| `whitelist-max-age-hours` | Hours before cached whitelist is considered expired; triggers fail-safe | 24          | `WHITELIST_MAX_AGE_HOURS` / `OPENPATH_WHITELIST_MAX_AGE_HOURS` - `linux/lib/defaults.conf` | `staleWhitelistMaxAgeHours` - `windows/lib/install/Installer.Config.ps1`                                        | Set to `0` on Linux to disable expiration checks.                                                                                |

### Checkpoint / Rollback

| Canonical name    | Purpose                                       | Default | Linux key (and env override)                                               | Windows config.json key                                       | Notes / aliases                                                                                                              |
| ----------------- | --------------------------------------------- | ------- | -------------------------------------------------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `max-checkpoints` | Maximum number of rollback snapshots retained | 3       | `MAX_CHECKPOINTS` / `OPENPATH_MAX_CHECKPOINTS` - `linux/lib/defaults.conf` | `maxCheckpoints` - `windows/lib/install/Installer.Config.ps1` | Windows also has `enableCheckpointRollback` (bool, `true`) to toggle the feature; Linux has no separate enable/disable flag. |

### Logging

| Canonical name    | Purpose                                  | Default                      | Linux key (and env override)                                            | Windows config.json key                                                                                                          | Notes / aliases                                            |
| ----------------- | ---------------------------------------- | ---------------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `log-max-size-mb` | Maximum log file size before rotation    | N/A (Linux uses `logrotate`) | Managed by `logrotate` config generated at install time; no runtime key | `logMaxSizeMb` - default `5`, enforced in `windows/lib/internal/OpenPathConfig.Model.ps1` (`ConvertTo-OpenPathNormalizedConfig`) | Windows rotates in-process; Linux delegates to `logrotate` |
| `log-keep-files`  | Number of rotated log archives to retain | N/A (Linux uses `logrotate`) | Managed by `logrotate` config at install time                           | `logKeepFiles` - default `3`, enforced in `windows/lib/internal/OpenPathConfig.Model.ps1`                                        | Same note as above                                         |

### Bypass Blocking

| Canonical name          | Purpose                                                          | Default                       | Linux key (and env override)                                                         | Windows config.json key                                                                                                  | Notes / aliases                                                                          |
| ----------------------- | ---------------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `doh-block-enabled`     | Block DoH resolver IPs on TCP/UDP 443 via ipset / firewall rules | 1 / `true`                    | `DOH_BLOCK_ENABLED` / `OPENPATH_DOH_BLOCK_ENABLED` - `linux/lib/defaults.conf`       | `enableDohIpBlocking` - `windows/lib/install/Installer.Config.ps1`                                                       | Linux uses `1`/`0`; Windows uses `$true`/`$false`                                        |
| `doh-resolver-ips`      | Comma-separated list of DoH resolver IPs to block                | See `linux/lib/defaults.conf` | `DOH_RESOLVERS` / `OPENPATH_DOH_RESOLVERS` - `linux/lib/defaults.conf`               | `dohResolverIps` (array) - populated by `Get-DefaultDohResolverIps` in `windows/lib/internal/Firewall.Catalog.ps1`       | Both platforms ship identical default sets                                               |
| `vpn-block-enabled`     | Block VPN tunnel ports and known VPN protocol egress             | 1 / N/A                       | `VPN_BLOCK_ENABLED` / `OPENPATH_VPN_BLOCK_ENABLED` - `linux/lib/defaults.conf`       | N/A - Windows always applies VPN block rules when the firewall is enabled (`enableFirewall = $true`); no separate toggle | Linux exposes an explicit enable/disable flag; Windows does not                          |
| `vpn-block-rules`       | Protocol:port:name rules defining VPN egress to block            | See `linux/lib/defaults.conf` | `VPN_BLOCK_RULES` / `OPENPATH_VPN_BLOCK_RULES` - `linux/lib/defaults.conf`           | `vpnBlockRules` (array) - populated by `Get-DefaultVpnBlockRules` in `windows/lib/internal/Firewall.Catalog.ps1`         | Same default set on both platforms (OpenVPN UDP/TCP, WireGuard, PPTP, IKE, IPSec-NAT)    |
| `vpn-block-interfaces`  | Interface patterns blocked on OUTPUT (Linux only)                | `tun+,tap+`                   | `VPN_BLOCK_INTERFACES` / `OPENPATH_VPN_BLOCK_INTERFACES` - `linux/lib/defaults.conf` | N/A - Windows firewall operates at the application/port level, not network interface level                               | Linux-only concept                                                                       |
| `tor-block-enabled`     | Block Tor relay and SOCKS ports                                  | 1 / N/A                       | `TOR_BLOCK_ENABLED` / `OPENPATH_TOR_BLOCK_ENABLED` - `linux/lib/defaults.conf`       | N/A - Windows always applies Tor block ports when the firewall is enabled; no separate toggle                            | Same as VPN: Linux has an explicit flag, Windows does not                                |
| `tor-block-ports`       | TCP ports used by Tor to block                                   | `9001,9030,9050,9051,9150`    | `TOR_BLOCK_PORTS` / `OPENPATH_TOR_BLOCK_PORTS` - `linux/lib/defaults.conf`           | `torBlockPorts` (array) - populated by `Get-DefaultTorBlockPorts` in `windows/lib/internal/Firewall.Catalog.ps1`         | Same default set on both platforms                                                       |
| `known-dns-ip-blocking` | Block known public DNS resolver IPs (non-DoH)                    | N/A                           | N/A                                                                                  | `enableKnownDnsIpBlocking` - `windows/lib/install/Installer.Config.ps1`                                                  | Windows-only switch; Linux relies on the firewall rules directly without a separate flag |
| `firewall-enabled`      | Master switch for all outbound firewall enforcement              | always active                 | N/A (Linux firewall is always activated on install; no runtime toggle)               | `enableFirewall` - `windows/lib/install/Installer.Config.ps1`                                                            | Linux does not expose a master enable/disable for the firewall                           |

### SSE (Real-Time Updates)

| Canonical name        | Purpose                                                        | Default | Linux key (and env override)                                                       | Windows config.json key                                                                                                                | Notes / aliases                                                        |
| --------------------- | -------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `sse-reconnect-min`   | Minimum reconnect delay after SSE drop (seconds)               | 5       | `SSE_RECONNECT_MIN` / `OPENPATH_SSE_RECONNECT_MIN` - `linux/lib/defaults.conf`     | `sseReconnectMin` - `windows/lib/install/Installer.Config.ps1`                                                                         | Exponential backoff starts here                                        |
| `sse-reconnect-max`   | Maximum reconnect delay with exponential backoff (seconds)     | 60      | `SSE_RECONNECT_MAX` / `OPENPATH_SSE_RECONNECT_MAX` - `linux/lib/defaults.conf`     | `sseReconnectMax` - `windows/lib/install/Installer.Config.ps1`                                                                         | Backoff is capped here                                                 |
| `sse-update-cooldown` | Minimum seconds between consecutive update triggers (debounce) | 10      | `SSE_UPDATE_COOLDOWN` / `OPENPATH_SSE_UPDATE_COOLDOWN` - `linux/lib/defaults.conf` | `sseUpdateCooldown` - default `10`, enforced in `windows/lib/internal/OpenPathConfig.Model.ps1` (`ConvertTo-OpenPathNormalizedConfig`) | Prevents thrashing when multiple SSE events arrive in rapid succession |

---

## Override Mechanisms

### Linux

All tunables can be overridden via:

1. **Environment variable** - set the `OPENPATH_*` variable before sourcing `linux/lib/defaults.conf` (see the env-var column above).
2. **Runtime config file** - write key=value pairs to `/etc/openpath/overrides.conf`; this file is sourced at the top of `linux/lib/defaults.conf` before any defaults are applied.

### Windows

All tunables are stored in the JSON config file (`config.json`) in the OpenPath installation directory. The file is written by `New-OpenPathInstallerConfig` (`windows/lib/install/Installer.Config.ps1`) at install time and can be edited by an operator. The `ConvertTo-OpenPathNormalizedConfig` function (`windows/lib/internal/OpenPathConfig.Model.ps1`) enforces floor values and fills missing fields with documented defaults on every read.

---

## Source Locations (verified)

| File                                                                                   | What it governs                                                                                    |
| -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `linux/lib/defaults.conf`                                                              | All Linux tunables and their `OPENPATH_*` env-var overrides                                        |
| `windows/lib/install/Installer.Config.ps1` - `New-OpenPathInstallerConfig`             | Windows config written to `config.json` at install time; canonical source of written defaults      |
| `windows/lib/internal/OpenPathConfig.Model.ps1` - `ConvertTo-OpenPathNormalizedConfig` | Windows runtime normalization; enforces `logMaxSizeMb`, `logKeepFiles`, `sseUpdateCooldown` floors |
| `windows/lib/internal/Common.Update.ps1`                                               | Runtime fallback for `updateIntervalMinutes` (defaults to `5` when the key is absent from config)  |
| `windows/lib/internal/Firewall.Catalog.ps1`                                            | Default catalogs for DoH/VPN/Tor rules                                                             |
