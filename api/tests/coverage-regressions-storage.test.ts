import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import * as classroomStorage from '../src/lib/classroom-storage.js';
import * as groupsStorage from '../src/lib/groups-storage.js';
import * as roleStorage from '../src/lib/role-storage.js';
import * as settingsStorage from '../src/lib/settings-storage.js';
import * as storage from '../src/lib/storage.js';
import * as userStorage from '../src/lib/user-storage.js';
import { CANONICAL_GROUP_IDS } from './fixtures.js';
import { registerCoverageRegressionLifecycle } from './coverage-regressions-test-harness.js';
import { uniqueDomain, uniqueEmail } from './test-utils.js';

registerCoverageRegressionLifecycle();

void describe('coverage regressions - storage helpers', () => {
  void it('covers storage CRUD helpers touched by the merge repair', async () => {
    const classroom = await classroomStorage.createClassroom({ name: 'Coverage Room A' });
    assert.ok(classroomStorage.buildMachineKey(classroom.id, 'Lab Host 01').includes('--'));
    assert.strictEqual(
      classroomStorage.machineHostnameMatches(
        { hostname: 'coverage-room-a-01', reportedHostname: 'Coverage-Room-A-01' },
        'coverage-room-a-01'
      ),
      true
    );
    assert.ok((await classroomStorage.getAllClassrooms()).length >= 1);
    assert.strictEqual((await classroomStorage.getClassroomById(classroom.id))?.id, classroom.id);
    assert.strictEqual(
      (await classroomStorage.getClassroomByName(classroom.name))?.displayName,
      classroom.displayName
    );
    assert.strictEqual(
      (
        await classroomStorage.updateClassroom(classroom.id, {
          displayName: 'Coverage Room A Updated',
          defaultGroupId: 'default',
        })
      )?.displayName,
      'Coverage Room A Updated'
    );
    assert.strictEqual(await classroomStorage.getCurrentGroupId(classroom.id), 'default');
    const machinesRemovedBefore = await classroomStorage.removeMachinesByClassroom(classroom.id);
    assert.strictEqual(machinesRemovedBefore, 0);

    const machine = await classroomStorage.registerMachine({
      hostname: 'coverage-room-a-01',
      classroomId: classroom.id,
      version: '1.0.0',
    });
    assert.strictEqual(machine.hostname, 'coverage-room-a-01');
    assert.ok((await classroomStorage.getAllMachines()).length >= 1);
    assert.strictEqual((await classroomStorage.getAllMachines(classroom.id)).length, 1);
    assert.strictEqual((await classroomStorage.getMachineById(machine.id))?.id, machine.id);
    assert.strictEqual(
      (await classroomStorage.getMachinesByClassroom(classroom.id)).some(
        (entry) => entry.id === machine.id
      ),
      true
    );
    assert.strictEqual(
      (await classroomStorage.getMachineOnlyByHostname('coverage-room-a-01'))?.id,
      machine.id
    );
    assert.strictEqual(
      (await classroomStorage.updateMachineLastSeen('coverage-room-a-01'))?.id,
      machine.id
    );
    assert.strictEqual(
      (await classroomStorage.resolveMachineGroupContext('coverage-room-a-01'))?.groupId,
      'default'
    );
    assert.strictEqual(
      (await classroomStorage.resolveMachineEnforcementContext('coverage-room-a-01'))?.groupId,
      'default'
    );
    assert.strictEqual(
      (await classroomStorage.resolveClassroomGroupContext(classroom.id))?.groupId,
      'default'
    );
    await classroomStorage.setMachineDownloadTokenHash(machine.id, 'coverage-download-token-hash');
    assert.strictEqual(
      (await classroomStorage.getMachineByDownloadTokenHash('coverage-download-token-hash'))?.id,
      machine.id
    );
    assert.strictEqual((await classroomStorage.getMachineTokenStatus(machine.id))?.hasToken, true);
    assert.strictEqual(
      (await classroomStorage.getWhitelistUrlForMachine('coverage-room-a-01'))?.groupId,
      'default'
    );
    assert.ok((await classroomStorage.getStats()).classrooms >= 1);
    assert.strictEqual(await classroomStorage.deleteMachine('coverage-room-a-01'), true);

    const machineRoom = await classroomStorage.createClassroom({ name: 'Coverage Room B' });
    await classroomStorage.registerMachine({
      hostname: 'coverage-room-b-01',
      classroomId: machineRoom.id,
      version: '1.0.0',
    });
    await classroomStorage.registerMachine({
      hostname: 'coverage-room-b-02',
      classroomId: machineRoom.id,
      version: '1.0.0',
    });
    assert.strictEqual(await classroomStorage.removeMachinesByClassroom(machineRoom.id), 2);
    assert.strictEqual(await classroomStorage.deleteClassroom(machineRoom.id), true);

    const groupId = await groupsStorage.createGroup('coverage-group', 'Coverage Group');
    assert.ok((await groupsStorage.getAllGroups()).some((group) => group.id === groupId));
    const groupById = await groupsStorage.getGroupById(groupId);
    assert.strictEqual(groupById?.name, 'coverage-group');
    const groupByName = await groupsStorage.getGroupByName('coverage-group');
    assert.strictEqual(groupByName?.id, groupId);
    await groupsStorage.updateGroup(groupId, 'Coverage Group Updated', true, 'private');
    assert.strictEqual(
      (await groupsStorage.getGroupById(groupId))?.displayName,
      'Coverage Group Updated'
    );

    const createdRule = await groupsStorage.createRule(groupId, 'whitelist', 'example.com');
    assert.strictEqual(createdRule.success, true);
    assert.ok(createdRule.id);
    assert.strictEqual((await groupsStorage.getRuleById(createdRule.id))?.value, 'example.com');
    assert.strictEqual(await groupsStorage.deleteRule(createdRule.id), true);

    await groupsStorage.bulkCreateRules(groupId, 'whitelist', ['a.example.com', 'b.example.com']);
    const rules = await groupsStorage.getRulesByGroup(groupId, 'whitelist');
    assert.strictEqual(rules.length, 2);
    assert.strictEqual((await groupsStorage.getRulesByIds(rules.map((rule) => rule.id))).length, 2);
    assert.strictEqual(
      (await groupsStorage.getRulesByGroupPaginated({ groupId, limit: 10, offset: 0 })).rules
        .length,
      2
    );
    assert.strictEqual(
      (await groupsStorage.getRulesByGroupGrouped({ groupId, limit: 10, offset: 0 })).groups.length,
      1
    );
    assert.strictEqual(
      (await groupsStorage.updateRule({ id: rules[0]?.id ?? '', value: 'updated.example.com' }))
        ?.value,
      'updated.example.com'
    );
    assert.ok((await groupsStorage.getStats()).groupCount >= 1);
    assert.ok((await groupsStorage.getSystemStatus()).totalGroups >= 1);
    assert.strictEqual((await groupsStorage.toggleSystemStatus(false)).enabled, false);
    assert.strictEqual(await groupsStorage.bulkDeleteRules(rules.map((rule) => rule.id)), 2);
    assert.strictEqual(await groupsStorage.deleteGroup(groupId), true);

    const request = await storage.createRequest({
      domain: uniqueDomain('coverage-storage'),
      requesterEmail: uniqueEmail('coverage-storage'),
      groupId: 'default',
    });
    assert.ok((await storage.getRequestById(request.id)) !== null);
    assert.strictEqual((await storage.getAllRequests()).length > 0, true);
    assert.strictEqual((await storage.getRequestsByGroup('default')).length > 0, true);
    // request-storage-query: aggregate stats + per-group pending dedupe (scoped
    // and global branches of hasPendingRequest).
    assert.ok((await storage.getStats()).total >= 1);
    assert.strictEqual(await storage.hasPendingRequest(request.domain, 'default'), true);
    assert.strictEqual(await storage.hasPendingRequest(uniqueDomain('never-pending')), false);
    assert.strictEqual(await storage.deleteRequest(request.id), true);

    await settingsStorage.setSetting('coverage-flag', 'enabled');
    assert.strictEqual(await settingsStorage.getSetting('coverage-flag'), 'enabled');
    assert.deepStrictEqual(await settingsStorage.getSettings(['coverage-flag']), {
      'coverage-flag': 'enabled',
    });
    assert.strictEqual((await settingsStorage.getBackupInfo()).lastBackupAt, null);
    assert.strictEqual(await settingsStorage.recordBackup('success', 1234), true);
    assert.strictEqual((await settingsStorage.getBackupInfo()).lastBackupStatus, 'success');
    assert.strictEqual(await settingsStorage.deleteSetting('coverage-flag'), true);

    const firstUser = await userStorage.createUser({
      email: uniqueEmail('role-user-1'),
      name: 'Role User One',
      password: 'Password123!',
    });
    const secondUser = await userStorage.createUser({
      email: uniqueEmail('role-user-2'),
      name: 'Role User Two',
      password: 'Password123!',
    });

    const firstRole = await roleStorage.assignRole({
      userId: firstUser.id,
      role: 'teacher',
      groupIds: [CANONICAL_GROUP_IDS.groupA],
      createdBy: 'legacy_admin',
    });
    assert.strictEqual((await roleStorage.getUserRoles(firstUser.id)).length, 1);
    assert.ok((await roleStorage.getUsersByRole('teacher')).length >= 1);
    assert.ok((await roleStorage.getAllTeachers()).length >= 1);
    assert.strictEqual(await roleStorage.hasAnyAdmins(), false);
    assert.strictEqual(await roleStorage.hasRole(firstUser.id, 'teacher'), true);
    assert.strictEqual(await roleStorage.isAdmin(firstUser.id), false);
    assert.strictEqual(
      await roleStorage.canApproveForGroup(firstUser.id, CANONICAL_GROUP_IDS.groupA),
      true
    );
    assert.deepStrictEqual(await roleStorage.getApprovalGroups(firstUser.id), [
      CANONICAL_GROUP_IDS.groupA,
    ]);
    const expandedRole = await roleStorage.addGroupsToRole(firstRole.id, [
      CANONICAL_GROUP_IDS.groupB,
    ]);
    assert.deepStrictEqual([...(expandedRole?.groupIds ?? [])].sort(), [
      CANONICAL_GROUP_IDS.groupA,
      CANONICAL_GROUP_IDS.groupB,
    ]);
    const trimmedRole = await roleStorage.removeGroupsFromRole(firstRole.id, [
      CANONICAL_GROUP_IDS.groupA,
    ]);
    assert.deepStrictEqual(trimmedRole?.groupIds, [CANONICAL_GROUP_IDS.groupB]);
    assert.strictEqual((await roleStorage.getRolesByUser(firstUser.id)).length, 1);
    assert.strictEqual((await roleStorage.getRoleById(firstRole.id))?.id, firstRole.id);
    assert.deepStrictEqual(
      (
        await roleStorage.updateRole(firstRole.id, {
          groupIds: [CANONICAL_GROUP_IDS.groupC],
          role: 'teacher',
        })
      )?.groupIds,
      [CANONICAL_GROUP_IDS.groupC]
    );
    assert.strictEqual(await roleStorage.removeGroupFromAllRoles(CANONICAL_GROUP_IDS.groupC), 1);
    assert.ok((await roleStorage.getStats()).total >= 1);
    assert.strictEqual(await roleStorage.revokeRole(firstRole.id), true);

    await roleStorage.assignRole({
      userId: secondUser.id,
      role: 'admin',
      groupIds: [CANONICAL_GROUP_IDS.groupZ],
      createdBy: 'legacy_admin',
    });
    assert.strictEqual((await roleStorage.getAllAdmins()).length, 1);
    assert.strictEqual(await roleStorage.hasAnyAdmins(), true);
    assert.strictEqual(await roleStorage.isAdmin(secondUser.id), true);
    assert.strictEqual(await roleStorage.canApproveForGroup(secondUser.id, 'any-group'), true);
    assert.strictEqual(await roleStorage.getApprovalGroups(secondUser.id), 'all');
    assert.deepStrictEqual(await roleStorage.getUsersWithRole('admin'), [secondUser.id]);
    assert.strictEqual(await roleStorage.revokeAllUserRoles(secondUser.id), 1);
  });
});
