import assert from 'node:assert/strict';
import { after, before, describe, test } from 'node:test';

process.env.NODE_ENV = 'test';

import { closeConnection } from '../src/db/index.js';
import classroomStorage, { buildMachineKey } from '../src/lib/classroom-storage.js';
import { createFixtureId } from './fixtures.js';
import { resetDb } from './test-utils.js';

await describe('classroom storage facade', async () => {
  before(async () => {
    await resetDb();
  });

  after(async () => {
    await resetDb();
    await closeConnection();
  });

  await test('maps classroom and machine operations through the public facade', async () => {
    const name = createFixtureId('facade-classroom');
    const created = await classroomStorage.createClassroom({
      name,
      displayName: 'Facade Classroom',
      captivePortalDomains: ['Portal.EXAMPLE.test'],
    });

    assert.deepEqual(created.captivePortalDomains, ['portal.example.test']);

    const listed = await classroomStorage.getAllClassrooms();
    assert.ok(listed.some((classroom) => classroom.id === created.id));

    const byId = await classroomStorage.getClassroomById(created.id);
    assert.equal(byId?.id, created.id);

    const byName = await classroomStorage.getClassroomByName(name);
    assert.equal(byName?.id, created.id);

    const updated = await classroomStorage.updateClassroom(created.id, {
      captivePortalDomains: ['login.example.test'],
    });
    assert.deepEqual(updated?.captivePortalDomains, ['login.example.test']);

    const machine = await classroomStorage.addMachine(created.id, 'Student-PC');
    const storedMachineKey = buildMachineKey(created.id, 'Student-PC');
    assert.equal(machine.hostname, 'Student-PC');
    assert.equal(await classroomStorage.updateMachineStatus(storedMachineKey, 'online'), true);

    const machineLookup = await classroomStorage.getMachineByHostname(storedMachineKey);
    assert.equal(machineLookup?.classroom.id, created.id);
    assert.equal(machineLookup?.machine.hostname, 'Student-PC');

    assert.equal(await classroomStorage.removeMachine('other-classroom', storedMachineKey), false);
    assert.equal(await classroomStorage.removeMachine(created.id, storedMachineKey), true);
    assert.equal(await classroomStorage.getMachineByHostname(storedMachineKey), null);

    assert.equal(await classroomStorage.getClassroomById('missing-classroom'), null);
    assert.equal(await classroomStorage.getClassroomByName('missing-classroom'), null);
    assert.equal(
      await classroomStorage.updateClassroom('missing-classroom', { displayName: 'x' }),
      null
    );
    assert.equal(await classroomStorage.updateMachineStatus('missing-machine', 'offline'), false);
  });
});
