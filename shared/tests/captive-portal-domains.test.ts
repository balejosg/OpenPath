import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { normalizeCaptivePortalDomains } from '../src/captive-portal-domains.js';

void describe('normalizeCaptivePortalDomains', () => {
  void it('trims, lowercases, and deduplicates exact hostnames', () => {
    assert.deepEqual(
      normalizeCaptivePortalDomains([' Login.EXAMPLE.test ', 'login.example.test']),
      ['login.example.test']
    );
  });

  void it('rejects URLs, wildcards, invalid hostnames, and more than 10 domains', () => {
    assert.throws(() => normalizeCaptivePortalDomains(['https://login.example.test']), /URLs/);
    assert.throws(() => normalizeCaptivePortalDomains(['*.example.test']), /wildcard/);
    assert.throws(() => normalizeCaptivePortalDomains(['bad_host.example']), /valid domain/);
    assert.throws(
      () =>
        normalizeCaptivePortalDomains(
          Array.from({ length: 11 }, (_, index) => `host${index}.example.test`)
        ),
      /at most 10/
    );
  });
});
