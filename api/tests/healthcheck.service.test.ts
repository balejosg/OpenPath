import assert from 'node:assert';
import test from 'node:test';

const HealthcheckService = await import('../src/services/healthcheck.service.js');

void test('healthcheck service returns readiness status shape', async () => {
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

void test('production health is degraded when the offline installer is not configured', async () => {
  const previous = {
    nodeEnv: process.env.NODE_ENV,
    jwtSecret: process.env.JWT_SECRET,
    templateDir: process.env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR,
    artifactsDir: process.env.OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR,
    version: process.env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION,
    commit: process.env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT,
    sha256: process.env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256,
    releaseTag: process.env.OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG,
  };

  process.env.NODE_ENV = 'production';
  process.env.JWT_SECRET = 'healthcheck-production-secret';
  for (const name of [
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR',
    'OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256',
    'OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG',
  ]) {
    Reflect.deleteProperty(process.env, name);
  }

  try {
    const result = await HealthcheckService.getReadinessStatus();
    assert.strictEqual(result.status, 'degraded');
    assert.equal(result.checks.windowsOfflineInstaller?.status, 'not_configured');
  } finally {
    if (previous.nodeEnv === undefined) Reflect.deleteProperty(process.env, 'NODE_ENV');
    else process.env.NODE_ENV = previous.nodeEnv;
    if (previous.jwtSecret === undefined) Reflect.deleteProperty(process.env, 'JWT_SECRET');
    else process.env.JWT_SECRET = previous.jwtSecret;

    const values: Record<string, string | undefined> = {
      OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR: previous.templateDir,
      OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR: previous.artifactsDir,
      OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: previous.version,
      OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: previous.commit,
      OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: previous.sha256,
      OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: previous.releaseTag,
    };
    for (const [name, value] of Object.entries(values)) {
      if (value === undefined) Reflect.deleteProperty(process.env, name);
      else process.env[name] = value;
    }
  }
});
