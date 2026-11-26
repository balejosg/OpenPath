import { act, renderHook } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { useDomainRequestsDialogs } from '../useDomainRequestsDialogs';

const request = {
  id: 'req-1',
  domain: 'example.com',
  reason: 'Necesario para clase',
  requesterEmail: 'teacher@example.com',
  groupId: 'group-1',
  status: 'pending',
  createdAt: '2026-04-01T10:00:00.000Z',
  updatedAt: '2026-04-01T10:00:00.000Z',
  resolvedAt: null,
  resolvedBy: null,
  originHost: null,
  machineHostname: null,
  clientVersion: null,
  source: 'manual',
  errorType: null,
} as const;

describe('useDomainRequestsDialogs', () => {
  it('submits rejections with the current reason and resets dialog state', async () => {
    const rejectRequest = vi.fn().mockResolvedValue({ success: true });

    const { result } = renderHook(() =>
      useDomainRequestsDialogs({
        approveRequest: vi.fn(),
        rejectRequest,
        deleteRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.setRejectModal({ open: true, request });
      result.current.setRejectionReason('No aplica');
    });

    await act(async () => {
      await result.current.handleReject();
    });

    expect(rejectRequest).toHaveBeenCalledWith({ id: 'req-1', reason: 'No aplica' });
    expect(result.current.rejectModal).toEqual({ open: false, request: null });
    expect(result.current.rejectionReason).toBe('');
  });

  it('approve modal defaults to host scope', async () => {
    const approveRequest = vi.fn().mockResolvedValue({ success: true });

    const { result } = renderHook(() =>
      useDomainRequestsDialogs({
        approveRequest,
        rejectRequest: vi.fn(),
        deleteRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.setApproveModal({ open: true, request });
    });

    await act(async () => {
      await result.current.handleApprove();
    });

    expect(approveRequest).toHaveBeenCalledWith({
      id: 'req-1',
      scope: 'host',
      unblock: false,
    });
  });

  it('choosing family sends family scope', async () => {
    const approveRequest = vi.fn().mockResolvedValue({ success: true });

    const { result } = renderHook(() =>
      useDomainRequestsDialogs({
        approveRequest,
        rejectRequest: vi.fn(),
        deleteRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.setApproveModal({ open: true, request });
      result.current.setApproveScope('family');
    });

    await act(async () => {
      await result.current.handleApprove();
    });

    expect(approveRequest).toHaveBeenCalledWith({
      id: 'req-1',
      scope: 'family',
      unblock: false,
    });
  });

  it('admin unblock is sent on approval', async () => {
    const approveRequest = vi.fn().mockResolvedValue({ success: true });

    const { result } = renderHook(() =>
      useDomainRequestsDialogs({
        approveRequest,
        rejectRequest: vi.fn(),
        deleteRequest: vi.fn(),
      })
    );

    act(() => {
      result.current.setApproveModal({ open: true, request });
      result.current.setApproveUnblock(true);
    });

    await act(async () => {
      await result.current.handleApprove();
    });

    expect(approveRequest).toHaveBeenCalledWith({
      id: 'req-1',
      scope: 'host',
      unblock: true,
    });
  });
});
