import { describe, expect, it } from 'vitest';
// Test-only runtime import from the shared barrel: tests are never bundled,
// so the SPA bundle-size rule (mirror constants locally) is not violated here.
import { CONFIG_POSTURE_KEYS as SHARED_CONFIG_POSTURE_KEYS } from '@openpath/shared';

import { CONFIG_POSTURE_KEYS, configPostureEntries } from '../config-posture';

describe('config-posture local mirror', () => {
  it('stays in sync with the @openpath/shared allowlist', () => {
    expect([...CONFIG_POSTURE_KEYS]).toEqual([...SHARED_CONFIG_POSTURE_KEYS]);
  });

  it('returns only allowlisted, non-empty entries in canonical order', () => {
    expect(
      configPostureEntries({
        freeForm: 'x',
        sinkholeFastFail: 'true',
        ipv6FirewallEnabled: 'false',
      })
    ).toEqual([
      { key: 'ipv6FirewallEnabled', value: 'false' },
      { key: 'sinkholeFastFail', value: 'true' },
    ]);
  });

  it('handles machines without posture', () => {
    expect(configPostureEntries(null)).toEqual([]);
    expect(configPostureEntries(undefined)).toEqual([]);
    expect(configPostureEntries({})).toEqual([]);
  });
});
