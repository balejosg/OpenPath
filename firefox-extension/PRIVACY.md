# OpenPath Extension Privacy Policy

> Status: maintained
> Applies to: `firefox-extension/`
> Last verified: 2026-05-09
> Source of truth: `firefox-extension/PRIVACY.md`

## Overview

The OpenPath extension is designed to operate locally in the browser. It is used to detect blocked resources and help operators inspect whitelist-related failures.

## Data Handling

- no analytics or telemetry are sent to third-party services
- routine blocked-resource state is kept in browser-local runtime state
- unblock requests send the blocked domain, request reason, and request metadata only to the configured OpenPath service after Firefox data-collection consent is granted
- blocked-page and popup access requests send user-initiated request details only to the configured OpenPath service after Firefox data-collection consent is granted
- Google game blocking is enforced locally through `webRequest` for known Snake, doodle-game, and interactive logo-game surfaces
- the Google visual guard locally neutralizes detected playable Google Search/Doodles game widgets without uploading browsing data
- Firefox Core includes an isolated-world page activity relay only; it does not use content scripts to observe AJAX/subresource URLs
- Firefox runtime dependencies are reduced to `{ anchorHost, dependencyHost, requestType }` and sent only to the local native host for local overlay validation
- Firefox Core does not include Android support, remote automatic AJAX/page-resource allowlisting, or live/automatic AMO upload
- clipboard access is used only when the user copies a blocked-domain list
- `nativeMessaging` communicates only with the local OpenPath native host on the same machine

The extension is intended for managed OpenPath deployments. It does not operate
as a general-purpose consumer blocker and does not sell, share, or monetize
browser data.

## Current Permissions

| Permission           | Purpose                                                               |
| -------------------- | --------------------------------------------------------------------- |
| `webRequest`         | Observe network failures and apply managed path/subdomain rules       |
| `webRequestBlocking` | Redirect or cancel blocked navigation/resource requests when required |
| `webNavigation`      | Reset per-tab blocked-resource state when navigation changes          |
| `tabs`               | Scope badge and popup data to the active tab                          |
| `clipboardWrite`     | Copy blocked-domain lists only after a user action                    |
| `nativeMessaging`    | Communicate with the local OpenPath native host when it is installed  |
| `storage`            | Keep managed config and local runtime state in browser storage        |
| `<all_urls>`         | Evaluate managed navigation and resource requests across web origins  |

The Firefox manifest declares `browsingActivity` as required Mozilla data
collection. User-initiated unblock requests verify that install-time permission
before transmitting the blocked domain and related navigation/request context to
the configured OpenPath service. Firefox Core registers a page activity
content script and a MAIN-world page-resource observer for local resource-candidate
diagnostics. Automatic runtime dependency handling is local to the managed computer: the background
script sends only the top-level anchor host, dependency host, and Firefox request type
to the native host. Windows writes a local Acrylic exact-host overlay; Linux queues the
same minimal payload for root-side validation and local `dnsmasq` overlay application.
Those dependency hosts are not uploaded or synchronized with the OpenPath service.
Firefox Core registers a Google Search/Doodles visual guard that locally neutralizes detected
playable game widgets without sending Google browsing activity to OpenPath or
third parties. Firefox Core does not register automatic AJAX/page-resource
remote allowlisting, Android support, or live/automatic AMO upload. Google game
blocking is a local browser policy and does not send third-party analytics or
telemetry.

Questions or changes to this policy should stay aligned with the source in this repository and the current extension manifest.
