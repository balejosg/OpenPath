# Firefox release signing: one signature per payload hash

Several workflows can sign the same Firefox XPI payload in one push
(`release-scripts.yml`, `e2e-tests.yml` Windows Student Policy, `build-deb.yml`,
`firefox-release-assets.yml`). They share the composite action
`.github/actions/prepare-firefox-release-artifacts`, which restores a cache keyed
by the payload hash and only signs on a cache miss. When two runs miss the cache
at the same time, one wins and the other used to fail hard with
`WebExtError: Submission failed (2): Conflict`.

## Behaviour since Phase 3A

The signing flow is idempotent per payload hash:

1. **Cache restore** (unchanged): `openpath-firefox-release-<payloadHash>`.
2. **Conflict recovery** (`sign-firefox-release.mjs`): a `Conflict` submission is
   treated as "another run already submitted this exact version" - both when the
   error embeds `Version ... already exists` and when it is a bare
   `Submission failed (N): Conflict`. The script polls AMO for the derived
   version (`2.0.<major>.<patch>`), tolerates `404` while the winning run is
   still publishing, downloads the signed XPI and reports
   `state=recovered-existing-version`.
3. **Verification** (unchanged): the downloaded XPI is checked as an AMO-signed
   XPI and the release metadata records the payload hash, which is re-verified
   when the artifact is consumed.

No new credentials and no new AMO permissions are involved: recovery uses the
same `WEB_EXT_API_KEY` / `WEB_EXT_API_SECRET` and the AMO API v5 version
endpoint.

## Tests

- `firefox-extension/tests/firefox-release.test.ts`:
  - `isAmoConflictOutput` accepts the bare `Conflict` payload and the
    version-embedded payload, and rejects unrelated submission failures;
  - `recoverSignedXpiFromAmo` polls through a `404` (the winner has not
    published yet), downloads the signed XPI and returns
    `recovered-existing-version`;
  - unrelated failures never touch AMO.
- Observation on the Phase 3A push: E2E and REL signed in the same push with no
  `Conflict` failure.
