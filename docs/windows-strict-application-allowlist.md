# Windows strict application allowlist

OpenPath keeps `ManagedBrowserCompatibility` as the default AppControl profile.
That profile permits applications installed in administrator-controlled Program
Files locations and blocks supported, discovered unapproved browsers plus
student-writable execution surfaces.

`StrictApplicationAllowlist` is an explicit opt-in. It removes the generic
Program Files and Microsoft packaged-app allows for restricted students. Its
restricted-user executable baseline is limited to `%WINDIR%`, the OpenPath
installation root, approved browser executable identities returned by the
canonical browser inventory, and entries in `approvedApplicationCatalog`.
The strict policy enables and validates the Exe, Script, Msi, Dll, and Appx
collections independently: MSI/script/Appx surfaces have no implicit broad
allow, while OpenPath native DLLs and approved browser DLL directories are
scoped to administrator-owned roots. Administrators and SYSTEM retain
allow-all recovery rules. The `%WINDIR%` and OpenPath roots are broad only
because both are administrator-controlled runtime roots; restricted users must
not receive write access to either root.

Configure `data/config.json` with an explicit profile and versioned catalog:

```json
{
  "appControlProfile": "StrictApplicationAllowlist",
  "approvedStudentBrowsers": ["Firefox"],
  "approvedApplicationCatalog": {
    "schemaVersion": 1,
    "applications": [
      {
        "id": "signed-classroom-app",
        "identity": {
          "type": "Publisher",
          "publisherName": "O=VENDOR LTD, L=MADRID, C=ES",
          "productName": "Classroom App",
          "binaryName": "classroom.exe"
        }
      }
    ]
  }
}
```

Identity types are:

- `Publisher`: exact non-wildcard publisher, product, and binary constraints;
- `Path`: an exact path below Program Files, with no wildcard or traversal;
- `Hash`: a 64-hex-character SHA-256 plus the source filename.

Use publisher identities for normally updated signed software, paths only for
administrator-controlled installation locations, and hashes for pinned unsigned
binaries. A hash approval stops matching when the binary changes.
An MSI/MSP/MST catalog entry approves that installer surface only; it does not
implicitly approve executables installed by the package, which need their own
catalog identity (or an administrator-managed deployment outside the student
boundary).

`approvedStudentBrowsers` is authoritative. Firefox Release identities are
approved only when the inventory marks the installed administrator-owned
Release binary; Tor, portable, and user-writable Firefox/Edge/Chrome copies do
not inherit that approval. `AppxPublisher` identities are first-class and are
matched by publisher/product/binary in the Appx collection. A publisher entry
must be bounded (no wildcard or path/control characters); a catalog path must
be an exact administrator-owned Program Files path and a catalog hash must be
SHA-256 plus a safe filename.

The configured `appControlProfile` is intent. `activeAppControlProfile` is
updated only after effective-policy and runtime validation succeeds. Policy
application backs up the prior local policy and restores it after failed
activation or validation. Switching profiles replaces only rules whose names
carry the OpenPath-managed prefix, leaving administrator-managed rules intact.

The installed acceptance harness is intentionally opt-in and records exact
policy decisions without mutating the machine unless `-ExecuteProbes` is used:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tests/e2e/ci/run-windows-strict-application-allowlist.ps1 `
  -OpenPathRoot C:\OpenPath `
  -EvidencePath C:\OpenPath\data\strict-application-allowlist-e2e `
  -RequireFixtures `
  -ExecuteProbes `
  -StudentUserName <restricted-user> `
  -StudentPassword <password>
```

The harness checks exact configured/active profile identity, local and
effective policy, synthetic `C:\Program Files\FutureBrowser\future.exe`,
approved browser and classroom-app fixtures, unapproved sibling/MSI/script/
Appx fixtures, and administrator/SYSTEM recovery rules. Missing optional
fixtures are recorded as `skip`; `-RequireFixtures` turns them into failures.
The password is used only for the temporary student process probes and is not
written to evidence.
