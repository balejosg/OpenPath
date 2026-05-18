import { useState, useEffect, useCallback } from 'react';
import { trpc } from '../lib/trpc';
import { getPrimaryRole, getRoleDisplayLabel as getRoleDisplayLabelFromLib } from '../lib/roles';
import { reportError } from '../lib/reportError';

export interface CurrentUser {
  id: string;
  name: string;
  email: string;
  roles: string[];
  capabilities: {
    teacherGroups: boolean;
  };
  initials: string;
  primaryRole: string;
}

interface UseCurrentUserResult {
  user: CurrentUser | null;
  loading: boolean;
  error: string | null;
  refetch: () => Promise<void>;
}

/**
 * Hook to fetch and cache the current authenticated user's profile.
 * Uses trpc.auth.me to get user data.
 */
export function useCurrentUser(): UseCurrentUserResult {
  const [user, setUser] = useState<CurrentUser | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchUser = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await trpc.auth.me.query();
      const profile = response.user;

      // Extract roles from the roles array
      const roles = profile.roles.map((r: { role: string }) => r.role);

      // Get initials from name (first letter of first two words)
      const nameParts = profile.name.split(' ').filter(Boolean);
      const initials = nameParts
        .slice(0, 2)
        .map((n: string) => n[0])
        .join('')
        .toUpperCase();

      const primaryRole = getPrimaryRole(roles);
      const profileWithOptionalCapabilities = profile as {
        capabilities?: { teacherGroups?: boolean };
      };

      setUser({
        id: profile.id,
        name: profile.name,
        email: profile.email,
        roles,
        capabilities: {
          teacherGroups: profileWithOptionalCapabilities.capabilities?.teacherGroups === true,
        },
        initials: initials || '??',
        primaryRole,
      });
    } catch (err) {
      reportError('Failed to fetch current user:', err);
      setError('Unable to load user profile');
      setUser(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchUser();
  }, [fetchUser]);

  return { user, loading, error, refetch: fetchUser };
}

/**
 * Get display label for a role.
 */
export function getRoleDisplayLabel(role: string): string {
  return getRoleDisplayLabelFromLib(role);
}
