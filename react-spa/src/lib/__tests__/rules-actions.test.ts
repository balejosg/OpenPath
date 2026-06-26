import { describe, it, expect, vi, beforeEach } from 'vitest';
import { waitFor } from '@testing-library/react';
import {
  addRuleWithDetection,
  bulkCreateRulesAction,
  bulkDeleteRulesWithUndoAction,
  deleteRuleWithUndoAction,
  updateRuleAction,
} from '../rules-actions';
import { translateProductText } from '../../i18n/product-i18n';

const t = (
  key: Parameters<typeof translateProductText>[1],
  params?: Parameters<typeof translateProductText>[2]
) => translateProductText('en', key, params);

vi.mock('../trpc', () => ({
  trpc: {
    groups: {
      listRules: {
        query: vi.fn(),
      },
      createRule: {
        mutate: vi.fn(),
      },
      bulkCreateRules: {
        mutate: vi.fn(),
      },
      bulkDeleteRules: {
        mutate: vi.fn(),
      },
      deleteRule: {
        mutate: vi.fn(),
      },
      revokeAutoApproval: {
        mutate: vi.fn(),
      },
      updateRule: {
        mutate: vi.fn(),
      },
    },
  },
}));

import { trpc } from '../trpc';

const mockListRules = trpc.groups.listRules.query as unknown as ReturnType<typeof vi.fn>;
const mockCreateRule = trpc.groups.createRule.mutate as unknown as ReturnType<typeof vi.fn>;
const mockBulkCreateRules = trpc.groups.bulkCreateRules.mutate as unknown as ReturnType<
  typeof vi.fn
>;
const mockBulkDeleteRules = trpc.groups.bulkDeleteRules.mutate as unknown as ReturnType<
  typeof vi.fn
>;
const mockDeleteRule = trpc.groups.deleteRule.mutate as unknown as ReturnType<typeof vi.fn>;
const mockRevokeAutoApproval = trpc.groups.revokeAutoApproval.mutate as unknown as ReturnType<
  typeof vi.fn
>;
const mockUpdateRule = trpc.groups.updateRule.mutate as unknown as ReturnType<typeof vi.fn>;

describe('rules-actions', () => {
  type OnToastFn = (message: string, type: 'success' | 'error', undoAction?: () => void) => void;

  const onToast = vi.fn<OnToastFn>();
  const fetchRules = vi.fn().mockResolvedValue(undefined);
  const fetchCounts = vi.fn().mockResolvedValue(undefined);

  const params = {
    groupId: 'g1',
    onToast,
    fetchRules,
    fetchCounts,
    t,
    locale: 'en' as const,
  };

  beforeEach(() => {
    vi.clearAllMocks();
    mockListRules.mockResolvedValue([]);
  });

  it('returns false for empty/whitespace input', async () => {
    await expect(addRuleWithDetection('   ', params)).resolves.toBe(false);
    expect(mockListRules).not.toHaveBeenCalled();
    expect(mockCreateRule).not.toHaveBeenCalled();
  });

  it('toasts duplicate when API returns created:false', async () => {
    mockCreateRule.mockResolvedValue({ created: false });

    await expect(addRuleWithDetection('example.com', params)).resolves.toBe(false);
    expect(onToast).toHaveBeenCalledWith('"example.com" already exists as Allowed', 'error');
    expect(fetchRules).not.toHaveBeenCalled();
    expect(fetchCounts).not.toHaveBeenCalled();
  });

  it('toasts duplicate when API throws conflict-like error', async () => {
    mockCreateRule.mockRejectedValue({ data: { code: 'CONFLICT' } });

    await expect(addRuleWithDetection('example.com', params)).resolves.toBe(false);
    expect(onToast).toHaveBeenCalledWith('"example.com" already exists as Allowed', 'error');
  });

  it('toasts success and refetches on success', async () => {
    mockCreateRule.mockResolvedValue({ id: 'r1' });

    await expect(addRuleWithDetection('example.com', params)).resolves.toBe(true);
    expect(onToast).toHaveBeenCalledWith('"example.com" added as Allowed', 'success');
    expect(fetchRules).toHaveBeenCalledTimes(1);
    expect(fetchCounts).toHaveBeenCalledTimes(1);
  });

  it('bulkCreateRulesAction: toasts success and refetches', async () => {
    mockBulkCreateRules.mockResolvedValue({ count: 2 });

    await expect(
      bulkCreateRulesAction(['a.com', 'b.com'], 'whitelist', {
        groupId: 'g1',
        onToast,
        fetchRules,
        fetchCounts,
        t,
        locale: 'en' as const,
      })
    ).resolves.toEqual({ created: 2, total: 2 });

    expect(onToast).toHaveBeenCalledWith('2 rules imported', 'success');
    expect(fetchRules).toHaveBeenCalled();
    expect(fetchCounts).toHaveBeenCalled();
  });

  it('bulkCreateRulesAction: toasts when everything is duplicate', async () => {
    mockBulkCreateRules.mockResolvedValue({ count: 0 });

    await expect(
      bulkCreateRulesAction(['a.com'], 'whitelist', {
        groupId: 'g1',
        onToast,
        fetchRules,
        fetchCounts,
        t,
        locale: 'en' as const,
      })
    ).resolves.toEqual({ created: 0, total: 1 });

    expect(onToast).toHaveBeenCalledWith('All rules already exist', 'error');
    expect(fetchRules).not.toHaveBeenCalled();
    expect(fetchCounts).not.toHaveBeenCalled();
  });

  it('updateRuleAction: toasts success and refetches', async () => {
    mockUpdateRule.mockResolvedValue({ id: 'r1' });

    await expect(
      updateRuleAction(
        'r1',
        { value: 'example.com' },
        { groupId: 'g1', onToast, fetchRules, t, locale: 'en' as const }
      )
    ).resolves.toBe(true);

    expect(onToast).toHaveBeenCalledWith('Rule updated', 'success');
    expect(fetchRules).toHaveBeenCalledTimes(1);
  });

  it('updateRuleAction: toasts error on failure', async () => {
    mockUpdateRule.mockRejectedValue(new Error('backend failure'));

    await expect(
      updateRuleAction(
        'r1',
        { value: 'example.com' },
        { groupId: 'g1', onToast, fetchRules, t, locale: 'en' as const }
      )
    ).resolves.toBe(false);

    expect(onToast).toHaveBeenCalledWith('Unable to update rule', 'error');
    expect(fetchRules).not.toHaveBeenCalled();
  });

  it('deleteRuleWithUndoAction: deletes and exposes undo action', async () => {
    mockDeleteRule.mockResolvedValue({ deleted: true });
    mockCreateRule.mockResolvedValue({ id: 'restored' });

    await deleteRuleWithUndoAction(
      {
        id: 'r1',
        groupId: 'g1',
        type: 'whitelist',
        value: 'example.com',
        comment: null,
      },
      { onToast, fetchRules, fetchCounts, t, locale: 'en' as const }
    );

    expect(mockDeleteRule).toHaveBeenCalledWith({ id: 'r1', groupId: 'g1' });
    expect(fetchRules).toHaveBeenCalledTimes(1);
    expect(fetchCounts).toHaveBeenCalledTimes(1);

    const undo = onToast.mock.calls.find((call) => call[0] === '"example.com" deleted')?.[2];
    expect(typeof undo).toBe('function');

    (undo as () => void)();

    await waitFor(() => {
      expect(mockCreateRule).toHaveBeenCalledWith({
        groupId: 'g1',
        type: 'whitelist',
        value: 'example.com',
        comment: undefined,
      });
    });

    await waitFor(() => {
      expect(onToast).toHaveBeenCalledWith('"example.com" restored', 'success');
    });
  });

  it('revokeAutoApprovalAction: confirms, revokes, and refetches without undo', async () => {
    const { revokeAutoApprovalAction } = await import('../rules-actions');
    mockRevokeAutoApproval.mockResolvedValue({ revoked: true, blockedRuleId: 'blocked-rule' });
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);

    await revokeAutoApprovalAction(
      {
        id: 'auto-1',
        groupId: 'g1',
        type: 'whitelist',
        value: 'cdn.example.com',
        comment: null,
      },
      { onToast, fetchRules, fetchCounts, t, locale: 'en' as const }
    );

    expect(confirmSpy).toHaveBeenCalledWith(
      'Revoking automatic approval for "cdn.example.com" will block this domain from being auto-approved again.'
    );
    expect(mockRevokeAutoApproval).toHaveBeenCalledWith({ id: 'auto-1', groupId: 'g1' });
    expect(onToast).toHaveBeenCalledWith(
      '"cdn.example.com" blocked after revoking automatic approval',
      'success'
    );
    expect(fetchRules).toHaveBeenCalledTimes(1);
    expect(fetchCounts).toHaveBeenCalledTimes(1);

    confirmSpy.mockRestore();
  });

  it('revokeAutoApprovalAction: skips API call when teacher cancels confirmation', async () => {
    const { revokeAutoApprovalAction } = await import('../rules-actions');
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);

    await revokeAutoApprovalAction(
      {
        id: 'auto-1',
        groupId: 'g1',
        type: 'whitelist',
        value: 'cdn.example.com',
        comment: null,
      },
      { onToast, fetchRules, fetchCounts, t, locale: 'en' as const }
    );

    expect(mockRevokeAutoApproval).not.toHaveBeenCalled();
    expect(onToast).not.toHaveBeenCalled();
    expect(fetchRules).not.toHaveBeenCalled();
    expect(fetchCounts).not.toHaveBeenCalled();

    confirmSpy.mockRestore();
  });

  it('revokeAutoApprovalAction: toasts error when revoke fails', async () => {
    const { revokeAutoApprovalAction } = await import('../rules-actions');
    mockRevokeAutoApproval.mockRejectedValue(new Error('backend failure'));
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);

    await revokeAutoApprovalAction(
      {
        id: 'auto-1',
        groupId: 'g1',
        type: 'whitelist',
        value: 'cdn.example.com',
        comment: null,
      },
      { onToast, fetchRules, fetchCounts, t, locale: 'en' as const }
    );

    expect(onToast).toHaveBeenCalledWith('Unable to revoke automatic approval', 'error');
    expect(fetchRules).not.toHaveBeenCalled();
    expect(fetchCounts).not.toHaveBeenCalled();

    confirmSpy.mockRestore();
  });

  it('bulkDeleteRulesWithUndoAction: clears selection, toasts, and supports undo', async () => {
    mockBulkDeleteRules.mockResolvedValue({
      deleted: 2,
      rules: [
        {
          id: 'r1',
          groupId: 'g1',
          type: 'whitelist',
          value: 'a.com',
          comment: null,
          createdAt: '2024-01-01',
        },
        {
          id: 'r2',
          groupId: 'g1',
          type: 'whitelist',
          value: 'b.com',
          comment: null,
          createdAt: '2024-01-01',
        },
      ],
    });
    mockCreateRule.mockResolvedValue({ id: 'restored' });

    const clearSelection = vi.fn();

    await bulkDeleteRulesWithUndoAction({
      ids: ['r1', 'r2'],
      clearSelection,
      onToast,
      fetchRules,
      fetchCounts,
      t,
      locale: 'en' as const,
    });

    expect(clearSelection).toHaveBeenCalledTimes(1);
    expect(fetchRules).toHaveBeenCalledTimes(1);
    expect(fetchCounts).toHaveBeenCalledTimes(1);

    const undo = onToast.mock.calls.find((call) => call[0] === '2 rules deleted')?.[2];
    expect(typeof undo).toBe('function');

    (undo as () => void)();

    await waitFor(() => {
      expect(mockCreateRule).toHaveBeenCalledTimes(2);
    });

    await waitFor(() => {
      expect(onToast).toHaveBeenCalledWith('2 rules restored', 'success');
    });
  });
});
