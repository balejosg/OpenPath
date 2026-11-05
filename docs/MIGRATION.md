# OpenPath Migration Notes

> Status: maintained
> Applies to: OpenPath repository
> Last verified: 2026-04-13
> Source of truth: `docs/MIGRATION.md`

This file only documents migration concerns that are still relevant to the current codebase.

## Linux Agent Upgrades

- packaged installs remain under the `openpath-dnsmasq` package name
- runtime state lives under `/var/lib/openpath`
- operator configuration remains under `/etc/openpath`
- upgrade paths should prefer APT/bootstrap or `openpath self-update` over ad hoc file copying

## Windows Agent Upgrades

- the supported upgrade paths are `OpenPath.ps1 self-update` and rerunning `Install-OpenPath.ps1`
- the `OpenPath-AgentUpdate` task applies the server package when `/api/agent/windows/manifest`
  advertises a newer `version`, or the same `version` with a `build` (sha256 of the sorted
  `path<TAB>sha256` file list) different from the `agentBuild` recorded in `config.json` at the
  last update. New code therefore reaches installed machines without bumping `VERSION`; an older
  server `version` is never applied. Agents older than 4.2.0 compare `version` only.
- browser-extension rollout artifacts must remain compatible with the Windows paths documented in [`../windows/README.md`](../windows/README.md)

## Downstream SPA Consumers

- consume only the explicit public entrypoints documented in [`../react-spa/README.md`](../react-spa/README.md)
- do not rely on deep imports into `react-spa/src`

## Documentation Cleanup

- canonical docs are maintained in English
- historical draft plans were removed from `docs/plans/`
- ADR numbering is inherited and non-sequential; use linked titles instead of numeric assumptions
- use maintained package/platform docs for active upgrade instructions; treat `CHANGELOG.md` and older ADRs as historical context only
