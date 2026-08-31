# Firefox Release Discovery Design

## Problem

The Windows installer can report `firefox-release-missing` after the managed
Firefox policy has passed because `Resolve-OpenPathFirefoxReleaseExecutable`
only checks the process-sensitive `ProgramFiles` and `ProgramFiles(x86)` paths.
On a 64-bit operating system running 32-bit PowerShell, that can miss a
64-bit Firefox Release installation under the native Program Files directory.

## Scope and compatibility

This change is limited to Firefox Release executable discovery and its
diagnostics. It does not add `-RequireRuntimeRegistration` to the installer
readiness phase and does not alter runtime registration semantics.

The existing `firefox-release-missing` failure code remains unchanged for
callers that consume it. Its message and structured readiness result will make
clear that executable discovery failed; policy validation and runtime
registration remain separate failure stages.

## Design

`Browser.FirefoxPolicy.psm1` will keep
`Resolve-OpenPathFirefoxReleaseExecutable` as the string-returning compatibility
seam, backed by a private discovery routine that records candidate sources and
rejections.

Candidates are evaluated in this order:

1. Firefox App Paths and Mozilla Firefox uninstall registration from the
   explicit 64-bit registry view.
2. The same registered sources from the explicit 32-bit registry view.
3. `$env:ProgramW6432\Mozilla Firefox\firefox.exe`.
4. `$env:ProgramFiles\Mozilla Firefox\firefox.exe`.
5. `ProgramFiles(x86)\Mozilla Firefox\firefox.exe`.

Registry access uses `Microsoft.Win32.RegistryKey.OpenBaseKey` with
`Registry64` and `Registry32`, so lookup does not depend on the bitness of the
PowerShell host. Normal Mozilla Firefox uninstall locations provide registered
custom-installation candidates. App Paths is used as corroborating machine
evidence only when its path matches that Release registration or the canonical
`Mozilla Firefox` installation directory; an uncorroborated App Paths
`firefox.exe` is rejected. All candidates are deduplicated case-insensitively
before validation.

Validation requires a real `firefox.exe` leaf and rejects paths identifying Tor
Browser, Firefox Portable, or a non-Release Firefox channel. Filesystem
fallbacks are restricted to the known Mozilla Firefox installation directory
shape; an arbitrary `firefox.exe` is never accepted merely because it exists.

When no candidate passes, readiness returns `firefox-release-missing` with a
message containing “Firefox Release executable could not be discovered” and
the consulted source/path diagnostics. The existing policy and runtime result
fields are preserved.

## Tests

Pester coverage will first add a red regression test that simulates a 64-bit
OS with a 32-bit PowerShell process (`ProgramFiles` and
`ProgramFiles(x86)` point to x86 Program Files while `ProgramW6432` points to
native Program Files). It will expose the x64 Firefox executable only through
the `ProgramW6432` candidate.

Additional focused tests will cover registry-view priority and custom
registered locations, deduplication, Firefox x86 fallback, Tor/Portable
rejection, deterministic absence, and the readiness message distinction from
machine-policy and runtime-registration failures.

No staging, production deployment, release, tag, promotion, or push is part of
this issue.
