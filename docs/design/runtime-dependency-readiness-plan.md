# Runtime Dependency Readiness Protocol

Status: all five packages implemented (2026-09-27); physical first-visit
acceptance on a student machine still pending.
Scope: `firefox-extension/`, `windows/`, `linux/`. No manifest permission changes; no new data collection; AMO unlisted signing profile preserved.

## Problem

When a student first opens a whitelisted page that pulls subresources from
not-yet-whitelisted domains (e.g. Reddit), the runtime dependency overlay
learns those domains, but the requests that triggered the learning are released
before the DNS exception is actually operative. The page loads incomplete on
first visit; later visits work because the overlay already contains the
domains.

Root causes verified in code (commit `2342794d`):

1. **The extension always resolves `{}` regardless of the native response.**
   `waitForLocalRuntimeDependencySoftTimeout()` in
   `firefox-extension/src/lib/background-listeners.ts` maps every outcome
   (success, `queued`, rejection, timeout) to `{}`, allowing the request.
   It never distinguishes "applied" from "accepted for processing".

2. **The 150 ms batch window consumes most of the XHR budget.**
   `LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS = 150`
   (`runtime-dependency-protocol.ts`) combined with the 250 ms soft timeout
   for `fetch`/`xmlhttprequest` leaves ~100 ms for the full native round trip
   in the worst case.

3. **Deduplication ends before the operation ends.**
   `flushRuntimeDependencyBatch()` deletes keys from
   `pendingRuntimeDependencyByKey` before `await sendMessage(...)`, so a
   second request for the same dependency during the native window starts a
   duplicate operation.

4. **Linux answers `queued` immediately.**
   `firefox-extension/native/openpath-native-host.py`
   `write_runtime_dependency_request()` returns `{success: True, queued: True}`
   right after writing the queue file. The actual application is asynchronous
   via `openpath-runtime-dependency-apply.path` (systemd), which regenerates
   and restarts `dnsmasq`.

5. **Windows waits, but on the wrong condition.**
   `Invoke-UpdateTask` waits until the queue file disappears **and** the
   overlay file contains the domain. In
   `Invoke-OpenPathRuntimeDependencyFastApply` (`windows/lib/Update.Runtime.psm1`)
   the overlay is written **before** `Restart-AcrylicService`, so the wait can
   complete while Acrylic still serves the previous configuration.

6. **Cached extension responses do not prove DNS readiness either.**
   `getCachedRuntimeDependency()` synthesizes `{success: true, cached: true}`
   for 30 minutes without consulting the agent; the domain may not be in the
   active DNS configuration (e.g. after overlay expiry or agent restart).

## Constraints

- No new manifest permissions: no `proxy`, no `dns`. The fix reuses the
  existing `webRequest` blocking flow and `nativeMessaging`.
- Native messaging payload stays `anchorHost + dependencyHost + requestType`;
  no request bodies, cookies, headers, or page content are added.
- Blocking waits remain bounded; the extension must not stall Firefox.
- OpenPath stays agnostic of ClassroomPath.
- Contract tests read some sources as raw text: check
  `docs/contract-tests.md` before renaming files or exported functions.

## Design

### New readiness vocabulary (extension)

Native responses gain an explicit readiness field, mapped to three states:

- `ready`: the dependency is operative in the local DNS path.
- `pending`: accepted, being applied; the requester should keep waiting.
- `denied` / `error`: will not be applied.

The field name is `runtimeDependencyState` (already present for `queued`);
we extend its value set instead of adding a parallel field, and keep
`queued = true` for backward compatibility with older extensions.

`waitForLocalRuntimeDependencySoftTimeout()` is changed to inspect the
resolved response: only `ready` (or a verified cached `ready`) resolves the
wait early; `pending` keeps waiting until the soft timeout; `denied`/`error`
resolve to `{}` immediately so the request fails fast instead of burning the
full timeout.

### Single shared operation per dependency

`pendingRuntimeDependencyByKey` entries are removed **after** the native
operation reaches a terminal state (`ready`, `denied`, or `error`), not at
batch flush time. Concurrent requests for the same triple share one promise
for the whole operation, not just for the batch window.

The 150 ms batching delay is removed for the first request of a dependency
that has no in-flight operation and no cached `ready`: that request is sent
immediately (batch flush with the current single entry). Additional requests
arriving while the operation is in flight attach to the shared promise.
Batching is kept only as a coalescing mechanism for simultaneous _new_
dependencies within a much shorter window (target: 25 ms), so a first-party
page fan-out still produces one native message per burst instead of twenty.

### Readiness confirmation protocol

Extension side, new native action `check-local-runtime-dependency` with
`{anchorHost, dependencyHost}` returning `{ready: bool, state, expiresAt}`.
This replaces the synthesized 30-minute cache: the extension may keep a
short-lived (e.g. 60 s) positive cache, but entries older than that are
confirmed against the agent before being treated as `ready`.

#### Windows

`Test-NativeHostRuntimeDependencyReady` is added next to the existing
overlay/queue helpers. It returns `$true` only when:

1. the queue file for the request no longer exists, **and**
2. the overlay contains the dependency host, **and**
3. the Acrylic hosts file was written **and** `Restart-AcrylicService`
   completed after that write.

To make (3) observable, `Invoke-OpenPathRuntimeDependencyQueueApply` records
a monotonically increasing `appliedGeneration` (timestamp of the successful
Acrylic reload) into the overlay JSON. The readiness check compares the
overlay entry's `appliedGeneration` against the overlay file's last
successful reload marker, so a freshly written-but-not-yet-reloaded entry
does not read as ready. The existing `Invoke-UpdateTask` wait condition is
extended with the generation comparison instead of the bare overlay
membership test.

`Invoke-NativeHostLocalRuntimeDependencyAction` and its batch variant keep
waiting inside the native host (current 14 s budget), but now return
`runtimeDependencyState = 'ready'` only when the generation check passes;
otherwise `queued`/`pending` with the existing metrics fields.

#### Linux

The Python native host gains a bounded wait loop: after writing the queue
file it polls (100 ms interval, up to a configurable budget, default 8 s)
for a readiness marker. Readiness is established by
`openpath-runtime-dependency-apply.sh`: after `restart_dnsmasq` succeeds,
the apply script appends the processed request IDs (or their
anchor/dependency pairs) to
`/var/lib/openpath/runtime-dependency-applied.json` with the DNS
configuration generation (`sha256sum` of `dnsmasq.conf` already computed
for `$DNSMASQ_CONF_HASH`). The Python host answers
`runtimeDependencyState = 'ready'` when the pair appears in the applied
marker at the current generation; on timeout it answers
`queued` (current behaviour), which the extension now treats as _keep
waiting until soft timeout_ instead of _release immediately_.

`check-local-runtime-dependency` on Linux reads the overlay plus the
applied marker and answers accordingly.

### Soft timeout budget changes

With `queued` no longer releasing requests early, the per-type soft timeouts
become the only release valve. Proposed values (unchanged unless first-visit
instrumentation says otherwise):

- `fetch` / `xmlhttprequest`: 250 ms -> **1500 ms**
- `image`: 500 ms -> 1500 ms
- `script` / `stylesheet` / `font`: 1200 ms -> 2000 ms

Rationale: the previous values were calibrated around the assumption that the
native side answers in ~100-200 ms, which is only true for the Linux `queued`
fast path. With real readiness the typical ready time is expected to be
300-900 ms (queue write + apply + DNS reload). The timeout remains a soft
cap: on expiry the request is allowed and the page may recover via its own
retry logic, but the overlay entry is still applied for the next attempt.

These values are instrumentation-driven: the Windows host already logs
`queueWriteMs`, `updateTriggerMs`, `updateWaitMs`, `acrylicReloadMs`; the
plan adds matching timing logs to the Linux host and an extension-side
counter of soft-timeout fallbacks per request type, so the numbers are
revisited with real first-visit data before release.

### What this plan deliberately does not do

- No `proxy.onRequest` / managed proxy: requires the `proxy` permission and
  changes the extension's function profile; out of scope for this bug.
- No `browser.dns.resolve()`: requires the `dns` permission; out of scope.
- No automatic page reload on late readiness.
- No upload of learned dependencies to the remote service.
- No change to the overlay's authorization scope (domain-level grant). The
  anchor-scoping question is a product decision tracked separately.

## Work packages

1. **Extension: readiness-aware wait + dedup lifetime**
   `background-listeners.ts`, `native-messaging-client.ts`,
   `runtime-dependency-protocol.ts`, `async-timeout.ts` (no changes needed),
   tests in `tests/background-listeners.test.ts` and
   `tests/native-messaging-client.test.ts`.
2. **Extension: native readiness check + cache confirmation**
   new `check-local-runtime-dependency` action, cache TTL reduction,
   generation-aware cache keys; tests updated accordingly.
3. **Windows: generation-stamped readiness**
   `RuntimeDependency.Overlay.ps1` (stamp `appliedGeneration`),
   `Update.Runtime.psm1` (record generation after Acrylic reload),
   `NativeHost.Actions.RuntimeDependency.ps1` (new readiness test + wait
   condition + response field), `Browser.FirefoxNativeHost.psm1`
   (`check-local-runtime-dependency` dispatch); Pester tests in
   `windows/tests/Windows.Browser.NativeHost.Tests.ps1` and
   `Windows.DNS.Core.Tests.ps1`.
4. **Linux: applied marker + host wait loop**
   `openpath-runtime-dependency-apply.sh` (write applied marker after
   successful `restart_dnsmasq`), `lib/runtime-dependency-queue.sh`
   (helper to read marker), `native/openpath-native-host.py` (wait loop +
   `check-local-runtime-dependency`); bats tests under `tests/` plus Python
   host tests.
5. **Timeout retuning + instrumentation**
   per-type budget changes, extension counters, Linux timing logs; validation
   per `docs/ci-cd-runner-measurement.md`-style evidence.

Dependency order: 1 and 2 are extension-only and safe to land first (they
treat every current native response as `queued`, which preserves today's
behaviour). 3 and 4 are independent of each other. 5 lands last.

### Implementation notes (packages 1-2, 2026-09-27)

- `waitForLocalRuntimeDependencySoftTimeout()` releases early only for
  `runtimeDependencyState: 'ready'`; `pending`/`queued`/legacy `success: true`
  wait for the per-type soft timeout; `denied`/`error`/`success: false` release
  immediately so the request fails fast.
- The batch coalescing window is 25 ms (`LOCAL_RUNTIME_DEPENDENCY_BATCH_DELAY_MS`).
  The plan's "sent immediately" is implemented as "flushed at the end of a 25 ms
  window": a fan-out burst still produces one native message, without the old
  150 ms penalty.
- `pendingRuntimeDependencyByKey` entries are removed when the shared operation
  settles (`ready`/`pending`/`error`), so concurrent requests for the same
  dependency reuse one native call instead of queuing a duplicate.
- Ready cache: 60 s fresh window, 30 min retention, re-confirmed through
  `check-local-runtime-dependency` when stale. Only explicit `ready` responses
  populate it; legacy acknowledgements are deduplicated for 5 s.
- The cached/confirmed response carries `runtimeDependencyState: 'ready'` so the
  listener can release it through the same path as a native ready result.

### Implementation notes (packages 3-5, 2026-09-27)

- Windows: the overlay records `generation` / `appliedGeneration`, and
  `Invoke-OpenPathRuntimeDependencyFastApply` stamps the applied generation only
  after `Restart-AcrylicService` reports success. The fast-apply path restarts
  Acrylic only when the generated `AcrylicHosts.txt` content actually changed or
  the overlay was left unapplied; repeat batches for already-applied domains
  stamp the current generation without paying another restart. The apply task
  uses `MultipleInstances=Queue` and the fast-apply debounces 300 ms and drains
  up to three iterations, so a page fan-out collapses into one or two reloads
  instead of one per batch (Windows apply latency measured at ~4.2 s per
  restart during the 2026-09-27 acceptance). The update runtime session loads a
  fixed set of modules without autoloading, so the apply path uses .NET APIs
  for file comparisons and sleeps instead of cmdlets such as `Get-FileHash`.
  `Test-NativeHostRuntimeDependencyReady` requires the queue request to be
  processed, the overlay to contain every dependency, and
  `appliedGeneration >= generation`. `allow-local-runtime-dependency` answers
  `runtimeDependencyState: 'ready'` after that wait (or `'error'` on failure),
  and the new `check-local-runtime-dependency` action answers from the overlay
  state. Idempotent/skipped resolutions report readiness too
  (`dependency-already-whitelisted`, applied `runtime-dependency-overlay-present`).
- Linux: `runtime-dependency-overlay.py` records the same generations and gains
  a `mark-applied` command. `openpath-runtime-dependency-apply.sh` marks the
  overlay applied after a successful `dnsmasq` restart, or when the generated
  configuration is unchanged (the effective DNS content is already operative).
  The Python native host waits (100 ms poll, 8 s default budget, env-tunable
  through `OPENPATH_RUNTIME_DEPENDENCY_READY_TIMEOUT_MS` / `..._POLL_MS`) for its
  pair to become applied before answering `ready`; on timeout it answers
  `pending`. Batches share a single wait and mark each result individually.
- Linux apply-path fix found by the target-platform acceptance: the apply
  service never sourced `openpath-update-runtime.sh`, so `has_config_changed`
  failed as an unknown command and the service always fell into the
  "unchanged" branch, silently skipping the `dnsmasq` reload. The script now
  sources the helper explicitly (same pattern as `openpath-update.sh`), so the
  readiness marker is only written after a real reload or a verified unchanged
  configuration. The `services.bats` apply tests exercise the real
  `has_config_changed` instead of stubbing it, which is what would have caught
  the omission.
- Soft wait budgets: `fetch`/`xmlhttprequest`/`image`/`imageset` 5000 ms,
  `script`/`stylesheet`/`font` 6000 ms (default 5000 ms), calibrated against the
  Windows acceptance measurements: Acrylic fast-apply needed ~4.2 s for a first
  batch and repeat batches took 3-8.6 s before the redundant-reload fix. The
  extension logs a local debug line when the cap is reached while the native
  side has not proven readiness; the Linux host logs wait outcome and duration
  to `native-host.log`; Windows already logs `queueWriteMs` / `updateWaitMs` /
  `acrylicReloadMs` plus `acrylicHostsChanged`.

Known adjacent defect (not addressed here): on Linux, `command_update` in
`runtime-dependency-overlay.py` mutates entry dicts in place before snapshotting
the "before" state, so metadata-only refreshes (`lastSeen`, `expiresAt`,
`requestTypes` on an existing pair) report `changed=false` and are not
persisted. Readiness is unaffected because only net-new domains change the
generation.

### Evidence (2026-09-27)

- `npm test --workspace=@openpath/firefox-extension`: 453 pass.
- Pester (PowerShell 7.6.2 on this Linux workspace):
  `Windows.Browser.NativeHost.Tests.ps1` 55 pass,
  `Windows.Update.Tests.ps1` 21 pass,
  `Windows.DNS.Core.Tests.ps1` 44 pass / 3 pre-existing `Stop-Service`
  platform failures / 5 skipped.
- `bats tests/browser_native_host.bats tests/services.bats` 34 pass;
  `bats tests/openpath-update.bats` 20 pass; `bats tests/dns.bats` 71 pass.
- Linux target-platform acceptance (`OPENPATH_STUDENT_COVERAGE_PROFILE=linux-runtime-dependency-apply`
  against the real installer, dnsmasq, and Firefox inside the student-flow
  container): the first pass exposed the apply-service sourcing defect with
  `firstProbeStatus: "blocked"` at 1084 ms while
  `linux-runtime-dependency-apply.json` still reported the overlay applied and
  the remote whitelist untouched; the collected container journal showed
  `has_config_changed: command not found`. After the sourcing fix, the same
  script run restarts `dnsmasq`, updates the config hash, and the learned
  domain stops resolving to the sinkhole (`192.0.2.1` before, NXDOMAIN after).
  The acceptance rerun recorded `firstProbeStatus: "ok"` at 1234 ms with
  `remoteWhitelistMutated: false`: the first browser request to the unknown
  dependency was held until the local overlay was truly applied and then
  completed.
- Windows target-platform acceptance on the desktop-survival lab VM
  (2026-09-27): the native host returned `runtimeDependencyState: "ready"` with
  the overlay `generation`/`appliedGeneration` stamped after the Acrylic
  reload. With host permissions granted, the first Reddit visit queued every
  dependency batch with `success=True` (waits 2-14 s while a burst was being
  coalesced) and rendered the full page in a cold profile: 81 resources,
  `www.redditstatic.com` scripts of 408 KB and 105 KB transferred, post images
  and the app shell visible in the screenshot; the second visit loaded 96
  resources. Earlier iterations on the same VM measured 3-8.6 s applies and
  released first-visit requests, which motivated the new budgets, the
  redundant-reload skip, the queue triggers, the drain loop and the debounce.
- Firefox host-permission representation (corrected 2026-09-30): an earlier
  note in this document described `userPermissions.origins = []` as a
  "host-permission gap". That was a misreading of the MV3 representation. In
  Firefox, optional host permissions are not materialized under
  `userPermissions.origins` for policy-managed (force-installed) extensions;
  the `<all_urls>` grant appears in
  `profile/extensions.json` + `extension-preferences.json` as a granted
  permission and `webRequest` sees page traffic. The Phase 1 lab
  (`evidence/spa-runtime-deps-phase1-20260929-1929/`) confirmed with Firefox
  156 release and the force-installed signed XPI that dependency learning and
  blocking worked with `userPermissions.origins = []`, so no product change is
  required for the permission path. See "Phase 2A" below for the actual
  Windows-side blockers that were measured.
- Physical acceptance (freshly installed student machine, Windows and Linux)
  remains pending.

### Phase 2A: resident worker, OS-level readiness, and negative caching (2026-09-30)

Phase 1 (lab, `evidence/spa-runtime-deps-phase1-20260929-1929/summary.md`, two
R2 runs + R3 + R1 on Windows 11 25H2 / Firefox 156 / Reddit) measured the
Windows path end to end and found four blockers beyond the protocol itself:

1. **Per-message cold start dominated the first batch.** Every learned batch
   paid a fresh `schtasks.exe /Run` + new PowerShell process + module import
   before the fast apply started. From the first dependency request to the
   start of the fast apply took ~10-12 s; the first batch was applied at
   T0+15-18 s. The extension's held requests release at the 5 s/6 s soft
   timeouts, so the requests that triggered the learning were released before
   the overlay became operative (holds 5,013-6,039 ms; never released by
   `ready`).
2. **The readiness wait was too coarse.** The native host polled the queue and
   overlay conditions at 1000 ms, adding up to a second of latency on top of
   the apply.
3. **Readiness was unreadable to the browser user.** The overlay lives under
   the restricted `C:\OpenPath\data` root; the staged native directory ACL is
   `BUILTIN\Users:(RX)` and neither the overlay nor the (previously)
   native-directory log file was writable/readable in the Firefox user
   context. `Write-NativeHostLog` failed silently and
   `Test-NativeHostRuntimeDependencyReady` could never observe a fresh
   generation, which is why the extension always fell back to the soft
   timeout. Two fixes: the overlay and worker heartbeat now receive an
   explicit `BUILTIN\Users` read ACE when written, and the native host log
   moved to `%LOCALAPPDATA%\OpenPath\native-host.log` (per-user, size-capped
   with one rotation).
4. **Negative caching kept failed dependencies broken after a late apply.**
   Firefox caches the NODATA answer for 60 s and `network.dnsCacheExpiration`
   only governed positive answers; Windows also kept 9501 (NODATA) entries.
   A successful Acrylic reload alone therefore did not make a _fresh_ OS
   lookup succeed.

Phase 2A changes:

- **Resident worker** (`scripts\Start-RuntimeDependencyWorker.ps1`,
  task `OpenPath-RuntimeDependencyWorker`): a single SYSTEM process started at
  boot that imports the update runtime once, watches the queue with a
  `FileSystemWatcher` plus a 2 s backup sweep and a 150 ms debounce, and
  applies batches in-process through
  `Invoke-OpenPathRuntimeDependencyFastApply`. If the global update mutex is
  busy the worker waits and retries instead of dropping the batch. It writes a
  heartbeat (`data\runtime-dependency-worker-state.json`, readable by the
  browser user) that the native host consults; the watchdog restarts the task
  if it is not running. `schtasks.exe` remains as the fallback trigger and
  `Apply-RuntimeDependencyQueue.ps1` keeps working for older layouts.
- **Ready implies an OS-level lookup.** After a successful Acrylic reload the
  fast apply now runs `Clear-OpenPathDnsClientCache`
  (`windows/lib/internal/DNS.Acrylic.Service.ps1`, with an
  `ipconfig /flushdns` fallback) before stamping `appliedGeneration`, and the
  metrics line records `dnsFlushMs`/`dnsFlushOk`.
- **Native host readiness poll** dropped from 1000 ms to 100 ms, and the
  per-message pipeline is instrumented in the per-user log: process start,
  message received, queue written, worker-fresh/task trigger, readiness
  observed, response sent (absolute timestamps plus script/process-relative
  milliseconds).
- **Firefox negative cache disabled through managed config**: the same three
  locks ship on Windows (`mozilla.cfg`) and Linux (mozilla.cfg +
  `policies.json` Preferences): `network.dns.refresh_negative_addr_on_use =
true`, `network.dnsNegativeCacheExpiration = 0`,
  `network.dnsNegativeCacheExpirationGracePeriod = 0`.

Measured outcome (Windows desktop-survival lab VM, two acceptance
executions `C1`/`D1` plus a pre-worker baseline `A1`; bundles with the
`2ffa52a1` scripts plus this change; full data in
`evidence/spa-runtime-deps-phase2a-20260930-0713/`):

- A lab-only defect surfaced before the fix could be trusted: the
  already-restricted `data\` root made the overlay unreadable to the
  Firefox user, so the native host could never observe a fresh
  `appliedGeneration` (this is why the extension always fell back to the
  soft timeout, in Phase 1 too). The overlay and the worker heartbeat now
  carry an explicit `BUILTIN\Users:(RX)` ACE, verified on the VM.
- Pre-worker baseline (`A1`): first dependency queue file at `T0+~7 s`;
  the schtasks-triggered fast apply only started `~8 s` after the queue
  write and completed after 14 s waits. The extension never saw `ready`;
  first-visit dependencies were released by the soft timeouts.
- With the worker (`C1`/`D1`): the worker reacts to the first queue file in
  `0.2-0.4 s` (FileSystemWatcher + 100 ms debounce, 1 s backup sweep) and
  applies in-process. `stage=worker-fresh skippedTaskTrigger=true` proves
  the native host no longer pays the schtasks hop. `ready`
  (`appliedGeneration` stamped after the Acrylic reload + DNS client
  flush) is observed by the extension for every batch; both runs show zero
  dependency-host `NS_ERROR_UNKNOWN_HOST` answers after their ready and no
  dependency-host 9501/9003 entries in the Windows cache after their
  ready. The worker survives a VM reboot (startup trigger) and the
  watchdog restarts it after a kill (verified).
- Residual latency (explicit Phase 2B target): the first batch still takes
  `~10-19 s` to `ready` in a cold profile because each extension message
  spawns a new `powershell.exe` native host (`message sent -> queue
written` alone is `~3.5-5 s` cold; the script init is ~1 s warm p95, and
  PowerShell host startup dominates). Request -> fast-apply start was
  `4.6 s` (`D1`) and `5.9 s` (`C1`); the apply itself starts as soon as
  the queue file exists. A persistent native-messaging host (transport
  change) removes this class of cold start; the extension-side decision to
  keep holding and retry failed dependency requests after late readiness
  is also Phase 2B.
- R5 observation: the periodic full update cycles still restart Acrylic
  twice per cycle in the lab (even when the local whitelist content is
  unchanged), matching the Phase 1 observation; left unchanged because it
  is not proven-trivial and the fast-apply path already skips redundant
  reloads.

## Verification

Focused suites per package (no broad CI first):

- `npx tsx --test tests/background-listeners.test.ts` and
  `npm test --workspace=@openpath/firefox-extension`
- `Invoke-Pester -Path tests\Windows.Browser.NativeHost.Tests.ps1` on a
  Windows-capable machine (or `npm run diagnostics:windows:direct` from this
  workspace)
- `cd tests && bats *.bats` for the Linux queue/apply changes

New end-to-end style coverage:

- Extension: a test where the native host answers `queued` first and `ready`
  after 400 ms proves the webRequest promise resolves only at `ready` and the
  request is not released early.
- Extension: two concurrent requests for the same dependency produce exactly
  one native operation.
- Windows Pester: overlay write without Acrylic reload does not satisfy the
  readiness wait; reload completing does.
- Linux bats: apply script writes the applied marker only after successful
  `restart_dnsmasq`; the Python host answers `queued` on marker timeout and
  `ready` when the marker appears.

Physical acceptance (manual, per Evidence Ladder): first visit to Reddit on a
freshly installed student machine (Windows and Linux) loads the page
completely without manual reload; overlay shows the learned dependencies;
no new AMO permissions in the signed XPI manifest.
