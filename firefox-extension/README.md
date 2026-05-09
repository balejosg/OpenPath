# OpenPath Browser Extension

> Status: maintained
> Applies to: `firefox-extension/`
> Last verified: 2026-05-06
> Source of truth: `firefox-extension/README.md`

This package contains the OpenPath browser-extension assets used to detect blocked resources and support managed browser rollout workflows.
Firefox blocked-path, blocked-subdomain, and Google game enforcement lives in this extension runtime. The Linux and Windows clients still own DNS/firewall enforcement, while Firefox path/subdomain decisions are loaded from the native host and applied through `webRequest`/`webNavigation`.

## Current Extension Shape

- Manifest version: `3`
- Firefox extension ID: `monitor-bloqueos@openpath`
- Core permissions include `webRequest`, `webRequestBlocking`, `webNavigation`, `tabs`, `clipboardWrite`, `storage`, and optional `nativeMessaging`
- Host permissions currently target `<all_urls>`
- Firefox Core does not register page activity content scripts, MAIN-world page-resource observers, Google visual DOM guards, or automatic AJAX/page-resource upload.

## Local Development

Temporary install in Firefox:

1. Open `about:debugging`
2. Choose `This Firefox`
3. Load the extension from `manifest.json`

Build/test commands:

```bash
npm run build --workspace=@openpath/firefox-extension
npm test --workspace=@openpath/firefox-extension
```

## Release Artifact Flows

Managed Firefox Release artifacts:

```bash
npm run build:firefox-release --workspace=@openpath/firefox-extension -- --signed-xpi /path/to/signed.xpi
npm run build:firefox-source --workspace=@openpath/firefox-extension
npm run verify:amo-submission --workspace=@openpath/firefox-extension
npm run sign:firefox-release --workspace=@openpath/firefox-extension
npm run verify:firefox-amo-version --workspace=@openpath/firefox-extension -- --version-id <amo-version-id> --require-source --require-approval-notes
```

Managed Chromium artifacts:

```bash
npm run build:chromium-managed --workspace=@openpath/firefox-extension
```

These flows prepare the artifacts consumed by the Windows rollout paths and the API delivery endpoints:

- `/api/extensions/firefox/openpath.xpi`
- `/api/extensions/chromium/updates.xml`
- `/api/extensions/chromium/openpath.crx`

## Optional Native Host

Native host files live under [`native/`](native/) and support optional local verification workflows. Installers and compatibility details are documented in [`AMO.md`](AMO.md) and [`PRIVACY.md`](PRIVACY.md).
The native host exposes `get-blocked-paths` and `get-blocked-subdomains` from the local whitelist file so the background runtime can refresh enforcement rules without relying on Firefox `WebsiteFilter`, search-engine, or DoH policies.
