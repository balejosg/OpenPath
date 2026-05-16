import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  cloneGroup,
  createGroup,
  deleteGroup,
  exportGroup,
  toggleSystemStatus,
} from '../src/services/groups-management.service.js';

function runWithFakeTx<T>(callback: (tx: never) => Promise<T>): Promise<T> {
  return callback({} as never);
}

function runWithFailingTx<T>(callback: (tx: never) => Promise<T>): Promise<T> {
  return callback({} as never).then(() => Promise.reject(new Error('rollback')));
}

await describe('groups management service', async () => {
  await test('sanitizes group names before creating them', async () => {
    let createdName = '';

    const result = await createGroup(
      {
        name: '  Aula Principal !!! ',
        displayName: 'Aula Principal',
      },
      {
        createGroup: (name) => {
          createdName = name;
          return Promise.resolve('group-1');
        },
      }
    );

    assert.deepEqual(result, {
      ok: true,
      data: {
        id: 'group-1',
        name: 'aula-principal',
      },
    });
    assert.equal(createdName, 'aula-principal');
  });

  await test('maps duplicate group names to conflict results', async () => {
    const result = await createGroup(
      {
        name: 'library',
        displayName: 'Library',
      },
      {
        createGroup: () => {
          throw new Error('UNIQUE_CONSTRAINT_VIOLATION');
        },
      }
    );

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'CONFLICT', message: 'A group with this name already exists' },
    });
  });

  await test('returns not found when exporting an unknown group', async () => {
    const result = await exportGroup('missing-group', {
      exportGroup: () => Promise.resolve(null),
      getGroupById: () => Promise.resolve(null),
    });

    assert.deepEqual(result, {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'Group not found' },
    });
  });

  await test('publishes a global whitelist refresh when toggling system status', async () => {
    let published = false;

    const result = await toggleSystemStatus(false, {
      publishAllWhitelistsChanged: () => {
        published = true;
      },
      toggleSystemStatus: () =>
        Promise.resolve({
          enabled: false,
          totalGroups: 10,
          activeGroups: 0,
          pausedGroups: 10,
        }),
    });

    assert.deepEqual(result, {
      enabled: false,
      totalGroups: 10,
      activeGroups: 0,
      pausedGroups: 10,
    });
    assert.equal(published, true);
  });

  await test('removes deleted group references from roles before publishing refresh', async () => {
    const calls: string[] = [];
    const result = await deleteGroup('group-to-delete', {
      deleteGroup: () => {
        calls.push('deleteGroup');
        return Promise.resolve(true);
      },
      getGroupById: () =>
        Promise.resolve({
          id: 'group-to-delete',
          name: 'group-to-delete',
          displayName: 'Group To Delete',
          enabled: true,
          visibility: 'private',
          ownerUserId: null,
          createdAt: '2026-05-16T00:00:00.000Z',
          updatedAt: '2026-05-16T00:00:00.000Z',
          whitelistCount: 0,
          blockedSubdomainCount: 0,
          blockedPathCount: 0,
        }),
      publishWhitelistChanged: (groupId) => {
        calls.push(`publishWhitelistChanged:${groupId}`);
      },
      removeGroupFromAllRoles: (groupId) => {
        calls.push(`removeGroupFromAllRoles:${groupId}`);
        return Promise.resolve(2);
      },
    });

    assert.deepEqual(result, { ok: true, data: { deleted: true } });
    assert.deepEqual(calls, [
      'deleteGroup',
      'removeGroupFromAllRoles:group-to-delete',
      'publishWhitelistChanged:group-to-delete',
    ]);
  });

  await test('does not remove role group references when storage deletion returns false', async () => {
    const calls: string[] = [];
    const result = await deleteGroup('group-to-delete', {
      deleteGroup: () => {
        calls.push('deleteGroup');
        return Promise.resolve(false);
      },
      getGroupById: () =>
        Promise.resolve({
          id: 'group-to-delete',
          name: 'group-to-delete',
          displayName: 'Group To Delete',
          enabled: true,
          visibility: 'private',
          ownerUserId: null,
          createdAt: '2026-05-16T00:00:00.000Z',
          updatedAt: '2026-05-16T00:00:00.000Z',
          whitelistCount: 0,
          blockedSubdomainCount: 0,
          blockedPathCount: 0,
        }),
      publishWhitelistChanged: (groupId) => {
        calls.push(`publishWhitelistChanged:${groupId}`);
      },
      removeGroupFromAllRoles: (groupId) => {
        calls.push(`removeGroupFromAllRoles:${groupId}`);
        return Promise.resolve(1);
      },
    });

    assert.deepEqual(result, { ok: true, data: { deleted: false } });
    assert.deepEqual(calls, ['deleteGroup']);
  });

  await test('publishes clone events after the transaction commits', async () => {
    const publishedGroups: string[] = [];

    const result = await cloneGroup(
      {
        sourceGroupId: 'source-group',
        displayName: 'Clone',
        ownerUserId: 'teacher-1',
      },
      {
        copyRulesToGroup: () => Promise.resolve(0),
        createGroup: () => Promise.resolve('cloned-group'),
        getGroupById: () =>
          ({
            id: 'source-group',
            name: 'source-group',
            displayName: 'Source',
            enabled: true,
            visibility: 'private',
            ownerUserId: null,
            whitelistCount: 1,
            blockedSubdomainCount: 0,
            blockedPathCount: 0,
          }) as never,
        getGroupMetaByName: () => Promise.resolve(null),
        publishWhitelistChanged: (groupId) => {
          publishedGroups.push(groupId);
        },
        touchGroupUpdatedAt: () => Promise.resolve(),
        withTransaction: runWithFakeTx,
      }
    );

    assert.deepEqual(result, {
      ok: true,
      data: {
        id: 'cloned-group',
        name: 'source-group-copy',
      },
    });
    assert.deepEqual(publishedGroups, ['cloned-group']);
  });

  await test('does not publish clone events when the transaction rolls back', async () => {
    const publishedGroups: string[] = [];

    await assert.rejects(
      () =>
        cloneGroup(
          {
            sourceGroupId: 'source-group',
            displayName: 'Clone',
            ownerUserId: 'teacher-1',
          },
          {
            copyRulesToGroup: () => Promise.resolve(0),
            createGroup: () => Promise.resolve('cloned-group'),
            getGroupById: () =>
              ({
                id: 'source-group',
                name: 'source-group',
                displayName: 'Source',
                enabled: true,
                visibility: 'private',
                ownerUserId: null,
                whitelistCount: 1,
                blockedSubdomainCount: 0,
                blockedPathCount: 0,
              }) as never,
            getGroupMetaByName: () => Promise.resolve(null),
            publishWhitelistChanged: (groupId) => {
              publishedGroups.push(groupId);
            },
            touchGroupUpdatedAt: () => Promise.resolve(),
            withTransaction: runWithFailingTx,
          }
        ),
      /rollback/
    );

    assert.deepEqual(publishedGroups, []);
  });
});
