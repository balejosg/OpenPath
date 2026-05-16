import { trpc } from './trpc';
import {
  ACCESS_TOKEN_KEY,
  COOKIE_SESSION_MARKER,
  USER_KEY,
  clearAuthStorage,
  getAccessToken,
  getRefreshToken,
  getUserJson,
  setAuthSession,
} from './auth-storage';
import type { UserRole } from '@openpath/shared';
import type { LegacyUserRole } from '@openpath/shared/roles';
import { userHasRole } from './auth-role-compat';

export interface User {
  id: string;
  email: string;
  name: string;
  roles: {
    role: UserRole | LegacyUserRole;
    groupIds?: string[];
  }[];
  capabilities?: {
    teacherGroups?: boolean;
  };
}

/**
 * Obtiene el usuario actual desde localStorage.
 */
export function getCurrentUser(): User | null {
  const userJson = getUserJson();
  if (!userJson) return null;
  try {
    return JSON.parse(userJson) as User;
  } catch {
    return null;
  }
}

/**
 * Verifica si el usuario está autenticado.
 */
export function isAuthenticated(): boolean {
  return !!getAccessToken();
}

/**
 * Verifica si el usuario es admin.
 */
export function isAdmin(): boolean {
  const user = getCurrentUser();
  return userHasRole(user?.roles, 'admin');
}

/**
 * Verifica si el usuario es profesor.
 */
export function isTeacher(): boolean {
  const user = getCurrentUser();
  return userHasRole(user?.roles, 'teacher');
}

/**
 * Verifica si el usuario es estudiante.
 */
export function isStudent(): boolean {
  const user = getCurrentUser();
  return userHasRole(user?.roles, 'student');
}

/**
 * Capability: allow teachers to create/manage their own groups in the UI.
 * Derived by the API and cached with the authenticated user; older cached users default to false.
 */
export function isTeacherGroupsFeatureEnabled(): boolean {
  return getCurrentUser()?.capabilities?.teacherGroups === true;
}

/**
 * Realiza login con email y password.
 */
export async function login(email: string, password: string): Promise<User> {
  const result = await trpc.auth.login.mutate({ email, password });

  // Guardar tokens
  setAuthSession(result.accessToken, result.refreshToken, result.user, result.sessionTransport);

  return result.user;
}

/**
 * Realiza login con Google.
 */
export async function loginWithGoogle(idToken: string): Promise<User> {
  const result = await trpc.auth.googleLogin.mutate({ idToken });

  // Guardar tokens
  setAuthSession(result.accessToken, result.refreshToken, result.user, result.sessionTransport);

  return result.user;
}

/**
 * Cierra la sesión actual.
 */
export function logout(): void {
  const accessToken = getAccessToken();
  const refreshToken =
    accessToken && accessToken !== COOKIE_SESSION_MARKER
      ? (getRefreshToken() ?? undefined)
      : undefined;
  void trpc.auth.logout
    .mutate({ refreshToken })
    .catch(() => {
      // Ignore network/auth errors during logout cleanup.
    })
    .finally(() => {
      clearAuthStorage();

      // Recargar para limpiar estado
      window.location.reload();
    });
}

/**
 * Escucha cambios de autenticación desde otras pestañas.
 */
export function onAuthChange(callback: () => void): () => void {
  const handler = (e: StorageEvent) => {
    if (e.key === ACCESS_TOKEN_KEY || e.key === USER_KEY) {
      callback();
    }
  };
  window.addEventListener('storage', handler);
  return () => {
    window.removeEventListener('storage', handler);
  };
}
