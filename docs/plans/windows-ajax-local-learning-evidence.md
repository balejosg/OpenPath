# Windows AJAX Local Learning Evidence

## Runner Evidence

The direct Windows runner lane completed successfully from the workspace root:

- Command: `./scripts/validate-hypothesis.sh openpath windows-direct`
- Local artifact directory: `OpenPath/.opencode/tmp/openpath-windows-direct/2026-05-09T10-10-00-142Z`
- Test result artifact: `OpenPath/.opencode/tmp/openpath-windows-direct/2026-05-09T10-10-00-142Z/windows-test-results.xml`
- Pester summary: `total="268"`, `failures="0"`, `errors="0"`, `skipped="9"`, `date="2026-05-09"`, `time="12:10:11"`

Measured fields from the read-only runner probe:

- ISO-8601 timestamp of the run: `2026-05-09T12:11:56.3844630+02:00`
- Runner hostname or runner id: `DESKTOP-MUV2C2K`
- Absolute Windows path to `AcrylicConfiguration.ini`: `C:\Program Files (x86)\Acrylic DNS Proxy\AcrylicConfiguration.ini`
- Absolute Windows path to `AcrylicHosts.txt`: `C:\Program Files (x86)\Acrylic DNS Proxy\AcrylicHosts.txt`
- Whether HitLog is enabled: no. `HitLogFileName` is empty.
- Current HitLog settings in production config: `HitLogFileName=""`, `HitLogFileWhat="XHCF"`, `HitLogFullDump="No"`, `HitLogMaxPendingHits="512"`.
- Exact setting needed before a private HitLog spike can produce a file: set `HitLogFileName` to an explicit diagnostic-only path. The current source already writes `HitLogFileWhat="XHCF"`, but the emitted field layout was not measured because no HitLog file is enabled.
- Whether the log includes timestamp, hostname, query type, and result: not available from this run. HitLog is disabled and no HitLog candidate files were present.
- Whether PowerShell can read HitLog while Acrylic writes it: not measured. There was no enabled HitLog file to read.
- Whether latency is acceptable for 60-120 second windows: sinkhole probe latency was `183` ms for `task7-sinkhole-29c561cb8f184c69bcf2dc63d4966a67.invalid`, which is well inside a 60-120 second observation window for active probes.
- Whether sinkhole/miss evidence is available without full DNS logging: yes for active, candidate-specific probes. `AcrylicHosts.txt` contains `NX *`, and the probe returned no answer through `127.0.0.1`.
- Recommended source: `none`.

Supporting repository evidence:

- `OpenPath/windows/lib/internal/DNS.Acrylic.Config.ps1` sets the default block rule to `NX *`.
- `OpenPath/windows/lib/internal/DNS.Acrylic.Config.ps1` sets `HitLogFileName` to an empty string, so full DNS hit logging is not enabled by default.
- `OpenPath/windows/lib/internal/DNS.Diagnostics.ps1` exposes `Test-DNSSinkhole`, which checks that a domain does not resolve via local Acrylic.
- `OpenPath/windows/tests/Windows.DNS.Core.Tests.ps1` protects the generated `NX *` ordering in the Acrylic hosts content.

## Decision

- no DNS-local learning; use recipes/manual approval only

Sinkhole evidence is acceptable as a narrow confirmation probe for a known candidate hostname, but it does not discover AJAX subresource hostnames by itself. Acrylic HitLog remains disabled by default, and this spike did not prove the HitLog field layout or concurrent PowerShell read behavior. Do not enable full DNS logging by default. If a later implementation needs local DNS evidence, add a separate explicit diagnostic command or experiment flag that writes to a private bounded HitLog path and records only the minimal fields needed for the diagnostic.
