import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

process.env.NODE_ENV = 'test';

await describe('classroom service shared helpers', async () => {
  const shared = await import('../src/services/classroom-service-shared.js');

  await test('normalizes unexpected group source values to none', () => {
    assert.equal(shared.normalizeCurrentGroupSource('unexpected'), 'none');
    assert.equal(shared.normalizeCurrentGroupSource('manual'), 'manual');
  });

  await test('maps machine state to dashboard shape', () => {
    const machine = shared.toMachineInfo({
      id: 'machine-1',
      hostname: 'lab-01',
      lastSeen: new Date(),
    });

    assert.equal(machine.id, 'machine-1');
    assert.equal(machine.hostname, 'lab-01');
    assert.ok(typeof machine.status === 'string');
  });

  await test('carries configPosture through toMachineInfo and defaults to null', () => {
    const withPosture = shared.toMachineInfo({
      id: 'machine-3',
      hostname: 'lab-03',
      lastSeen: new Date(),
      configPosture: { sinkholeFastFail: 'true', rfc1918EgressMode: 'restricted' },
    });
    assert.deepEqual(withPosture.configPosture, {
      sinkholeFastFail: 'true',
      rfc1918EgressMode: 'restricted',
    });

    const withoutPosture = shared.toMachineInfo({
      id: 'machine-4',
      hostname: 'lab-04',
      lastSeen: null,
    });
    assert.equal(withoutPosture.configPosture, null);
  });
});
