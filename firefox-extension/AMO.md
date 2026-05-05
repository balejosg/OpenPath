# Firefox Add-ons Submission Notes

> Status: maintained
> Applies to: `firefox-extension/`
> Last verified: 2026-05-05
> Source of truth: `firefox-extension/AMO.md`

This document captures the current AMO-facing notes for the OpenPath extension.
Use it when updating the Mozilla Add-ons Developer Hub listing, reviewer notes,
privacy-policy link, screenshots, or release metadata.

## Current Submission Facts

- extension ID: `monitor-bloqueos@openpath`
- manifest: `v3`
- current signing channel: `unlisted` through `sign-firefox-release.mjs`
- default manifest name: `Monitor de Bloqueos de Red`
- package/license source of truth: [`package.json`](package.json)
- privacy policy source: [`PRIVACY.md`](PRIVACY.md)

The repository signs self-hosted Firefox artifacts through AMO. If the add-on is
later published as a listed AMO page, keep the listing text below as the
canonical starting point and update it in the Developer Hub before publishing.

## Recommended AMO Listing Copy

### Summary

OpenPath companion extension for managed Firefox devices. It explains blocked
sites/resources, supports access requests, and checks local allowlist state
without analytics or telemetry.

### Full Description

OpenPath Block Monitor is the Firefox companion for OpenPath-managed devices. It
helps students, teachers, and operators understand why a page or embedded
resource is blocked, request access when a classroom workflow needs it, and
verify whether the local allowlist has caught up.

What it does:

- detects DNS, firewall, path, and blocked-subdomain failures visible in Firefox
- shows a clear OpenPath blocked-page screen for blocked main-frame navigation
- lets users request access to a blocked domain when the OpenPath administrator
  has enabled requests
- reports blocked page-resource candidates to the configured OpenPath service so
  classroom pages can load required assets after review or auto-allow policy
- optionally talks to the OpenPath native host on the same computer to check
  local allowlist state and refresh path/subdomain enforcement data

What it does not do:

- it is not a standalone consumer website blocker; it is intended for managed
  OpenPath deployments
- it does not replace the OpenPath Linux or Windows endpoint agent, DNS rules,
  firewall rules, or administrator policy
- it does not send analytics, telemetry, or browsing-history data to third-party
  services

Privacy and deployment notes:

- routine blocked-resource state is held in browser-local runtime state
- unblock requests send the blocked domain, request reason, and related OpenPath
  request metadata only to the configured OpenPath service
- page-resource auto-allow candidates send the blocked host, originating page,
  and request type only to the configured OpenPath service
- optional native messaging is local to the same computer and talks only to the
  OpenPath native host installed by the managed client

### Data Collection Disclosure

For Mozilla's "Permissions and data" section, disclose that the extension
transmits website activity/content only to the configured OpenPath service when
requests or page-resource auto-allow are enabled. The user-facing wording should
make clear that OpenPath does not send third-party analytics or telemetry.

Do not add `browser_specific_settings.gecko.data_collection_permissions` to the
manifest without also deciding the Firefox compatibility policy. Mozilla's
manifest-level data collection consent is supported by Firefox 140+ on desktop
and Firefox for Android 142+. The current manifest still declares
`strict_min_version: 109.0`, so adding the field without changing compatibility
would make AMO lint report unsupported-version warnings.

If the project raises the minimum supported Firefox version to the consent-aware
runtime, use this manifest disclosure:

```json
"data_collection_permissions": {
  "required": ["browsingActivity", "websiteContent"]
}
```

### Suggested Tags

`education`, `content blocker`, `allowlist`, `school`, `open source`

### Screenshot Checklist

Use screenshots that show real OpenPath behavior, not generic browser chrome:

- blocked-page screen with the requested domain and request form visible
- popup showing detected blocked domains and request/verify actions
- native-host status in the popup when local verification is available
- successful request or local allowlist verification state after policy catches
  up

## Permission Rationale

- `<all_urls>`: required to detect blocked third-party resources regardless of origin
- `webRequest` and `webRequestBlocking`: required to detect blocked-resource failures and path-blocking behavior
- `webNavigation`: clears per-tab state when navigation changes
- `tabs`: updates the tab badge and popup context
- `clipboardWrite`: copies blocked-domain lists for operator workflows
- `nativeMessaging`: optional local-only integration with the native host

AMO permission explanations should keep the same wording as the table in
[`PRIVACY.md`](PRIVACY.md). Do not describe `<all_urls>` as user tracking; the
extension needs broad host access so Firefox can expose network failures across
managed pages and embedded resources.

## Reviewer Notes

Suggested reviewer note for AMO submissions:

> OpenPath is a managed education/allowlist system. This extension is the
> Firefox companion for managed devices. It observes blocked network requests,
> shows a blocked-page/request UI, and optionally communicates with the local
> OpenPath native host. It does not include third-party analytics or telemetry.
> Self-hosted deployments provide the configured OpenPath API/native-host state.

## Release Workflow

Use the package scripts documented in [`README.md`](README.md):

```bash
npm run build:firefox-release --workspace=@openpath/firefox-extension -- --signed-xpi /path/to/signed.xpi
npm run sign:firefox-release --workspace=@openpath/firefox-extension
```

Keep AMO listing text and screenshots aligned with the current extension behavior before publishing.
