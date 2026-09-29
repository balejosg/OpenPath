# Release Checklist

Use this checklist before releasing changes to student machines.

## Pre-Release

- [ ] All required CI checks pass
- [ ] Local pre-push verification passed on the release commit set
- [ ] E2E tests pass on real hardware (not just CI VMs)
- [ ] Tested on Ubuntu 22.04 LTS
- [ ] Tested on Ubuntu 24.04 LTS

## Upgrade Testing

- [ ] Fresh install works
- [ ] Upgrade from previous version works
- [ ] Rollback procedure tested

## Documentation

- [ ] `npm run verify:docs` passes
- [ ] Release notes written
- [ ] Breaking changes documented

## Post-Release Monitoring

- [ ] Monitor `/api/health-reports` for FAIL_OPEN or CRITICAL statuses
- [ ] Check for stale hosts (not reporting for >10 minutes)

## Publishing a Release

- [ ] Dispatch `Release Installation Scripts` on `main` for the exact HEAD SHA
      that must be published. The push-triggered run of that same SHA is
      cancelled by design (same-SHA concurrency group), and the dispatch run
      carries the release train: Windows qualification -> tag and GitHub
      prerelease -> `Release Scripts Success` -> promotion state -> prerelease
      `.deb` -> APT unstable plus v1 contract -> v2 promotion contract -> WEDU
      lab dispatch.
- [ ] Do not dispatch the same SHA again while its dispatch run is in flight.
- [ ] Re-dispatching an already promoted SHA publishes nothing new: an
      existing exact-SHA v2 contract skips the APT/v2 republication, and a
      green `WEDU captive portal lab` check skips the WEDU dispatch.

## Delivery State

For any user-visible fix shipped in a release artifact, report exactly which
delivery boundary has been crossed:

- `SOURCE FIXED` - merged in OpenPath source, but not yet promoted.
- `PROMOTED` - published under an immutable, exact-SHA Promotion Contract v2.
- `DOWNSTREAM SHIPPED` - consumed and proven by a downstream release; OpenPath
  release evidence alone cannot establish this state.

For `PROMOTED`, record the complete immutable identity:

- OpenPath target SHA
- promotion contract URL
- contract SHA-256
- Windows component source SHA
- Windows release tag
- Windows template SHA-256
- payload manifest SHA-256

The Windows artifact named by the contract must be the artifact built and
executed by the successful `Release Installation Scripts` run for the same
OpenPath target SHA. Never substitute `main`, `latest`, another run, or another
packaging path.
