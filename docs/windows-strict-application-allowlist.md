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
Administrators and SYSTEM retain allow-all recovery rules. The `%WINDIR%` and
OpenPath roots are broad only because both are administrator-controlled runtime
roots; restricted users must not receive write access to either root.

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

The configured `appControlProfile` is intent. `activeAppControlProfile` is
updated only after effective-policy and runtime validation succeeds. Policy
application backs up the prior local policy and restores it after failed
activation or validation. Switching profiles replaces only rules whose names
carry the OpenPath-managed prefix, leaving administrator-managed rules intact.
