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

Known adjacent defect (fixed in Phase 2B, 2026-09-30): on Linux,
`command_update` in `runtime-dependency-overlay.py` mutated entry dicts in place
before snapshotting the "before" state, so metadata-only refreshes (`lastSeen`,
`expiresAt`, `requestTypes` on an existing pair) reported `changed=false` and
were not persisted. The snapshot is now taken before the merge loop; see the
Phase 2B notes below.

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

### Phase 2B: per-entry readiness, worker hot path, and non-blocking protocol (2026-09-30)

Phase 2B keeps the Phase 2A wire behavior by default and removes the remaining
self-inflicted latency:

**Per-entry readiness (Windows + Linux).** The overlay keeps a document
`generation` and `appliedGeneration`, but every entry that is added now also
carries its own `generation` (the document generation that made it newly
resolvable). An entry is ready when `appliedGeneration >= entry.generation`;
entries without a per-entry stamp (written by older agents) fall back to the
document rule. Metadata-only refreshes (`lastSeen`, `expiresAt`,
`requestTypes` of an existing pair) and prune rewrites no longer move the
document generation. Before this change, writing generation `k+1` (any new
dependency) made every already-applied entry answer `pending` until the next
stamp -- the Phase 2A lab measured that window as up to ~24 s of a full batch
drain (gen1 08:14:49 / gen2 08:14:57 / gen3 08:15:03 in the D1 run). Now the
worker stamps `appliedGeneration` at the end of every drain iteration, so the
entries of iteration `k` become ready while iteration `k+1` is still pending.
On Linux the same rule lives in `runtime-dependency-overlay.py` and
`openpath-native-host.py::is_runtime_dependency_ready`, and the in-place
"before" snapshot defect is fixed so metadata refreshes are persisted.

**Worker hot path (Windows).** `Invoke-OpenPathRuntimeDependencyFastApply` no
longer runs `Get-OpenPathConfig` + `Sync-FirefoxNativeHostMirror` on every
batch: the mirror is rebuilt only when the fingerprint of `data\whitelist.txt`
and `data\config.json` changes (`data\native-host-mirror-sync.json`), and any
sync performed by the update flow records the same fingerprint. The queue
drain builds the whitelist/protected/blocked sets once per batch instead of
once per request. Acrylic's generated files are only rewritten when their
content changed (the ~35 KB INI and `AcrylicHosts.txt`), the service wait
polls at 100 ms, and the DNS client cache flush prefers an in-process
`DnsFlushResolverCache` P/Invoke over the ~500 ms `Clear-DnsClientCache`
cmdlet (reload -> flush -> stamp order preserved). The total debounce is
`100 ms` (worker watcher) + `150 ms` (fast apply) <= 300 ms.

**Busy heartbeat.** While a batch is applying, the worker publishes
`busySince` / `busyStage` and refreshes them per iteration and around the
Acrylic reload through the optional `-WorkerStatePath`. The native host treats
a busy mark younger than 120 s as "worker alive", so a >10 s batch no longer
triggers a duplicate schtasks fast apply (observed in Phase 2A: pid 3292
restarted Acrylic again after the worker had already stamped ready).

**Non-blocking protocol.** `allow-local-runtime-dependency` and its batch
variant accept `mode: 'enqueue'`: the host validates and queues, ensures the
apply path will run (Windows nudges the apply task only when the worker is not
alive; Linux relies on the systemd path unit) and answers immediately with the
per-entry state (`ready` / `pending` / `denied` / `error`). Without `mode` the
blocking behavior is unchanged, so the signed extension of `main` keeps
working. `check-local-runtime-dependency` accepts a batch and answers per
entry after a single overlay read. Both hosts echo an optional request `id` in
the response for the persistent transport of Phase 2C, and the Windows host
caches the expensive validation sets per process keyed by whitelist/state
file metadata.

Measured outcome (Windows desktop-survival lab VM 111, synthetic burst +
two cold Reddit runs `BR1`/`BR2`; full data in
`evidence/spa-runtime-deps-phase2b-20260930-1250/`):

- Synthetic burst (20 new dependencies over 3 s, `mode: "enqueue"`, one
  persistent native host process): 20/20 entries ready, per-entry
  enqueue -> ready 1.7-3.1 s, and entries of an iteration were observed ready
  within <=~60 ms of that iteration's stamp while the next iteration was still
  pending. Worker iterations took 1.4/1.5/1.5 s (b4); the whole batch applied
  in 5.1 s including three Acrylic restarts (`acrylicReloadMs=2433`).
- Hot path (vs the Phase 2A D1 baseline): the config + mirror preamble went
  from ~5 s per batch to 2-66 ms (`mirrorSynced=False`); the DNS flush went
  from 506-589 ms to 0-3 ms; the INI/hosts writers skip unchanged content; the
  total debounce is 250 ms (100 + 150).
- Cold Reddit runs (extension from `main`, blocking mode): first iteration
  detection -> stamp 3.0 s (BR1) and 6.6 s (BR2, cold caches: 4.6 s queue
  processing + 2.4 s Acrylic reload); the first dependency wave reported
  `ready` at T0+13.3 s (BR1) / T0+13.0 s (BR2), and the re-issued requests
  resolved at T0+13-15 s (BR1) / +13-18 s (BR2); the screendumps render the
  full first visit from +30 s. The remaining request -> ready latency is the
  per-message native host cold start (Phase 2C transport) plus the Acrylic
  service stop/start, not queue work.
- Zero post-ready negatives for every overlay entry in both runs: no
  `NS_ERROR_UNKNOWN_HOST` after the entry's own generation was stamped, and no
  dependency-host 9501/9003 entries in the Windows cache after that point.
- Zero schtasks fallbacks and zero duplicate fast applies: every blocking
  message took `stage=worker-fresh skippedTaskTrigger=true`; the one lock
  contention observed (13:59:35) made the worker wait and retry, and the batch
  was applied once the lock freed. A 30 s simulated busy batch keeps the
  native host from triggering the fallback (unit-covered).
- Guards preserved: the worker survives a reboot, the watchdog relaunched it
  after a kill within ~75 s, `example.org` still returns no address (Windows
  cache status 9501) and the served whitelist did not change.

### Phase 2C: persistent native transport, cancel, and one automatic reload (2026-09-30)

Phase 2B measured the remaining first-visit problem precisely: every message
paid a native host cold start (1.2-2.5 s per `sendNativeMessage`, up to 7 s
after login), 83 host processes in 3.7 minutes, and a held request was
_released_ at its 5-6 s budget while the apply finished at T0+13 s. The page
then had to retry by itself, which it only did when the request happened to be
re-issued late (BR1 rendered without CSS; BR2 only worked by luck).

Phase 2C moves the extension and the hosts to a persistent protocol:

- **Capabilities.** `ping` now answers `protocolVersion: 2` and
  `capabilities: [...]`. A host that does not is served exactly like before
  (same messages, same 5/6 s budgets, same release behavior). The retirement
  switch (`runtimeDependencyPersistentTransportDisabled` in the Windows config,
  `runtime-dependency-persistent-transport.conf` on Linux) drops the
  `runtime-dependency-enqueue` and `runtime-dependency-auto-reload`
  capabilities so the fleet can be rolled back without re-signing the XPI.
- **One port.** The background keeps one `connectNative` port, probes it with a
  capability `ping` (10 s cold-start timeout), correlates responses by a
  monotonic `id`, and uses it for the dependency flow plus the cheap periodic
  reads (`get-policy-version`, `get-blocked-paths`, `get-blocked-subdomains`,
  `get-allowed-paths`). A port timeout tears it down with exponential backoff
  (1 s .. 30 s) and the in-flight dependency work is redone one-shot. Cold
  prewarm happens at background start and on `onBeforeNavigate` frame 0.
- **Enqueue + prober.** Dependencies coalesce for 25 ms (<= 20 entries) and are
  sent with `mode: "enqueue"`; `pending` entries stay open and are polled with
  a batch `check` every 150 ms (one in flight). `ready` releases the hold,
  `denied`/`error` releases it as a failure, exactly like 2B.
- **Budgets.** While the persistent transport is active the soft budgets are
  10 s for `script`/`stylesheet`/`font` and 8 s for
  `fetch`/`xmlhttprequest`/`image`/`imageset`. Justification from 2B: the first
  worker apply reached ready at T0+13.0-13.3 s (first wave) but individual
  requests were issued up to 7 s into the navigation; a 10 s budget covers
  apply windows up to ~10 s while the 12 s element-probe timeout and the 15 s
  driver timeout in the Selenium student-policy scenarios still hold. The
  budget is only the _cancel/release_ bound: the prober releases as soon as the
  host proves readiness (1.7-3.1 s in the 2B burst).
- **Cancel instead of release.** With the persistent transport active, a budget
  expiry while the entry is still `pending` returns `{ cancel: true }` from the
  `onBeforeRequest` listener. No DNS query happens, so no negative answer is
  cached and the page does not permanently fail that host. The cancellation is
  recorded as a `cancelled-pending` dependency-observation event and its
  request id is remembered so the resulting `onErrorOccurred` (typically
  `NS_BINDING_ABORTED`, otherwise `NS_ERROR_UNKNOWN_HOST`) is not counted as a
  blocked domain and never reaches the blocked screen or a native `check`.
- **One automatic reload.** When a cancelled render-critical request
  (`script`/`stylesheet`/`font`, frame 0) becomes ready, the tab is reloaded
  once after a 400 ms coalescing window, provided all conditions hold: the host
  announced `runtime-dependency-auto-reload`, the navigation is still the same
  one (no newer main-frame navigation or commit), the URL matches ignoring the
  fragment, the main-frame request was a GET, the navigation is at most 30 s
  old, no auto-reload happened for that navigation in the last 30 s, and the
  tab is not an extension page, the blocked screen or a captive-portal flow.
  The reload is recorded with its reason (`reloaded`, `url-mismatch`,
  `navigation-too-old`, ...) in the dependency-observation diagnostics.
- **Host freshness and log policy.** A persistent host re-reads state and
  whitelist sections on every message (the validation context cache is keyed by
  whitelist/state mtime+size, so a staged policy change invalidates it). Poll
  actions are logged as transitions/aggregates (once per minute or 500
  messages) instead of one line per message, and the Windows hot path was
  measured in-process (ping ~9 ms, batch check ~6 ms, enqueue ~72 ms).

Correction from the lab (2026-09-30, same day): the first lab run showed the
first dependency batch arriving about 1 s into the page load, before the
browser had even spawned the host process (about 6 s under a cold Firefox load
plus a 3 s spawn/probe). The 4 s first-port wait expired before the port
existed, so the batch fell to the one-shot path and its stylesheet was
_released_ at the legacy 6 s budget: at that expiry the persistent capability
was not ready, so nobody could cancel it, and the page rendered unstyled until
the single auto-reload repaired it. The first port wait now covers the full
probe window (10 s) and the persistent budget family applies while the port is
ready **or still connecting**, so a cold first batch waits for the port
decision, enqueues, and its render-critical entries are cancelled at their
persistent budget (then repaired by the reload) instead of being released.

Measured outcome (fill-in after the lab run): see
`evidence/spa-runtime-deps-phase2c-<timestamp>/summary.md`.

### Phase 2D: first-visit latency (2026-10-01)

Phase 2D starts from a corrected reading of the 2C lab evidence. The audit
changed three conclusions before any code was written:

- The criterion "page complete at +15 s" was **not** met in 2C. At +15 s R1 and
  R3 were blank and R2 was unstyled; the pages completed at +60 s, +30 s and
  +30 s. R2 and R3 completed _because of_ the single automatic reload (+24.8 s
  in R2). Only R4 (settled system, bbc.com, styled at +10 s without a reload)
  and R5b met the intended behaviour. 2D evaluates "<=10 s, no reload" literally.
- There was **no listener start race**. The unstyled first paint came from the
  latency to `ready`, not from requests escaping the listeners: the 2C R2 CSS
  (`styles-css-inlined-css-*.css`) was held from 21:10:33.338 and cancelled at
  21:10:43.361 (10 s budget). The "unheld" `www.redditstatic.com` request was
  the favicon (`/shreddit/assets/favicon/64x64.png`), which Firefox loads and
  which is not interceptable.
- 2C R4 never measured port survival: it was a **new Firefox process** (its
  `MOZ_LOG` parent started at 21:22:59 while R3's had used another parent), so
  the idle-port question stayed open. Firefox exempts an event page with active
  native app ports from idle termination
  (`toolkit/components/extensions/parent/ext-backgroundPage.js`,
  `hasActiveNativeAppPorts` -> `nativeapp` idle reset), and
  `extensions.background.idle.timeout` is capped at 5 minutes, so it cannot be
  used as a keepalive. 2D measures the real behaviour in one Firefox process
  across >=5 minutes of rest.

Workstreams:

- **D1 -- the transport must not self-destruct under load.** A request timeout no
  longer disconnects the port. The only teardown paths are `onDisconnect` and a
  failed liveness probe: a timed-out call only marks the port dead when the host
  has been silent for >=15 s and a probe `ping` also times out. Per-action port
  timeouts replace the old uniform 3 s default: enqueue >=10 s, checks and cheap
  reads >=5 s, capability probe 10 s. While the port is `ready` or `connecting`,
  runtime dependency batches never take the one-shot path; the one-shot path
  remains only for hosts without capabilities and for the backoff window after a
  real disconnect. A slow batch that fails after the enqueue was written stays
  pending on the prober instead of spawning one-shot hosts.
- **D2 -- the native host must start fast.** The startup path no longer imports
  `RequestSetup.State.psm1`, `TaskRunner.ps1` or the three captive portal
  support files; each is loaded on demand by the action that needs it (with
  existing function overrides preserved, so test doubles survive the lazy load).
  The hot path keeps only what ping, enqueue, batch check and the cheap reads
  touch. The host writes one `stage=startup-profile` line per process with
  `processToScriptMs`, per-file load times, `pingMs`, `firstEnqueueMs` and
  `firstEnqueueAtMs`; targets are process->ping p95 <=1.5 s on a settled system
  (<=3.5 s freshly installed or at boot) and first enqueue <=150 ms.
- **D3 -- the worker starts warm and detects fast.** At startup the resident
  worker pre-warms the DNS flush P/Invoke (`Initialize-OpenPathDnsFlushType`,
  whose Add-Type compile cost 1.7-4 s in the 2C first flush), the whitelist and
  policy sets, the overlay read and validation (through an isolated temp queue
  with one invalid request) and the Acrylic content generation in dry-run mode
  (`Initialize-OpenPathAcrylicHostRenderDryRun`, render only, no writes). It
  logs one `stage=prewarm` line with per-stage milliseconds. Detection now logs
  `queueFileAgeMs` (age of the oldest queue file when the batch is noticed) and
  the idle sweep interval dropped from 1 s to 250 ms so a missed watcher event
  cannot push detection past the 300 ms bound. The Acrylic service restart stays
  and is reported separately in the apply metrics.
- **D4 -- measure port survival in one Firefox process.** In the S2/S4 scenarios
  the same browser idles >=5 minutes and then navigates to a new anchor; the
  evidence correlates the host pid, the `Native host port disconnected` log line
  and the message index. If the port dies, the closer is identified (extension,
  host or Firefox) and fixed; if it survives it is documented (expected:
  Firefox keeps the event page because a native app port is open).
- **D5 -- documentation.** This section plus the `windows/TROUBLESHOOTING.md`
  entries for `stage=startup-profile`, `stage=prewarm` and `queueFileAgeMs`.

Corrections to the 2C report are recorded above; the 2C intermediate SHAs also
had red CI runs (7fe6a47e: Pester shard 5/5 and E2E; 41cc1e6c: Linux
student-policy `firefox_registration_missing` and APT contracts) before the
final green `e54858a5`. The E2E `Windows Student Policy` job and `Release
Installation Scripts` sign the same AMO version concurrently and one of them
fails with a hard-failure; this recurs on every push that changes the XPI and
is worked around by re-running the failed jobs (fix planned for Phase 3).

Measured outcome (fill-in after the lab run): see
`evidence/spa-runtime-deps-phase2d-<timestamp>/summary.md`.

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

## Phase 2E: observability, reload repair and class-boot latency

Phase 2E adds three things on top of 2D, grouped in one XPI-affecting push:

- **Extension diagnostics (E1).** A bounded in-memory buffer
  (`firefox-extension/src/lib/extension-diagnostics.ts`) records background
  start, transport transitions, navigation identity, every held request with its
  transport state and outcome, and every auto-reload decision _with its reason_
  (the paths that used to be silent now report `navigation-mismatch`,
  `navigation-unknown`, `url-mismatch`, `navigation-form-submit`, ...). A
  rate-limited reporter (at most one message every 2 s, at most 50 events,
  `report-extension-diagnostics` over the persistent port) sends the batches to
  the native host, which sanitizes them (hosts, types, reason codes, ids and ms
  only; URLs and unknown fields are dropped) and writes one
  `stage=extension-diagnostic {json}` line per event to the user's
  `native-host.log`. The capability `extension-diagnostics` is announced by
  `ping` unless the host config disables it
  (`windows`: `data\config.json` key `extensionDiagnosticsDisabled`; `linux`:
  `/etc/openpath/extension-diagnostics.conf` or
  `OPENPATH_EXTENSION_DIAGNOSTICS_CONF`), so retiring it never needs a new XPI.
- **Auto-reload repair (E2/E3).** Navigation identity is built from any
  available event (webRequest main frame, `onBeforeNavigate`, `onCommitted`,
  `onHistoryStateUpdated`) and, as a fallback for a background that starts late,
  from the cancelled frame-0 request's `documentUrl`. An unknown method allows
  the reload unless `onCommitted` reported `form_submit`; URL comparison
  tolerates same-path history changes and path changes with an observed
  history update, and never reloads when the tab is in another document.
- **Class-boot latency (E4/E5).** The first host process of each user session
  still pays the platform's first-script cost (AppLocker/AMSI/Defender; measured
  in the Phase 2E lab), so render-critical budgets stay at 10 s and the repair
  path above covers the gap.

Evidence: `evidence/spa-runtime-deps-phase2e-20261001-1514/` (including the
reusable `analyze-mozlog-2e.py` channel-matched MOZ_LOG analyzer and
`e1-timeline.py`).

## Phase 3A: the first-visit lane and what stays open

Phase 3A turns the 2E lab work into a permanent CI lane
([`docs/windows-first-visit-lab.md`](../windows-first-visit-lab.md)) with a
site-agnostic fixture, a self-report verdict and per-wave metrics, and fixes the
E1 diagnostics loop (the 2E host handler cast epoch-millisecond fields to
`[int]`, which threw on every real batch).

Design principle (user decision): the solution and the tests are
**site-agnostic**. No domain list may be tied to a concrete site; everything the
product allows is learned at runtime with the current generic rules. That is why
the fixture uses random hosts per run and why no part of the lane may depend on
knowing the site.

Status after Phase 2E (verified on captures and MOZ_LOG):

- class boot (S3): 3/3 complete with exactly one automatic reload; last
  render-critical success at +24.2 / +22.6 / +22.7 s; styled captures at ~+30 s;
  broken in every execution before `e0d73bb9`;
- freshly installed (S1g): last success at +13.0 s;
- settled system (S2): last success at +12.2 s - **the <=10 s objective is not
  met**;
- slow path (S5b): one reload, last success at +25.4 s;
- measured costs: cold class-boot host 9-15 s to ping; settled host 1-3 s; one
  worker iteration per dependency wave with an Acrylic restart, 0.9-3.4 s.

What remains open for Phase 4 (measured, not inferred):

- settled visits above 10 s (W/S2);
- the 25 s/30 s budgets that the class-boot repair path needs;
- automatic reload only covers script/stylesheet/font;
- a 9-15 s cold host at class boot;
- one Acrylic restart per dependency wave.

Phase 3B keeps its own scope: real-site canary, the MOZ_LOG analyzer inside the
repo, the strict Linux profile in CI, the `firefox_registration_missing` flake
and hardening SP-006.
