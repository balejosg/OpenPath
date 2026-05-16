import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { resolveDashboardCookieSecret } from '../src/app.js';

void describe('dashboard cookie secret configuration', () => {
  void it('fails production startup when COOKIE_SECRET is missing', () => {
    assert.throws(
      () => resolveDashboardCookieSecret(undefined, 'production'),
      /COOKIE_SECRET must be set to a non-default value in production/
    );
  });

  void it('fails production startup when COOKIE_SECRET is the development default', () => {
    assert.throws(
      () => resolveDashboardCookieSecret('dashboard-dev-secret', 'production'),
      /COOKIE_SECRET must be set to a non-default value in production/
    );
  });

  void it('keeps the development default outside production', () => {
    assert.strictEqual(
      resolveDashboardCookieSecret(undefined, 'development'),
      'dashboard-dev-secret'
    );
    assert.strictEqual(resolveDashboardCookieSecret(undefined, 'test'), 'dashboard-dev-secret');
  });

  void it('uses an explicit production secret when provided', () => {
    assert.strictEqual(
      resolveDashboardCookieSecret('strong-production-cookie-secret', 'production'),
      'strong-production-cookie-secret'
    );
  });
});
