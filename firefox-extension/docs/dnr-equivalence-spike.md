# Firefox DNR Equivalence Spike

Status: spike result, not a production migration plan.

Applies to: Firefox extension path, subdomain, native-host refreshed, and Google game request policy.

## Summary

The minimal prototype in `firefox-extension/tests/dnr-equivalence-spike.test.ts`
documents a plausible Declarative Net Request rule shape for the current
`webRequestBlocking` responsibilities:

- top-frame blocked-screen redirect;
- dynamic rule replacement from native-host state;
- one blocked path rule;
- one blocked subdomain rule;
- priority ordering where blocked path wins over blocked subdomain, and both
  win over Google game policy after auto-allow removal.

This is only partial equivalence. It is not enough to migrate production
behavior yet.

## Prototype Shape

The spike models every native-host policy entry as generated DNR rules rather
than as a direct runtime callback:

- `BLOCKED_PATH_POLICY:<rule>` expands to a main-frame redirect rule and a
  sub-frame/XMLHttpRequest block rule.
- `BLOCKED_SUBDOMAIN_POLICY:<rule>` expands to a main-frame redirect rule and a
  broader subresource block rule.
- Google game policy stays as a lower-priority rule.
- Native-host refresh is represented as a replace-all
  `updateDynamicRules({ removeRuleIds, addRules })` style update.

Priorities in the prototype preserve the current listener order:

| Policy             | Priority |
| ------------------ | -------: |
| Blocked path       |      300 |
| Blocked subdomain  |      200 |
| Google game policy |      100 |

The prototype deliberately contains no DNR `allow` action. That matches the
post-auto-allow Core direction: page-resource and AJAX observation should not
release a request after a stronger managed block decision.

## Findings

Top-frame redirect: feasible for a static blocked-page extension path. The
prototype can encode policy reason and raw rule into `extensionPath` query
parameters.

Native-host refresh: feasible as a dynamic-rule replacement model. A controller
could diff or replace previously generated rule IDs when the native host returns
new blocked path/subdomain hashes.

Blocked path: feasible for simple host/path rules such as
`example.com/private`. The spike does not prove full equivalence for every
current glob shape, port normalization behavior, or the current `fetch` request
type handling.

Blocked subdomain: feasible for one exact/nested subdomain family using a DNR
domain-anchored URL filter.

Priority versus Google policy: feasible at the rule-priority level. The
prototype keeps blocked path and blocked subdomain policy ahead of Google game
policy and does not introduce any auto-allow rules.

## Gaps Before Production Migration

The spike does not prove that Firefox DNR can provide enough per-request context
for the current blocked screen. Current `webRequestBlocking` redirects include
the request hostname and origin/document URL. The prototype only encodes static
rule context because DNR redirect rules are declarative.

The spike does not prove all current blocked-path glob semantics. Existing code
supports wildcard path rules, subdomain expansion, and port-normalized matching.
Those cases need a larger compatibility matrix before replacing
`evaluatePathBlocking`.

The spike does not prove Firefox's DNR request-type mapping for `fetch`.
Current path policy explicitly handles both `xmlhttprequest` and `fetch`; DNR
resource types may not preserve that distinction in the same way.

The spike does not prove production-scale rule limits. Current caps are 500
blocked path rules and 1000 blocked subdomain rules before DNR rule expansion.
Because each policy entry can expand into multiple DNR rules, effective DNR
capacity must be measured against Firefox's dynamic rule limits before any
migration.

## Decision

Do not migrate production behavior yet. Keep `webRequestBlocking` for the
current release path. DNR remains a candidate only after a follow-up validates
dynamic blocked-screen context, complete path glob equivalence, Firefox
request-type mapping, and real organization rule counts against Firefox DNR
limits.
