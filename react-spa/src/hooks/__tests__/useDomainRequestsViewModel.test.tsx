import { act, renderHook } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { useDomainRequestsViewModel } from '../useDomainRequestsViewModel';

const { mockApprove, mockReject, mockRequests } = vi.hoisted(() => {
  const requests = [
    {
      id: 'req-old-pending',
      domain: 'old.example.com',
      reason: 'Necesario para clase',
      requesterEmail: 'teacher@example.com',
      machineHostname: 'host-old',
      groupId: 'group-1',
      status: 'pending',
      source: 'manual',
      blockCause: { kind: 'blocked_by_rule', matchedRule: '*.google.com' },
      originHost: null,
      clientVersion: null,
      errorType: null,
      createdAt: '2026-04-01T10:00:00.000Z',
      updatedAt: '2026-04-01T10:00:00.000Z',
      resolvedAt: null,
      resolvedBy: null,
    },
    {
      id: 'req-new-pending',
      domain: 'new.example.com',
      reason: 'Extension request',
      requesterEmail: 'teacher@example.com',
      machineHostname: 'host-new',
      groupId: 'group-2',
      status: 'pending',
      source: 'firefox-extension',
      blockCause: { kind: 'already_allowed', matchedRule: 'google.com' },
      originHost: null,
      clientVersion: '1.2.3',
      errorType: null,
      createdAt: '2026-04-02T10:00:00.000Z',
      updatedAt: '2026-04-02T10:00:00.000Z',
      resolvedAt: null,
      resolvedBy: null,
    },
    {
      id: 'req-approved',
      domain: 'approved.example.com',
      reason: 'Already reviewed',
      requesterEmail: 'teacher@example.com',
      machineHostname: 'host-approved',
      groupId: 'group-1',
      status: 'approved',
      source: 'manual',
      originHost: null,
      clientVersion: null,
      errorType: null,
      createdAt: '2026-04-03T10:00:00.000Z',
      updatedAt: '2026-04-03T10:00:00.000Z',
      resolvedAt: '2026-04-03T11:00:00.000Z',
      resolvedBy: 'admin@example.com',
    },
  ] as const;

  return {
    mockApprove: vi.fn(),
    mockReject: vi.fn(),
    mockRequests: requests,
  };
});

vi.mock('../useDomainRequestsData', () => ({
  useDomainRequestsData: () => ({
    requests: [...mockRequests],
    groups: [
      { id: 'group-1', path: 'group-1', name: 'Grupo 1' },
      { id: 'group-2', path: 'group-2', name: 'Grupo 2' },
    ],
    loading: false,
    fetching: false,
    error: null,
    approveRequest: mockApprove,
    rejectRequest: mockReject,
    deleteRequest: vi.fn(),
    actionsLoading: false,
  }),
}));

describe('useDomainRequestsViewModel', () => {
  it('exposes render-ready rows and resets filtering through one view-model intent', () => {
    const { result } = renderHook(() => useDomainRequestsViewModel({ canDeleteRequests: false }));

    expect(result.current.table.rows.map((row) => row.domain)).toEqual([
      'old.example.com',
      'new.example.com',
      'approved.example.com',
    ]);
    expect(result.current.table.rows[0]?.groupName).toBe('Grupo 1');
    expect(result.current.table.rows[0]?.formattedCreatedAt).toMatch(/01/);
    expect(result.current.table.canDeleteRequests).toBe(false);
    expect(result.current.table.rows[0]?.blockCauseLabel).toBe('Blocked by rule *.google.com');
    expect(result.current.table.rows[1]?.blockCauseLabel).toBe('Already allowed by google.com');
    expect(result.current.table.rows[2]?.blockCauseLabel).toBeNull();

    act(() => {
      result.current.table.onOpenApprove('req-old-pending');
    });

    expect(result.current.dialogs.approveModal.request?.blockCause).toEqual({
      kind: 'blocked_by_rule',
      matchedRule: '*.google.com',
    });
    expect(result.current.dialogs.approveScope).toBe('family');

    act(() => {
      result.current.dialogs.onApproveScopeChange('host');
      result.current.dialogs.onApproveUnblockChange(true);
    });

    expect(result.current.dialogs.approveScope).toBe('host');
    expect(result.current.dialogs.approveUnblock).toBe(true);

    act(() => {
      result.current.filters.onSearchChange('new.example.com');
      result.current.filters.onSourceFilterChange('firefox-extension');
    });

    expect(result.current.table.rows.map((row) => row.domain)).toEqual(['new.example.com']);
    expect(result.current.table.emptyState).toBeNull();

    act(() => {
      result.current.table.onClearFilters();
    });

    expect(result.current.filters.searchTerm).toBe('');
    expect(result.current.filters.sourceFilter).toBe('all');
    expect(result.current.filters.statusFilter).toBe('all');
    expect(result.current.table.rows.map((row) => row.domain)).toEqual([
      'old.example.com',
      'new.example.com',
      'approved.example.com',
    ]);
  });

  it('keeps selection, bulk retry, and pagination mechanics behind the view model', async () => {
    mockApprove.mockRejectedValueOnce(new Error('temporary failure')).mockResolvedValueOnce({
      success: true,
    });

    const { result } = renderHook(() => useDomainRequestsViewModel({ canDeleteRequests: true }));

    act(() => {
      result.current.filters.onPageSizeChange(1);
    });

    expect(result.current.table.pagination.totalPages).toBe(3);

    act(() => {
      result.current.table.pagination.onChangePage(2);
    });

    expect(result.current.table.pagination.currentPage).toBe(2);

    act(() => {
      result.current.filters.onSearchChange('old');
    });

    expect(result.current.table.pagination.currentPage).toBe(1);
    expect(result.current.table.bulkSelection.canSelectPage).toBe(true);

    act(() => {
      result.current.table.bulkSelection.onToggleSelectPage();
    });

    expect(result.current.bulkActions.selectedCount).toBe(1);

    act(() => {
      result.current.bulkActions.onApproveSelected();
    });

    const approveConfirm = result.current.dialogs.bulkConfirm;
    expect(approveConfirm?.mode).toBe('approve');

    await act(async () => {
      if (approveConfirm?.mode === 'approve') {
        await result.current.dialogs.onBulkApproveConfirm(approveConfirm.requestIds);
      }
    });

    expect(result.current.bulkActions.failedCount).toBe(1);

    act(() => {
      result.current.bulkActions.onRetryFailed();
    });

    expect(result.current.dialogs.bulkConfirm).toEqual({
      mode: 'approve',
      requestIds: ['req-old-pending'],
    });
  });
});
