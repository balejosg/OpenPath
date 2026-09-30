import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { Browser, Runtime } from 'webextension-polyfill';

import {
  createPersistentNativeTransport,
  isProtocolVersionSupported,
  type PersistentNativeTransport,
} from '../src/lib/persistent-native-transport.js';
import { NATIVE_HOST_CAPABILITIES } from '../src/lib/runtime-dependency-protocol.js';

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

  await test('a request timeout marks the port unhealthy with exponential backoff', async () => {
    const harness = createHarness({ pingResponse: capablePing });
    const transport = createTransport(harness, {
      requestTimeoutMs: 20,
      reconnectBaseDelayMs: 1000,
    });
    await transport.ensureConnected();

    await assert.rejects(transport.call({ action: 'check-local-runtime-dependency' }), /timed out/);
    assert.equal(transport.isReady(), false);

    // Within the backoff window the transport refuses to reconnect.
    assert.equal(await transport.ensureConnected(), false);
    assert.equal(harness.ports.length, 1);

    // After the window elapses a new connection is attempted.
    harness.nowValue.value += 1500;
    assert.equal(await transport.ensureConnected(), true);
    assert.equal(harness.ports.length, 2);
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
