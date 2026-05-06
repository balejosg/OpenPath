import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createTransactionalWriter } from '../src/services/domain-events/transactional-writer.js';

void test('transactional writer owns post-commit event publication', async () => {
  const calls: string[] = [];
  const writer = createTransactionalWriter({
    publishers: {
      publishWhitelistChanged: (groupId) => {
        calls.push(`event:${groupId}`);
      },
    },
    transactionRunner: async (operation) => {
      calls.push('begin');
      const result = await operation({ id: 'tx-1' });
      calls.push('commit');
      return result;
    },
  });

  const result = await writer.write((tx, events) => {
    assert.deepEqual(tx, { id: 'tx-1' });
    calls.push('write');
    events.publishWhitelistChanged('group-a');
    return Promise.resolve('ok');
  });

  assert.equal(result, 'ok');
  assert.deepEqual(calls, ['begin', 'write', 'commit', 'event:group-a']);
});

void test('transactional writer does not publish events when transaction fails', async () => {
  const calls: string[] = [];
  const writer = createTransactionalWriter({
    publishers: {
      publishWhitelistChanged: (groupId) => {
        calls.push(`event:${groupId}`);
      },
    },
    transactionRunner: async (operation) => {
      calls.push('begin');
      await operation({ id: 'tx-1' });
      throw new Error('rollback');
    },
  });

  await assert.rejects(
    () =>
      writer.write((_tx, events) => {
        events.publishWhitelistChanged('group-a');
        return Promise.resolve('ok');
      }),
    /rollback/
  );

  assert.deepEqual(calls, ['begin']);
});
