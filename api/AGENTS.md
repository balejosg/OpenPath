# API AGENTS.md

Express + tRPC API with PostgreSQL/Drizzle. Service-oriented architecture.

## Execution Boundary

```text
Routers / routes -> services -> storage helpers -> PostgreSQL
```

Source-of-truth files:

- `src/server.ts`: Express middleware and REST route mounting
- `src/routes/`: public REST surfaces
- `src/trpc/routers/index.ts`: current app router inventory
- `src/services/`: business logic and transaction boundaries
- `src/db/schema.ts`: schema shape

## Router And Procedure Guidance

The exact router list changes over time. Use `src/trpc/routers/index.ts` instead of relying on stale counts.

Current procedure types:

- `publicProcedure`: health, setup, and other unauthenticated flows
- `protectedProcedure`: authenticated user flows
- `adminProcedure`: admin-only flows
- `teacherProcedure`: teacher/admin classroom flows
- `sharedSecretProcedure`: machine-auth or shared-secret flows

## Conventions

- Keep routers thin; business logic belongs in services.
- Multi-write flows should use service-owned transaction boundaries.
- Use Zod validation from `@openpath/shared` at API boundaries.
- Use Winston-based logging, not `console.*`.
- Keep `.js` import extensions for NodeNext compatibility.

## Testing

Suite tiers:

- `npm test` is the curated fast smoke subset, NOT the full suite. Root `test`/`test:local`/`test:api`, turbo caching, and the pre-push `verify:unit` lane all depend on its speed; only append to it (`scripts/run-api-coverage.js` regex-parses it).
- `npm run test:all` runs every runnable `test:*` suite. Its command list is derived from `package.json` by `scripts/test-script-inventory.ts`, followed by a remainder lane for top-level test files no script references. New `test:*` scripts are picked up automatically; a script that must not run there needs an entry in `EXCLUDED_TEST_SCRIPTS` with a reason, otherwise `test:all` and the contract test fail loudly. `tests/test-script-coverage-contract.test.ts` fails, listing exact files, if any test file becomes unreachable. Per-command watchdog: `RUN_ALL_TIMEOUT_MS` (default 120000). Many suites expect the Docker test DB from the repo root `docker-compose.test.yml` (port 5433).
- `npm run test:coverage` is the CI coverage lane; it discovers every top-level test file programmatically and provisions its own DB env.

Prefer existing scripts because they already provision an ephemeral loopback port and keep the Node test runner serial:

```bash
npm run test:auth --workspace=@openpath/api
npm run test:e2e --workspace=@openpath/api
npm run test:health-status --workspace=@openpath/api
npm run test:healthcheck --workspace=@openpath/api
npm run test:integration --workspace=@openpath/api
npm run test:api-tokens --workspace=@openpath/api
npm run test:machines --workspace=@openpath/api
npm run test:schedules --workspace=@openpath/api
npm run test:server --workspace=@openpath/api
npm run test:security --workspace=@openpath/api
npm run test:setup --workspace=@openpath/api
```

Single-file example:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/groups-auth.test.ts tests/groups-teacher-access.test.ts tests/groups-rule-ops.test.ts tests/groups-export.test.ts
```

Serial multi-file example for DB-reset-heavy suites:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/service-coverage-user-storage.test.ts tests/service-coverage-setup.test.ts tests/service-coverage-schema.test.ts tests/service-coverage-user-service.test.ts tests/service-coverage-auth-service.test.ts
```

Auth split example:

```bash
cd api
tsx scripts/run-node-test-suite.ts tests/auth-registration.test.ts tests/auth-google-login.test.ts tests/auth-session.test.ts tests/auth-password.test.ts tests/auth-admin-guards.test.ts
```

Google auth split example:

```bash
cd api
tsx scripts/run-node-test-suite.ts tests/google-auth-config.test.ts tests/google-auth-misconfig.test.ts tests/google-auth-invalid-token.test.ts
```

Backup split example:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/backup-surface.test.ts tests/backup-auth.test.ts tests/backup-recording.test.ts tests/backup.test.ts
```

API smoke split example:

```bash
cd api
tsx scripts/run-node-test-suite.ts tests/api-basic-http.test.ts tests/api-submit-routes.test.ts tests/api-requests-trpc.test.ts tests/api-request-auth-guards.test.ts tests/lib/machine-proof.test.ts tests/lib/public-request-input.test.ts tests/lib/exemption-storage.test.ts tests/routes/public-requests.test.ts
```

Storage unit split example:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/schedules-time-utils.test.ts tests/schedules-crud.test.ts tests/schedules-query.test.ts tests/schedules-current.test.ts
```

Security split example:

```bash
cd api
tsx scripts/run-node-test-suite.ts tests/security-headers.test.ts tests/security-authorization.test.ts tests/security-auth.test.ts tests/security-input-validation.test.ts tests/security-privacy-rate-limits.test.ts
```

Setup split example:

```bash
cd api
tsx scripts/run-node-test-suite.ts tests/setup-status.test.ts tests/setup-first-admin.test.ts tests/setup-token-validation.test.ts tests/setup-auth-guards.test.ts
```

E2E teacher split example:

```bash
cd api
tsx scripts/run-node-test-suite.ts tests/e2e-admin-bootstrap.test.ts tests/e2e-teacher-profile.test.ts tests/e2e-teacher-requests.test.ts tests/e2e-teacher-boundaries.test.ts
```

Push split example:

```bash
cd api
tsx scripts/run-node-test-suite.ts tests/push-vapid.test.ts tests/push-subscription.test.ts tests/push-status.test.ts tests/push-unsubscribe.test.ts
```

SSE split example:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/sse-auth.test.ts tests/sse-connection.test.ts tests/sse-events.test.ts
```

Coverage regression split example:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/coverage-regressions-storage.test.ts tests/coverage-regressions-legacy-storage.test.ts tests/coverage-regressions-router-validation.test.ts
```

Classrooms split example:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/classrooms-crud.test.ts tests/classrooms-machines.test.ts tests/classrooms-cleanup.test.ts
```

Machine auth scope split example:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/machine-auth-scope-enrollment.test.ts tests/machine-auth-scope-boundaries.test.ts tests/machine-auth-scope-operational.test.ts
```

Blocked domains split example:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/blocked-domains-check.test.ts tests/blocked-domains-list.test.ts tests/blocked-domains-approval.test.ts
```

Roles split example:

```bash
cd api
NODE_ENV=test node --import tsx --test --test-concurrency=1 --test-force-exit tests/roles-assignment.test.ts tests/roles-revoke.test.ts tests/roles-authorization.test.ts tests/roles-list-teachers.test.ts
```

## Anti-Patterns

- direct DB queries in routers
- side effects inside transaction bodies
- missing Zod validation on request input/output boundaries
- `console.*` in production paths
