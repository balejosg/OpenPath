import { act } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useUsersActions } from '../useUsersActions';
import { renderHookWithQueryClient } from '../../test-utils/query';

let queryClient: ReturnType<typeof renderHookWithQueryClient>['queryClient'] | null = null;

function renderUseUsersActions() {
  const rendered = renderHookWithQueryClient(() => useUsersActions());
  queryClient = rendered.queryClient;
  return rendered;
}

const mockUsersCreateMutate = vi.fn();
const mockUsersUpdateMutate = vi.fn();
const mockUsersDeleteMutate = vi.fn();
const mockGenerateResetTokenMutate = vi.fn();

vi.mock('../../lib/trpc', () => ({
  trpc: {
    auth: {
      generateResetToken: {
        mutate: (input: unknown): unknown => mockGenerateResetTokenMutate(input),
      },
    },
    users: {
      create: { mutate: (input: unknown): unknown => mockUsersCreateMutate(input) },
      update: { mutate: (input: unknown): unknown => mockUsersUpdateMutate(input) },
      delete: { mutate: (input: unknown): unknown => mockUsersDeleteMutate(input) },
    },
  },
}));

describe('useUsersActions', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    queryClient?.clear();
    queryClient = null;
  });

  it('validates required create fields before API call', async () => {
    const { result } = renderUseUsersActions();

    let createResult: Awaited<ReturnType<typeof result.current.handleCreateUser>> = { ok: false };
    await act(async () => {
      createResult = await result.current.handleCreateUser({
        name: '',
        email: 'user@example.com',
        password: 'SecurePass123!',
        role: 'teacher',
      });
    });

    expect(createResult.ok).toBe(false);
    expect(result.current.createError).toBe('Name is required');
    expect(mockUsersCreateMutate).not.toHaveBeenCalled();
  });

  it('maps duplicate-user errors into actionable create message', async () => {
    mockUsersCreateMutate.mockRejectedValueOnce({ data: { code: 'CONFLICT' } });
    const { result } = renderUseUsersActions();

    await act(async () => {
      await result.current.handleCreateUser({
        name: 'User Repetido',
        email: 'dup@example.com',
        password: 'SecurePass123!',
        role: 'teacher',
      });
    });

    expect(result.current.createError).toBe('A user with that email already exists');
  });

  it('shows inline delete error when delete mutation fails', async () => {
    mockUsersDeleteMutate.mockRejectedValueOnce(new Error('backend failure'));
    const { result } = renderUseUsersActions();

    act(() => {
      result.current.requestDeleteUser({ id: 'user-1', name: 'Cannot Delete' });
    });

    let ok = true;
    await act(async () => {
      ok = await result.current.handleConfirmDeleteUser();
    });

    expect(ok).toBe(false);
    expect(result.current.deleteError).toBe('Unable to delete user. Try again.');
  });

  it('maps reset-token permission failures into actionable message', async () => {
    mockGenerateResetTokenMutate.mockRejectedValueOnce({ data: { code: 'FORBIDDEN' } });
    const { result } = renderUseUsersActions();

    let resetResult: Awaited<ReturnType<typeof result.current.handleGenerateResetToken>> = {
      ok: false,
    };
    await act(async () => {
      resetResult = await result.current.handleGenerateResetToken({ email: 'admin@example.com' });
    });

    expect(resetResult.ok).toBe(false);
    expect(result.current.resetError).toBe('You do not have permission to reset passwords');
  });
});
