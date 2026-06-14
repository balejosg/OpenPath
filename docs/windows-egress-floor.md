# Windows Outbound Egress Floor (operator opt-in + canary)

> Status: maintained
> Applies to: OpenPath operators running the Windows agent
> Last verified: 2026-06-14
> Source of truth: `docs/windows-egress-floor.md`

The outbound egress floor is an OPTIONAL, DEFAULT-OFF Windows hardening layer. This
runbook explains what it does, why it is opt-in, how to enable it on a pilot
cohort, how to grow the allow-list, and how to roll it back.

## What it closes

The DNS sinkhole stops name-based lookups, but a program can still open a raw
connection to an arbitrary IP literal on 443 with a spoofed `Host:` header and
reach a non-whitelisted site. The AppLocker tool-blocks (`powershell`, `pwsh`,
`ftp`, `tftp`) and Appx denies (WSL, Windows Terminal, OpenSSH) -- which are ON by
default -- stop the easy paths. The egress floor closes the residual: a
user-supplied or custom-compiled program doing IP-literal egress. With the floor
on, a non-system program can only reach whitelist-resolved IPs on TCP 80/443.

## How it works

When enabled and a non-empty whitelist-IP set resolves, the floor:

- sets a machine-wide outbound default-deny:
  `Set-NetFirewallProfile -Profile Domain,Private,Public -DefaultOutboundAction Block`;
- adds ALLOW rules that carve back the permitted egress (an Allow overrides the
  profile default block; the floor creates no competing explicit Block rule):
  - system-service programs -- full egress (any protocol/port/remote);
  - each resolved whitelist IP -- TCP 80/443;
  - IPv4 loopback (127.0.0.1) and DHCP (UDP 67/68);
- refreshes the whitelist-IP allows as CDN addresses rotate (watchdog, per cycle).

Inbound is never touched (`DefaultInboundAction` is left as-is), so RDP / WinRM /
remote management keep working.

## Why it is OFF by default

- It is an ALL-PORT machine-wide default-deny, broader than the Linux agent's
  name-aware egress (which scopes only 80/443). Windows has no working 443-only
  scoping for this: an explicit Block rule wins over an Allow on the Windows
  Filtering Platform, so the only mechanism that lets the system-service Allows
  function is the profile-level default block.
- Any legitimate NON-whitelisted egress by non-system software is blocked unless
  that program is on the system-service allow-list. Real managed devices run
  software a CI runner does not -- MDM/Intune agents, Defender cloud lookups, OEM
  agents, licensing checks. Whether the allow-list is complete is per-fleet and
  cannot be proven from one machine.
- Validation status: the mechanism and the reachability matrix were confirmed on
  a real Windows runner on 2026-06-14 (a non-system program was blocked from a
  non-whitelisted IP, reached a whitelisted IP, and a system program still reached
  any IP -- no brick). Allow-list completeness across a real fleet is NOT
  validated. That is what the canary establishes.

## Fail-open brick-guard

If whitelist-IP resolution yields an EMPTY set (Acrylic down, empty whitelist),
the floor does NOT set the default block: it restores the prior default and clears
its rules, so a resolution outage cannot black-hole all egress. Note this does NOT
protect a legitimate but un-listed program when resolution succeeds -- that
program is blocked until you add it (see Grow the allow-list).

## Enable on a device

1. Edit `C:\OpenPath\data\config.json` and set:

   ```json
   {
     "outboundEgressFloorEnabled": true
   }
   ```

   Optionally pre-extend the allow-list for software your image ships (see Grow
   the allow-list):

   ```json
   {
     "outboundEgressFloorEnabled": true,
     "outboundEgressFloorSystemPrograms": ["C:\\Program Files\\Vendor\\agent.exe"]
   }
   ```

2. Apply (Administrator): `& C:\OpenPath\OpenPath.ps1 enable` re-applies DNS +
   firewall enforcement and reads the flag. `& C:\OpenPath\OpenPath.ps1 update`
   does the same as part of a full update. The watchdog also re-applies on its
   cycle, so a device picks the change up within about a minute regardless.

3. Verify:

   ```powershell
   (Get-NetFirewallProfile -All).DefaultOutboundAction   # expect Block
   Get-NetFirewallRule -DisplayName "*EgressFloor*" | Measure-Object
   & C:\OpenPath\OpenPath.ps1 status                     # Firewall active: True
   ```

## What the default allow-list covers

System-service programs granted full egress out of the box:

- `svchost.exe` -- hosts Windows Update / BITS / Delivery Optimization / W32Time;
  these have no per-service exe, so `svchost.exe` itself is allowed. This is a
  deliberate residual-surface trade-off (a malicious svchost-hosted service would
  be permitted); the floor is defense-in-depth on top of the sinkhole + AppLocker,
  not a replacement.
- `w32tm.exe` (time sync), `UsoClient.exe`, `MoUsoCoreWorker.exe`,
  `TrustedInstaller.exe` (update workers).
- The OpenPath agent: `powershell.exe` (System32 + SysWOW64) and `pwsh.exe`
  (Program Files + Program Files (x86)).
- `AcrylicService.exe` (the local DNS proxy and its upstream).

Managed browsers (`firefox.exe`, `chrome.exe`) are deliberately NOT on this list:
restricting them to whitelisted IPs is the point.

## Grow the allow-list (the canary's main job)

Add absolute program paths to `outboundEgressFloorSystemPrograms` for any
device-management, security, or OEM agent that legitimately needs non-whitelisted
egress, for example:

- Intune / MDM: `omadmclient.exe`, `dmclient.exe`
- Microsoft Defender: `MsMpEng.exe`, `MpCmdRun.exe`
- any vendor / OEM agents your image ships

A path that does not exist on a given device simply never matches, so
over-listing is safe.

## Canary procedure (toward fleet-wide)

1. Pick a small, REPRESENTATIVE set of real managed devices -- the actual image
   with the same MDM, AV, and OEM agents. Do NOT use CI runners: they lack fleet
   software and a default-deny would also cut their own CI egress.
2. Turn on blocked-connection logging to discover gaps:

   ```powershell
   Set-NetFirewallProfile -All -LogBlocked True `
     -LogFileName "%SystemRoot%\System32\LogFiles\Firewall\pfirewall.log"
   ```

3. Enable the floor on the canary cohort and run normal workloads for a
   representative window (a school day).
4. Inspect `pfirewall.log` for dropped OUTBOUND connections by legitimate
   processes. For each, either add the program to
   `outboundEgressFloorSystemPrograms`, or add the destination to the whitelist if
   it is a site the cohort should reach. Re-apply.
5. Monitor the enforcement heartbeat in the console for the cohort -- the
   `enforcement-down`, `enforcement-unknown`, and `whitelist-stale` alerts -- and
   watch for support reports of broken legitimate apps.
6. Iterate until a canary day produces no new legitimate drops. Only then widen
   the cohort, and finally consider fleet-wide. Keep `LogBlocked` on through early
   rollout so new gaps surface.

## Roll back

Set `"outboundEgressFloorEnabled": false` in `config.json` and run
`& C:\OpenPath\OpenPath.ps1 enable` (or `update`). The floor restores the prior
`DefaultOutboundAction` and removes its `*-EgressFloor-*` rules; the same restore
runs on `OpenPath.ps1 disable` and on uninstall. Verify:

```powershell
(Get-NetFirewallProfile -All).DefaultOutboundAction          # back to prior value
Get-NetFirewallRule -DisplayName "*EgressFloor*" | Measure-Object   # Count 0
```

## Known limitations

- All-port default-deny: a non-system program can only reach whitelisted IPs on
  80/443; anything else (other ports, non-whitelisted IPs) is blocked. This is the
  intended lockdown but is broader than the Linux agent's 80/443 scoping.
- IPv6-only whitelisted hosts: the per-IP allows are IPv4; an IPv6-only
  whitelisted host is unreachable while the floor is on.
- Not a substitute for AppLocker: keep the tool-blocks and Appx denies on.
