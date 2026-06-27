import { describe, it, expect, vi, beforeEach } from 'vitest';

const setRuleEnabled = vi.fn(async (_arg: unknown) => ({}));
vi.mock('../trpc', () => ({
  trpc: { groups: { setRuleEnabled: { mutate: (a: unknown) => setRuleEnabled(a) } } },
}));
vi.mock('../reportError', () => ({ reportError: vi.fn() }));

import { setRuleEnabledAction } from '../rules-actions';

const t = ((k: string) => k) as never;

describe('setRuleEnabledAction', () => {
  beforeEach(() => vi.clearAllMocks());
  it('llama setRuleEnabled y notifica con undo', async () => {
    const onToast = vi.fn();
    const fetchRules = vi.fn(async () => {});
    const fetchCounts = vi.fn(async () => {});
    await setRuleEnabledAction(
      { id: 'r1', groupId: 'g', type: 'whitelist', value: 'a.example.com', comment: null },
      false,
      { onToast, fetchRules, fetchCounts, t, locale: 'es' }
    );
    expect(setRuleEnabled).toHaveBeenCalledWith({ id: 'r1', groupId: 'g', enabled: false });
    expect(onToast).toHaveBeenCalledWith(expect.any(String), 'success', expect.any(Function));
  });
});
