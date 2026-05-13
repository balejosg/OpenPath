import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

process.env.NODE_ENV = 'test';

await describe('classroom command service exports', async () => {
  const service = await import('../src/services/classroom-command.service.js');

  await test('exposes write-oriented classroom commands', () => {
    assert.equal(typeof service.createClassroom, 'function');
    assert.equal(typeof service.updateClassroom, 'function');
    assert.equal(typeof service.registerMachine, 'function');
    assert.equal(typeof service.rotateMachineToken, 'function');
    assert.equal(typeof service.createExemptionForClassroom, 'function');
    assert.equal(typeof service.createOperationalExemptionForClassroom, 'function');
  });
});
