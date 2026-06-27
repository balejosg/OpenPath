import { describe, it, expect } from 'vitest';
// Unit test for tab construction: verify the exported pure function.
// Asserts that the 'disabled' tab is present and 'automatic' is absent.
import { buildRulesManagerTabs } from '../useRulesManagerViewModel';

describe('rules manager tabs', () => {
  it('includes disabled and excludes automatic', () => {
    const tabs = buildRulesManagerTabs({
      all: 4,
      allowed: 2,
      automatic: 1,
      blocked: 1,
      disabled: 1,
    });
    const ids = tabs.map((t) => t.id);
    expect(ids).toContain('disabled');
    expect(ids).not.toContain('automatic');
  });
});
