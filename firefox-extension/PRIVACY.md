# OpenPath Extension Privacy Policy

> Status: maintained
> Applies to: `firefox-extension/`
> Last verified: 2026-05-05
> Source of truth: `firefox-extension/PRIVACY.md`

## Overview

The OpenPath extension is designed to operate locally in the browser. It is used to detect blocked resources and help operators inspect whitelist-related failures.

## Data Handling

- no analytics or telemetry are sent to third-party services
- routine blocked-resource state is kept in browser-local runtime state
- unblock requests send the blocked domain, request reason, and request metadata only to the configured OpenPath service
- page-resource auto-allow candidates send the blocked host, originating page, and request type only to the configured OpenPath service
- clipboard access is used only when the user copies a blocked-domain list
- optional `nativeMessaging` communicates only with the local OpenPath native host on the same machine

The extension is intended for managed OpenPath deployments. It does not operate
as a general-purpose consumer blocker and does not sell, share, or monetize
browser data.

## Current Permissions

| Permission           | Purpose                                                                |
| -------------------- | ---------------------------------------------------------------------- |
| `webRequest`         | Observe network failures and blocked resources visible to Firefox      |
| `webRequestBlocking` | Redirect or cancel blocked navigation/resource requests when required  |
| `webNavigation`      | Reset per-tab blocked-resource state when navigation changes           |
| `tabs`               | Scope badge and popup data to the active tab                           |
| `clipboardWrite`     | Copy blocked-domain lists only after a user action                     |
| `nativeMessaging`    | Communicate with the local OpenPath native host when it is installed   |
| `<all_urls>`         | Observe managed-page resources regardless of origin or embedded domain |

Questions or changes to this policy should stay aligned with the source in this repository and the current extension manifest.
