import { describe, it, expect, vi, beforeEach } from 'vitest';
import { waitFor } from '@testing-library/react';

const setRuleEnabled = vi.fn((_arg: unknown) => Promise.resolve({}));
const bulkSetRulesEnabled = vi.fn((_arg: unknown) => Promise.resolve({ updated: 0 }));
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
import { reportError } from '../reportError';

const mockReportError = reportError as ReturnType<typeof vi.fn>;

const t = ((k: string, vars?: Record<string, unknown>) =>
  vars !== undefined ? `${k}:${JSON.stringify(vars)}` : k) as never;

const rule = {
  id: 'r1',
  groupId: 'g',
  type: 'whitelist' as const,
  value: 'a.example.com',
  comment: null,
};

describe('setRuleEnabledAction', () => {
  beforeEach(() => vi.clearAllMocks());

  it('calls setRuleEnabled and notifies with undo', async () => {
    const onToast = vi.fn();
    const fetchRules = vi.fn(() => Promise.resolve());
    const fetchCounts = vi.fn(() => Promise.resolve());
    await setRuleEnabledAction(rule, false, { onToast, fetchRules, fetchCounts, t, locale: 'es' });
    expect(setRuleEnabled).toHaveBeenCalledWith({ id: 'r1', groupId: 'g', enabled: false });
    expect(onToast).toHaveBeenCalledWith(expect.any(String), 'success', expect.any(Function));
  });

  it('calls reportError and toasts error when mutate rejects', async () => {
    const err = new Error('network failure');
    setRuleEnabled.mockRejectedValueOnce(err);
    const onToast = vi.fn();
    const fetchRules = vi.fn(() => Promise.resolve());
    const fetchCounts = vi.fn(() => Promise.resolve());

    await setRuleEnabledAction(rule, true, { onToast, fetchRules, fetchCounts, t, locale: 'es' });

    expect(mockReportError).toHaveBeenCalledWith('Failed to set rule enabled:', err);
    expect(onToast).toHaveBeenCalledWith('rulesActions.unableToUpdate', 'error');
    expect(fetchRules).not.toHaveBeenCalled();
    expect(fetchCounts).not.toHaveBeenCalled();
  });

  it('undo callback calls setRuleEnabled with the inverse value and refetches', async () => {
    const onToast = vi.fn();
    const fetchRules = vi.fn(() => Promise.resolve());
    const fetchCounts = vi.fn(() => Promise.resolve());

    // First call succeeds (the main action), second also succeeds (the undo)
    setRuleEnabled.mockResolvedValueOnce({}).mockResolvedValueOnce({});

    await setRuleEnabledAction(rule, true, { onToast, fetchRules, fetchCounts, t, locale: 'es' });

    // Extract and invoke the undo callback
    const undoFn = onToast.mock.calls[0]?.[2] as (() => void) | undefined;
    expect(typeof undoFn).toBe('function');
    undoFn?.();

    // Wait for the async undo IIFE to complete
    await waitFor(() => {
      expect(setRuleEnabled).toHaveBeenCalledTimes(2);
    });
    expect(setRuleEnabled).toHaveBeenNthCalledWith(2, {
      id: 'r1',
      groupId: 'g',
      enabled: false, // inverse of `true` passed above
    });
    await waitFor(() => {
      expect(fetchRules).toHaveBeenCalledTimes(2); // once for main action, once for undo
    });
    await waitFor(() => {
      expect(fetchCounts).toHaveBeenCalledTimes(2);
    });
  });

  it('undo callback toasts error when the inverse mutate rejects', async () => {
    const err = new Error('undo failure');
    const onToast = vi.fn();
    const fetchRules = vi.fn(() => Promise.resolve());
    const fetchCounts = vi.fn(() => Promise.resolve());

    // Main action resolves; undo rejects
    setRuleEnabled.mockResolvedValueOnce({}).mockRejectedValueOnce(err);

    await setRuleEnabledAction(rule, true, { onToast, fetchRules, fetchCounts, t, locale: 'es' });

    const undoFn = onToast.mock.calls[0]?.[2] as (() => void) | undefined;
    undoFn?.();

    await waitFor(() => {
      expect(mockReportError).toHaveBeenCalledWith('Failed to undo set-enabled:', err);
    });
    await waitFor(() => {
      expect(onToast).toHaveBeenCalledWith('rulesActions.unableToUpdate', 'error');
    });
  });
});

describe('bulkSetRulesEnabledAction', () => {
  beforeEach(() => vi.clearAllMocks());

  it('calls bulkSetRulesEnabled with ids and enabled, then clears selection and toasts success', async () => {
    bulkSetRulesEnabled.mockResolvedValueOnce({ updated: 2 });

    const clearSelection = vi.fn();
    const onToast = vi.fn();
    const fetchRules = vi.fn(() => Promise.resolve());
    const fetchCounts = vi.fn(() => Promise.resolve());

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

  it('calls reportError and toasts error when mutate rejects', async () => {
    const err = new Error('bulk network failure');
    bulkSetRulesEnabled.mockRejectedValueOnce(err);

    const onToast = vi.fn();
    const fetchRules = vi.fn(() => Promise.resolve());
    const fetchCounts = vi.fn(() => Promise.resolve());

    await bulkSetRulesEnabledAction({
      ids: ['a', 'b'],
      enabled: true,
      onToast,
      fetchRules,
      fetchCounts,
      t,
      locale: 'es',
    });

    expect(mockReportError).toHaveBeenCalledWith('Failed to bulk set enabled:', err);
    expect(onToast).toHaveBeenCalledWith('rulesActions.unableToUpdate', 'error');
    expect(fetchRules).not.toHaveBeenCalled();
    expect(fetchCounts).not.toHaveBeenCalled();
  });
});
