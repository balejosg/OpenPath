import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test-jwt-secret';

await describe('public request service', async () => {
  const { submitMachineRequest } = await import('../src/services/public-request.service.js');

  await test('rejects blank machine tokens before creating requests', async () => {
    const result = await submitMachineRequest({
      domainRaw: 'example.com',
      hostnameRaw: 'lab-host-01',
      token: '   ',
      reason: 'Need access',
    });

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'FORBIDDEN', message: 'Invalid machine token' },
    });
  });
});
