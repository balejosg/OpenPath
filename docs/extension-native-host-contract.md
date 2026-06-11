# Extension <-> Native Host Message Contract

> Status: maintained
> Applies to: OpenPath repository
> Last verified: 2026-06-11
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
- Windows host entry point: `windows/scripts/OpenPath-NativeHost.ps1`; framing in `windows/lib/internal/NativeHost.Protocol.ps1::Read-NativeMessage` / `Write-NativeMessage`
- Linux host entry point: `linux/native/openpath-native-host.py` (Python; not covered in detail here)
- Dispatch: `windows/lib/internal/NativeHost.Actions.ps1::Handle-Message` -> `Invoke-NativeHostMessageAction`

Every response includes at minimum `{ success: boolean }`. Errors add `{ error: string }`.

---

## Message Types

| Message type                           | Direction         | Payload fields (request -> response)                                                                                                                                                                                                                                                             | TS definition (file:symbol)                                                                                                                                                                 | PS handler (file:function)                                                                                                                                                                                                                                            |
| -------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ping`                                 | Extension -> Host | Request: _(none)_ / Response: `{ success, action: 'ping', message: 'pong', version }`                                                                                                                                                                                                            | `firefox-extension/src/lib/native-messaging-client.ts::isAvailable` (sends `{ action: 'ping' }`)                                                                                            | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostMessageAction` (`'ping'` branch)                                                                                                                                                       |
| `get-hostname`                         | Extension -> Host | Request: _(none)_ / Response: `{ success, action: 'get-hostname', hostname: string }`                                                                                                                                                                                                            | `firefox-extension/src/lib/native-messaging-client.ts` (called via `sendMessage({ action: 'get-hostname' })` in `background-runtime.ts`)                                                    | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostMessageAction` (`'get-hostname'` branch)                                                                                                                                               |
| `get-machine-token`                    | Extension -> Host | Request: _(none)_ / Response: `{ success, action: 'get-machine-token', token: string }` or `{ success: false, error }`                                                                                                                                                                           | `firefox-extension/src/lib/native-messaging-client.ts` (called via `sendMessage({ action: 'get-machine-token' })` in `background-runtime.ts`)                                               | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostMessageAction` (`'get-machine-token'` branch)                                                                                                                                          |
| `get-config`                           | Extension -> Host | Request: _(none)_ / Response: `{ success, action: 'get-config', apiUrl, requestApiUrl, fallbackApiUrls, hostname, machineToken, whitelistUrl }` or `{ success: false, error }`                                                                                                                   | `firefox-extension/src/lib/config-storage-native.ts::NativeConfigMessageSender` (type alias for `(msg: { action: 'get-config' }) => Promise<unknown>`)                                      | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostMessageAction` (`'get-config'` branch)                                                                                                                                                 |
| `get-blocked-paths`                    | Extension -> Host | Request: _(none)_ / Response: `{ success, action: 'get-blocked-paths', ... }`                                                                                                                                                                                                                    | `firefox-extension/src/lib/background-runtime.ts` (sends `{ action: 'get-blocked-paths' }` via `nativeMessagingClient.sendMessage`)                                                         | `windows/lib/internal/NativeHost.Actions.Shared.ps1::Get-NativeHostBlockedPathResponse` (invoked from `Invoke-NativeHostMessageAction` `'get-blocked-paths'` branch)                                                                                                  |
| `get-blocked-subdomains`               | Extension -> Host | Request: _(none)_ / Response: `{ success, action?: 'get-blocked-subdomains', subdomains?, count?, hash?, mtime?, source?, error? }`                                                                                                                                                              | `firefox-extension/src/lib/native-messaging-client.ts::NativeBlockedSubdomainsResponse` (response interface)                                                                                | `windows/lib/internal/NativeHost.Actions.Shared.ps1::Get-NativeHostBlockedSubdomainResponse` (invoked from `Invoke-NativeHostMessageAction` `'get-blocked-subdomains'` branch)                                                                                        |
| `check`                                | Extension -> Host | Request: `{ action: 'check', domains: string[], error?: string, source?: string }` / Response: `{ success, results: NativeCheckResult[] }` where each result has `{ domain, in_whitelist, policy_active?, portal_recovery_eligible?, portal_recovery_signal?, resolves?, resolved_ip?, error? }` | `firefox-extension/src/lib/native-messaging-client.ts::NativeCheckResponse`, `NativeCheckResult`, `checkDomains()`                                                                          | `windows/lib/internal/NativeHost.Actions.MessageDispatch.ps1::Invoke-NativeHostCheckAction` (top of file)                                                                                                                                                             |
| `update-whitelist`                     | Extension -> Host | Request: `{ action: 'update-whitelist', domains?: string[] }` / Response: `{ success }`                                                                                                                                                                                                          | `firefox-extension/src/lib/native-messaging-client.ts::requestLocalWhitelistUpdate`                                                                                                         | `windows/lib/internal/NativeHost.Actions.RuntimeDependency.ps1::Invoke-UpdateTask` (invoked from `Invoke-NativeHostMessageAction` `'update-whitelist'` branch)                                                                                                        |
| `allow-local-runtime-dependency`       | Extension -> Host | Request: `{ action: 'allow-local-runtime-dependency', anchorHost: string, dependencyHost: string, requestType: string }` / Response: `{ success, action: 'allow-local-runtime-dependency', anchorHost?, dependencyHost?, requestType?, skipped?, reason?, runtimeDependencyState?, queued? }`    | `firefox-extension/src/lib/runtime-dependency-protocol.ts::RUNTIME_DEPENDENCY_ACTIONS.allowLocal`; `firefox-extension/src/lib/native-messaging-client.ts::sendSingleLocalRuntimeDependency` | `windows/lib/internal/NativeHost.Actions.RuntimeDependency.ps1::Invoke-NativeHostLocalRuntimeDependencyAction` (invoked via `$script:OpenPathRuntimeDependencyActionAllowLocal`); constant defined in `windows/lib/internal/RuntimeDependency.Protocol.ps1`           |
| `allow-local-runtime-dependency-batch` | Extension -> Host | Request: `{ action: 'allow-local-runtime-dependency-batch', entries: LocalRuntimeDependencyInput[] }` / Response: `{ success, action: 'allow-local-runtime-dependency-batch', results?: NativeResponse[] }`                                                                                      | `firefox-extension/src/lib/runtime-dependency-protocol.ts::RUNTIME_DEPENDENCY_ACTIONS.allowLocalBatch`; `firefox-extension/src/lib/native-messaging-client.ts::flushRuntimeDependencyBatch` | `windows/lib/internal/NativeHost.Actions.RuntimeDependency.ps1::Invoke-NativeHostLocalRuntimeDependencyBatchAction` (invoked via `$script:OpenPathRuntimeDependencyActionAllowLocalBatch`); constant defined in `windows/lib/internal/RuntimeDependency.Protocol.ps1` |
| `recover-captive-portal-navigation`    | Extension -> Host | Request: `{ action: 'recover-captive-portal-navigation', operation: 'open' \| 'reconcile', triggerHost?, portalRecoveryHosts?, portalState?, source?, tabId? }` / Response: `{ success, action?: 'recover-captive-portal-navigation', portalModeActive?, requestId?, state?, triggerHost? }`     | `firefox-extension/src/lib/native-messaging-client.ts::CaptivePortalRecoveryInput`, `CaptivePortalRecoveryResponse`, `recoverCaptivePortalNavigation()`                                     | `windows/lib/internal/NativeHost.Actions.CaptivePortal.ps1::Invoke-NativeHostCaptivePortalRecoveryAction` (invoked from `Invoke-NativeHostMessageAction` `'recover-captive-portal-navigation'` branch)                                                                |

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

- The Linux Python native host (`linux/native/openpath-native-host.py`) is not covered by this
  document. It should implement the same action set; verify parity if adding a new message type.
- The `get-blocked-paths` response schema is not typed in a dedicated TS interface; the response
  is consumed as `unknown` and cast at call sites in `background-runtime.ts`.
