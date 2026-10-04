# Extension <-> Native Host Message Contract

> Status: maintained
> Applies to: OpenPath repository
> Last verified: 2026-09-30
> Source of truth: `docs/extension-native-host-contract.md` -- update this file whenever a message type is added, removed, or its payload changes.

## Purpose

The OpenPath Firefox extension communicates with the Windows PowerShell native host (and the
Linux Python native host) through the browser native-messaging API. The native host performs
operations the extension cannot: reading the local whitelist, checking domain policy, triggering
whitelist updates, and probing captive portals.

This document covers the full set of message types exchanged between the extension and the native
host. It does **not** cover internal extension messages (background <-> blocked-page / popup) that
are handled entirely inside the extension; those are defined in
`firefox-extension/src/lib/blocked-screen-contract.ts` and dispatched by
`firefox-extension/src/lib/background-message-handler.ts`.

## Transport

- Protocol: [browser native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging)
- API: `browser.runtime.sendNativeMessage()` / `browser.runtime.connectNative()`
- Framing: 4-byte little-endian length prefix followed by UTF-8 JSON (standard native-messaging wire format)
- Windows host entry point: `windows/scripts/OpenPath-NativeHost.ps1` (PowerShell reference and fallback); on installed machines the registered host is the compiled `OpenPath-NativeHost.exe` built from `windows/native-host/OpenPathNativeHost.cs`; framing in `windows/lib/internal/NativeHost.Protocol.ps1::Read-NativeMessage` / `Write-NativeMessage` and the identical C# reader/writer
- Linux host entry point: `firefox-extension/native/openpath-native-host.py`
- Dispatch: `windows/lib/internal/NativeHost.Actions.ps1::Handle-Message` -> `Invoke-NativeHostMessageAction`; the compiled host mirrors the same dispatch table

Every response includes at minimum `{ success: boolean }`. Errors add `{ error: string }`.

### Compiled Windows host (Phase 5)

The classroom AppLocker boundary denies `powershell.exe`/`pwsh.exe` to the
restricted student, which blocked the PowerShell host. The installer compiles
the C# source with the in-box .NET Framework compiler and registers the
executable only after a framed `ping` health check; the PowerShell/cmd host
stays as the registered fallback whenever the build or the health check fails.
The wire format, action names, response shapes, `protocolVersion`, capability
list, id echo and the per-user `native-host.log` lines are identical, and
`windows/tests/Windows.NativeHostParity.Tests.ps1` compares both hosts action by
action on Windows. See
[`design/windows-native-host-under-appcontrol.md`](design/windows-native-host-under-appcontrol.md).

### Persistent transport (Phase 2C)

The background keeps **one long-lived `connectNative` port** per browser
session. Opening it removes the per-message native host cold start measured in
Phase 2B (1.2-2.5 s per `sendNativeMessage`, up to 7 s for the first one after
login) and lets the host answer many messages from one process.

- On connect, the extension probes the host with a `ping` carrying a monotonic
  `id` (probe timeout 10 s to cover a cold start). A host that answers with
  `protocolVersion` >= 2 and `capabilities` is served over the port; a host
  without capabilities keeps the historical one-shot behavior exactly (same
  budgets, same messages).
- Capabilities announced by `ping`:
  - `runtime-dependency-enqueue`
  - `runtime-dependency-check-batch`
  - `message-id-echo`
  - `runtime-dependency-auto-reload`
- Actions served over the port: `ping`,
  `allow-local-runtime-dependency(-batch)` with `mode: "enqueue"`,
  `check-local-runtime-dependency` (batch) and the cheap periodic reads
  (`get-policy-version`, `get-blocked-paths`, `get-blocked-subdomains`,
  `get-allowed-paths`). Everything else (`check`, `update-whitelist`,
  captive-portal recovery, `get-config`, `get-machine-token`, ...) stays
  one-shot so a slow action never blocks the port.
- Requests over the port are correlated by the echoed `id`; a request timeout
  (3 s) tears the port down and the extension reconnects with exponential
  backoff (1 s .. 30 s) while in-flight dependency work is redone through the
  one-shot path.
- **Retirement switch (no new XPI required):** setting
  `runtimeDependencyPersistentTransportDisabled: true` in the Windows agent
  config (`data\config.json`) or writing `disabled` in
  `/etc/openpath/runtime-dependency-persistent-transport.conf` (override:
  `OPENPATH_RUNTIME_DEPENDENCY_TRANSPORT_CONF`) makes the host stop announcing
  `runtime-dependency-enqueue` and `runtime-dependency-auto-reload`; the
  extension then behaves like the legacy one-shot client. Default: announced.
- Poll-style actions (`check` batch, policy/subdomain/path reads) are logged as
  aggregates (once per minute or per 500 messages) plus state transitions, not
  one line per message.

---

## Message Types

| Message type                           | Direction         | Payload fields (request -> response)                                                                                                                                                                                                                                                                                                                                                                                                  | TS definition (file:symbol)                                                                                                                                                                                                               | PS handler (file:function)                                                                                                                                                                                                                                                                                   |
| -------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ping`                                 | Extension -> Host | Request: `{ id?: number }` / Response: `{ success, action: 'ping', message: 'pong', version, protocolVersion: number, capabilities: string[] }` (the `id` is echoed back when supplied; capabilities as listed under _Persistent transport_)                                                                                                                                                                                          | `firefox-extension/src/lib/native-messaging-client.ts::isAvailable` (sends `{ action: 'ping' }`)                                                                                                                                          | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostMessageAction` (`'ping'` branch)                                                                                                                                                                                              |
| `get-hostname`                         | Extension -> Host | Request: _(none)_ / Response: `{ success, action: 'get-hostname', hostname: string }`                                                                                                                                                                                                                                                                                                                                                 | `firefox-extension/src/lib/native-messaging-client.ts` (called via `sendMessage({ action: 'get-hostname' })` in `background-runtime.ts`)                                                                                                  | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostMessageAction` (`'get-hostname'` branch)                                                                                                                                                                                      |
| `get-machine-token`                    | Extension -> Host | Request: _(none)_ / Response: `{ success, action: 'get-machine-token', token: string }` or `{ success: false, error }`                                                                                                                                                                                                                                                                                                                | `firefox-extension/src/lib/native-messaging-client.ts` (called via `sendMessage({ action: 'get-machine-token' })` in `background-runtime.ts`)                                                                                             | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostMessageAction` (`'get-machine-token'` branch)                                                                                                                                                                                 |
| `get-config`                           | Extension -> Host | Request: _(none)_ / Response: `{ success, action: 'get-config', apiUrl, requestApiUrl, fallbackApiUrls, hostname, machineToken, whitelistUrl }` or `{ success: false, error }`                                                                                                                                                                                                                                                        | `firefox-extension/src/lib/config-storage-native.ts::NativeConfigMessageSender` (type alias for `(msg: { action: 'get-config' }) => Promise<unknown>`)                                                                                    | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostMessageAction` (`'get-config'` branch)                                                                                                                                                                                        |
| `get-blocked-paths`                    | Extension -> Host | Request: _(none)_ / Response: `{ success, action: 'get-blocked-paths', ... }`                                                                                                                                                                                                                                                                                                                                                         | `firefox-extension/src/lib/background-runtime.ts` (sends `{ action: 'get-blocked-paths' }` via `nativeMessagingClient.sendMessage`)                                                                                                       | `windows/lib/internal/NativeHost.Actions.Shared.ps1::Get-NativeHostBlockedPathResponse` (invoked from `Invoke-NativeHostMessageAction` `'get-blocked-paths'` branch)                                                                                                                                         |
| `get-blocked-subdomains`               | Extension -> Host | Request: _(none)_ / Response: `{ success, action?: 'get-blocked-subdomains', subdomains?, count?, hash?, mtime?, source?, error? }`                                                                                                                                                                                                                                                                                                   | `firefox-extension/src/lib/native-messaging-client.ts::NativeBlockedSubdomainsResponse` (response interface)                                                                                                                              | `windows/lib/internal/NativeHost.Actions.Shared.ps1::Get-NativeHostBlockedSubdomainResponse` (invoked from `Invoke-NativeHostMessageAction` `'get-blocked-subdomains'` branch)                                                                                                                               |
| `check`                                | Extension -> Host | Request: `{ action: 'check', domains: string[], error?: string, source?: string }` / Response: `{ success, results: NativeCheckResult[] }` where each result adds `{ policy_decision: 'allowed' \| 'blocked' \| 'unknown', policy_reason, policy_version }` and preserves `{ domain, in_whitelist, policy_active, portal_recovery_eligible?, portal_recovery_signal?, resolves?, resolved_ip?, error? }`                              | `firefox-extension/src/lib/native-messaging-client.ts::NativeCheckResponse`, `NativeCheckResult`, `checkDomains()`                                                                                                                        | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostCheckAction`                                                                                                                                                                                                                  |
| `get-policy-version`                   | Extension -> Host | Request: `{ action: 'get-policy-version' }` / Response: `{ success: true, action, version }` or `{ success: false, error }`. The opaque revision identifies the same local inputs used by `check`.                                                                                                                                                                                                                                    | `firefox-extension/src/lib/background-tab-reconciliation.ts::NativePolicyVersionResponse`                                                                                                                                                 | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostMessageAction` (`'get-policy-version'` branch)                                                                                                                                                                                |
| `update-whitelist`                     | Extension -> Host | Request: `{ action: 'update-whitelist', domains?: string[] }` / Response: `{ success }`                                                                                                                                                                                                                                                                                                                                               | `firefox-extension/src/lib/native-messaging-client.ts::requestLocalWhitelistUpdate`                                                                                                                                                       | `windows/lib/internal/NativeHost.Actions.RuntimeDependency.ps1::Invoke-UpdateTask` (invoked from `Invoke-NativeHostMessageAction` `'update-whitelist'` branch)                                                                                                                                               |
| `allow-local-runtime-dependency`       | Extension -> Host | Request: `{ action: 'allow-local-runtime-dependency', anchorHost: string, dependencyHost: string, requestType: string, mode?: 'blocking'                                                                                                                                                                                                                                                                                              | 'enqueue', id?: string }`/ Response:`{ success, action: 'allow-local-runtime-dependency', anchorHost?, dependencyHost?, requestType?, skipped?, reason?, runtimeDependencyState?: 'ready' \| 'pending' \| 'denied' \| 'error', queued? }` | `firefox-extension/src/lib/runtime-dependency-protocol.ts::RUNTIME_DEPENDENCY_ACTIONS.allowLocal`; `firefox-extension/src/lib/native-messaging-client.ts::sendSingleLocalRuntimeDependency`                                                                                                                  | `windows/lib/internal/NativeHost.Actions.RuntimeDependency.ps1::Invoke-NativeHostLocalRuntimeDependencyAction` (invoked via `$script:OpenPathRuntimeDependencyActionAllowLocal`); constant defined in `windows/lib/internal/RuntimeDependency.Protocol.ps1`           |
| `allow-local-runtime-dependency-batch` | Extension -> Host | Request: `{ action: 'allow-local-runtime-dependency-batch', entries: LocalRuntimeDependencyInput[], mode?: 'blocking'                                                                                                                                                                                                                                                                                                                 | 'enqueue', id?: string }`/ Response:`{ success, action: 'allow-local-runtime-dependency-batch', results?: NativeResponse[] }`                                                                                                             | `firefox-extension/src/lib/runtime-dependency-protocol.ts::RUNTIME_DEPENDENCY_ACTIONS.allowLocalBatch`; `firefox-extension/src/lib/native-messaging-client.ts::flushRuntimeDependencyBatch`                                                                                                                  | `windows/lib/internal/NativeHost.Actions.RuntimeDependency.ps1::Invoke-NativeHostLocalRuntimeDependencyBatchAction` (invoked via `$script:OpenPathRuntimeDependencyActionAllowLocalBatch`); constant defined in `windows/lib/internal/RuntimeDependency.Protocol.ps1` |
| `check-local-runtime-dependency`       | Extension -> Host | Request: `{ action: 'check-local-runtime-dependency', anchorHost: string, dependencyHost: string, entries?: { anchorHost: string, dependencyHost: string }[], id?: string }` / Response: `{ success, action: 'check-local-runtime-dependency', ready: boolean, runtimeDependencyState?, expiresAt? }` (batch form answers `{ success, count, results: [{ anchorHost, dependencyHost, ready, runtimeDependencyState, expiresAt? }] }`) | `firefox-extension/src/lib/runtime-dependency-protocol.ts::RUNTIME_DEPENDENCY_ACTIONS.checkLocal`; `firefox-extension/src/lib/native-messaging-client.ts::confirmCachedRuntimeDependency`                                                 | Windows: `windows/lib/internal/NativeHost.Actions.RuntimeDependency.ps1::Invoke-NativeHostLocalRuntimeDependencyCheckAction`; Linux: `firefox-extension/native/openpath-native-host.py::is_runtime_dependency_ready`. The extension treats a non-ready answer as "not confirmed" and re-runs the allow flow. |
| `recover-captive-portal-navigation`    | Extension -> Host | Request: `{ action: 'recover-captive-portal-navigation', operation: 'open' \| 'reconcile', triggerHost?, portalRecoveryHosts?, portalState?, source?, tabId? }` / Response: `{ success, action?: 'recover-captive-portal-navigation', portalModeActive?, requestId?, state?, triggerHost? }`                                                                                                                                          | `firefox-extension/src/lib/native-messaging-client.ts::CaptivePortalRecoveryInput`, `CaptivePortalRecoveryResponse`, `recoverCaptivePortalNavigation()`                                                                                   | `windows/lib/internal/NativeHost.Actions.CaptivePortal.ps1::Invoke-NativeHostCaptivePortalRecoveryAction` (invoked from `Invoke-NativeHostMessageAction` `'recover-captive-portal-navigation'` branch)                                                                                                       |

---

## Runtime dependency readiness

`allow-local-runtime-dependency`, its batch variant, and
`check-local-runtime-dependency` report readiness through
`runtimeDependencyState` (plus `queued` for older hosts):

- `ready`: the host proved the dependency is operative in the local DNS path
  (queue applied and DNS configuration reloaded). The extension releases the
  blocked request as soon as it observes this state.
- `pending` / `queued`: accepted but not yet proven applied. The extension keeps
  the request waiting until its per-type soft timeout.
- `denied` / `error`, or `success: false`: terminal. The extension releases the
  request immediately so it fails fast instead of burning the wait budget.
- A legacy `success: true` without any readiness state is treated as `pending`:
  old-host behaviour is preserved without letting an unproven result release a
  request early.

Both hosts stamp the local overlay with a content `generation`, a per-entry
`generation`, and an `appliedGeneration` after a successful local DNS reload
(Acrylic restart on Windows, `dnsmasq` restart or an unchanged effective
configuration on Linux). **Readiness is per entry**:

- an entry added or materially changed in generation `k` is ready when
  `appliedGeneration >= k` (its own `generation` field);
- metadata-only refreshes (`lastSeen`, `expiresAt`, `requestTypes` of an
  existing pair) and prune rewrites do not move the document generation, so
  already-applied entries never fall back to `pending` while a later batch is
  still waiting to be applied;
- entries written before per-entry generations existed (no `generation` field)
  fall back to the document-level rule `appliedGeneration >= generation`, so
  overlays written by older agents keep working.

The extension caches a `ready` result for 60 seconds and keeps the entry for up
to 30 minutes. Older entries are confirmed with `check-local-runtime-dependency`
before being treated as ready again; when confirmation fails or is unsupported,
the entry is dropped and the normal allow flow runs.

The extension also shares one native operation per
`anchorHost|dependencyHost|requestType` triple, so concurrent requests for the
same dependency reuse the in-flight result instead of sending a duplicate.

### Non-blocking enqueue mode (`mode: "enqueue"`)

`allow-local-runtime-dependency` and `allow-local-runtime-dependency-batch`
accept an optional `mode` field:

- absent (or `"blocking"`): the historical behavior is unchanged -- the host
  validates, queues, triggers the apply path and waits for readiness up to its
  budget, then answers.
- `"enqueue"`: the host validates and queues, ensures the apply path will run
  (Windows: nudge the scheduled apply task only when the resident worker is not
  alive; Linux: the systemd path unit observes the new queue file), and answers
  **immediately** with the per-entry state:
  - `ready: true`, `queued: false` -- the dependency is already operative, no
    queue write happened;
  - `ready: false`, `queued: true` -- the request is queued; the answer does not
    wait for the DNS reload;
  - `denied` / `error` -- terminal, nothing was queued beyond the failed entry.
- any other value: `success: false` with
  `Unsupported runtime dependency mode`.

The Windows host answers enqueue batches with `mode: "enqueue"`,
`queuedCount`, `workerTriggered` and a `results` array whose entries carry
`queued`, `ready` and `runtimeDependencyState`.

### Batch checks

`check-local-runtime-dependency` also accepts a batch:

```json
{
  "action": "check-local-runtime-dependency",
  "id": "port-7",
  "entries": [
    { "anchorHost": "www.reddit.com", "dependencyHost": "cdn.example" },
    { "anchorHost": "www.reddit.com", "dependencyHost": "img.example" }
  ]
}
```

The overlay is read once and the response is
`{ success, action, count, results: [{ success, anchorHost, dependencyHost, ready, runtimeDependencyState, expiresAt? }] }`.
The historical single-pair request still works and keeps its response shape
(with `expiresAt` now also reported when present).

### Cancellation and automatic reload

When the persistent transport is active (enqueue + id-echo + auto-reload
capabilities), a dependency request whose budget expires while the entry is
still `pending` is **cancelled** instead of released: the request never reaches
DNS, so no negative answer is cached and the page does not gain a permanent
failure for that host. The soft budgets in this mode are 10 000 ms for
`script`/`stylesheet`/`font` and 8 000 ms for `fetch`/`xmlhttprequest`/
`image`/`imageset`.

While cancelled dependencies are pending, the extension polls them over the
port (`check-local-runtime-dependency` batch every ~150 ms). When one becomes
`ready`:

- the request is released normally if it was still held;
- for a cancelled render-critical request (`script`/`stylesheet`/`font` in the
  main frame of the tab's current navigation), the extension may reload the tab
  **once**: after a 400 ms coalescing window, and only if the host announced
  `runtime-dependency-auto-reload`, the navigation is still the same (no newer
  main-frame navigation), the current URL matches ignoring the fragment, the
  navigation was a GET, it is at most 30 s old, the tab was not reloaded by
  this mechanism in the last 30 s, and the tab is not one of the extension's
  own pages, the blocked screen or a captive-portal flow. The reload is
  recorded as a `runtimeDependencyAutoReload` dependency-observation
  diagnostic event with its reason.

### Correlation ids

Every message may carry an optional `id` field. Both hosts echo the received
`id` back in the response (`"id": <value>`). It is opaque to the host and exists
so a persistent transport (Phase 2C) can correlate answers per
port/connection. Messages without `id` produce responses without the field.

---

## Policy decision semantics and compatibility

`policy_decision` is the only native field that can authorize a domain-policy redirect. The
extension additionally requires `success: true`, `policy_active: true`, no per-result error, and a
non-empty `policy_reason` and `policy_version` matching the current policy epoch. DNS resolution,
HTTP status, `resolved_ip: null`, and legacy `in_whitelist: false` are diagnostic data and never
prove a block by themselves.

`in_whitelist` remains the effective legacy permission bit. It is true for allowed descendants,
protected infrastructure, configured captive-portal domains, exact runtime dependencies, and an
explicitly disabled policy. A missing or incoherent snapshot returns `success: false` and
`policy_decision: 'unknown'`; it is not represented as an empty active policy.

- New extension + new host: uses the explicit decision and revision.
- New extension + old host: treats the native blocking capability as unavailable; explicit
  path/subdomain interception and endpoint DNS/firewall enforcement remain unchanged.
- Old extension + new host: receives coherent legacy fields. It does not gain the navigation-race
  fixes implemented in the new extension.

The extension keeps one `sendNativeMessage` request per shared host/epoch check. The 4,000 ms soft
budget does not discard a response; a still-current navigation may use it until the 12,000 ms
logical hard limit. Neither timeout creates a blocked verdict.

---

## Internal extension messages (not native host)

The following message types travel between extension pages (blocked-page / popup) and the
background script over `browser.runtime.sendMessage`. They are **not** sent to the native host.
They are defined in `firefox-extension/src/lib/blocked-screen-contract.ts` and handled in
`firefox-extension/src/lib/background-message-handler.ts::createBackgroundMessageHandler`.

| Message type                          | Direction          | TS definition (file:symbol)                                                                                                 |
| ------------------------------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| `submitBlockedDomainRequest`          | Page -> Background | `blocked-screen-contract.ts::SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION`, `SubmitBlockedDomainRequestMessage`                     |
| `getRecentBlockedDomainRequestStatus` | Page -> Background | `blocked-screen-contract.ts::GET_RECENT_BLOCKED_DOMAIN_REQUEST_STATUS_ACTION`, `GetRecentBlockedDomainRequestStatusMessage` |
| `getBlockedPageContext`               | Page -> Background | `blocked-screen-contract.ts::GET_BLOCKED_PAGE_CONTEXT_ACTION`, `GetBlockedPageContextMessage`                               |

---

## When you add a message type

1. **TypeScript contract**: Add a typed interface or constant in the appropriate file under
   `firefox-extension/src/lib/` (use `native-messaging-client.ts` for native-host messages,
   `blocked-screen-contract.ts` for internal extension messages).
2. **PowerShell handler**: Add a `case` branch to `Invoke-NativeHostMessageAction` in
   `windows/lib/internal/NativeHost.Actions.ps1`, or add a new helper function and call it from
   there. If the action value is reused across files, define the constant in
   `windows/lib/internal/RuntimeDependency.Protocol.ps1` (or a new protocol file) and reference
   it via `$script:`.
3. **This doc**: Add a row to the message-types table above with the TS definition file:symbol and
   PS handler file:function. Mark any payload fields as "not yet implemented" if the PS side lags.
4. **Tests**: Add a test in `firefox-extension/tests/` for the TypeScript side and in
   `windows/tests/Windows.Browser.NativeHost.Tests.ps1` for the PowerShell side.

---

## Known gaps

- The `get-blocked-paths` response schema is not typed in a dedicated TS interface; the response
  is consumed as `unknown` and cast at call sites in `background-runtime.ts`.
