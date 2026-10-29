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

| Order | Source                                                                                                                                                                                  | Owner                                  |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 1     | RSoP (`root\rsop\computer`, `RSOP_RegistryPolicySetting`) with `GPOID` `LocalGPO`                                                                                                       | `LocalGpo`                             |
| 1     | RSoP with any other `GPOID` (lowest `precedence` wins; ties prefer the non-local record)                                                                                                | `DomainGpo` (GPO name from `RSOP_GPO`) |
| 2     | The value exists in the local `Registry.pol`                                                                                                                                            | `LocalGpo`                             |
| 3     | A `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device` area whose name contains `Firefox`, `Chrome` or `Edge` (matching the key) holds a value named `<ValueName>` or `*~<ValueName>` | `Mdm`                                  |
| 4     | The value exists in the registry only (for example written by an older OpenPath)                                                                                                        | `Unknown`                              |
| 5     | Nothing found                                                                                                                                                                           | `None`                                 |

RSoP is queried with a WQL filter on the policy key (`registryKey = '<key>'`), and
the key and value name are compared again case-insensitively. MDM ownership is per
value: an Intune-managed browser area that does not contain the requested value does
not block it. Whole-key lookups for list policies match the last key segment, for
example `URLBlocklist` or `ExtensionInstallForcelist`.

What OpenPath does with each owner:

- `None`, `Unknown`, `LocalGpo`: OpenPath writes (see below).
- `DomainGpo`, `Mdm`: OpenPath does not write. The call returns the failure code
  `policy-externally-managed` and the agent logs a WARN naming the owner.

If RSoP is unavailable the lookup continues with rule 2 and records
`rsop-unavailable` as evidence. Without RSoP a domain GPO cannot be seen, so the
result degrades to `LocalGpo`, `Mdm` heuristics, or `Unknown`.

## What OpenPath writes and where

All normal writes go through `PolicyStore.psm1`. The only exceptions are the legacy
numbered-value cleanup that `Remove-BrowserPolicy` runs before removing a list, the
registry-only hand-back of Firefox vendor entries (see Uninstall), and the
direct-registry fallback in `Uninstall-OpenPath.ps1`.

Every `Registry.pol` and ledger read-modify-write runs under the machine-wide mutex
`Global\OpenPath-LocalGpo-v1`, with a bounded wait of 30 seconds. An abandoned mutex
counts as acquired; a timeout returns `local-gpo-busy` without writing. AppLocker and
other writers replace `Registry.pol` without that mutex, so the store re-reads the
file right before replacing it. If the bytes changed since the merge was computed,
the merge is recomputed from the new content, at most three times, and then the call
returns `local-gpo-busy`.

1. Merge the value into `C:\Windows\System32\GroupPolicy\Machine\Registry.pol`
   (PReg version 1). A new file is created when none exists. Existing entries from
   other writers are kept. The previous file is kept as `Registry.pol.openpath-bak`
   while the new bytes are swapped in. Before the first write of a scalar value, the
   ledger records what `Registry.pol` held for it (see the ledger).
2. Bump the machine `Version` in `C:\Windows\System32\GroupPolicy\gpt.ini` only when
   the `Registry.pol` bytes actually changed. A no-op sync does not touch either file.
   The version is an unsigned 32-bit number; the machine half wraps from 65535 to 1.
   Hidden, System and ReadOnly attributes on either file are cleared for the write
   and restored afterwards.
3. Mirror the value into `HKLM\SOFTWARE\Policies` so it is effective immediately,
   without waiting for a refresh.
4. In the classroom-mode, registered install path, the installer forces
   `gpupdate /target:computer /force` before the Firefox readiness check. A restart
   prompt is answered `N` on standard input; a non-zero exit is logged as a WARN that
   some policies may require a restart. The watchdog repeats the Firefox sync each cycle (idempotent) and tracks only the
   owner of Firefox `ExtensionSettings`: every owner change is recorded in the
   ledger, and a WARN is logged once only when the new owner is `DomainGpo` or `Mdm`.

Values written:

- Firefox: `Mozilla\Firefox\ExtensionSettings`. The OpenPath entry is merged into
  the existing JSON. Vendor entries and the existing value type (REG_SZ or
  MULTI_SZ) are preserved. If the current value cannot be parsed, OpenPath fails
  closed and does not overwrite it.
- Chrome and Edge: the list policies `URLBlocklist` and `ExtensionInstallForcelist`
  are synced as lists (see the ledger). Scalar policies use the same store path.
  Each list owner is resolved once and handed to the sync. When a list key is
  registry-only (owner `Unknown`, written directly by an older agent), the sync
  prunes those numbered registry values only after `Registry.pol` holds the new
  list, so a failed sync never leaves the blocklist empty.

## Failure codes

| Code                                        | Meaning                                                                                                                                      | Operator action                                                                                 |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `policy-externally-managed`                 | A domain GPO or MDM owns the value; nothing was written.                                                                                     | Add the OpenPath entry to that policy (next section).                                           |
| `firefox-machine-policy-externally-managed` | Firefox readiness result for the same situation. The message includes the exact JSON entry to add.                                           | Same as above.                                                                                  |
| `local-gpo-unreadable`                      | `Registry.pol` is truncated, corrupt, or lacks the PReg header. OpenPath refuses to write rather than overwrite it.                          | Inspect the file (a `.openpath-bak` copy may exist), repair or remove it, then re-run the sync. |
| `local-gpo-write-failed`                    | `Registry.pol` could not be written (permissions, locks, disk).                                                                              | Check disk space, ACLs and security software; retry.                                            |
| `gpt-ini-bump-failed`                       | `Registry.pol` was written but `gpt.ini` was not versioned. The registry mirror is correct now, but Group Policy may not re-apply the value. | Fix `gpt.ini` access, then re-run; the next sync bumps the version.                             |
| `registry-write-failed`                     | The registry mirror failed.                                                                                                                  | Check HKLM permissions and policy-protecting software.                                          |
| `local-gpo-busy`                            | Another writer held the store mutex for 30 seconds, or `Registry.pol` changed three times in a row while merging. Nothing was written.       | Usually transient; the next sync retries. Check for a stuck OpenPath or policy process.         |
| `ledger-write-failed`                       | The policy store ledger could not be saved, so nothing was written to `Registry.pol`.                                                        | Check that `HKLM\SOFTWARE\OpenPath\PolicyStore` is writable.                                    |

## When a domain GPO or MDM owns the value

OpenPath cannot and will not edit policy it does not own. The browser extension or
blocklist then only works if the owning policy contains OpenPath's entries.

- Firefox: the readiness result reports
  `firefox-machine-policy-externally-managed` and prints the exact entry to add,
  shaped like this:

  ```json
  "<extension-id>": { "installation_mode": "force_installed", "install_url": "https://openpath.example.invalid/...", "private_browsing": true }
  ```

  Add that entry to the `ExtensionSettings` JSON in the domain GPO or in the MDM
  profile that owns it. Readiness reads the effective `HKLM` value, so it turns
  ready after the next policy refresh.

- Chrome and Edge: unlike Firefox, no ready-made entry is printed. The agent log
  only says
  `Chromium policy <key> is managed by <Owner> (<GpoName>); OpenPath cannot write it`.
  The entries to add come from the OpenPath policy and whitelist configuration of
  that machine (the extension force-install entry and the
  blocked-domain list), which the administrator must copy into the owning policy.
- After editing the owning policy, run `gpupdate /target:computer /force` (or wait
  for the MDM sync). The next watchdog cycle or update run then re-checks the value.

## The policy store ledger

List policies are numbered values (`1`, `2`, ...) that vendors may also use, and
scalar values may replace a vendor value. To change only what OpenPath wrote, the
store keeps a ledger in the registry, outside the install root, as the REG_SZ JSON
value `Ledger` under `HKLM\SOFTWARE\OpenPath\PolicyStore`:

- `lists`: the entries OpenPath last wrote per list policy.
- `lastOwners`: the last owner seen per value, used to log owner changes once.
- `originals`: per scalar `Key|ValueName`, the `Registry.pol` state before OpenPath's
  first write: either `{ "inPol": false }` or
  `{ "inPol": true, "type": <n>, "dataBase64": "..." }`. An existing original is
  never overwritten, and a write that does not change `Registry.pol` records none.

On sync, OpenPath removes the entries recorded in the ledger, keeps everything else,
appends the current entries after the highest vendor index, and updates the ledger.
The ledger is written before `Registry.pol` (fail closed): if it cannot be saved,
nothing is written. A missing or corrupt ledger is treated as empty (a WARN is
logged).

Builds that kept the ledger in `<OpenPathRoot>\data\policy-store-ledger.json` are
migrated once: when the registry value is absent, the file is imported and then
deleted. Because the ledger now survives a reinstall or a wiped `data` folder,
OpenPath's own entries are not mistaken for vendor entries afterwards.

## Uninstall and rollback

- `Remove-BrowserPolicy` and the Firefox removal remove only OpenPath's entries.
  The ledger entries are subtracted from the Chromium lists. For a scalar value with
  a recorded original, the vendor entry OpenPath replaced is restored in
  `Registry.pol` and in the registry mirror; when the original was absent, or no
  original is recorded (lost or older ledger), the value is deleted.
- Firefox `ExtensionSettings`: OpenPath's entry is subtracted from the merged value.
  If the value was in `Registry.pol` before OpenPath (or no original is recorded),
  the remaining vendor entries are written back to `Registry.pol` with their type.
  If it was not, the remaining entries came from the registry, so the
  `Registry.pol` entry is removed and they are written back to the registry only.
  A value that held only OpenPath's entry is deleted.
- Fail-open (`EndpointStateReconciler` calling
  `Remove-BrowserPolicy -PreserveFirefoxManagedExtension`) keeps the Firefox
  extension policy but removes the Chromium lists and scalars too, restoring
  recorded originals.
- `Uninstall-OpenPath.ps1` deletes `HKLM\SOFTWARE\OpenPath\PolicyStore` after the
  browser policy removal, but only when every removal succeeded. After a failure or
  an externally managed value, the ledger is kept so a later install still
  recognises the entries left behind. Firefox ids that are always tried (current
  and legacy) and are not in `ExtensionSettings` are not reported as failures.
- Rollback and reinstall cleanup (`Installer.Cleanup.ps1`) runs the cleanup with
  the previous install's modules before the install root is wiped. When that
  install has no `lib\Browser.psm1`, a warning says the local GPO may still hold
  OpenPath entries.
- The same ownership rules apply on removal: nothing is removed from a value owned
  by a domain GPO or MDM.

## Known limits

- Domain GPO and MDM paths are covered by unit tests only. No domain controller or
  MDM was available in the lab, so these were not verified on a live machine.
- MDM detection relies on PolicyManager naming: a browser area whose name contains
  the browser name and a value named like the policy (or ending in `~<ValueName>`).
  An MDM that stores the policy under a different value name is not detected.
- When RSoP is unavailable, a domain GPO is invisible and the owner may be
  reported as `LocalGpo` or `Unknown`.
- Only machine-scope policy is handled; per-user policy is out of scope.
