import assert from 'node:assert/strict';
import { describe, mock, test } from 'node:test';
import type { Browser, Runtime } from 'webextension-polyfill';

import {
  createPersistentNativeTransport,
  isProtocolVersionSupported,
  type PersistentNativeTransport,
} from '../src/lib/persistent-native-transport.js';
import { NATIVE_HOST_CAPABILITIES } from '../src/lib/runtime-dependency-protocol.js';

async function flushMicrotasks(): Promise<void> {
  for (let i = 0; i < 8; i += 1) {
    await Promise.resolve();
  }
}

interface FakePort {
  name: string;
  sent: unknown[];
  onMessage: {
    addListener: (callback: (message: unknown) => void) => void;
    removeListener: (callback: unknown) => void;
  };
  onDisconnect: {
    addListener: (callback: () => void) => void;
    removeListener: (callback: unknown) => void;
  };
  postMessage: (message: unknown) => void;
  disconnect: () => void;
  emitMessage: (message: unknown) => void;
  emitDisconnect: () => void;
  onPost?: (message: unknown) => void;
}

function createFakePort(name: string): FakePort {
  const messageListeners: ((message: unknown) => void)[] = [];
  const disconnectListeners: (() => void)[] = [];
  let disconnected = false;

  const port: FakePort = {
    name,
    sent: [],
    onMessage: {
      addListener: (callback) => {
        messageListeners.push(callback);
      },
      removeListener: (callback) => {
        const index = messageListeners.indexOf(callback as (message: unknown) => void);
        if (index >= 0) messageListeners.splice(index, 1);
      },
    },
    onDisconnect: {
      addListener: (callback) => {
        disconnectListeners.push(callback);
      },
      removeListener: (callback) => {
        const index = disconnectListeners.indexOf(callback as () => void);
        if (index >= 0) disconnectListeners.splice(index, 1);
      },
    },
    postMessage: (message) => {
      port.sent.push(message);
      port.onPost?.(message);
    },
    disconnect: () => {
      if (disconnected) return;
      disconnected = true;
      for (const listener of disconnectListeners) listener();
    },
    emitMessage: (message) => {
      for (const listener of [...messageListeners]) listener(message);
    },
    emitDisconnect: () => {
      port.disconnect();
    },
  };

  return port;
}

interface TransportHarness {
  browser: Browser;
  ports: FakePort[];
  logger: { errors: string[]; infos: string[] };
  nowValue: { value: number };
}

function createHarness(options?: {
  pingResponse?: (message: Record<string, unknown>) => unknown;
  onPost?: (message: Record<string, unknown>, port: FakePort) => void;
}): TransportHarness {
  const ports: FakePort[] = [];
  const nowValue = { value: 1_000_000 };
  const logger = { errors: [] as string[], infos: [] as string[] };

  const browser = {
    runtime: {
      connectNative: (hostName: string) => {
        const port = createFakePort(hostName);
        port.onPost = (message): void => {
          const typed = message as Record<string, unknown>;
          options?.onPost?.(typed, port);
          if (typed.action === 'ping') {
            const response = options?.pingResponse?.(typed);
            if (response !== undefined) {
              queueMicrotask(() => {
                port.emitMessage(response);
              });
            }
          }
        };
        ports.push(port);
        return port as unknown as Runtime.Port;
      },
      lastError: undefined,
    },
  } as unknown as Browser;

  return { browser, ports, logger, nowValue };
}

function createTransport(
  harness: TransportHarness,
  overrides: Record<string, unknown> = {}
): PersistentNativeTransport {
  return createPersistentNativeTransport({
    browserApi: harness.browser,
    hostName: 'whitelist_native_host',
    logger: {
      error: (message) => {
        harness.logger.errors.push(message);
      },
      info: (message) => {
        harness.logger.infos.push(message);
      },
    },
    now: () => harness.nowValue.value,
    ...overrides,
  });
}

const HOST_CAPABILITIES = [
  NATIVE_HOST_CAPABILITIES.enqueue,
  NATIVE_HOST_CAPABILITIES.checkBatch,
  NATIVE_HOST_CAPABILITIES.idEcho,
  NATIVE_HOST_CAPABILITIES.autoReload,
];

function capablePing(message: Record<string, unknown>): unknown {
  return {
    success: true,
    action: 'ping',
    id: message.id,
    protocolVersion: 2,
    capabilities: HOST_CAPABILITIES,
  };
}

await describe('persistent native transport', async () => {
  await test('probes capabilities on connect and exposes them by id', async () => {
    const harness = createHarness({ pingResponse: capablePing });
    const transport = createTransport(harness);

    assert.equal(await transport.ensureConnected(), true);
    assert.equal(transport.isReady(), true);
    assert.equal(transport.getProtocolVersion(), 2);
    assert.deepEqual([...transport.getCapabilities()].sort(), [...HOST_CAPABILITIES].sort());
    assert.equal(transport.supports(NATIVE_HOST_CAPABILITIES.enqueue), true);
    assert.equal(transport.supports('runtime-dependency-unknown'), false);
    assert.equal(harness.ports.length, 1);
    assert.equal((harness.ports[0]?.sent[0] as { id?: unknown }).id, 1);
    assert.equal(isProtocolVersionSupported(2), true);
    assert.equal(isProtocolVersionSupported(1), false);
  });

  await test('correlates concurrent calls by monotonic id even when responses arrive out of order', async () => {
    const harness = createHarness({ pingResponse: capablePing });
    const transport = createTransport(harness);
    await transport.ensureConnected();

    const first = transport.call({ action: 'check-local-runtime-dependency' });
    const second = transport.call({ action: 'get-policy-version' });
    const port = harness.ports[0];
    assert.ok(port, 'expected a connected port');
    const firstId = (port.sent[1] as { id: number }).id;
    const secondId = (port.sent[2] as { id: number }).id;
    assert.equal(firstId, 2);
    assert.equal(secondId, 3);

    port.emitMessage({ success: true, id: secondId, version: 'v2' });
    port.emitMessage({ success: true, id: firstId, ready: true });

    assert.deepEqual(await first, { success: true, id: firstId, ready: true });
    assert.deepEqual(await second, { success: true, id: secondId, version: 'v2' });
  });

  await test('treats a host without capabilities as legacy and never waits for it again', async () => {
    const harness = createHarness({
      pingResponse: (message) => ({ success: true, action: 'ping', id: message.id }),
    });
    const transport = createTransport(harness);

    assert.equal(await transport.ensureConnected(), true);
    assert.equal(transport.isReady(), false);
    assert.equal(transport.supports(NATIVE_HOST_CAPABILITIES.enqueue), false);
    assert.equal(await transport.waitUntilReady(50), false);
  });

  await test('accepts a legacy response without an id when a single call is in flight', async () => {
    const harness = createHarness({
      pingResponse: () => ({ success: true, action: 'ping' }),
    });
    const transport = createTransport(harness);
    assert.equal(await transport.ensureConnected(), true);
    assert.equal(transport.isReady(), false);
    assert.equal(harness.ports.length, 1);
  });

  await test('a slow call does not disconnect a live port (per-action timeouts)', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      const harness = createHarness({ pingResponse: capablePing });
      const transport = createTransport(harness);
      assert.equal(await transport.ensureConnected(), true);
      const port = harness.ports[0];
      assert.ok(port, 'expected a connected port');

      // An enqueue that takes 2 s resolves under the 10 s action timeout.
      const enqueue = transport.call(
        { action: 'allow-local-runtime-dependency-batch' },
        { timeoutMs: 10_000 }
      );
      mock.timers.tick(2_000);
      port.emitMessage({ id: (port.sent[1] as { id: number }).id, success: true });
      await enqueue;
      assert.equal(transport.isReady(), true);

      // A check that takes 4 s resolves under the 5 s action timeout; the old
      // 3 s default tore the port down here (Phase 2C behaviour).
      const check = transport.call(
        { action: 'check-local-runtime-dependency' },
        { timeoutMs: 5_000 }
      );
      mock.timers.tick(4_000);
      port.emitMessage({
        id: (port.sent[2] as { id: number }).id,
        success: true,
        ready: true,
      });
      await check;
      assert.equal(transport.isReady(), true);
      assert.equal(harness.ports.length, 1);
      assert.equal(
        harness.logger.infos.some((entry) => entry.includes('liveness')),
        false
      );
    } finally {
      mock.timers.reset();
    }
  });

  await test('a timed-out call keeps the port when the liveness ping is answered', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      let pingCount = 0;
      const harness = createHarness({
        pingResponse: (message) => {
          pingCount += 1;
          // Only the connect probe gets an automatic answer; the liveness ping
          // is answered manually below.
          return pingCount === 1 ? capablePing(message) : undefined;
        },
      });
      const transport = createTransport(harness, {
        livenessStaleMs: 15_000,
        livenessPingTimeoutMs: 5_000,
      });
      assert.equal(await transport.ensureConnected(), true);
      const port = harness.ports[0];
      assert.ok(port, 'expected a connected port');

      // The host is silent for 15 s and then a call times out.
      harness.nowValue.value += 15_000;
      const hung = transport.call(
        { action: 'check-local-runtime-dependency' },
        { timeoutMs: 1_000 }
      );
      mock.timers.tick(1_000);
      await assert.rejects(hung, /timed out/);

      const livenessPing = port.sent.find(
        (message) =>
          (message as { action?: string }).action === 'ping' &&
          (message as { id?: number }).id !== 1
      );
      assert.ok(livenessPing, 'expected a liveness ping on the same port');
      port.emitMessage({ success: true, id: (livenessPing as { id: number }).id });
      await flushMicrotasks();

      assert.equal(transport.isReady(), true);
      assert.equal(harness.ports.length, 1);

      // A new call still works over the kept port.
      const next = transport.call({ action: 'get-policy-version' }, { timeoutMs: 5_000 });
      port.emitMessage({
        id: (port.sent[port.sent.length - 1] as { id: number }).id,
        success: true,
        version: 'v3',
      });
      assert.deepEqual(await next, {
        success: true,
        id: (port.sent[port.sent.length - 1] as { id: number }).id,
        version: 'v3',
      });
    } finally {
      mock.timers.reset();
    }
  });

  await test('a liveness failure tears the port down with backoff', async () => {
    mock.timers.enable({ apis: ['setTimeout'] });
    try {
      let pingCount = 0;
      const harness = createHarness({
        pingResponse: (message) => {
          pingCount += 1;
          return pingCount === 1 ? capablePing(message) : undefined;
        },
      });
      const transport = createTransport(harness, {
        livenessStaleMs: 15_000,
        livenessPingTimeoutMs: 2_000,
        reconnectBaseDelayMs: 1_000,
      });
      assert.equal(await transport.ensureConnected(), true);

      harness.nowValue.value += 15_000;
      const hung = transport.call({ action: 'check-local-runtime-dependency' }, { timeoutMs: 500 });
      mock.timers.tick(500);
      await assert.rejects(hung, /timed out/);
      mock.timers.tick(2_000);
      await flushMicrotasks();

      assert.equal(transport.isReady(), false);
      assert.equal(await transport.ensureConnected(), false);
      assert.equal(harness.ports.length, 1);
    } finally {
      mock.timers.reset();
    }
  });

  await test('a dropped port rejects in-flight calls and reconnects after the backoff window', async () => {
    const harness = createHarness({ pingResponse: capablePing });
    const transport = createTransport(harness, { reconnectBaseDelayMs: 500 });
    await transport.ensureConnected();

    const inFlight = transport.call({ action: 'get-policy-version' });
    const port = harness.ports[0];
    assert.ok(port, 'expected a connected port');
    port.emitDisconnect();
    await assert.rejects(inFlight, /disconnected/);
    assert.equal(await transport.waitUntilReady(20), false);

    harness.nowValue.value += 600;
    assert.equal(await transport.ensureConnected(), true);
    assert.equal(harness.ports.length, 2);
  });

  await test('a failed probe keeps the transport unhealthy and backs off', async () => {
    const harness = createHarness({
      pingResponse: (message) => ({ success: false, id: message.id, error: 'probe failed' }),
    });
    const transport = createTransport(harness, { reconnectBaseDelayMs: 1000 });
    assert.equal(await transport.ensureConnected(), false);
    assert.equal(transport.isReady(), false);
    assert.equal(await transport.ensureConnected(), false);
    assert.equal(harness.ports.length, 1);
  });

  await test('waitUntilReady resolves true when an in-flight probe succeeds', async () => {
    const control: { respond: (() => void) | null } = { respond: null };
    const harness = createHarness({
      onPost: (message, port): void => {
        if (message.action === 'ping') {
          control.respond = (): void => {
            port.emitMessage({
              success: true,
              id: message.id,
              protocolVersion: 2,
              capabilities: HOST_CAPABILITIES,
            });
          };
        }
      },
    });
    const transport = createTransport(harness, { probeTimeoutMs: 500 });

    const readyPromise = transport.waitUntilReady(500);
    assert.notEqual(control.respond, null);
    control.respond?.();

    assert.equal(await readyPromise, true);
    assert.equal(transport.isReady(), true);
  });

  await test('calls reject while the port is not ready and after shutdown', async () => {
    const harness = createHarness({ pingResponse: capablePing });
    const transport = createTransport(harness);

    await assert.rejects(transport.call({ action: 'ping' }), /not ready/);
    await transport.ensureConnected();
    transport.shutdown();
    await assert.rejects(transport.call({ action: 'ping' }), /not ready|shut down/);
  });
});
