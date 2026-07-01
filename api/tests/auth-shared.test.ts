import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  buildLoginResponse,
  EMAIL_VERIFICATION_REQUIRED_MESSAGE,
  mapRoleInfo,
} from '../src/services/auth-shared.js';

void test('auth-shared maps roles and builds auth payloads', () => {
  const roles = mapRoleInfo([{ role: 'openpath-admin', groupIds: null }]);

  assert.deepEqual(roles, [{ role: 'admin', groupIds: [] }]);
  assert.equal(EMAIL_VERIFICATION_REQUIRED_MESSAGE.length > 0, true);
});

void test('auth-shared builds login responses from token and session environment', () => {
  const previousCookieName = process.env.OPENPATH_ACCESS_TOKEN_COOKIE_NAME;
  try {
    delete process.env.OPENPATH_ACCESS_TOKEN_COOKIE_NAME;
    const tokenResponse = buildLoginResponse(
      {
        accessToken: 'not-a-jwt',
        refreshToken: 'refresh-token',
        expiresIn: '2h',
        tokenType: 'Bearer',
      },
      { id: 'user-1', email: 'user@example.com', name: 'User One' },
      [{ role: 'teacher', groupIds: [] }]
    );

    process.env.OPENPATH_ACCESS_TOKEN_COOKIE_NAME = 'openpath_access';
    const cookieResponse = buildLoginResponse(
      {
        accessToken: 'not-a-jwt',
        refreshToken: 'refresh-token',
        expiresIn: 'invalid',
        tokenType: 'Bearer',
      },
      { id: 'user-1', email: 'user@example.com', name: 'User One' },
      []
    );

    assert.equal(tokenResponse.expiresIn, 7200);
    assert.equal(tokenResponse.sessionTransport, 'token');
    assert.equal(cookieResponse.expiresIn, 86400);
    assert.equal(cookieResponse.sessionTransport, 'cookie');
  } finally {
    if (previousCookieName === undefined) {
      delete process.env.OPENPATH_ACCESS_TOKEN_COOKIE_NAME;
    } else {
      process.env.OPENPATH_ACCESS_TOKEN_COOKIE_NAME = previousCookieName;
    }
  }
});
