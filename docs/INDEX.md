# OpenPath Documentation Index

> Status: maintained
> Applies to: OpenPath repository
> Last verified: 2026-04-13
> Source of truth: `docs/INDEX.md`

## Start Here

- Repo overview: [`README.md`](../README.md)
- LLM agent workflow: [`AGENTS.md`](../AGENTS.md)
- Contribution guide: [`CONTRIBUTING.md`](../CONTRIBUTING.md)
- Code of conduct: [`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md)
- Project roadmap: [`ROADMAP.md`](../ROADMAP.md)
- Security policy: [`SECURITY.md`](../SECURITY.md)
- Licensing: [`LICENSING.md`](../LICENSING.md)

## Canonical Architecture And Contracts

- ADR index: [`docs/ADR.md`](ADR.md)
- Transactional service writes: [`docs/adr/0009-transactional-service-writes.md`](adr/0009-transactional-service-writes.md)
- Public SPA extension surface: [`docs/adr/0010-public-spa-extension-surface.md`](adr/0010-public-spa-extension-surface.md)
- Group role join table plan: [`docs/group-role-join-table-plan.md`](group-role-join-table-plan.md)
- Environment variable registry: [`docs/ENVIRONMENT_VARIABLES.md`](ENVIRONMENT_VARIABLES.md)
- Extension <-> native host message contract: [`docs/extension-native-host-contract.md`](extension-native-host-contract.md)
- API package guide: [`api/README.md`](../api/README.md)
- Shared package guide: [`shared/README.md`](../shared/README.md)
- Dashboard package guide: [`dashboard/README.md`](../dashboard/README.md)

## Operations And Troubleshooting

- How-to guide: [`docs/HOWTO.md`](HOWTO.md)
- Troubleshooting: [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md)
- CI/CD runner timing and artifact measurement: [`docs/ci-cd-runner-measurement.md`](ci-cd-runner-measurement.md)
- Student-policy contract matrix: [`docs/testing/student-policy-contract-matrix.md`](testing/student-policy-contract-matrix.md)
- WEDU captive portal lab: [`docs/testing/wedu-captive-portal-lab.md`](testing/wedu-captive-portal-lab.md)
- WEDU gateway VM provisioning: [`docs/testing/wedu-captive-portal-lab-provisioning.md`](testing/wedu-captive-portal-lab-provisioning.md)
- Shared workspace hypothesis-validation wrapper: `../scripts/validate-hypothesis.sh` from the workspace root when working inside `Whitelist/`
- Direct Windows runner diagnostic: [`scripts/run-windows-runner-direct.mjs`](../scripts/run-windows-runner-direct.mjs)
- Migration notes: [`docs/MIGRATION.md`](MIGRATION.md)
- Security hardening: [`docs/SECURITY-HARDENING.md`](SECURITY-HARDENING.md)
- APT signing key workflow: [`docs/apt-signing-key.md`](apt-signing-key.md)
- Linux runtime library load order: [`docs/linux-load-order.md`](linux-load-order.md)
- Linux deployment notes: [`linux/DEPLOYMENT.md`](../linux/DEPLOYMENT.md)
- Linux troubleshooting: [`linux/TROUBLESHOOTING.md`](../linux/TROUBLESHOOTING.md)

## Evaluation

- OSS adoption path for technical evaluators: [`docs/evaluation/adoption-path.md`](evaluation/adoption-path.md)
- Self-hosting prerequisites: [`docs/evaluation/self-hosted-prerequisites.md`](evaluation/self-hosted-prerequisites.md)
- Deployment shapes: [`docs/evaluation/deployment-shapes.md`](evaluation/deployment-shapes.md)
- Support and ownership boundaries: [`docs/evaluation/support-boundaries.md`](evaluation/support-boundaries.md)
- Security and hardening baseline: [`docs/SECURITY-HARDENING.md`](SECURITY-HARDENING.md)
- Public OSS security policy: [`SECURITY.md`](../SECURITY.md)

## Package-Specific Docs

- React SPA: [`react-spa/README.md`](../react-spa/README.md)
- Linux agent: [`linux/README.md`](../linux/README.md)
- Windows agent: [`windows/README.md`](../windows/README.md)
- Firefox extension: [`firefox-extension/README.md`](../firefox-extension/README.md)
- Firefox AMO submission notes: [`firefox-extension/AMO.md`](../firefox-extension/AMO.md)
- Firefox extension privacy policy: [`firefox-extension/PRIVACY.md`](../firefox-extension/PRIVACY.md)
- E2E/contract test inventory: [`tests/e2e/README.md`](../tests/e2e/README.md)

## Notes

- Canonical docs are maintained in English.
- Historical files such as [`../CHANGELOG.md`](../CHANGELOG.md) and most ADR records provide context, not current operator instructions.
- Active plan files under `docs/plans/` are working artifacts and are not part of the canonical doc set.
- Repo-process docs under `.github/` and package `AGENTS.md` files are workflow references, not product runbooks.
- `docs/adr/template.md` is a template, not a current architecture contract.
- ADR numbering is inherited and not strictly sequential; use titles and links, not numeric assumptions.
