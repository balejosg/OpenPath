import type express from 'express';
import type { Request, Response } from 'express';

import { changePassword, login, logout } from './api-client.js';
import { asyncHandler, getAccessToken, getToken, requireAuth } from './app-middleware.js';

export interface RegisterAuthRoutesOptions {
  cookieSecure: boolean;
}

export function registerAuthRoutes(app: express.Express, options: RegisterAuthRoutesOptions): void {
  app.post(
    '/api/auth/login',
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const { username, password } = req.body as Record<string, unknown>;
      if (typeof username !== 'string' || typeof password !== 'string') {
        res.status(400).json({ error: 'Invalid request' });
        return;
      }

      const result = await login(username, password);

      if (result.success && result.accessToken && result.refreshToken) {
        res.cookie('access_token', result.accessToken, {
          httpOnly: true,
          secure: options.cookieSecure,
          signed: true,
          maxAge: 24 * 60 * 60 * 1000,
          sameSite: 'strict',
        });
        res.cookie('refresh_token', result.refreshToken, {
          httpOnly: true,
          secure: options.cookieSecure,
          signed: true,
          maxAge: 7 * 24 * 60 * 60 * 1000,
          sameSite: 'strict',
        });

        res.json({ success: true, user: result.user });
      } else {
        res.status(401).json({ error: result.error ?? 'Invalid credentials' });
      }
    })
  );

  app.post(
    '/api/auth/logout',
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const accessToken = req.signedCookies.access_token as string | undefined;
      const refreshToken = req.signedCookies.refresh_token as string | undefined;

      if (accessToken && refreshToken) {
        await logout(accessToken, refreshToken);
      }

      res.clearCookie('access_token');
      res.clearCookie('refresh_token');
      res.json({ success: true });
    })
  );

  app.get('/api/auth/check', (req: Request, res: Response): void => {
    res.json({ authenticated: getToken(req) !== null });
  });

  app.post(
    '/api/auth/change-password',
    requireAuth,
    asyncHandler(async (req: Request, res: Response): Promise<void> => {
      const { currentPassword, newPassword } = req.body as Record<string, unknown>;
      if (
        typeof currentPassword !== 'string' ||
        typeof newPassword !== 'string' ||
        newPassword.length < 8
      ) {
        res.status(400).json({ error: 'Password must be at least 8 characters' });
        return;
      }

      const result = await changePassword(getAccessToken(req), currentPassword, newPassword);
      if (result.success) {
        res.json({ success: true });
      } else {
        res.status(400).json({ error: result.error });
      }
    })
  );
}
