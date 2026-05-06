# Firefox Add-ons Submission Notes

> Status: maintained
> Applies to: `firefox-extension/`
> Last verified: 2026-05-06
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
- reviewer metadata source: [`amo-review-metadata.json`](amo-review-metadata.json)
- human-readable source notes: [`SOURCE_REVIEW_NOTES.md`](SOURCE_REVIEW_NOTES.md)

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
- reports blocked page-resource candidates from `fetch`, `XMLHttpRequest`, and
  dynamic resource insertions to the configured OpenPath service so classroom
  pages can load required assets after review or auto-allow policy
- blocks supported Google Search/Doodles games on managed devices when the
  school policy requires it
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
- page-resource auto-allow candidates send the target host/URL, originating
  page, resource type, and policy reason only to the configured OpenPath service
- Google games enforcement is limited to supported Google Search and
  `doodles.google` pages and does not profile general browsing
- optional native messaging is local to the same computer and talks only to the
  OpenPath native host installed by the managed client

### Data Collection Disclosure

For Mozilla's "Permissions and data" section, disclose that the extension
transmits website activity/content only to the configured OpenPath service when
requests or page-resource auto-allow are enabled. The user-facing wording should
make clear that OpenPath does not send third-party analytics or telemetry.

The manifest intentionally declares Mozilla's data collection consent field and
raises compatibility to consent-aware Firefox runtimes:

```json
"data_collection_permissions": {
  "required": ["browsingActivity", "websiteActivity", "websiteContent"]
}
```

Keep this disclosure in the manifest. Removing it would hide the fact that
OpenPath can transmit blocked-page requests and page-resource auto-allow
candidates to the configured OpenPath service.

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

- `<all_urls>`: required for the page activity and page-resource observers to
  detect blocked third-party resources regardless of origin
- `webRequest` and `webRequestBlocking`: required to detect blocked-resource failures and path-blocking behavior
- `webNavigation`: clears per-tab state when navigation changes
- `tabs`: updates the tab badge and popup context
- `clipboardWrite`: copies blocked-domain lists for operator workflows
- `nativeMessaging`: optional local-only integration with the native host
- `storage`: keeps managed config and local runtime state in browser storage

AMO permission explanations should keep the same wording as the table in
[`PRIVACY.md`](PRIVACY.md). Do not describe `<all_urls>` as user tracking; the
extension needs broad host access so Firefox can expose network failures across
managed pages and embedded resources.

## Reviewer Notes

Use [`amo-review-metadata.json`](amo-review-metadata.json) as the source of
truth for `web-ext sign --amo-metadata`. It explains the AJAX/page-resource
auto-allow flow, Google games scope, data destination, and local-only native
messaging boundary for Mozilla reviewers.

Attach the reproducible source archive generated by:

```bash
npm run build:firefox-source --workspace=@openpath/firefox-extension
npm run verify:amo-submission --workspace=@openpath/firefox-extension
```

The archive includes [`SOURCE_REVIEW_NOTES.md`](SOURCE_REVIEW_NOTES.md), source,
tests, build configs, static extension assets, and package metadata. It excludes
generated `dist`, `build`, `node_modules`, coverage, and TypeScript build-info
files.

## Release Workflow

Use the package scripts documented in [`README.md`](README.md):

```bash
npm run build:firefox-release --workspace=@openpath/firefox-extension -- --signed-xpi /path/to/signed.xpi
npm run build:firefox-source --workspace=@openpath/firefox-extension
npm run verify:amo-submission --workspace=@openpath/firefox-extension
npm run sign:firefox-release --workspace=@openpath/firefox-extension
```

`sign-firefox-release.mjs` reads `WEB_EXT_SIGN_SOURCE_CODE_ARCHIVE` and
`WEB_EXT_AMO_METADATA`, or accepts `--upload-source-code` and `--amo-metadata`,
and passes those values through to `web-ext sign`.

To attach the source package to the current pending AMO version without creating
another version:

```bash
npm run build:firefox-source --workspace=@openpath/firefox-extension
npm run upload:firefox-amo-source --workspace=@openpath/firefox-extension -- --version-id 6249209 --verify
```

The upload command requires an explicit `--version-id`, `--version`, or
`AMO_VERSION_ID` so an operator cannot accidentally patch a stale AMO version.
If AMO returns a metadata throttle, the script prints the delay and a
`--metadata-only` retry command that does not re-upload the source archive. To
wait for an acceptable throttle explicitly:

```bash
npm run upload:firefox-amo-source --workspace=@openpath/firefox-extension -- --version-id 6249209 --metadata-only --verify --wait-for-throttle --max-throttle-wait-seconds 10800 --max-retries 3
```

To verify AMO's stored source and reviewer notes without uploading:

```bash
npm run verify:firefox-amo-version --workspace=@openpath/firefox-extension -- --version-id 6249209 --require-source --require-approval-notes
```

To sync the AMO privacy policy from this repository, load the AMO credentials
and run the operator command below. Keep this out of release CI unless there is
a deliberate decision to spend extra AMO API calls during signing.

```bash
npm run sync:firefox-amo-policy --workspace=@openpath/firefox-extension
```

Keep AMO listing text and screenshots aligned with the current extension behavior before publishing.
