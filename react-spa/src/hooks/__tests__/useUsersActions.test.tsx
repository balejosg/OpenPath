import { act } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useUsersActions } from '../useUsersActions';
import { renderHookWithQueryClient } from '../../test-utils/query';
import { USERS_QUERY_KEY } from '../useUsersList';
import { UserRole } from '../../types';
import type { User } from '../../types';

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

  it('validates required email before API call', async () => {
    const { result } = renderUseUsersActions();

    let createResult: Awaited<ReturnType<typeof result.current.handleCreateUser>> = { ok: false };
    await act(async () => {
      createResult = await result.current.handleCreateUser({
        name: 'Test User',
        email: '',
        password: 'SecurePass123!',
        role: 'teacher',
      });
    });

    expect(createResult.ok).toBe(false);
    expect(result.current.createError).toBe('Email is required');
    expect(mockUsersCreateMutate).not.toHaveBeenCalled();
  });

  it('validates password minimum length before API call', async () => {
    const { result } = renderUseUsersActions();

    let createResult: Awaited<ReturnType<typeof result.current.handleCreateUser>> = { ok: false };
    await act(async () => {
      createResult = await result.current.handleCreateUser({
        name: 'Test User',
        email: 'test@example.com',
        password: 'short',
        role: 'teacher',
      });
    });

    expect(createResult.ok).toBe(false);
    expect(result.current.createError).toBe('Password must be at least 8 characters');
    expect(mockUsersCreateMutate).not.toHaveBeenCalled();
  });

  it('creates user successfully and returns ok:true with user data', async () => {
    const apiUser = {
      id: 'new-user-1',
      name: 'New Teacher',
      email: 'teacher@example.com',
      isActive: true,
      roles: [{ role: 'teacher' }],
    };
    mockUsersCreateMutate.mockResolvedValueOnce(apiUser);
    const { result } = renderUseUsersActions();

    let createResult: Awaited<ReturnType<typeof result.current.handleCreateUser>> = { ok: false };
    await act(async () => {
      createResult = await result.current.handleCreateUser({
        name: 'New Teacher',
        email: 'teacher@example.com',
        password: 'SecurePass123!',
        role: 'teacher',
      });
    });

    expect(createResult.ok).toBe(true);
    expect(result.current.createError).toBe('');
    expect(mockUsersCreateMutate).toHaveBeenCalledWith({
      name: 'New Teacher',
      email: 'teacher@example.com',
      password: 'SecurePass123!',
      role: 'teacher',
    });
  });

  it('handles create with unmappable API response by triggering refresh', async () => {
    mockUsersCreateMutate.mockResolvedValueOnce({ unexpected: true });
    const { result } = renderUseUsersActions();

    let createResult: Awaited<ReturnType<typeof result.current.handleCreateUser>> = { ok: false };
    await act(async () => {
      createResult = await result.current.handleCreateUser({
        name: 'Test User',
        email: 'test@example.com',
        password: 'SecurePass123!',
        role: 'admin',
      });
    });

    expect(createResult.ok).toBe(true);
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

  it('maps bad-request create errors into email-invalid message', async () => {
    mockUsersCreateMutate.mockRejectedValueOnce({ data: { code: 'BAD_REQUEST' } });
    const { result } = renderUseUsersActions();

    await act(async () => {
      await result.current.handleCreateUser({
        name: 'Test',
        email: 'bad-email',
        password: 'SecurePass123!',
        role: 'teacher',
      });
    });

    expect(result.current.createError).toBe('Email is invalid');
  });

  it('maps forbidden create errors into permission message', async () => {
    mockUsersCreateMutate.mockRejectedValueOnce({ data: { code: 'FORBIDDEN' } });
    const { result } = renderUseUsersActions();

    await act(async () => {
      await result.current.handleCreateUser({
        name: 'Test',
        email: 'test@example.com',
        password: 'SecurePass123!',
        role: 'admin',
      });
    });

    expect(result.current.createError).toBe('You do not have permission to create users');
  });

  it('maps unknown create errors into fallback message', async () => {
    mockUsersCreateMutate.mockRejectedValueOnce(new Error('unexpected'));
    const { result } = renderUseUsersActions();

    await act(async () => {
      await result.current.handleCreateUser({
        name: 'Test',
        email: 'test@example.com',
        password: 'SecurePass123!',
        role: 'teacher',
      });
    });

    expect(result.current.createError).toBe('Unable to create user. Try again.');
  });

  it('saves edit successfully and returns true', async () => {
    const updatedUser = {
      id: 'user-1',
      name: 'Updated Name',
      email: 'updated@example.com',
      isActive: true,
      roles: [{ role: 'teacher' }],
    };
    mockUsersUpdateMutate.mockResolvedValueOnce(updatedUser);
    const { result } = renderUseUsersActions();

    let saveResult = false;
    await act(async () => {
      saveResult = await result.current.handleSaveEdit({
        id: 'user-1',
        name: 'Updated Name',
        email: 'updated@example.com',
      });
    });

    expect(saveResult).toBe(true);
    expect(mockUsersUpdateMutate).toHaveBeenCalledWith({
      id: 'user-1',
      name: 'Updated Name',
      email: 'updated@example.com',
    });
  });

  it('returns false when save edit fails', async () => {
    mockUsersUpdateMutate.mockRejectedValueOnce(new Error('update failed'));
    const { result } = renderUseUsersActions();

    let saveResult = true;
    await act(async () => {
      saveResult = await result.current.handleSaveEdit({
        id: 'user-1',
        name: 'Name',
        email: 'user@example.com',
      });
    });

    expect(saveResult).toBe(false);
  });

  it('saves edit with unmappable API response triggers refresh', async () => {
    mockUsersUpdateMutate.mockResolvedValueOnce({ unexpected: true });
    const { result } = renderUseUsersActions();

    let saveResult = false;
    await act(async () => {
      saveResult = await result.current.handleSaveEdit({
        id: 'user-1',
        name: 'Name',
        email: 'user@example.com',
      });
    });

    expect(saveResult).toBe(true);
  });

  it('updates user in-place in the cache when the user already exists there', async () => {
    vi.useFakeTimers();
    const existingUser: User = {
      id: 'user-existing',
      name: 'Original Name',
      email: 'original@example.com',
      roles: [UserRole.TEACHER],
      status: 'Active',
    };
    const updatedApiUser = {
      id: 'user-existing',
      name: 'Updated Name',
      email: 'updated@example.com',
      isActive: true,
      roles: [{ role: 'admin' }],
    };
    mockUsersUpdateMutate.mockResolvedValueOnce(updatedApiUser);

    const { result, queryClient: qc } = renderUseUsersActions();

    act(() => {
      qc.setQueryData<User[]>(USERS_QUERY_KEY, [existingUser]);
    });

    let saveResult = false;
    await act(async () => {
      saveResult = await result.current.handleSaveEdit({
        id: 'user-existing',
        name: 'Updated Name',
        email: 'updated@example.com',
      });
    });

    expect(saveResult).toBe(true);
    const cached = qc.getQueryData<User[]>(USERS_QUERY_KEY);
    expect(cached).toHaveLength(1);
    expect(cached?.[0]?.name).toBe('Updated Name');
    expect(cached?.[0]?.id).toBe('user-existing');

    vi.useRealTimers();
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

  it('handleConfirmDeleteUser returns false when no deleteTarget is set', async () => {
    const { result } = renderUseUsersActions();

    let ok = true;
    await act(async () => {
      ok = await result.current.handleConfirmDeleteUser();
    });

    expect(ok).toBe(false);
    expect(mockUsersDeleteMutate).not.toHaveBeenCalled();
  });

  it('deletes user successfully and returns true', async () => {
    mockUsersDeleteMutate.mockResolvedValueOnce({ success: true });
    const { result } = renderUseUsersActions();

    act(() => {
      result.current.requestDeleteUser({ id: 'user-to-delete', name: 'Target User' });
    });

    expect(result.current.deleteTarget).toEqual({ id: 'user-to-delete', name: 'Target User' });

    let ok = false;
    await act(async () => {
      ok = await result.current.handleConfirmDeleteUser();
    });

    expect(ok).toBe(true);
    expect(result.current.deleteTarget).toBeNull();
    expect(mockUsersDeleteMutate).toHaveBeenCalledWith({ id: 'user-to-delete' });
  });

  it('clearDeleteState resets deleteError and deleteTarget', () => {
    const { result } = renderUseUsersActions();

    act(() => {
      result.current.requestDeleteUser({ id: 'user-1', name: 'Test' });
    });

    expect(result.current.deleteTarget).toEqual({ id: 'user-1', name: 'Test' });

    act(() => {
      result.current.clearDeleteState();
    });

    expect(result.current.deleteTarget).toBeNull();
    expect(result.current.deleteError).toBe('');
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

  it('generates reset token successfully and returns ok:true with token', async () => {
    mockGenerateResetTokenMutate.mockResolvedValueOnce({ token: 'secret-reset-token' });
    const { result } = renderUseUsersActions();

    const results: Awaited<ReturnType<typeof result.current.handleGenerateResetToken>>[] = [];
    await act(async () => {
      results.push(await result.current.handleGenerateResetToken({ email: 'user@example.com' }));
    });

    const resetResult = results[0] as { ok: true; token: string } | { ok: false } | undefined;
    expect(resetResult).toBeDefined();
    // Access token through cast to avoid discriminated union narrowing issues
    const successResult = resetResult as { ok: true; token: string };
    expect(successResult.ok).toBe(true);
    expect(successResult.token).toBe('secret-reset-token');
    expect(result.current.resetError).toBe('');
  });

  it('maps not-found reset token error into user-friendly message', async () => {
    mockGenerateResetTokenMutate.mockRejectedValueOnce({ data: { code: 'NOT_FOUND' } });
    const { result } = renderUseUsersActions();

    await act(async () => {
      await result.current.handleGenerateResetToken({ email: 'ghost@example.com' });
    });

    expect(result.current.resetError).toBe('No user exists with that email');
  });

  it('maps unknown reset token errors into fallback message', async () => {
    mockGenerateResetTokenMutate.mockRejectedValueOnce(new Error('server error'));
    const { result } = renderUseUsersActions();

    await act(async () => {
      await result.current.handleGenerateResetToken({ email: 'user@example.com' });
    });

    expect(result.current.resetError).toBe('Unable to generate token. Try again.');
  });

  it('clearResetError clears the reset error state', async () => {
    mockGenerateResetTokenMutate.mockRejectedValueOnce({ data: { code: 'NOT_FOUND' } });
    const { result } = renderUseUsersActions();

    await act(async () => {
      await result.current.handleGenerateResetToken({ email: 'ghost@example.com' });
    });

    expect(result.current.resetError).toBe('No user exists with that email');

    act(() => {
      result.current.clearResetError();
    });

    expect(result.current.resetError).toBe('');
  });

  it('setCreateError clears the create error state', async () => {
    const { result } = renderUseUsersActions();

    await act(async () => {
      await result.current.handleCreateUser({
        name: '',
        email: 'user@example.com',
        password: 'SecurePass123!',
        role: 'teacher',
      });
    });

    expect(result.current.createError).toBe('Name is required');

    act(() => {
      result.current.setCreateError('');
    });

    expect(result.current.createError).toBe('');
  });

  it('requestDeleteUser clears any prior deleteError before setting target', async () => {
    mockUsersDeleteMutate.mockRejectedValueOnce(new Error('fail'));
    const { result } = renderUseUsersActions();

    act(() => {
      result.current.requestDeleteUser({ id: 'u1', name: 'First' });
    });
    await act(async () => {
      await result.current.handleConfirmDeleteUser();
    });

    expect(result.current.deleteError).toBe('Unable to delete user. Try again.');

    act(() => {
      result.current.requestDeleteUser({ id: 'u2', name: 'Second' });
    });

    expect(result.current.deleteError).toBe('');
    expect(result.current.deleteTarget).toEqual({ id: 'u2', name: 'Second' });
  });
});
