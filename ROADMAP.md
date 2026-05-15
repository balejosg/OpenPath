# OpenPath Roadmap

> Status: maintained
> Applies to: OpenPath public project direction
> Last verified: 2026-05-15
> Source of truth: `ROADMAP.md`

OpenPath is an open-source classroom internet control project focused on
privacy, auditability, and teacher-directed allowlists. This roadmap explains
where the project is stable, where it needs validation, and where contributors
can help.

## Stable

- Core allowlist model: teachers approve what a class needs, and everything
  else is blocked by default.
- Local enforcement architecture: endpoint agents apply policy locally instead
  of sending browsing history to the server.
- Maintained documentation map: `docs/INDEX.md` is the entrypoint for current
  technical and evaluation docs.
- Developer workflow: repository hooks and verification commands protect
  formatting, tests, docs, and security-sensitive files.

## Needs Real-World Validation

- Classroom domain recipes for common lessons, subjects, and online tools.
- Student-facing blocked-page wording and unblock-request flows.
- Self-hosting runbooks for small schools, labs, and technical evaluators.
- Managed browser rollout paths beyond the currently supported Firefox-centered
  classroom workflow.
- Operator guidance for backups, monitoring, upgrades, rollback, and incident
  response.

## Help Wanted

- Documentation improvements for teachers, school IT teams, and self-hosting
  evaluators.
- Test coverage for shared helpers, API validation, UI workflows, and browser
  extension behavior.
- Frontend polish for empty states, classroom workflows, and accessible copy.
- Sanitized classroom feedback from real lessons and lab evaluations.
- Domain recipe proposals that explain the lesson goal and required public
  domains.

## Maintainer-Owned Areas

These areas are high impact or security-sensitive. They are still open to
discussion, but first-time contributors should start elsewhere unless a
maintainer has scoped a specific issue.

- Windows DNS enforcement internals.
- Release, signing, and package publication workflows.
- Secrets, authentication, and security-sensitive API paths.
- Firefox extension publication and AMO packaging changes.
- Production deployment assumptions for downstream wrappers.

## Out Of Scope

- Browsing telemetry or analytics collection.
- Advertising, tracking, or student data monetization.
- Blacklist-first filtering as the default product model.
- Hidden proprietary enforcement logic.
- Downstream-wrapper-specific requirements inside OpenPath core.
