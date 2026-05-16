import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';

import type { RolesTestHarness } from './roles-test-harness.js';
import { startRolesTestHarness } from './roles-test-harness.js';

let harness: RolesTestHarness | undefined;

function getHarness(): RolesTestHarness {
  assert.ok(harness, 'Roles harness should be initialized');
  return harness;
}

void describe('Role management - teacher listings', () => {
  before(async () => {
    harness = await startRolesTestHarness();
  });

  after(async () => {
    await harness?.close();
    harness = undefined;
  });

  void test('lists teachers with their approval groups', async (): Promise<void> => {
    const teacher = await getHarness().createUser();
    await getHarness().assignRole({
      userId: teacher.id,
      role: 'teacher',
      groupIds: [getHarness().groupIds.ciencias],
    });

    const teachers = await getHarness().listTeachers();
    assert.ok(Array.isArray(teachers));
    const teacherEntry = teachers.find((entry) => entry.userId === teacher.id);
    assert.ok(teacherEntry);
    assert.ok(teacherEntry.groupIds.includes(getHarness().groupIds.ciencias));
  });

  void test('omits deleted groups from teacher approval groups', async (): Promise<void> => {
    const teacher = await getHarness().createUser();
    await getHarness().assignRole({
      userId: teacher.id,
      role: 'teacher',
      groupIds: [getHarness().groupIds.ciencias, getHarness().groupIds.matematicas],
    });

    await getHarness().deleteGroup(getHarness().groupIds.ciencias);

    const teachers = await getHarness().listTeachers();
    const teacherEntry = teachers.find((entry) => entry.userId === teacher.id);
    assert.ok(teacherEntry);
    assert.deepEqual(teacherEntry.groupIds, [getHarness().groupIds.matematicas]);
  });
});
