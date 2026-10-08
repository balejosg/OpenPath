# Windows first-visit lab lane

Phase 3A adds a CI lane that captures and measures the **first visit to a
generic multi-host page on Windows** in the three situations that matter in a
classroom: a settled system, a hot session, and a class boot (logon + Firefox
within a minute). It exists because no other lane exercises the runtime
dependency learning path end to end, and because Phase 4 will be measured with
it.

The lane is **site-agnostic**: nothing in the repository lists Reddit, BBC or any
other site. Every run generates random hosts and lets the product learn them
with the generic rules.

## What it runs

| Scenario | Name                            | What happens                                                                                        |
| -------- | ------------------------------- | --------------------------------------------------------------------------------------------------- |
| W        | `first-visit-settled`           | settled install; a fresh Firefox opens anchor 1                                                     |
| W2       | `first-visit-hot`               | same Firefox stays open >=5 min; a new window opens anchor 2                                        |
| B        | `first-visit-class-boot`        | install, warm-up + clean close, reboot, autologon, Firefox <=60 s after logon                       |
| F        | `first-visit-floor`             | like W but the dependency hosts are pre-whitelisted (the environment floor; `control` is the alias) |
| S        | `first-visit-site`              | Phase 6 C: real-site canary, settled-like, dispatch only (see below)                                |
| SB       | `first-visit-site-class-boot`   | Phase 6 C: real-site canary through the class-boot refresh, dispatch only                           |
| U        | `first-visit-update-contention` | Phase 7 L1: settled-like, with the product update started right before the visit (see below)        |

W also runs the security checks (`first-visit-settled`/`first-visit-floor`):
the never-learnable host stays blocked, the unlisted host does not resolve, the
whitelist never changes and the overlay contains exactly the learned hosts.

### The fixture (generic, per run)

`tests/e2e/ci/first-visit/fixture_server.py` serves, from the Proxmox host and
routed by `Host` header, two anchors with independent dependency sets. Hostnames
are `<role><n>-<token>.<ip>.sslip.io`, unique per run:

- wave 1: blocking CSS (styles host), `<script src>` (core host), web font with
  `font-display:block` (font host), image (image host);
- wave 2: the core script injects a deferred script from the deferred host;
- wave 3: the deferred script fetches JSON from the api host and paints it.

The page self-reports to `POST /__report`: computed style, executed scripts,
painted API, font/image load, navigation type, in-page reload counter and
per-wave times from `navigationStart`. The server records every request and
report as JSONL. The product's AcrylicHosts renderer maps **whitelisted** sslip names
(the anchors) to a static `<ip> <domain>` line (`Get-AcrylicForwardRules`), so
anchor queries never reach the DNS fixture; **learned runtime dependencies** use
an exact forward rule (`Get-AcrylicExactForwardRule`) and _are_ forwarded to the
fixture (visible as `sslip-answer` in `dns.jsonl`). A dependency therefore
resolves **only after the product learns it** (Phase 5.3 P5; see the fixture
docstring for the exact path).

The served whitelist contains only the two anchors (plus every dependency host
in the `floor` scenario, Phase 5.3 B4); the never-learnable host is listed under
`## BLOCKED-SUBDOMAINS`.

### Browser logic check (mandatory local verification, Phase 5.3 P2)

`tests/e2e/ci/first-visit/test_fixture_browser.mjs` loads the fixture page in
floor mode with Playwright Firefox (every fixture hostname is routed back to
the local fixture with the original `Host` header, and the real CDN
`Access-Control-Allow-Origin` responses are exercised) and requires all three
waves plus `fontLoaded`. There is no Firefox job in CI, so run it before any
change to the fixture:

```bash
node tests/e2e/ci/first-visit/test_fixture_browser.mjs
```

It exits non-zero and prints the observed flags when a wave is missing. The
Phase 5.3 red reference is the `dec79a43` fixture (`coreExecuted`,
`deferredExecuted`, `apiPainted` and `imageLoaded` all false: the synchronous
`core.js` ran before the page defined `window.__firstVisit` and the image PNG
had an invalid CRC). `tests/e2e/ci/first-visit/test_fixture.py`
covers the plan, routing, report and log contracts, and
`windows/tests/Windows.FirstVisitLane.Tests.ps1` proves the fixture-shaped hosts
are learnable (and the never-learnable one is not) under
`RuntimeDependency.Policy`.

### Managed extension install in the lab (Phase 3A.2 correction)

Production points `ExtensionSettings.install_url` at the managed API
(`<apiUrl>/api/extensions/firefox/openpath.xpi`) and the agent writes that policy
to both `distribution/policies.json` and the machine registry
(`HKLM\SOFTWARE\Policies\Mozilla\Firefox`, `REG_MULTI_SZ`). The lane **never
rewrites that policy**: the registry entry, the file and
`distribution/extensions/` stay exactly as the product wrote them.

The only lab-specific staging is the XPI bytes: the harness copies the signed
XPI the template installer left in `C:\OpenPath\browser-extension\` and uploads
it to the fixture (`POST /xpi`); the fixture serves it **only** on the managed
`/api/extensions/firefox/openpath.xpi` path. The controller records the
installed and served sha256 and fails the run when either differs from the
template's `payload-manifest.json` digest.

Phase 3A concluded there was a "Firefox does not register the extension" lab
blocker. That was wrong: the verification read `extensions.json` **while Firefox
was still running**, and Firefox only flushes the add-on registry on shutdown,
so the read was a false negative. The one real defect was that the fixture did
not serve the managed XPI path at all (`GET /api/extensions/firefox/openpath.xpi
404`), fixed in `d0ccdb6c`.

The warm-up verification therefore never reads `extensions.json` with Firefox
open:

- live signal (browser running): `initialization completed` in the student's
  `%LOCALAPPDATA%\OpenPath\native-host.log`, plus `background-start` and the
  `stage=extension-diagnostic-batch first=...` line on builds that emit them
  (the controller derives the build's capabilities from the template source SHA
  and an unknown SHA fails open to the state signal alone);
- state signal (after an orderly close: `taskkill /T`, then `/F` only if needed):
  the add-on entry with `active=true`, `userDisabled=false`, `appDisabled=false`,
  its version, `location`, `signedState` and `installTelemetryInfo`.

Explicit failures: `xpi-not-fetched`, `host-not-started`,
`xpi-fetched-not-registered`, `extension-registered-inactive`,
`extension-version-mismatch`.

Known fixture difference: the fixture does not emulate
`/api/machines/client-config` or `/trpc/healthReports.submit` (both 404). It is
inert for this lane (client-config only syncs `captivePortalDomains` into the
runtime dependency worker), but it is a documented difference from production.

## Verdict

The verdict comes from the **page self-report**, never from MOZ_LOG heuristics:

- W and W2: all three waves complete within 15 s and **0 reloads**;
- B: complete within 30 s and **at most 1 reload**;
- a missing self-report is FAIL, never a pass;
- if the DNS or the fixture server do not answer, the run is INFRA.

Thresholds were fixed with data (observed maximum + margin, never above the
caps above); `Get-OpenPathFirstVisitReportVerdict` takes them as parameters and
records `fontLoaded`, `neverLearnableBlocked`, reloads and per-wave times.

## Metrics

`tests/e2e/ci/aggregate-windows-first-visit.ps1` writes
`first-visit-summary.json` and a Markdown job-summary table with per-run rows and
the baseline (median/max per scenario group, reload maximum). Each scenario
artifact directory contains:

- `metrics.json`: verdict, reasons, wave times, reloads and their E1 reasons,
  host startup profile (`processToScriptMs`, `pingMs`, `firstEnqueueMs`), the
  E1 diagnostics per kind (transport transitions, holds with their outcomes,
  reload decisions with each reason, background-start), the warm-up XPI fetch
  delay and the worker apply time. Every segment stays on a single clock: page
  waves from the in-page self-report, the fetch delay from the fixture clock and
  host segments from the native host's own lines;
- `observe.json`: the correlated controller observation (visit delay for B,
  security checks, fixture state);
- `captures/console-<scenario>-t{005,010,015,020,030,060}.ppm` and
  `console-<scenario>-blocked.ppm`;
- `guest-logs/native-host.log` (with the E1 `stage=extension-diagnostic` lines)
  and `guest-logs/openpath.log`;
- `fixture/{plan.json,requests.jsonl,reports.jsonl,dns.jsonl}`.

## How to run it

```bash
# Manual dispatch (template from a release-scripts run):
gh workflow run windows-first-visit-lab.yml -f template_run_id=<rel-run-id> \
  -f scenarios=settled,class-boot -f repetitions=1

# Automatic triggers (Phase 3A.2 K2):
# - after a successful Release Installation Scripts run on main, when the push
#   range (head_sha against the newest comparable base) touches
#   firefox-extension/src/**, firefox-extension/native/**, windows/lib/**,
#   windows/scripts/**, tests/e2e/ci/first-visit/** or the lane itself
#   (an undeterminable range fails open): W, B and U, one repetition each;
# - nightly (02:17): settled, hot, class-boot and floor with two repetitions
#   plus update-contention once (9 scenes: 9 x 30-min worst-case scene budget +
#   15 min overhead = 285 min <= 288 min = 80% of the 360-min job timeout);
# - dispatch: exactly the scenarios/repetitions requested.
```

The lane serializes with the desktop-survival suite through the same lab lock
(see below) and never signs in AMO: it consumes the `windows-offline-template`
and `windows-personalized-exe` artifacts of the exact release-scripts run.

## Smart App Control simulation (Phase 6 B, positive proof in 6.1 C)

`smart_app_control: unchanged` is the default. With `smart_app_control: on`
(class-boot only; any other scenario is rejected before the lab), the lane
simulates an installed machine to which Windows turns SAC on:

1. install + warm-up run with SAC=2 (evaluation, the lab baseline);
2. `VerifiedAndReputablePolicyState=1` is written under
   `HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy` and `CiTool.exe -r` runs
   when present (`sac-apply` step, records the previous/applied value);
3. the lane reboots (dedicated SAC reboot in prepare, so the measured
   class-boot visit stays clean) and then proves enforcement with a **positive
   control**, not with the registry:
   - `sac-control` (every scene, SAC=2 baseline included) compiles a trivial
     console exe with the .NET Framework `csc.exe` in
     `C:\Windows\Temp\openpath-sac-control`, keeps a `control-motw.exe` copy
     with a `Zone.Identifier`/ZoneId=3 mark and a `control-plain.exe` copy,
     runs both as SYSTEM with a 10 s timeout, records the exit code or the
     Win32 policy-block error and the CodeIntegrity XML events naming them,
     then deletes the directory. No binary ever enters the repository;
   - `sac-state` reads `Win32_DeviceGuard`
     (`UsermodeCodeIntegrityPolicyEnforcementStatus`), `CiTool.exe -lp`
     (raw + `--json` when the build supports it), the Defender status
     (`Get-MpComputerStatus`, `HKLM\SOFTWARE\Policies\Microsoft\Windows
Defender`) and the CodeIntegrity/Operational events in **XML** from the
     scene start (`TimeCreated`, `EventID`, `FileName`, `PolicyId`; <=200
     events and <=1 MB per query). The registry value is informational only;
4. SAC counts as applied only with the UMCI enforcement status enforced **and**
   `control-motw` blocked. Anything else is INFRA `sac-not-enforced` (registry
   and Defender cannot override it) and stops there. One extra attempt is
   allowed: if Defender is disabled by policy, `sac-defender-enable` removes
   those values, starts `WinDefend`, re-applies SAC and repeats the control.
   The enforcement cycles run inside prepare with their own reboots (each
   requested before it is awaited); a SAC scene gets a larger prepare budget
   (1500 s) while the scheduled scene budget stays untouched.

Every scene also records the harness `LanguageMode`, constrained-language lines
from `openpath.log` and the post-boot agent state (Acrylic service, anchor DNS,
OpenPath-\* tasks). When the harness itself runs under `ConstrainedLanguage`,
the affected steps fall back to a minimal cmd/wevtutil collection and the
evidence says so. A blocked (3033/3034) Code Integrity event naming the native
host (or the browser) with the host not started adds the product signal
`native-host-blocked-by-smart-app-control`; audit-only events (3076/3077) never
raise it.

## Real-site canary (Phase 6 C)

`site` runs **only by dispatch** (never in the auto-run or the nightly) with two
inputs: `site_url` (required) and `site_whitelist` (comma-separated domains).
`site` visits in-session; `site-class-boot` runs the same real-site plan through
the class-boot refresh (reboot + logon launch). The real URL is the anchor, the
served whitelist contains only those domains and there is no fixture dependency
precondition; the real site learns its own CDN hosts through the product.

Phase 6.1 A: the visit wrapper is built line by line (`FirstVisitLaunch.psm1`,
unit tested): every `set` directive and the launch line own their own line, so
the launch line always starts with the quoted `firefox.exe` path and carries
`-new-window` and the URL. MOZ_LOG uses Firefox's own rotation
(`timestamp,rotate:16,nsHostResolver:5`, four `.0-.3` files) and no unknown
environment variable; the collect records the real file names it found. Phase
6.1 B: every scene records any Firefox that was already open at visit launch
(pid, creation, parent and command line via Win32_Process) and closes it for
every non-hot scenario, so `settled`/`site` measure the browser the visit
starts (hot keeps the warm-session case). A `site` scene whose extension
diagnostics never show a `navigation` to the site host is INFRA
`site-not-navigated`; CANARY-PASS/CANARY-RED are only possible after real
navigation.

- metrics: holds and their outcomes (ready/cancelled/error), ready retention
  p50/max, last ready relative to the navigation, E1 reloads and reasons,
  learned hosts, negative lookups (or `NS_ERROR_UNKNOWN_HOST`) for a learned
  host **after** its ready, service-worker holds (tabId < 0) and worker
  stamp->ready gaps over 2 s;
- CANARY-PASS requires every hold to end in `ready`, zero negative lookups
  after ready and at most one reload. CANARY-RED is evidence, never a run
  failure: only INFRA fails the run.

The captures `t005..t060` are described manually (blank / unstyled / complete).

## Update contention, stall diagnosis and SAC-before-install (Phase 7)

`update-contention` (nightly once, in every auto-run and by dispatch) is the
settled-like visit with the product update started right before the browser
launch:

- the guest `update-trigger` step runs
  `%SystemRoot%\System32\schtasks.exe /Run /TN OpenPath-Update` (absolute path);
  a direct `Update-OpenPath.ps1` start is the fallback only when the task cannot
  run **and** no update is already in course (log tail);
- the scene proves from the collected logs that an update run was still in
  course when the first dependency retention arrived
  (`Get-OpenPathFirstVisitUpdateContention`);
- the acceptance counters are the canary retention metrics: enqueue->ready
  p95 <= 3 s and zero `cancelled-budget` holds (`CONTENTION-PASS`).

Phase 7 P1 adds the stall diagnosis to every scene. The guest runs a 50 ms
sampler (high-resolution counter + UTC clock) with a per-second CPU census
(firefox, the worker powershell, MsMpEng, Acrylic and system CPU); the
controller samples the Proxmox host (`/proc/pressure/{cpu,io,memory}`, load,
the VM's kvm CPU) and classifies every >2 s worker/fast-apply gap:

- `vm-stall`: the sampler stops in the same window (the whole VM paused);
- `guest-saturated`: the sampler runs and system CPU is pinned (the culprit
  process names travel in the evidence);
- `worker-only`: sampler alive, CPU normal, only the worker/native sequence
  paused.

A `vm-stall` overlapping a not-ready retention makes the scene INFRA `vm-stall`
(the product is not blamed for a hypervisor pause); the raw samples live in
`stall-samples.json`.

`smart_app_control: on-before-install` (class-boot only) applies SAC **before**
the product install: the pre-install cycle boots into enforcement and proves it
with the positive control, and only then the template installs. The scene
records the pre-install decision, the compiled native host state
(`host-compile-state`: sha256 of the exe and build manifest plus the product
ensure result), the forced recompilation with SAC still active
(`host-recompile`: delete the compiled exe + build manifest, call the product
ensure, repeat the student probe) and the CodeIntegrity XML window.

## Smart App Control and canary runbooks

```bash
# SAC simulation (class-boot only), template from the push's REL run:
gh workflow run windows-first-visit-lab.yml -f template_run_id=<rel-run-id> \
  -f scenarios=class-boot -f repetitions=1 -f smart_app_control=on

# SAC already enforced before the install (Phase 7 L2):
gh workflow run windows-first-visit-lab.yml -f template_run_id=<rel-run-id> \
  -f scenarios=class-boot -f repetitions=1 -f smart_app_control=on-before-install

# Update contention (Phase 7 L1; also in the auto-run and nightly):
gh workflow run windows-first-visit-lab.yml -f template_run_id=<rel-run-id> \
  -f scenarios=update-contention -f repetitions=2

# Real-site canary (base URL + domains only; never committed to the repo):
gh workflow run windows-first-visit-lab.yml -f template_run_id=<rel-run-id> \
  -f scenarios=site -f repetitions=1 \
  -f site_url=https://example.invalid/ -f site_whitelist=example.invalid
# class-boot canary variant:
gh workflow run windows-first-visit-lab.yml -f template_run_id=<rel-run-id> \
  -f scenarios=site-class-boot -f repetitions=1 \
  -f site_url=https://example.invalid/ -f site_whitelist=example.invalid
```

Requirements on the self-hosted runner: the lab inventory
(`OPENPATH_DESKTOP_LAB_CONFIG`, default
`~/.config/openpath/desktop-survival-lab.json`) with an acceptance scenario whose
`vmid`/`baselineSnapshot` point at the candidate Windows VM, and a lab
controller (`OPENPATH_FIRST_VISIT_CONTROLLER`, falling back to
`OPENPATH_DESKTOP_SURVIVAL_CONTROLLER` or the repo controller). Ports 80 (HTTP
fixture) and 53/UDP (DNS fixture) must be free on the Proxmox host.

## Lab lock (Phase 3A G3)

The lock lives in the operator config (`lockFile`, e.g.
`/run/openpath-desktop-survival.lock`) and is now implemented once in
`tests/e2e/ci/controllers/proxmox-lab-lock.sh`:

- `owner`, `created` and `heartbeat` files; the CI and the phase functions
  refresh the heartbeat between guest steps;
- a lock is **stale only when its heartbeat is older than the TTL** - an old
  `created` with a live heartbeat is not stale;
- a live lock is **waited for** (`lockWaitSeconds`, default 900) instead of
  being stolen, so a CI run can no longer replace a live manual session;
- every replacement appends the previous owner to
  `<lock_dir>.replacements.log`.

Manual sessions use `tests/e2e/ci/controllers/proxmox-lab-lock.ps1`
(`-Action status|acquire|renew|release`) and can renew their heartbeat while
investigating. `tests/lab_lock.bats` covers acquire/wait/renew/stale/replace.

## Capture proof (obligatoria)

The lane must go **red with the correct reason** against known broken builds and
**green on the current SHA**. The evidence summary lists, per run: build SHA,
scenario, verdict, reason and workflow run id. Any old template that cannot be
installed by the lane is documented and substituted by another known-broken
build (`c28bf26e` for B; `2342794d`/`0c38ed57` for W).

## Debugging a red run

1. Read the job summary: `verdict`, `reasons`, wave times and reloads.
2. Read `metrics.json` + `fixture/last_report.json`: a wave flag that never
   became true names the wave; `reloads > 0` means the product repaired the
   visit (expected in B, a finding in W).
3. Read `guest-logs/native-host.log`: `stage=extension-diagnostic` lines carry
   the E1 decision reasons; `stage=startup-profile` carries the host startup
   numbers.
4. If the fixture never served requests, the run is INFRA, not a product
   failure.
