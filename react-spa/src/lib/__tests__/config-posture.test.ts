import { describe, expect, it } from 'vitest';
import { CONFIG_POSTURE_KEYS as SHARED_CONFIG_POSTURE_KEYS } from '@openpath/shared/schemas';

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
