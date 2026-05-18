import { useQuery } from '@tanstack/react-query';
import { useCallback, useEffect, useRef } from 'react';

import type { User } from '../types';
import { trpc } from '../lib/trpc';
import { mapBackendRoleToUserRole } from '../lib/roles';

export const USERS_QUERY_KEY = ['users.list'] as const;

interface ApiUserLike {
  id: string;
  name: string;
  email: string;
  isActive: boolean;
  roles: { role: string }[];
}

function parseApiUserLike(value: unknown): ApiUserLike | null {
  if (!value || typeof value !== 'object') return null;
  const obj = value as Record<string, unknown>;

  const id = obj.id;
  const name = obj.name;
  const email = obj.email;
  const isActive = obj.isActive;

  if (typeof id !== 'string') return null;
  if (typeof name !== 'string') return null;
  if (typeof email !== 'string') return null;
  if (typeof isActive !== 'boolean') return null;

  const rolesRaw = obj.roles;
  const roles: { role: string }[] = [];
  if (Array.isArray(rolesRaw)) {
    for (const r of rolesRaw) {
      if (!r || typeof r !== 'object') continue;
      const role = (r as Record<string, unknown>).role;
      if (typeof role !== 'string') continue;
      roles.push({ role });
    }
  }

  return { id, name, email, isActive, roles };
}

function mapApiUserToUser(u: ApiUserLike): User {
  return {
    id: u.id,
    name: u.name,
    email: u.email,
    roles: Array.isArray(u.roles) ? u.roles.map((r) => mapBackendRoleToUserRole(r.role)) : [],
    status: u.isActive ? 'Active' : 'Inactive',
  };
}

export function mapUnknownApiUserToUser(value: unknown): User | null {
  const parsed = parseApiUserLike(value);
  if (!parsed) return null;
  return mapApiUserToUser(parsed);
}

function mapApiUsersToUsers(apiUsers: unknown): User[] {
  const mapped: User[] = [];

  if (Array.isArray(apiUsers)) {
    for (const u of apiUsers) {
      const next = mapUnknownApiUserToUser(u);
      if (!next) continue;
      mapped.push(next);
    }
  }

  return mapped;
}

export function useUsersList(): {
  users: User[];
  hasData: boolean;
  loading: boolean;
  fetching: boolean;
  error: string | null;
  fetchUsers: () => Promise<void>;
} {
  const query = useQuery({
    queryKey: USERS_QUERY_KEY,
    queryFn: async () => {
      const apiUsers = await trpc.users.list.query();
      return mapApiUsersToUsers(apiUsers);
    },
  });

  const lastUsersRef = useRef<User[]>([]);

  useEffect(() => {
    if (query.data !== undefined) {
      lastUsersRef.current = query.data;
    }
  }, [query.data]);

  const fetchUsers = useCallback(async () => {
    await query.refetch();
  }, [query.refetch]);

  const hasData = query.data !== undefined || lastUsersRef.current.length > 0;
  const users = query.data ?? lastUsersRef.current;
  const loading = query.status === 'pending';
  const fetching = query.fetchStatus === 'fetching';
  const error = query.error ? 'Unable to load users' : null;

  return { users, hasData, loading, fetching, error, fetchUsers };
}
