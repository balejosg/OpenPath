import { waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { renderHookWithQueryClient } from '../../test-utils/query';
import { useDomainRequestsData } from '../useDomainRequestsData';

const { mockList, mockListGroups, mockApprove, mockReject, mockDelete } = vi.hoisted(() => ({
  mockList: vi.fn(),
  mockListGroups: vi.fn(),
  mockApprove: vi.fn(),
  mockReject: vi.fn(),
  mockDelete: vi.fn(),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: {
    requests: {
      list: { query: mockList },
      listGroups: { query: mockListGroups },
      approve: { mutate: mockApprove },
      reject: { mutate: mockReject },
      delete: { mutate: mockDelete },
    },
  },
}));

describe('useDomainRequestsData', () => {
  it('loads requests and groups through react-query', async () => {
    mockList.mockResolvedValueOnce([
      {
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
      },
    ]);
    mockListGroups.mockResolvedValueOnce([{ id: 'group-1', name: 'Grupo 1', path: 'group-1' }]);

    const { result } = renderHookWithQueryClient(() => useDomainRequestsData('all'));

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.requests).toHaveLength(1);
    expect(result.current.groups).toEqual([{ id: 'group-1', name: 'Grupo 1', path: 'group-1' }]);
    expect(result.current.error).toBeNull();
  });

  it('sends scope and unblock in approve mutations', async () => {
    mockList.mockResolvedValue([]);
    mockListGroups.mockResolvedValue([]);
    mockApprove.mockResolvedValue({ success: true });

    const { result } = renderHookWithQueryClient(() => useDomainRequestsData('all'));

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    await result.current.approveRequest({ id: 'req-1', scope: 'family', unblock: true });

    expect(mockApprove).toHaveBeenCalledWith({
      id: 'req-1',
      scope: 'family',
      unblock: true,
    });
  });
});
