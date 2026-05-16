import { logger } from './lib/logger.js';
import { createTRPCPublic, createTRPCWithAuth, getTRPCErrorMessage } from './trpc.js';
import type { LoginResult } from './api-client-types.js';

function usernameToEmail(username: string): string {
  return username.includes('@') ? username : `${username}@dashboard.local`;
}

export async function login(username: string, password: string): Promise<LoginResult> {
  const trpc = createTRPCPublic();
  const email = usernameToEmail(username);

  try {
    const result = await trpc.auth.login.mutate({ email, password });

    return {
      success: true,
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
      user: {
        id: result.user?.id ?? '',
        email: result.user?.email ?? email,
        name: result.user?.name ?? username,
      },
    };
  } catch (error) {
    logger.error('Login failed', { error: getTRPCErrorMessage(error) });
    return {
      success: false,
      error: getTRPCErrorMessage(error),
    };
  }
}

export async function refreshToken(refreshTokenValue: string): Promise<LoginResult> {
  const trpc = createTRPCPublic();

  try {
    const result = await trpc.auth.refresh.mutate({ refreshToken: refreshTokenValue });

    return {
      success: true,
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
    };
  } catch (error) {
    logger.error('Token refresh failed', { error: getTRPCErrorMessage(error) });
    return {
      success: false,
      error: getTRPCErrorMessage(error),
    };
  }
}

export async function logout(accessToken: string, refreshTokenValue: string): Promise<boolean> {
  const trpc = createTRPCWithAuth(accessToken);

  try {
    await trpc.auth.logout.mutate({ refreshToken: refreshTokenValue });
    return true;
  } catch (error) {
    logger.error('Logout failed', { error: getTRPCErrorMessage(error) });
    return false;
  }
}

export async function changePassword(
  accessToken: string,
  currentPassword: string,
  newPassword: string
): Promise<{ success: boolean; error?: string }> {
  const trpc = createTRPCWithAuth(accessToken);

  try {
    await trpc.auth.changePassword.mutate({
      currentPassword,
      newPassword,
    });
    return { success: true };
  } catch (error) {
    logger.error('Change password failed', { error: getTRPCErrorMessage(error) });
    return {
      success: false,
      error: getTRPCErrorMessage(error),
    };
  }
}
