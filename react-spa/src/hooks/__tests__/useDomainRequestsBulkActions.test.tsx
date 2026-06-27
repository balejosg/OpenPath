import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { DomainRequest } from '@openpath/api';
import { useDomainRequestsBulkActions } from '../useDomainRequestsBulkActions';

const pendingRequest = {
  id: 'req-1',
  domain: 'example.com',
  reason: 'Necesario para clase',
  requesterEmail: 'teacher@example.com',
  groupId: 'group-1',
  status: 'pending' as const,
  createdAt: '2026-04-01T10:00:00.000Z',
  updatedAt: '2026-04-01T10:00:00.000Z',
  resolvedAt: null,
  resolvedBy: null,
  originHost: null,
  machineHostname: null,
  clientVersion: null,
  source: 'manual' as const,
  errorType: null,
};

const approvedRequest = {
  ...pendingRequest,
  id: 'req-1',
  status: 'approved' as const,
};

const requests = [pendingRequest];

describe('useDomainRequestsBulkActions', () => {
  it('opens a bulk-approve confirmation and clears selection after success', async () => {
    const setSelectedRequestIds = vi.fn();
    const approveRequest = vi.fn().mockResolvedValue({ success: true });

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest,
        rejectRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.openBulkApproveConfirm();
    });

    expect(result.current.bulkConfirm).toEqual({
      mode: 'approve',
      requestIds: ['req-1'],
    });

    await act(async () => {
      await result.current.runBulkApprove(['req-1']);
    });

    expect(approveRequest).toHaveBeenCalledWith('req-1');
    expect(setSelectedRequestIds).toHaveBeenCalledWith([]);
  });

  it('openBulkApproveConfirm with empty selection does nothing', () => {
    const setSelectedRequestIds = vi.fn();

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: [],
        setSelectedRequestIds,
        approveRequest: vi.fn(),
        rejectRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.openBulkApproveConfirm();
    });

    expect(result.current.bulkConfirm).toBeNull();
  });

  it('openBulkRejectConfirm sets bulkConfirm with mode reject', () => {
    const setSelectedRequestIds = vi.fn();

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest: vi.fn(),
        rejectRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.openBulkRejectConfirm();
    });

    expect(result.current.bulkConfirm).toEqual({
      mode: 'reject',
      requestIds: ['req-1'],
      rejectReason: undefined,
    });
  });

  it('openBulkRejectConfirm includes trimmed reason when set', () => {
    const setSelectedRequestIds = vi.fn();

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest: vi.fn(),
        rejectRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.setBulkRejectReason('  bad content  ');
    });

    act(() => {
      result.current.openBulkRejectConfirm();
    });

    expect(result.current.bulkConfirm).toEqual({
      mode: 'reject',
      requestIds: ['req-1'],
      rejectReason: 'bad content',
    });
  });

  it('openBulkRejectConfirm with empty selection does nothing', () => {
    const setSelectedRequestIds = vi.fn();

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: [],
        setSelectedRequestIds,
        approveRequest: vi.fn(),
        rejectRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.openBulkRejectConfirm();
    });

    expect(result.current.bulkConfirm).toBeNull();
  });

  it('runBulkApprove with empty requestIds returns early', async () => {
    const approveRequest = vi.fn();

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: [],
        setSelectedRequestIds: vi.fn(),
        approveRequest,
        rejectRequest: vi.fn(),
      })
    );

    await act(async () => {
      await result.current.runBulkApprove([]);
    });

    expect(approveRequest).not.toHaveBeenCalled();
    expect(result.current.bulkLoading).toBe(false);
  });

  it('runBulkApprove with some failures populates bulkFailedIds', async () => {
    const setSelectedRequestIds = vi.fn();
    const approveRequest = vi
      .fn()
      .mockResolvedValueOnce({ success: true })
      .mockRejectedValueOnce(new Error('network error'));

    const twoRequests = [pendingRequest, { ...pendingRequest, id: 'req-2' }];

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests: twoRequests,
        selectedPendingRequests: twoRequests,
        setSelectedRequestIds,
        approveRequest,
        rejectRequest: vi.fn(),
      })
    );

    await act(async () => {
      await result.current.runBulkApprove(['req-1', 'req-2']);
    });

    expect(result.current.bulkFailedIds).toEqual(['req-2']);
    // setSelectedRequestIds called because one succeeded
    expect(setSelectedRequestIds).toHaveBeenCalledWith([]);
    expect(result.current.bulkMessage).not.toBeNull();
  });

  it('runBulkApprove all fail does not call setSelectedRequestIds and bulkFailedIds is populated', async () => {
    const setSelectedRequestIds = vi.fn();
    const approveRequest = vi.fn().mockRejectedValue(new Error('fail'));

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest,
        rejectRequest: vi.fn(),
      })
    );

    await act(async () => {
      await result.current.runBulkApprove(['req-1']);
    });

    expect(setSelectedRequestIds).not.toHaveBeenCalled();
    expect(result.current.bulkFailedIds).toEqual(['req-1']);
  });

  it('runBulkReject with empty requestIds returns early', async () => {
    const rejectRequest = vi.fn();

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: [],
        setSelectedRequestIds: vi.fn(),
        approveRequest: vi.fn(),
        rejectRequest,
      })
    );

    await act(async () => {
      await result.current.runBulkReject([]);
    });

    expect(rejectRequest).not.toHaveBeenCalled();
    expect(result.current.bulkLoading).toBe(false);
  });

  it('runBulkReject success clears selection and bulkRejectReason', async () => {
    const setSelectedRequestIds = vi.fn();
    const rejectRequest = vi.fn().mockResolvedValue({ success: true });

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest: vi.fn(),
        rejectRequest,
      })
    );

    act(() => {
      result.current.setBulkRejectReason('off-topic');
    });

    await act(async () => {
      await result.current.runBulkReject(['req-1'], 'off-topic');
    });

    expect(rejectRequest).toHaveBeenCalledWith({ id: 'req-1', reason: 'off-topic' });
    expect(setSelectedRequestIds).toHaveBeenCalledWith([]);
    expect(result.current.bulkRejectReason).toBe('');
    expect(result.current.bulkFailedIds).toEqual([]);
  });

  it('runBulkReject with failures populates bulkFailedIds', async () => {
    const setSelectedRequestIds = vi.fn();
    const rejectRequest = vi
      .fn()
      .mockResolvedValueOnce({ success: true })
      .mockRejectedValueOnce(new Error('server error'));

    const twoRequests = [pendingRequest, { ...pendingRequest, id: 'req-2' }];

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests: twoRequests,
        selectedPendingRequests: twoRequests,
        setSelectedRequestIds,
        approveRequest: vi.fn(),
        rejectRequest,
      })
    );

    await act(async () => {
      await result.current.runBulkReject(['req-1', 'req-2']);
    });

    expect(result.current.bulkFailedIds).toEqual(['req-2']);
    expect(setSelectedRequestIds).toHaveBeenCalledWith([]);
  });

  it('handleRetryFailed returns early when no failed ids', () => {
    const setSelectedRequestIds = vi.fn();

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest: vi.fn(),
        rejectRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.handleRetryFailed();
    });

    expect(setSelectedRequestIds).not.toHaveBeenCalled();
    expect(result.current.bulkConfirm).toBeNull();
  });

  it('handleRetryFailed in approve mode sets bulkConfirm for pending retry candidates', async () => {
    const setSelectedRequestIds = vi.fn();
    const approveRequest = vi.fn().mockRejectedValue(new Error('fail'));

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest,
        rejectRequest: vi.fn(),
      })
    );

    await act(async () => {
      await result.current.runBulkApprove(['req-1']);
    });

    expect(result.current.bulkFailedIds).toEqual(['req-1']);

    act(() => {
      result.current.handleRetryFailed();
    });

    expect(result.current.bulkConfirm).toEqual({
      mode: 'approve',
      requestIds: ['req-1'],
    });
    expect(setSelectedRequestIds).toHaveBeenCalledWith(['req-1']);
  });

  it('handleRetryFailed in reject mode sets bulkConfirm for pending retry candidates', async () => {
    const setSelectedRequestIds = vi.fn();
    const rejectRequest = vi.fn().mockRejectedValue(new Error('fail'));

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest: vi.fn(),
        rejectRequest,
      })
    );

    await act(async () => {
      await result.current.runBulkReject(['req-1']);
    });

    expect(result.current.bulkFailedIds).toEqual(['req-1']);

    act(() => {
      result.current.handleRetryFailed();
    });

    expect(result.current.bulkConfirm).toEqual({
      mode: 'reject',
      requestIds: ['req-1'],
      rejectReason: undefined,
    });
    expect(setSelectedRequestIds).toHaveBeenCalledWith(['req-1']);
  });

  it('handleRetryFailed in reject mode passes trimmed reason', async () => {
    const setSelectedRequestIds = vi.fn();
    const rejectRequest = vi.fn().mockRejectedValue(new Error('fail'));

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest: vi.fn(),
        rejectRequest,
      })
    );

    act(() => {
      result.current.setBulkRejectReason('  spam  ');
    });

    await act(async () => {
      await result.current.runBulkReject(['req-1'], 'spam');
    });

    act(() => {
      result.current.handleRetryFailed();
    });

    expect(result.current.bulkConfirm).toEqual({
      mode: 'reject',
      requestIds: ['req-1'],
      rejectReason: 'spam',
    });
  });

  it('handleRetryFailed sets noFailedToRetry message when failed requests are no longer pending', async () => {
    const setSelectedRequestIds = vi.fn();
    const approveRequest = vi.fn().mockRejectedValue(new Error('fail'));

    const { result, rerender } = renderHook(
      ({ reqs }: { reqs: DomainRequest[] }) =>
        useDomainRequestsBulkActions({
          requests: reqs,
          selectedPendingRequests: reqs,
          setSelectedRequestIds,
          approveRequest,
          rejectRequest: vi.fn(),
        }),
      { initialProps: { reqs: requests as DomainRequest[] } }
    );

    await act(async () => {
      await result.current.runBulkApprove(['req-1']);
    });

    expect(result.current.bulkFailedIds).toEqual(['req-1']);

    // Re-render with the request now approved (no longer pending)
    rerender({ reqs: [approvedRequest] });

    act(() => {
      result.current.handleRetryFailed();
    });

    expect(result.current.bulkMessage).toBeTruthy();
    expect(result.current.bulkFailedIds).toEqual([]);
  });

  it('clearBulkSelection resets all selection state', async () => {
    const setSelectedRequestIds = vi.fn();
    const approveRequest = vi.fn().mockRejectedValue(new Error('fail'));

    const { result } = renderHook(() =>
      useDomainRequestsBulkActions({
        requests,
        selectedPendingRequests: requests,
        setSelectedRequestIds,
        approveRequest,
        rejectRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.setBulkRejectReason('some reason');
    });

    await act(async () => {
      await result.current.runBulkApprove(['req-1']);
    });

    expect(result.current.bulkFailedIds).toEqual(['req-1']);

    act(() => {
      result.current.clearBulkSelection();
    });

    expect(setSelectedRequestIds).toHaveBeenCalledWith([]);
    expect(result.current.bulkFailedIds).toEqual([]);
    expect(result.current.bulkRejectReason).toBe('');
  });

  describe('bulkMessage auto-clear effect', () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it('clears bulkMessage after 4 seconds', async () => {
      const approveRequest = vi.fn().mockResolvedValue({ success: true });

      const { result } = renderHook(() =>
        useDomainRequestsBulkActions({
          requests,
          selectedPendingRequests: requests,
          setSelectedRequestIds: vi.fn(),
          approveRequest,
          rejectRequest: vi.fn(),
        })
      );

      await act(async () => {
        await result.current.runBulkApprove(['req-1']);
      });

      expect(result.current.bulkMessage).not.toBeNull();

      act(() => {
        vi.advanceTimersByTime(4000);
      });

      expect(result.current.bulkMessage).toBeNull();
    });

    it('does not clear message before 4 seconds', async () => {
      const approveRequest = vi.fn().mockResolvedValue({ success: true });

      const { result } = renderHook(() =>
        useDomainRequestsBulkActions({
          requests,
          selectedPendingRequests: requests,
          setSelectedRequestIds: vi.fn(),
          approveRequest,
          rejectRequest: vi.fn(),
        })
      );

      await act(async () => {
        await result.current.runBulkApprove(['req-1']);
      });

      expect(result.current.bulkMessage).not.toBeNull();

      act(() => {
        vi.advanceTimersByTime(3999);
      });

      expect(result.current.bulkMessage).not.toBeNull();
    });
  });
});
