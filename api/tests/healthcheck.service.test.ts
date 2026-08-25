import assert from 'node:assert';
import test from 'node:test';

const HealthcheckService = await import('../src/services/healthcheck.service.js');

await test('healthcheck service returns readiness status shape', async () => {
  const previousJwtSecret = process.env.JWT_SECRET;
  process.env.JWT_SECRET = 'test-jwt-secret';

  try {
    const result = await HealthcheckService.getReadinessStatus();
    assert.strictEqual(result.service, 'openpath-api');
    assert.ok(typeof result.status === 'string');
    assert.ok(typeof result.uptime === 'number');
    assert.ok(typeof result.responseTime === 'string');
    assert.ok(result.checks.auth !== undefined);
    assert.ok(result.checks.storage !== undefined);
    assert.equal(result.checks.windowsOfflineInstaller?.status, 'not_configured');
  } finally {
    if (previousJwtSecret === undefined) {
      Reflect.deleteProperty(process.env, 'JWT_SECRET');
    } else {
      process.env.JWT_SECRET = previousJwtSecret;
    }
  }
});
