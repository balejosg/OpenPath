# OpenPath Browser Extension

> Status: maintained
> Applies to: `firefox-extension/`
> Last verified: 2026-07-02
> Source of truth: `firefox-extension/README.md`

This package contains the OpenPath browser-extension assets used to detect blocked resources and support managed browser rollout workflows.
Firefox blocked-path and blocked-subdomain enforcement lives in this extension runtime. The Linux and Windows clients still own DNS/firewall enforcement, while Firefox path/subdomain decisions are loaded from the native host and applied through `webRequest`/`webNavigation`.

## Current Extension Shape

- Manifest version: `3`
- Firefox extension ID: `openpath-block-monitor@openpath`
- Core permissions include `webRequest`, `webRequestBlocking`, `webNavigation`, `tabs`, `clipboardWrite`, `storage`, and `nativeMessaging`
- Mozilla data collection declares `required: ["browsingActivity"]`; blocked-page and popup access requests verify that install-time consent before submitting request details
- Host permissions currently target `<all_urls>`
- Firefox Core includes local Google game blocking for known Snake, doodle-game, and interactive logo-game surfaces.
- Firefox Core includes a Google Search/Doodles visual guard content script that locally neutralizes detected playable game widgets.
- Firefox Core includes an isolated-world page activity relay only; it does not inject a MAIN-world resource observer or relay AJAX/subresource URLs from content scripts.
- On Windows, Firefox may send `{ anchorHost, dependencyHost, requestType }` from `webRequest` to the local native host so the Windows client can maintain an exact-host Acrylic runtime-dependency overlay. Those dependency hosts are never sent to the OpenPath service.
- Firefox Core does not include Android support, remote automatic AJAX/page-resource allowlisting, or live/automatic AMO upload.

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

Optional native-host-backed checks in dev builds need the native messaging host registered for your user:

```bash
firefox-extension/native/install-native-host.sh
```

The script is a thin wrapper over the production Linux registration seam (`install_native_host` in `linux/lib/browser-native-host.sh`), scoped to the current user -- no sudo. It writes the manifest to `~/.mozilla/native-messaging-hosts/whitelist_native_host.json` and the host script to `~/.local/lib/openpath/`; override with `FIREFOX_NATIVE_HOST_DIR` / `OPENPATH_NATIVE_HOST_INSTALL_DIR`. Production installs go through `linux/install.sh` with the system paths instead.

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
The native host exposes `get-blocked-paths` and `get-blocked-subdomains` from the local whitelist file so the background runtime can refresh enforcement rules without relying on Firefox `WebsiteFilter`, search-engine, or DoH policies. It also accepts `allow-local-runtime-dependency` with only normalized `anchorHost`, `dependencyHost`, and `requestType`. Windows applies exact-host Acrylic overlay entries after local validation. Linux writes a local queue entry for root-side validation and `dnsmasq` overlay application. This flow does not send full URLs, headers, cookies, DOM data, page titles, request bodies, or dependency hosts to OpenPath APIs, and it does not create remote whitelist rules.
