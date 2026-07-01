import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  getCurrentUser,
  isAdmin,
  isTeacher,
  isStudent,
  login,
  loginWithGoogle,
  logout,
  onAuthChange,
  User,
} from '../auth';
import {
  ACCESS_TOKEN_KEY,
  COOKIE_SESSION_MARKER,
  REFRESH_TOKEN_KEY,
  USER_KEY,
} from '../auth-storage';

const { loginMutateMock, googleLoginMutateMock, logoutMutateMock } = vi.hoisted(() => ({
  loginMutateMock: vi.fn(),
  googleLoginMutateMock: vi.fn(),
  logoutMutateMock: vi.fn().mockResolvedValue(undefined),
}));

vi.mock('../trpc', () => ({
  trpc: {
    auth: {
      login: {
        mutate: loginMutateMock,
      },
      googleLogin: {
        mutate: googleLoginMutateMock,
      },
      logout: {
        mutate: logoutMutateMock,
      },
    },
  },
}));

describe('Auth functions', () => {
  beforeEach(() => {
    localStorage.clear();
    vi.clearAllMocks();
    loginMutateMock.mockResolvedValue({
      accessToken: 'token',
      refreshToken: 'refresh',
      sessionTransport: 'token',
      user: {
        id: '1',
        email: 'teacher@example.com',
        name: 'Teacher',
        roles: [{ role: 'teacher' }],
      },
    });
    googleLoginMutateMock.mockResolvedValue({
      accessToken: 'google-token',
      refreshToken: 'google-refresh',
      sessionTransport: 'cookie',
      user: {
        id: '2',
        email: 'google@example.com',
        name: 'Google User',
        roles: [{ role: 'admin' }],
      },
    });
    logoutMutateMock.mockResolvedValue(undefined);
  });

  describe('getCurrentUser', () => {
    it('should return null if no user in localStorage', () => {
      expect(getCurrentUser()).toBeNull();
    });

    it('should return user object if valid JSON in localStorage', () => {
      const user: User = {
        id: '1',
        email: 'test@example.com',
        name: 'Test User',
        roles: [{ role: 'user' }],
      };
      localStorage.setItem(USER_KEY, JSON.stringify(user));
      expect(getCurrentUser()).toEqual(user);
    });

    it('should return null if invalid JSON in localStorage', () => {
      localStorage.setItem(USER_KEY, 'invalid-json');
      expect(getCurrentUser()).toBeNull();
    });
  });

  describe('isAdmin', () => {
    it('should return true if user has admin role', () => {
      const user: User = {
        id: '1',
        email: 'admin@example.com',
        name: 'Admin',
        roles: [{ role: 'admin' }],
      };
      localStorage.setItem(USER_KEY, JSON.stringify(user));
      expect(isAdmin()).toBe(true);
    });

    it('should treat legacy openpath-admin role as admin', () => {
      const user: User = {
        id: '1',
        email: 'admin@example.com',
        name: 'Admin',
        roles: [{ role: 'openpath-admin' }],
      };
      localStorage.setItem(USER_KEY, JSON.stringify(user));
      expect(isAdmin()).toBe(true);
    });

    it('should return false if user does not have admin role', () => {
      const user: User = {
        id: '1',
        email: 'user@example.com',
        name: 'User',
        roles: [{ role: 'teacher' }],
      };
      localStorage.setItem(USER_KEY, JSON.stringify(user));
      expect(isAdmin()).toBe(false);
    });
  });

  describe('isTeacher', () => {
    it('should return true if user has teacher role', () => {
      const user: User = {
        id: '1',
        email: 'teacher@example.com',
        name: 'Teacher',
        roles: [{ role: 'teacher' }],
      };
      localStorage.setItem(USER_KEY, JSON.stringify(user));
      expect(isTeacher()).toBe(true);
    });
  });

  describe('isStudent', () => {
    it('should return true if user has student role', () => {
      const user: User = {
        id: '1',
        email: 'student@example.com',
        name: 'Student',
        roles: [{ role: 'student' }],
      };
      localStorage.setItem(USER_KEY, JSON.stringify(user));
      expect(isStudent()).toBe(true);
    });

    it('should treat legacy user/viewer roles as student', () => {
      const user: User = {
        id: '1',
        email: 'student@example.com',
        name: 'Student',
        roles: [{ role: 'user' }, { role: 'viewer' }],
      };
      localStorage.setItem(USER_KEY, JSON.stringify(user));
      expect(isStudent()).toBe(true);
    });
  });

  describe('logout', () => {
    it('stores token-based sessions after login', async () => {
      const user = await login('teacher@example.com', 'secret');

      expect(loginMutateMock).toHaveBeenCalledWith({
        email: 'teacher@example.com',
        password: 'secret',
      });
      expect(user).toEqual({
        id: '1',
        email: 'teacher@example.com',
        name: 'Teacher',
        roles: [{ role: 'teacher' }],
      });
      expect(localStorage.getItem(ACCESS_TOKEN_KEY)).toBe('token');
      expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBe('refresh');
    });

    it('stores cookie-backed sessions after Google login', async () => {
      const user = await loginWithGoogle('google-id-token');

      expect(googleLoginMutateMock).toHaveBeenCalledWith({
        idToken: 'google-id-token',
      });
      expect(user).toEqual({
        id: '2',
        email: 'google@example.com',
        name: 'Google User',
        roles: [{ role: 'admin' }],
      });
      expect(localStorage.getItem(ACCESS_TOKEN_KEY)).toBe(COOKIE_SESSION_MARKER);
      expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBeNull();
      expect(localStorage.getItem(USER_KEY)).toBe(
        JSON.stringify({
          id: '2',
          email: 'google@example.com',
          name: 'Google User',
          roles: [{ role: 'admin' }],
        })
      );
    });

    it('calls auth.logout and clears session storage before reload', async () => {
      localStorage.setItem(ACCESS_TOKEN_KEY, 'token');
      localStorage.setItem(REFRESH_TOKEN_KEY, 'refresh');
      localStorage.setItem(USER_KEY, JSON.stringify({ id: '1' }));

      logout();
      await vi.waitFor(() => {
        expect(logoutMutateMock).toHaveBeenCalledTimes(1);
        expect(localStorage.getItem(ACCESS_TOKEN_KEY)).toBeNull();
        expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBeNull();
        expect(localStorage.getItem(USER_KEY)).toBeNull();
      });
    });

    it('omits refresh token revocation when the browser is using cookie sessions', async () => {
      localStorage.setItem(ACCESS_TOKEN_KEY, COOKIE_SESSION_MARKER);
      localStorage.setItem(REFRESH_TOKEN_KEY, 'stale-refresh');
      localStorage.setItem(USER_KEY, JSON.stringify({ id: '1' }));

      logout();
      await vi.waitFor(() => {
        expect(logoutMutateMock).toHaveBeenCalledWith({ refreshToken: undefined });
        expect(localStorage.getItem(ACCESS_TOKEN_KEY)).toBeNull();
        expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBeNull();
      });
    });

    it('still clears session storage when auth.logout fails', async () => {
      logoutMutateMock.mockRejectedValueOnce(new Error('network failure'));
      localStorage.setItem(ACCESS_TOKEN_KEY, 'token');
      localStorage.setItem(REFRESH_TOKEN_KEY, 'refresh');
      localStorage.setItem(USER_KEY, JSON.stringify({ id: '1' }));

      logout();
      await vi.waitFor(() => {
        expect(logoutMutateMock).toHaveBeenCalledTimes(1);
        expect(localStorage.getItem(ACCESS_TOKEN_KEY)).toBeNull();
        expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBeNull();
        expect(localStorage.getItem(USER_KEY)).toBeNull();
      });
    });
  });

  describe('onAuthChange', () => {
    it('subscribes to storage updates for auth keys and unsubscribes cleanly', () => {
      const callback = vi.fn();
      const unsubscribe = onAuthChange(callback);

      window.dispatchEvent(new StorageEvent('storage', { key: 'other-key' }));
      expect(callback).not.toHaveBeenCalled();

      window.dispatchEvent(new StorageEvent('storage', { key: ACCESS_TOKEN_KEY }));
      window.dispatchEvent(new StorageEvent('storage', { key: USER_KEY }));
      expect(callback).toHaveBeenCalledTimes(2);

      unsubscribe();
      window.dispatchEvent(new StorageEvent('storage', { key: ACCESS_TOKEN_KEY }));
      expect(callback).toHaveBeenCalledTimes(2);
    });
  });
});
