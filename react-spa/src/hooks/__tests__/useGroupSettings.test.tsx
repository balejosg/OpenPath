import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useGroupSettings } from '../useGroupSettings';

const mockRefetch = vi.fn().mockResolvedValue(undefined);
const mockUpdate = vi.fn();
const groupById = new Map([
  [
    'group-1',
    {
      id: 'group-1',
      name: 'grupo-1',
      displayName: 'Grupo 1',
      enabled: true,
      visibility: 'private',
    },
  ],
]);

vi.mock('../useAllowedGroups', () => ({
  useAllowedGroups: () => ({ groupById, refetch: mockRefetch }),
}));

vi.mock('../../lib/trpc', () => ({
  trpc: { groups: { update: { mutate: (input: unknown): unknown => mockUpdate(input) } } },
}));

describe('useGroupSettings', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockUpdate.mockResolvedValue(undefined);
  });

  it('exposes metadata from the allowed groups cache when active', () => {
    const { result } = renderHook(() => useGroupSettings({ groupId: 'group-1', active: true }));
    expect(result.current.metadata).toEqual({
      displayName: 'Grupo 1',
      status: 'Active',
      visibility: 'private',
    });
  });

  it('returns null metadata when inactive (read-only)', () => {
    const { result } = renderHook(() => useGroupSettings({ groupId: 'group-1', active: false }));
    expect(result.current.metadata).toBeNull();
  });

  it('open() seeds the form; save() calls update + refetch and closes', async () => {
    const { result } = renderHook(() => useGroupSettings({ groupId: 'group-1', active: true }));

    act(() => result.current.open());
    expect(result.current.isOpen).toBe(true);
    expect(result.current.description).toBe('Grupo 1');
    expect(result.current.status).toBe('Active');

    act(() => result.current.setStatus('Inactive'));
    await act(async () => {
      await result.current.save();
    });

    expect(mockUpdate).toHaveBeenCalledWith({
      id: 'group-1',
      displayName: 'Grupo 1',
      enabled: false,
      visibility: 'private',
    });
    expect(mockRefetch).toHaveBeenCalled();
    expect(result.current.isOpen).toBe(false);
    expect(result.current.error).toBeNull();
  });

  it('surfaces a friendly error and keeps the drawer open when update fails', async () => {
    mockUpdate.mockRejectedValueOnce({ data: { code: 'BAD_REQUEST' } });
    const { result } = renderHook(() => useGroupSettings({ groupId: 'group-1', active: true }));

    act(() => result.current.open());
    await act(async () => {
      await result.current.save();
    });

    await waitFor(() =>
      expect(result.current.error).toBe('Review the group settings before saving.')
    );
    expect(result.current.isOpen).toBe(true);
  });
});
