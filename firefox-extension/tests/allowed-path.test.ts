import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  compileAllowedPathRules,
  evaluateAllowedPath,
  type AllowedPathRulesState,
} from '../src/lib/allowed-path.js';

function state(paths: string[]): AllowedPathRulesState {
  const { rules, managedHosts } = compileAllowedPathRules(paths);
  return { version: 'v', rules, managedHosts };
}
const EXT = 'moz-extension://abc/';

describe('evaluateAllowedPath', () => {
  it('ignores a host with no allowed_path rule', () => {
    const s = state(['youtube.com/watch?v=abc']);
    assert.equal(
      evaluateAllowedPath({ type: 'main_frame', url: 'https://example.com/x' }, s, {
        extensionOrigin: EXT,
      }),
      null
    );
  });
  it('allows the matching URL on a managed host (incl. extra params + www)', () => {
    const s = state(['youtube.com/watch?v=abc']);
    assert.equal(
      evaluateAllowedPath(
        { type: 'main_frame', url: 'https://www.youtube.com/watch?v=abc&t=30s' },
        s,
        { extensionOrigin: EXT }
      ),
      null
    );
  });
  it('blocks a non-matching main_frame URL on a managed host', () => {
    const s = state(['youtube.com/watch?v=abc']);
    const r = evaluateAllowedPath(
      { type: 'main_frame', url: 'https://www.youtube.com/watch?v=zzz' },
      s,
      { extensionOrigin: EXT }
    );
    assert.ok(r?.redirectUrl?.startsWith(EXT));
  });
  it('never gates sub-resources, even on a managed host', () => {
    const s = state(['youtube.com/watch?v=abc']);
    assert.equal(
      evaluateAllowedPath({ type: 'xmlhttprequest', url: 'https://www.youtube.com/api/stats' }, s, {
        extensionOrigin: EXT,
      }),
      null
    );
  });
  it('drops a global-wildcard rule (no managed host)', () => {
    const s = state(['*/watch']);
    assert.equal(s.managedHosts.size, 0);
    assert.equal(
      evaluateAllowedPath({ type: 'main_frame', url: 'https://anything.com/x' }, s, {
        extensionOrigin: EXT,
      }),
      null
    );
  });
});
