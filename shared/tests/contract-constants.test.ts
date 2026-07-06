import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  LINUX_CAPTIVE_PORTAL_PROBE_DOMAINS,
  WHITELIST_DISABLED_SENTINEL,
  WHITELIST_SECTION_HEADERS,
  WINDOWS_CAPTIVE_PORTAL_DETECTION_HOSTS,
  WINDOWS_CAPTIVE_PORTAL_PROBE_DOMAINS,
} from '../src/contract-constants.js';

describe('contract-constants', () => {
  it('pins the canonical disabled sentinel (uppercase, no space)', () => {
    assert.equal(WHITELIST_DISABLED_SENTINEL, '#DESACTIVADO');
  });

  it('pins the four wire-format section headers', () => {
    assert.deepEqual(
      { ...WHITELIST_SECTION_HEADERS },
      {
        whitelist: '## WHITELIST',
        blockedSubdomains: '## BLOCKED-SUBDOMAINS',
        blockedPaths: '## BLOCKED-PATHS',
        allowedPaths: '## ALLOWED-PATHS',
      }
    );
  });

  it('keeps the linux probe list a subset of the windows probe list', () => {
    for (const domain of LINUX_CAPTIVE_PORTAL_PROBE_DOMAINS) {
      assert.ok(
        (WINDOWS_CAPTIVE_PORTAL_PROBE_DOMAINS as readonly string[]).includes(domain),
        `${domain} missing from windows probe list`
      );
    }
  });

  it('keeps detection hosts a subset of the windows probe list', () => {
    for (const domain of WINDOWS_CAPTIVE_PORTAL_DETECTION_HOSTS) {
      assert.ok(
        (WINDOWS_CAPTIVE_PORTAL_PROBE_DOMAINS as readonly string[]).includes(domain),
        `${domain} missing from windows probe list`
      );
    }
  });
});
