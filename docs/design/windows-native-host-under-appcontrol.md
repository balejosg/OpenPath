# Windows native host under the AppControl boundary

Status: design only, no implementation. Phase 3A.3, pending product decision.

## Problem

Every Firefox first visit in a classroom deployment runs with the OpenPath
non-admin AppLocker boundary installed. The boundary emits `BlockedWindowsTools`
as explicit DENY rules for the restricted SID (`OpenPath-Restricted`), including:

- `%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe`
- `%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`
- `%PROGRAMFILES%\PowerShell\7\pwsh.exe`

The registered Firefox native messaging host is launched by the browser **as
the signed-in student**, and its launcher is exactly that interpreter:

```
whitelist_native_host.json -> ...\OpenPath-NativeHost.cmd
OpenPath-NativeHost.cmd    -> powershell.exe -File OpenPath-NativeHost.ps1
```

So the host cannot start: the process is denied by policy before any protocol
frame is processed. The E1 evidence recorded by the lane (Phase 3A.3 H0) shows
the deny events for the student and no `initialization completed` line in the
per-user host log, with the managed XPI fetched and the add-on active.

This is a production defect: in a classroom install the extension is installed
and enabled but has no host to talk to, so the runtime-dependency queue, the
whitelist mirror refresh and the first-visit reload decisions never happen. The
same deny blocks every other entry point that shells out to the host launcher.

The lab lane used in Phases 3A/3A.2 installed in autonomous mode
(`-WhitelistUrl -Unattended`, `enableNonAdminAppControl=false`), which is why
earlier phases did not see the failure. The lane now installs with the managed
boundary, matching production.

## Actions the extension sends to the host

Source: `docs/extension-native-host-contract.md` and
`firefox-extension/src/lib/native-messaging-client.ts`.

| Action                                   | Direction         | Needs the student's session? | Notes                                                 |
| ---------------------------------------- | ----------------- | ---------------------------- | ----------------------------------------------------- |
| `ping` (availability probe)              | extension -> host | yes (the browser spawns it)  | must answer `pong` with version/protocol/capabilities |
| `enqueue` (runtime dependency / request) | extension -> host | no                           | validated and applied in the SYSTEM worker            |
| `check` (whitelist/config freshness)     | extension -> host | no                           | reads the whitelist mirror + config                   |
| `get-policy-version`                     | extension -> host | no                           | reads staged policy state                             |
| `diagnostic` / diagnostic batch          | extension -> host | no                           | E1 evidence written to the per-user log               |
| captive portal recovery trigger          | extension -> host | no                           | touches the SYSTEM scheduled task                     |
| reload/hold decisions                    | host -> extension | n/a                          | host-side decision, extension acts                    |

Only `ping` and the _transport attachment_ inherently require a process started
by the browser in the student's session. Every payload is already validated and
applied by the SYSTEM worker (`OpenPath-RuntimeDependencyWorker`,
`OpenPath-Update`), never by the host process itself.

## Recommended fix: a compiled host under `C:\OpenPath`

Ship a small compiled native host (C#) whose executable lives under the OpenPath
runtime root, so the existing allow rule covers it:

- `windows/lib/AppControl.psm1` builds `$openPathRuntimePath =
"$OpenPathRoot\*"` and adds it to `AllowPaths` / `AllowPathsByCollection`
  (`Exe` and `Script`) for the restricted SID in both the compatibility and the
  strict profile, confirmed in the current source.
- A binary under `C:\OpenPath\...\OpenPath-NativeHost.exe` is therefore allowed
  for `OpenPath-Restricted` while `powershell.exe` remains denied.

Build and packaging rules:

1. **No binaries in the repository.** The installer compiles the host on the
   target machine with the C# compiler that ships with the .NET Framework
   (`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, present on every
   supported Windows client). The source file ships as a payload.
2. The staged executable lands under the OpenPath capability storage root next
   to today's script, and the native messaging manifest `path` changes from the
   `.cmd` wrapper to the `.exe`. `Register-OpenPathFirefoxNativeHost` owns the
   registration (both registry views) and the manifest content.
3. **Identical wire protocol**: same framing (4-byte little-endian length +
   UTF-8 JSON), same action names, same response shapes, same E1 log lines. The
   contract tests that parse the protocol stay authoritative; a new contract
   test asserts the manifest path points at the `.exe` and that no launcher
   interpreter is required.
4. **Validation stays in the SYSTEM worker.** The host only forwards, formats
   and reads staged state; it never applies policy, so the compiled surface stays
   small.
5. **Integrity, uninstall, offline installer manifest, registration.** The
   existing artifact catalog (`NativeHost.ArtifactCatalog.ps1`) and uninstall
   flow must stage/remove the `.exe` and the `.cs` source; the offline
   installer payload manifest must list them; `Test-OpenPath...` readiness
   checks must accept the compiled host as "host staged".
6. **Anti-regression for W-1(a).** `powershell.exe`/`pwsh.exe` stay denied for
   restricted users: the fix must not relax any deny rule.

## Alternatives considered and rejected

- **Allow `powershell.exe` for the restricted SID.** Reopens W-1(a): any
  standard user can then launch an interpreter that opens a socket to a literal
  IP and spoofs the Host header, bypassing the name-based whitelist. Rejected.
- **Copy `powershell.exe`/`pwsh.exe` under `C:\OpenPath`.** The AppLocker rules
  are path-based; the copy would be allowed, and it is a full scripting host the
  student can reach (`C:\OpenPath\...\powershell.exe -c ...`), i.e. the same
  W-1(a) surface. Rejected.
- **Move the host to `%PROGRAMFILES%`.** `%PROGRAMFILES%\*` is allowed, but the
  `BlockedWindowsTools` denies are explicit path denies evaluated over allows,
  so a copied interpreter would still be a reachable interpreter; and shipping a
  second interpreter is worse than compiling our own host. Rejected.
- **Run the host in the SYSTEM session** (scheduled task + IPC). The browser
  needs the native messaging pipe in its own session; there is no supported way
  to bridge the pipe across sessions without an in-session process. Rejected as
  the primary design; the SYSTEM worker already handles the privileged work.

## Functions broken today by the same deny

Everything that reaches the browser through the native host while the boundary
is enforced: `enqueue` (runtime dependencies), `check` (whitelist/config
freshness), `get-policy-version`, captive portal recovery triggers, the
diagnostic batch, and the extension's availability check. The lane's
`native-host-blocked-by-appcontrol` product reason is the observable symptom.

## Test plan

1. **Protocol contract (unit):** existing contract tests keep the wire format
   and action names fixed for both hosts; a new test compiles the C# source in
   CI (on the Windows runner) and runs a framed `ping` end to end.
2. **Installers:** offline installer payload manifest lists the host source;
   uninstall removes it; native host registration points at the `.exe`; the
   `Test-...` readiness probe passes with only the compiled host staged.
3. **Boundary acceptance (lab, mandatory):** on an image installed with
   `enableNonAdminAppControl=true` (`StrictApplicationAllowlist`), run the host
   **as the restricted student** with a framed `ping` and assert a valid
   `pong`; assert `powershell.exe` is still denied for the same user (W-1(a)
   regression guard); assert `native-host.log` records `initialization
completed`.
4. **First-visit lane:** `native-host-blocked-by-appcontrol` must disappear for
   a template that ships the compiled host, while the production template keeps
   reporting it until the fix lands.
