# Windows Browser Policy Ownership and the Local GPO Store

> Status: maintained
> Applies to: OpenPath operators and maintainers of the Windows agent
> Last verified: 2026-10-29
> Source of truth: `windows/lib/PolicyStore.psm1`,
> `windows/lib/internal/PolicyStore.Owner.ps1`,
> `windows/lib/internal/PolicyStore.RegistryPol.ps1`,
> `windows/lib/Browser.FirefoxPolicy.psm1`, and `windows/lib/Browser.psm1`

The Windows agent configures Firefox, Chrome and Edge through machine policy under
`HKLM\SOFTWARE\Policies`. This document explains who owns those values, where
OpenPath writes them, and what an operator must do when something else owns them.

## The problem

Writing a policy value straight into the registry is not durable when the machine has
a local Group Policy Object (GPO) that defines the same value. The Group Policy
Registry client-side extension rewrites `HKLM\SOFTWARE\Policies` from
`C:\Windows\System32\GroupPolicy\Machine\Registry.pol` whenever Group Policy
refreshes. Windows itself triggers a refresh when the AppLocker policy is applied,
which OpenPath does during install.

A typical failure: an OEM image whose local GPO defines Firefox `ExtensionSettings`
(for example, two `blocked` vendor entries stored as REG_SZ). OpenPath wrote a merged
MULTI_SZ value, the AppLocker refresh restored the vendor-only value, and the
managed extension readiness check failed with `firefox-machine-policy-missing`.

The fix is to treat the local GPO as the store: merge OpenPath's entries into
`Registry.pol` so every refresh reproduces them.

## Ownership model

Every policy value is resolved to one owner before OpenPath writes it
(`Get-OpenPathPolicyValueOwner`). The first rule that matches wins:

| Order | Source                                                                                                                                       | Owner                                  |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 1     | RSoP (`root\rsop\computer`, `RSOP_RegistryPolicySetting`) with `GPOID` `LocalGPO`                                                            | `LocalGpo`                             |
| 1     | RSoP with any other `GPOID` (lowest `precedence` wins; ties prefer the non-local record)                                                     | `DomainGpo` (GPO name from `RSOP_GPO`) |
| 2     | The value exists in the local `Registry.pol`                                                                                                 | `LocalGpo`                             |
| 3     | `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device` has an area whose name contains `Firefox`, `Chrome` or `Edge` matching the policy key | `Mdm`                                  |
| 4     | The value exists in the registry only (for example written by an older OpenPath)                                                             | `Unknown`                              |
| 5     | Nothing found                                                                                                                                | `None`                                 |

What OpenPath does with each owner:

- `None`, `Unknown`, `LocalGpo`: OpenPath writes (see below).
- `DomainGpo`, `Mdm`: OpenPath does not write. The call returns the failure code
  `policy-externally-managed` and the agent logs a WARN naming the owner.

If RSoP is unavailable the lookup continues with rule 2 and records
`rsop-unavailable` as evidence. Without RSoP a domain GPO cannot be seen, so the
result degrades to `LocalGpo`, `Mdm` heuristics, or `Unknown`.

## What OpenPath writes and where

All normal writes go through `PolicyStore.psm1`. The only exceptions are the legacy
numbered-value cleanup in `Browser.psm1` and the direct-registry fallback in
`Uninstall-OpenPath.ps1`.

1. Merge the value into `C:\Windows\System32\GroupPolicy\Machine\Registry.pol`
   (PReg version 1). A new file is created when none exists. Existing entries from
   other writers are kept. The previous file is kept as `Registry.pol.openpath-bak`
   while the new bytes are swapped in.
2. Bump the machine `Version` in `C:\Windows\System32\GroupPolicy\gpt.ini` only when
   the `Registry.pol` bytes actually changed. A no-op sync does not touch either file.
3. Mirror the value into `HKLM\SOFTWARE\Policies` so it is effective immediately,
   without waiting for a refresh.
4. In the classroom-mode, registered install path, the installer forces
   `gpupdate /target:computer /force` before the Firefox readiness check. The
   watchdog repeats the Firefox sync each cycle (idempotent) and tracks only the
   owner of Firefox `ExtensionSettings`: every owner change is recorded in the
   ledger, and a WARN is logged once only when the new owner is `DomainGpo` or `Mdm`.

Values written:

- Firefox: `Mozilla\Firefox\ExtensionSettings`. The OpenPath entry is merged into
  the existing JSON. Vendor entries and the existing value type (REG_SZ or
  MULTI_SZ) are preserved. If the current value cannot be parsed, OpenPath fails
  closed and does not overwrite it.
- Chrome and Edge: the list policies `URLBlocklist` and `ExtensionInstallForcelist`
  are synced as lists (see the ledger). Scalar policies use the same store path.
  Legacy registry-only values from older agents are migrated into the store on the
  next sync.

## Failure codes

| Code                                        | Meaning                                                                                                                                      | Operator action                                                                                 |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `policy-externally-managed`                 | A domain GPO or MDM owns the value; nothing was written.                                                                                     | Add the OpenPath entry to that policy (next section).                                           |
| `firefox-machine-policy-externally-managed` | Firefox readiness result for the same situation. The message includes the exact JSON entry to add.                                           | Same as above.                                                                                  |
| `local-gpo-unreadable`                      | `Registry.pol` is truncated, corrupt, or lacks the PReg header. OpenPath refuses to write rather than overwrite it.                          | Inspect the file (a `.openpath-bak` copy may exist), repair or remove it, then re-run the sync. |
| `local-gpo-write-failed`                    | `Registry.pol` could not be written (permissions, locks, disk).                                                                              | Check disk space, ACLs and security software; retry.                                            |
| `gpt-ini-bump-failed`                       | `Registry.pol` was written but `gpt.ini` was not versioned. The registry mirror is correct now, but Group Policy may not re-apply the value. | Fix `gpt.ini` access, then re-run; the next sync bumps the version.                             |
| `registry-write-failed`                     | The registry mirror failed.                                                                                                                  | Check HKLM permissions and policy-protecting software.                                          |
| `ledger-write-failed`                       | The Chromium list ledger could not be saved.                                                                                                 | Check that `<OpenPathRoot>\data` is writable.                                                   |

## When a domain GPO or MDM owns the value

OpenPath cannot and will not edit policy it does not own. The browser extension or
blocklist then only works if the owning policy contains OpenPath's entries.

- Firefox: the readiness result reports
  `firefox-machine-policy-externally-managed` and prints the entry, shaped like
  `"<extension-id>": { "installation_mode": "force_installed", "install_url": "https://openpath.example.invalid/...",
"private_browsing": true }`. The exact entry is printed in the readiness message.
  Add that entry to the `ExtensionSettings` JSON in the domain GPO or in the MDM
  profile that owns it. Readiness reads the effective `HKLM` value, so it turns
  ready after the next policy refresh.
- Chrome and Edge: unlike Firefox, no ready-made entry is printed. The agent log
  only says `Chromium policy <key> is managed by <Owner> (<GpoName>); OpenPath
cannot write it`. The entries to add come from the OpenPath policy and whitelist
  configuration of that machine (the extension force-install entry and the
  blocked-domain list), which the administrator must copy into the owning policy.
- After editing the owning policy, run `gpupdate /target:computer /force` (or wait
  for the MDM sync). The next watchdog cycle or update run then re-checks the value.

## The Chromium list ledger

List policies are numbered values (`1`, `2`, ...) that vendors may also use. To
change only OpenPath's items, the store keeps a ledger at
`<OpenPathRoot>\data\policy-store-ledger.json`:

- `lists`: the entries OpenPath last wrote per list policy.
- `lastOwners`: the last owner seen per value, used to log owner changes once.

On sync, OpenPath removes the entries recorded in the ledger, keeps everything else,
appends the current entries after the highest vendor index, and updates the ledger.
A missing or corrupt ledger is treated as empty (a WARN is logged) and never fails
the sync.

## Uninstall and rollback

- `Remove-BrowserPolicy` and the Firefox removal remove only OpenPath's entries:
  the Firefox `ExtensionSettings` entry is subtracted from the merged value and the
  ledger entries are subtracted from the Chromium lists. Vendor entries stay, with
  their original types. A value that OpenPath alone created is deleted.
- Rollback and reinstall cleanup (`Installer.Cleanup.ps1`) runs the cleanup with
  the previous install's modules, before the install root and its ledger are wiped,
  so the store can still recognise its own entries.
- The same ownership rules apply on removal: nothing is removed from a value owned
  by a domain GPO or MDM.

## Known limits

- Domain GPO and MDM paths are covered by unit tests only. No domain controller or
  MDM was available in the lab, so these were not verified on a live machine.
- MDM detection is a heuristic (a PolicyManager device area whose name contains the
  browser name). It can report `Mdm` for an unrelated area of the same browser, in
  which case OpenPath does not write.
- When RSoP is unavailable, a domain GPO is invisible and the owner may be
  reported as `LocalGpo` or `Unknown`.
- Only machine-scope policy is handled; per-user policy is out of scope.
