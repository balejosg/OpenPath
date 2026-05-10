# Firefox Extension AGENTS.md

WebExtension for detecting blocked resources, showing operator-facing diagnostics, and supporting optional native-host flows.

## Structure

- `src/background.ts`: background script logic and request monitoring
- `src/popup.ts`: popup behavior
- `src/blocked-page.ts`: blocked-page contract and rendering support
- `src/lib/`: shared helpers
- `manifest.json`: manifest source of truth
- `native/`: optional native-host assets
- `build-firefox-release.mjs`, `sign-firefox-release.mjs`, `build-chromium-managed.mjs`, `build-xpi.sh`: release/build tooling

## Current Contract

- manifest version: `3`
- Firefox extension ID: `openpath-block-monitor@openpath`
- host permissions: `<all_urls>`
- optional native host: `native/openpath-native-host.py`

Use `manifest.json` and the build scripts as source of truth instead of older assumptions about MV2 or removed content-script layouts.

## Conventions

- use `src/lib/logger.ts` rather than ad hoc logging
- prefer `browser.storage.local` for persisted config/state
- degrade gracefully when native-host capabilities are unavailable
- keep AMO/release docs aligned with manifest permissions and artifact outputs

## Testing

```bash
npm test
npx tsx --test tests/background.test.ts
```

## Build And Release

```bash
npm run build --workspace=@openpath/firefox-extension
./build-xpi.sh
npm run build:firefox-release --workspace=@openpath/firefox-extension
npm run sign:firefox-release --workspace=@openpath/firefox-extension
```

## Anti-Patterns

- reintroducing deep assumptions about MV2-only behavior
- changing extension IDs, native-host names, or artifact contracts without updating tests and release docs
- storing sensitive data in sync storage or remote telemetry paths
