# ADR 0010: Public SPA Extension Surface

**Status:** Accepted  
**Date:** 2026-04-01  
**Decision Makers:** OpenPath maintainers

## Context

Downstream consumers needed a small set of OpenPath React SPA components, views, auth helpers, styles, and Google type definitions. Importing those files through private source paths created upgrade fragility and leaked OpenPath internal layout into downstream apps.

## Decision

OpenPath React SPA now exposes a small public surface through explicit entrypoints:

- `openpath.css`
- `public-ui`
- `public-shell`
- `public-auth`
- `public-google`
- `public-i18n`

Consumers should use these entrypoints instead of deep-importing files under `src/`.

## Consequences

### Positive

- downstream consumers have a bounded contract
- OpenPath can reorganize internal SPA files with less breakage risk
- the exported surface is explicit and testable

### Negative

- maintainers must consciously decide what becomes public
- new public exports should remain small and justified

### Neutral

- the public surface is currently source-based, not a separately versioned package

## Alternatives Considered

- allow deep imports into `src/`: rejected because it couples downstream apps to OpenPath internals
- move shared UI into a new package immediately: rejected as too large for the current iteration
