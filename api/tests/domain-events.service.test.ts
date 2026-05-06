import { test } from 'node:test';
import assert from 'node:assert/strict';

import DomainEventsService from '../src/services/domain-events.service.js';

void test('domain-events service exposes event dispatch functions', () => {
  assert.equal(typeof DomainEventsService.createDispatcher, 'function');
  assert.equal(typeof DomainEventsService.publishWhitelistChanged, 'function');
  assert.equal(typeof DomainEventsService.publishAllWhitelistsChanged, 'function');
  assert.equal(typeof DomainEventsService.publishClassroomChanged, 'function');
  assert.equal(typeof DomainEventsService.tickScheduleBoundaryEvents, 'function');
  assert.equal(typeof DomainEventsService.withQueuedEvents, 'function');
  assert.equal(typeof DomainEventsService.withTransactionEvents, 'function');
  assert.equal(typeof DomainEventsService.createTransactionalWriter, 'function');
});

void test('withTransactionEvents publishes queued events after success', async () => {
  const published: string[] = [];

  const dispatcher = DomainEventsService.createDispatcher({
    publishWhitelistChanged: (groupId) => {
      published.push(groupId);
    },
  });

  const result = await DomainEventsService.withTransactionEvents(
    (operation) => operation({} as never),
    (_tx, events) => {
      events.publishWhitelistChanged('group-a');
      events.publishWhitelistChanged('group-b');
      return Promise.resolve('ok');
    },
    dispatcher
  );

  assert.equal(result, 'ok');
  assert.deepEqual(published, ['group-a', 'group-b']);
});

void test('withTransactionEvents deduplicates repeated events after commit', async () => {
  const published: { classroomId: string; now?: Date | undefined; type: string }[] = [];

  const dispatcher = DomainEventsService.createDispatcher({
    publishClassroomChanged: (classroomId, now) => {
      published.push({ classroomId, now, type: 'classroom.changed' });
    },
    publishWhitelistChanged: (groupId) => {
      published.push({ classroomId: groupId, type: 'whitelist.changed' });
    },
  });

  await DomainEventsService.withTransactionEvents(
    (operation) => operation({} as never),
    (_tx, events) => {
      events.publishWhitelistChanged('group-a');
      events.publishWhitelistChanged('group-a');
      events.publishClassroomChanged('room-1', new Date('2026-04-14T09:00:00.000Z'));
      events.publishClassroomChanged('room-1', new Date('2026-04-14T09:05:00.000Z'));
      return Promise.resolve(undefined);
    },
    dispatcher
  );

  assert.deepEqual(published, [
    { classroomId: 'group-a', type: 'whitelist.changed' },
    {
      classroomId: 'room-1',
      now: new Date('2026-04-14T09:05:00.000Z'),
      type: 'classroom.changed',
    },
  ]);
});

void test('withTransactionEvents collapses group-level events into global whitelist refreshes', async () => {
  const published: string[] = [];

  const dispatcher = DomainEventsService.createDispatcher({
    publishAllWhitelistsChanged: () => {
      published.push('all');
    },
    publishWhitelistChanged: (groupId) => {
      published.push(groupId);
    },
  });

  await DomainEventsService.withTransactionEvents(
    (operation) => operation({} as never),
    (_tx, events) => {
      events.publishWhitelistChanged('group-a');
      events.publishWhitelistChanged('group-b');
      events.publishAllWhitelistsChanged();
      events.publishWhitelistChanged('group-c');
      return Promise.resolve(undefined);
    },
    dispatcher
  );

  assert.deepEqual(published, ['all']);
});

void test('withTransactionEvents does not publish queued events after failure', async () => {
  const published: string[] = [];

  const dispatcher = DomainEventsService.createDispatcher({
    publishWhitelistChanged: (groupId) => {
      published.push(groupId);
    },
  });

  await assert.rejects(
    () =>
      DomainEventsService.withTransactionEvents(
        (operation) => operation({} as never),
        (_tx, events) => {
          events.publishWhitelistChanged('group-a');
          return Promise.reject(new Error('rollback'));
        },
        dispatcher
      ),
    /rollback/
  );

  assert.deepEqual(published, []);
});

void test('publishClassroomChanged accepts immediate and timestamped changes', () => {
  assert.doesNotThrow(() => {
    DomainEventsService.publishClassroomChanged('room-1');
    DomainEventsService.publishClassroomChanged('room-1', new Date('2026-05-06T12:00:00.000Z'));
  });
});

void test('withDbTransactionEvents publishes queued events after database commit', async () => {
  const published: string[] = [];
  const dispatcher = DomainEventsService.createDispatcher({
    publishWhitelistChanged: (groupId) => {
      published.push(groupId);
    },
  });

  const result = await DomainEventsService.withDbTransactionEvents(
    (operation) => operation({} as never),
    (_tx, events) => {
      events.publishWhitelistChanged('group-a');
      return Promise.resolve('ok');
    },
    dispatcher
  );

  assert.equal(result, 'ok');
  assert.deepEqual(published, ['group-a']);
});
