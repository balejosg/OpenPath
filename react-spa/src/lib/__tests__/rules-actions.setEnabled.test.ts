import { describe, it, expect, vi, beforeEach } from 'vitest';

const setRuleEnabled = vi.fn(async (_arg: unknown) => ({}));
const bulkSetRulesEnabled = vi.fn(async (_arg: unknown) => ({ updated: 0 }));
vi.mock('../trpc', () => ({
  trpc: {
    groups: {
      setRuleEnabled: { mutate: (a: unknown) => setRuleEnabled(a) },
      bulkSetRulesEnabled: { mutate: (a: unknown) => bulkSetRulesEnabled(a) },
    },
  },
}));
vi.mock('../reportError', () => ({ reportError: vi.fn() }));

import { setRuleEnabledAction, bulkSetRulesEnabledAction } from '../rules-actions';

const t = ((k: string, vars?: Record<string, unknown>) =>
  vars !== undefined ? `${k}:${JSON.stringify(vars)}` : k) as never;

describe('setRuleEnabledAction', () => {
  beforeEach(() => vi.clearAllMocks());
  it('calls setRuleEnabled and notifies with undo', async () => {
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

describe('bulkSetRulesEnabledAction', () => {
  beforeEach(() => vi.clearAllMocks());

  it('calls bulkSetRulesEnabled with ids and enabled, then clears selection and toasts success', async () => {
    bulkSetRulesEnabled.mockResolvedValueOnce({ updated: 2 });

    const clearSelection = vi.fn();
    const onToast = vi.fn();
    const fetchRules = vi.fn(async () => {});
    const fetchCounts = vi.fn(async () => {});

    await bulkSetRulesEnabledAction({
      ids: ['a', 'b'],
      enabled: false,
      clearSelection,
      onToast,
      fetchRules,
      fetchCounts,
      t,
      locale: 'es',
    });

    // mutate called with exactly the right payload — no 'rules' or other fields
    expect(bulkSetRulesEnabled).toHaveBeenCalledOnce();
    expect(bulkSetRulesEnabled).toHaveBeenCalledWith({ ids: ['a', 'b'], enabled: false });

    // selection cleared
    expect(clearSelection).toHaveBeenCalledOnce();

    // toast fired as success and the message reflects the count of 2 (not rows from a .rules field)
    expect(onToast).toHaveBeenCalledOnce();
    const [toastMessage, toastType] = onToast.mock.calls[0] as [string, string];
    expect(toastType).toBe('success');
    expect(toastMessage).toContain('2');

    // fetchRules and fetchCounts run after the toast
    expect(fetchRules).toHaveBeenCalledOnce();
    expect(fetchCounts).toHaveBeenCalledOnce();
  });
});
