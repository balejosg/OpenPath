# Windows Outbound Egress Floor (operator opt-in + canary)

> Status: maintained
> Applies to: OpenPath operators running the Windows agent
> Last verified: 2026-11-03 (rule model validated on a lab VM; fleet canary pending)
> Source of truth: `docs/windows-egress-floor.md`

The outbound egress floor is an OPTIONAL, DEFAULT-OFF Windows hardening layer.
It cuts network access for restricted students except from approved browsers,
the OpenPath native host, and catalog applications explicitly marked
`network: true`. Teachers, administrators, SYSTEM, and services keep full
egress. This runbook explains the model, how to enable it on one device, how
to read what it blocked, and how to roll it back.

## What it closes

The DNS sinkhole stops name-based lookups, but a program can open a raw
connection to an IP literal and reach a non-whitelisted site. Examples are
FTP/SFTP clients, a `python.exe` bundled with an installed application,
MSBuild, `rundll32`, a custom-compiled executable, or a Store app. AppLocker
blocks the obvious tools, but it cannot enumerate every program that has a
network stack. The floor closes the residual by scoping egress by USER, not by
destination: a restricted student's process has no network unless the program
is one of the few allowed ones.

The Firefox extension complements it: navigations to a public IP literal are
redirected to the blocked screen (private, CGNAT, link-local, and loopback
literals stay reachable for captive portals and LAN gateways).

## The model

- Profile `DefaultOutboundAction=Block` on Domain, Private, and Public.
- Rules scoped by `-LocalUser` SDDL on the SID of the local group
  `OpenPath-Restricted` (resolved by SID, never by name, never widened to
  `BUILTIN\Users`). Students must be members of that group.
- One "everyone except the group" Allow keeps all non-student egress working,
  so there is no machine-wide program allow-list to maintain.
- The rule set is static: no IP lists and no whitelist dependency. It is
  applied by `Set-OpenPathFirewall` (`OpenPath.ps1 enable` / `update`),
  drift-checked and reapplied by the watchdog, and removed on disable and
  uninstall.

Rules (`G` = the `OpenPath-Restricted` SID; names carry the `OpenPath-DNS-`
prefix):

| Rule                                               | Action | Scope                                                          |
| -------------------------------------------------- | ------ | -------------------------------------------------------------- |
| `Allow-EgressFloor-NonStudent`                     | Allow  | LocalUser `D:(D;;CC;;;G)(A;;CC;;;WD)`, any protocol/remote     |
| `Allow-EgressFloor-NonStudentAppContainers`        | Allow  | Package `*`, LocalUser `D:(D;;CC;;;G)(A;;CC;;;WD)(A;;CC;;;AC)` |
| `Allow-EgressFloor-Student-<id>` (one per program) | Allow  | Program path, LocalUser `D:(A;;CC;;;G)`                        |
| `Allow-EgressFloor-Loopback`                       | Allow  | RemoteAddress `127.0.0.0/8`, `::1`                             |
| `Block-EgressFloor-StudentAppContainers`           | Block  | Package `*`, LocalUser `D:(A;;CC;;;G)(A;;CC;;;AC)`             |
| `Block-EgressFloor-ICMPv4-Internet`                | Block  | ICMPv4 to `Internet`                                           |
| `Block-EgressFloor-ICMPv6-Internet`                | Block  | ICMPv6 to `Internet`                                           |
| `Block-EgressFloor-SMB-Internet`                   | Block  | TCP 139/445 to `Internet`                                      |
| `Block-EgressFloor-WebClient-Internet`             | Block  | Service `WebClient` to `Internet`                              |

Student programs (`<id>` is the sanitized file stem plus an 8-hex SHA-256
prefix of the lower-cased path):

- approved student browser executables reported by the browser inventory
  (`approvedStudentBrowsers`, administrator-owned Release installs only);
- `C:\OpenPath\browser-extension\firefox\native\OpenPath-NativeHost.exe`;
- `approvedApplicationCatalog` entries with a `Path` identity under Program
  Files and `"network": true` (see
  [`windows-strict-application-allowlist.md`](windows-strict-application-allowlist.md)).

The `(A;;CC;;;AC)` ACE is required: without it an SDDL never matches an
AppContainer token, and the built-in "InternetClient Default Rule" would give
every student Store app egress.

### Safety behavior

- Fail-open: if the `OpenPath-Restricted` SID cannot be resolved, or any rule
  or profile change fails, the floor restores the pre-floor
  `DefaultOutboundAction` and removes its rules. It never leaves Block without
  the non-student Allow.
- The pre-floor outbound default is saved once to
  `C:\OpenPath\data\egress-floor-prev-outbound.json` and never overwritten
  while the floor is on (this also covers upgrades from the old IP-set floor,
  whose `-EgressFloor-Whitelist-*` / `-EgressFloor-System-*` rules are removed
  on first apply).
- If no approved browser is installed, the floor still applies: students have
  no browser egress, administrators are unaffected, a WARN is logged, and the
  watchdog reapplies once the browser path appears.
- The old config keys `outboundEgressFloorAllowIps` and
  `outboundEgressFloorSystemPrograms` are ignored with a WARN.

## Spike-derived caveats

- ICMP and SMB to the Internet are blocked for EVERYONE. Kernel-mode clients
  (ping, SMB) are attributed to `System`, not the user, so only a protocol
  Block can stop them for students. LAN ping and LAN SMB are unaffected.
- The Windows captive-portal sign-in window (an OS component) has no network
  for students. Students sign in to a captive portal from Firefox instead.
- There is no audit-only mode: with `DefaultOutboundAction=Allow`, Windows does
  not plumb outbound Allow rules into the filtering platform, so the rule set
  cannot be dry-run. Use the one-PC canary below instead.

## Known residuals

- Service-brokered egress: a student can ask a service that runs as SYSTEM to
  fetch something for them (BITS jobs over COM, other broker services). The
  non-student Allow covers those services. The `WebClient` Block closes the
  WebDAV case only.
- Web-content tunnels: anything reachable through an approved browser on a
  whitelisted site stays reachable. The floor does not inspect content.
- Not a substitute for AppLocker: keep the tool blocks and Appx denies on.

## Enable on a device

1. Make sure students are members of `OpenPath-Restricted` and teachers and
   administrators are NOT.
2. Edit `C:\OpenPath\data\config.json`:

   ```json
   {
     "outboundEgressFloorEnabled": true
   }
   ```

3. Apply (Administrator): `& C:\OpenPath\OpenPath.ps1 enable`. The watchdog
   would also apply it on its next cycle.
4. Verify:

   ```powershell
   (Get-NetFirewallProfile -All).DefaultOutboundAction   # expect Block
   Get-NetFirewallRule -DisplayName "*EgressFloor*" | Select-Object DisplayName, Action
   ```

Enabling the floor also turns on failure auditing for the "Filtering Platform
Connection" subcategory (`{0CCE9226-69AE-11D9-BED3-505054503030}`) so blocked
connections are recorded as Security event 5157. The previous setting is saved
to `C:\OpenPath\data\egress-floor-audit-prev.json` and restored on rollback.

## See what was blocked: `egress-report`

```powershell
& C:\OpenPath\OpenPath.ps1 egress-report        # last 24 hours
& C:\OpenPath\OpenPath.ps1 egress-report 12     # last 12 hours
```

It prints one line per application with its blocked destinations, read from
outbound Security 5157 events (loopback excluded). Event 5157 carries no user
SID, but under the floor non-students are allowed everything, so an outbound
block is student (or kernel ICMP/SMB) traffic.

For each legitimate application in the report, either add a catalog `Path`
entry with `"network": true` (the program must live under Program Files) or
decide it stays blocked.

## Canary procedure

1. Pick ONE real classroom PC with the normal image. Do not use CI runners.
2. Enable the floor (above) before the school day.
3. Run one school day of normal lessons.
4. Read `OpenPath.ps1 egress-report 12` and triage every application.
5. Add `network: true` catalog entries as needed, re-apply, and repeat until a
   day produces no legitimate blocks. Only then widen the cohort.

## Roll back

Set `"outboundEgressFloorEnabled": false` and run
`& C:\OpenPath\OpenPath.ps1 enable` (or `update`). The floor restores the
saved `DefaultOutboundAction`, removes every `*-EgressFloor-*` rule, and
restores the previous audit setting. `OpenPath.ps1 disable` and uninstall do
the same. Verify:

```powershell
(Get-NetFirewallProfile -All).DefaultOutboundAction                 # pre-floor value
Get-NetFirewallRule -DisplayName "*EgressFloor*" | Measure-Object   # Count 0
```
