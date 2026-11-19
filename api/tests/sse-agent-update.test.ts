import { after, before, describe, test } from 'node:test';
import assert from 'node:assert';

import { agentReleaseRepository } from '../src/services/agent-release.service.js';
import { emitAgentUpdateAvailable } from '../src/lib/rule-events.js';
import { createSseTestClient } from './sse-test-utils.js';
import type { SseMachine, SseTestHarness } from './sse-test-harness.js';
import { startSseTestHarness } from './sse-test-harness.js';

const RELEASE_TOKEN = 'sse-agent-update-release-token';

let harness: SseTestHarness | undefined;

function getHarness(): SseTestHarness {
  assert.ok(harness, 'SSE harness should be initialized');
  return harness;
}

async function setRing(machine: SseMachine, ring: 'stable' | 'canary'): Promise<void> {
  const response = await fetch(`${getHarness().apiUrl}/api/agent/windows/rings`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${RELEASE_TOKEN}` },
    body: JSON.stringify({ hostname: machine.hostname, ring }),
  });
  assert.strictEqual(response.status, 200, await response.text());
}

function connect(machine: SseMachine): ReturnType<typeof createSseTestClient> {
  return createSseTestClient({
    url: `${getHarness().apiUrl}/api/machines/events`,
    headers: { Authorization: `Bearer ${machine.token}` },
  });
}

void describe('SSE agent-update-available targeting', { timeout: 60000 }, () => {
  before(async () => {
    harness = await startSseTestHarness({ OPENPATH_AGENT_RELEASE_TOKEN: RELEASE_TOKEN });
  });

  after(async () => {
    await harness?.close();
    harness = undefined;
  });

  void test('a machine moved to canary while connected gets the ring event and later publishes', async () => {
    const groupId = await getHarness().createGroup('sse-ring', 'SSE Ring Group');
    const moved = await getHarness().createMachineForGroup(groupId, 'sse-ring-a', 'SSE Ring A');
    const stable = await getHarness().createMachineForGroup(groupId, 'sse-ring-b', 'SSE Ring B');
    const movedClient = connect(moved);
    const stableClient = connect(stable);

    try {
      await Promise.all([movedClient.connect(), stableClient.connect()]);
      await Promise.all([
        movedClient.waitFor((event) => event.event === 'connected', 5000, 'connected (moved)'),
        stableClient.waitFor((event) => event.event === 'connected', 5000, 'connected (stable)'),
      ]);

      // Registered as stable; the ring changes without a reconnect.
      await setRing(moved, 'canary');
      await movedClient.waitFor(
        (event) => event.event === 'agent-update-available',
        5000,
        'agent-update-available after the ring change'
      );

      const build = 'd'.repeat(64);
      await emitAgentUpdateAvailable({ build });
      const published = (await movedClient.waitFor(
        (event) => event.event === 'agent-update-available' && event.build === build,
        5000,
        'agent-update-available for the publish'
      )) as { build?: string };
      assert.strictEqual(published.build, build);

      await assert.rejects(
        stableClient.waitFor(
          (event) => event.event === 'agent-update-available',
          1500,
          'a stable machine should not receive the publish'
        ),
        /should not receive/
      );
    } finally {
      movedClient.close();
      stableClient.close();
      await setRing(moved, 'stable');
    }
  });

  void test('retiring the active release tells the canary ring to check now', async () => {
    const groupId = await getHarness().createGroup('sse-retire', 'SSE Retire Group');
    const canary = await getHarness().createMachineForGroup(groupId, 'sse-retire', 'SSE Retire');
    await setRing(canary, 'canary');
    const build = 'e'.repeat(64);
    await agentReleaseRepository.publishRelease(
      { build, ring: 'canary', sourceSha: 'a'.repeat(40), signature: 'stored' },
      [{ path: 'lib/Alpha.psm1', sha256: 'f'.repeat(64), size: 5, content: Buffer.from('alpha') }]
    );
    const client = connect(canary);

    try {
      await client.connect();
      await client.waitFor((event) => event.event === 'connected', 5000, 'connected');

      const response = await fetch(
        `${getHarness().apiUrl}/api/agent/windows/releases/${build}/retire`,
        { method: 'POST', headers: { Authorization: `Bearer ${RELEASE_TOKEN}` } }
      );
      assert.strictEqual(response.status, 200, await response.text());

      await client.waitFor(
        (event) => event.event === 'agent-update-available',
        5000,
        'agent-update-available after the retire'
      );
    } finally {
      client.close();
      await setRing(canary, 'stable');
    }
  });

  void test('a machine set back to stable is told to check now', async () => {
    const groupId = await getHarness().createGroup('sse-back', 'SSE Back Group');
    const machine = await getHarness().createMachineForGroup(groupId, 'sse-back', 'SSE Back');
    await setRing(machine, 'canary');
    const client = connect(machine);

    try {
      await client.connect();
      await client.waitFor((event) => event.event === 'connected', 5000, 'connected');
      await setRing(machine, 'stable');
      await client.waitFor(
        (event) => event.event === 'agent-update-available',
        5000,
        'agent-update-available after returning to stable'
      );
    } finally {
      client.close();
    }
  });

  void test('the release publish route refuses a caller without the token before parsing the body', async () => {
    const response = await fetch(`${getHarness().apiUrl}/api/agent/windows/releases`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{"not": json',
    });

    // A parsed body would have failed as 400 (malformed JSON) first.
    assert.strictEqual(response.status, 403);
  });
});
