import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useCallback, useState } from 'react';

import type { User } from '../types';
import type { CreateUserRole } from '../lib/roles';
import { resolveTrpcErrorMessage } from '../lib/error-utils';
import { trpc } from '../lib/trpc';
import { reportError } from '../lib/reportError';
import { mapUnknownApiUserToUser, USERS_QUERY_KEY } from './useUsersList';

export interface UserDeleteTarget {
  id: string;
  name: string;
}

interface CreateUserInput {
  name: string;
  email: string;
  password: string;
  role: CreateUserRole;
}

type CreatedUser = Awaited<ReturnType<typeof trpc.users.create.mutate>>;

export type CreateUserResult = { ok: true; user: CreatedUser } | { ok: false };

interface UpdateUserInput {
  id: string;
  name: string;
  email: string;
}

interface GenerateResetTokenInput {
  email: string;
}

export const useUsersActions = () => {
  const queryClient = useQueryClient();

  const cancelUsersListQuery = useCallback(async () => {
    await queryClient.cancelQueries({ queryKey: USERS_QUERY_KEY });
  }, [queryClient]);

  const invalidateUsersList = useCallback(() => {
    void queryClient.invalidateQueries({ queryKey: USERS_QUERY_KEY });
  }, [queryClient]);

  const refreshUsersListFromServer = useCallback(async () => {
    await cancelUsersListQuery();
    invalidateUsersList();
  }, [cancelUsersListQuery, invalidateUsersList]);

  const deferredInvalidate = useCallback(() => {
    // Yield to let React render the optimistic data before triggering
    // a background refetch. If the refetch fails, the rendering logic
    // now shows data independently of error state, so the grid survives.
    window.setTimeout(() => {
      invalidateUsersList();
    }, 0);
  }, [invalidateUsersList]);

  const mutateUsersCache = useCallback(
    (mutate: (users: User[]) => User[]) => {
      // Cancel any in-flight list query synchronously so its stale response
      // cannot overwrite the optimistic data we are about to set.
      void queryClient.cancelQueries({ queryKey: USERS_QUERY_KEY }, { revert: false });
      queryClient.setQueryData<User[]>(USERS_QUERY_KEY, (prev) => {
        const prevUsers = Array.isArray(prev) ? prev : [];
        return mutate(prevUsers);
      });
      deferredInvalidate();
    },
    [deferredInvalidate, queryClient]
  );

  const [createError, setCreateError] = useState('');
  const [deleteError, setDeleteError] = useState('');
  const [deleteTarget, setDeleteTarget] = useState<UserDeleteTarget | null>(null);
  const [resetError, setResetError] = useState('');

  const createMutation = useMutation({
    mutationFn: async (input: CreateUserInput) => {
      return await trpc.users.create.mutate(input);
    },
  });

  const updateMutation = useMutation({
    mutationFn: async (input: UpdateUserInput) => {
      return await trpc.users.update.mutate(input);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: async (input: { id: string }) => {
      return await trpc.users.delete.mutate(input);
    },
  });

  const resetTokenMutation = useMutation({
    mutationFn: async (input: GenerateResetTokenInput) => {
      return await trpc.auth.generateResetToken.mutate(input);
    },
  });

  const saving = createMutation.status === 'pending' || updateMutation.status === 'pending';
  const deleting = deleteMutation.status === 'pending';
  const resettingPassword = resetTokenMutation.status === 'pending';

  const upsertUserInCache = useCallback(
    async (apiUser: unknown) => {
      const mapped = mapUnknownApiUserToUser(apiUser);
      if (!mapped) {
        // Can't map the response — cancel any in-flight list query so we can
        // force a fresh refetch that will include the newly created user.
        await refreshUsersListFromServer();
        return;
      }

      mutateUsersCache((prevUsers) => {
        return [mapped, ...prevUsers.filter((u) => u.id !== mapped.id)];
      });
    },
    [mutateUsersCache, refreshUsersListFromServer]
  );

  const updateUserInCache = useCallback(
    async (apiUser: unknown) => {
      const mapped = mapUnknownApiUserToUser(apiUser);
      if (!mapped) {
        await refreshUsersListFromServer();
        return;
      }

      mutateUsersCache((prevUsers) => {
        const idx = prevUsers.findIndex((u) => u.id === mapped.id);
        if (idx === -1) return [mapped, ...prevUsers];
        const next = [...prevUsers];
        next[idx] = mapped;
        return next;
      });
    },
    [mutateUsersCache, refreshUsersListFromServer]
  );

  const handleSaveEdit = useCallback(
    async (input: UpdateUserInput): Promise<boolean> => {
      try {
        const updated = await updateMutation.mutateAsync(input);
        void updateUserInCache(updated);
        return true;
      } catch (err) {
        reportError('Failed to update user:', err);
        return false;
      }
    },
    [updateMutation, updateUserInCache]
  );

  const handleCreateUser = useCallback(
    async (input: CreateUserInput): Promise<CreateUserResult> => {
      if (!input.name.trim()) {
        setCreateError('Name is required');
        return { ok: false };
      }
      if (!input.email.trim()) {
        setCreateError('Email is required');
        return { ok: false };
      }
      if (!input.password.trim() || input.password.length < 8) {
        setCreateError('Password must be at least 8 characters');
        return { ok: false };
      }

      try {
        setCreateError('');
        const user = await createMutation.mutateAsync({
          name: input.name.trim(),
          email: input.email.trim(),
          password: input.password,
          role: input.role,
        });

        void upsertUserInCache(user);
        return { ok: true, user };
      } catch (err) {
        reportError('Failed to create user:', err);
        setCreateError(
          resolveTrpcErrorMessage(err, {
            badRequest: 'Email is invalid',
            conflict: 'A user with that email already exists',
            forbidden: 'You do not have permission to create users',
            unauthorized: 'You do not have permission to create users',
            fallback: 'Unable to create user. Try again.',
          })
        );
        return { ok: false };
      }
    },
    [createMutation, upsertUserInCache]
  );

  const requestDeleteUser = useCallback((target: UserDeleteTarget) => {
    setDeleteError('');
    setDeleteTarget(target);
  }, []);

  const clearDeleteState = useCallback(() => {
    setDeleteError('');
    setDeleteTarget(null);
  }, []);

  const clearResetError = useCallback(() => {
    setResetError('');
  }, []);

  const handleConfirmDeleteUser = useCallback(async (): Promise<boolean> => {
    if (!deleteTarget) return false;

    try {
      setDeleteError('');
      await deleteMutation.mutateAsync({ id: deleteTarget.id });

      mutateUsersCache((prevUsers) => prevUsers.filter((u) => u.id !== deleteTarget.id));

      setDeleteTarget(null);
      return true;
    } catch (err) {
      reportError('Failed to delete user:', err);
      setDeleteError('Unable to delete user. Try again.');
      return false;
    }
  }, [deleteTarget, deleteMutation, mutateUsersCache]);

  const handleGenerateResetToken = useCallback(
    async (
      input: GenerateResetTokenInput
    ): Promise<{ ok: true; token: string } | { ok: false }> => {
      try {
        setResetError('');
        const result = await resetTokenMutation.mutateAsync(input);
        return { ok: true, token: result.token };
      } catch (err) {
        reportError('Failed to generate reset token:', err);
        setResetError(
          resolveTrpcErrorMessage(err, {
            forbidden: 'You do not have permission to reset passwords',
            unauthorized: 'You do not have permission to reset passwords',
            notFound: 'No user exists with that email',
            fallback: 'Unable to generate token. Try again.',
          })
        );
        return { ok: false };
      }
    },
    [resetTokenMutation]
  );

  return {
    saving,
    deleting,
    resettingPassword,
    createError,
    setCreateError,
    deleteError,
    deleteTarget,
    resetError,
    handleSaveEdit,
    handleCreateUser,
    requestDeleteUser,
    clearDeleteState,
    handleConfirmDeleteUser,
    clearResetError,
    handleGenerateResetToken,
  };
};
