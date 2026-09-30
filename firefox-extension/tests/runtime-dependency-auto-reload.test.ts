import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { Tabs } from 'webextension-polyfill';

import {
  createRuntimeDependencyAutoReloadController,
  type AutoReloadDiagnosticEvent,
  type RuntimeDependencyAutoReloadController,
} from '../src/lib/runtime-dependency-auto-reload.js';

function waitForMs(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

interface AutoReloadHarness {
  controller: RuntimeDependencyAutoReloadController;
  events: AutoReloadDiagnosticEvent[];
  reloads: number[];
  setCurrentUrl: (url: string) => void;
}

function createAutoReloadHarness(options?: {
  capable?: () => boolean;
  currentUrl?: string;
  excludedUrl?: (url: string) => boolean;
  now?: () => number;
  coalesceMs?: number;
  maxNavigationAgeMs?: number;
  tabCooldownMs?: number;
  reloadImpl?: (tabId: number) => Promise<void>;
}): AutoReloadHarness {
  let currentUrl = options?.currentUrl ?? 'https://www.reddit.com/r/openpath';
  const reloads: number[] = [];
  const events: AutoReloadDiagnosticEvent[] = [];
  const browserTabs = {
    get: (tabId: number) => Promise.resolve({ id: tabId, url: currentUrl }),
    reload: (tabId: number): Promise<void> => {
      reloads.push(tabId);
      return options?.reloadImpl ? options.reloadImpl(tabId) : Promise.resolve();
    },
  } as unknown as Pick<Tabs.Static, 'get' | 'reload'>;

  const controller = createRuntimeDependencyAutoReloadController({
    browserTabs,
    isCapable: options?.capable ?? ((): boolean => true),
    ...(options?.excludedUrl ? { isExcludedUrl: options.excludedUrl } : {}),
    ...(options?.now ? { now: options.now } : {}),
    coalesceMs: options?.coalesceMs ?? 10,
    ...(options?.maxNavigationAgeMs !== undefined
      ? { maxNavigationAgeMs: options.maxNavigationAgeMs }
      : {}),
    ...(options?.tabCooldownMs !== undefined ? { tabCooldownMs: options.tabCooldownMs } : {}),
    recordEvent: (event) => {
      events.push(event);
    },
  });

  return {
    controller,
    events,
    reloads,
    setCurrentUrl: (url: string): void => {
      currentUrl = url;
    },
  };
}

function startNavigation(
  harness: AutoReloadHarness,
  tabId: number,
  url = 'https://www.reddit.com/r/openpath',
  method = 'GET'
): void {
  harness.controller.noteNavigationStarted({ tabId, url });
  harness.controller.noteMainFrameRequest({ tabId, url, method });
  harness.controller.noteNavigationCommitted({ tabId, url });
}

await describe('runtime dependency auto-reload', async () => {
  await test('reloads once when a cancelled render dependency becomes ready', async () => {
    const harness = createAutoReloadHarness();
    startNavigation(harness, 5);
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });

    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);

    assert.deepEqual(harness.reloads, [5]);
    assert.deepEqual(
      harness.events.map((event) => event.reason),
      ['reloaded']
    );
  });

  await test('coalesces a wave of ready dependencies into one reload', async () => {
    const harness = createAutoReloadHarness({ coalesceMs: 40 });
    startNavigation(harness, 5);
    for (const [host, type] of [
      ['www.redditstatic.com', 'stylesheet'],
      ['emoji.redditmedia.com', 'font'],
    ] as const) {
      harness.controller.noteDependencyCancelled({
        dependencyHost: host,
        frameId: 0,
        requestType: type,
        tabId: 5,
      });
    }

    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'emoji.redditmedia.com',
      requestType: 'font',
    });
    await waitForMs(80);

    assert.deepEqual(harness.reloads, [5]);
  });

  await test('ignores non-render types, sub-frame requests and unknown tabs', async () => {
    const harness = createAutoReloadHarness();
    startNavigation(harness, 5);
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'i.redd.it',
      frameId: 0,
      requestType: 'image',
      tabId: 5,
    });
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 2,
      requestType: 'stylesheet',
      tabId: 5,
    });
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'cdn.example',
      frameId: 0,
      requestType: 'script',
      tabId: 99,
    });

    for (const host of ['i.redd.it', 'www.redditstatic.com', 'cdn.example']) {
      harness.controller.noteDependencyReady({
        anchorHost: 'www.reddit.com',
        dependencyHost: host,
        requestType: 'stylesheet',
      });
    }
    await waitForMs(40);

    assert.deepEqual(harness.reloads, []);
    assert.deepEqual(harness.events, []);
  });

  await test('does not reload when a newer navigation replaced the cancelled one', async () => {
    const harness = createAutoReloadHarness();
    startNavigation(harness, 5);
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });

    startNavigation(harness, 5, 'https://www.reddit.com/r/other');
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);

    assert.deepEqual(harness.reloads, []);
  });

  await test('does not reload POST navigations or stale navigations', async () => {
    const post = createAutoReloadHarness();
    startNavigation(post, 5, 'https://www.reddit.com/', 'POST');
    post.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'script',
      tabId: 5,
    });
    post.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'script',
    });
    await waitForMs(40);
    assert.deepEqual(post.reloads, []);
    assert.deepEqual(
      post.events.map((event) => event.reason),
      ['navigation-not-get']
    );

    let currentNow = 1_000_000;
    const stale = createAutoReloadHarness({ now: () => currentNow, maxNavigationAgeMs: 30_000 });
    startNavigation(stale, 5);
    stale.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'script',
      tabId: 5,
    });
    currentNow += 31_000;
    stale.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'script',
    });
    await waitForMs(40);
    assert.deepEqual(stale.reloads, []);
    assert.deepEqual(
      stale.events.map((event) => event.reason),
      ['navigation-too-old']
    );
  });

  await test('reloads at most once per navigation', async () => {
    const harness = createAutoReloadHarness();
    startNavigation(harness, 5);
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);
    assert.deepEqual(harness.reloads, [5]);

    harness.controller.noteDependencyCancelled({
      dependencyHost: 'emoji.redditmedia.com',
      frameId: 0,
      requestType: 'font',
      tabId: 5,
    });
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'emoji.redditmedia.com',
      requestType: 'font',
    });
    await waitForMs(40);

    assert.deepEqual(harness.reloads, [5]);
    assert.deepEqual(
      harness.events.map((event) => event.reason),
      ['reloaded', 'already-reloaded']
    );
  });

  await test('enforces a per-tab cooldown between navigations', async () => {
    let currentNow = 1_000_000;
    const harness = createAutoReloadHarness({
      now: () => currentNow,
      tabCooldownMs: 30_000,
    });
    startNavigation(harness, 5);
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);
    assert.deepEqual(harness.reloads, [5]);

    currentNow += 5_000;
    startNavigation(harness, 5, 'https://www.reddit.com/r/other');
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);

    assert.deepEqual(harness.reloads, [5]);
    assert.ok(harness.events.some((event) => event.reason === 'tab-cooldown'));
  });

  await test('checks the live URL, exclusions and the host capability before reloading', async () => {
    const mismatch = createAutoReloadHarness();
    startNavigation(mismatch, 5);
    mismatch.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    mismatch.setCurrentUrl('https://www.reddit.com/r/different');
    mismatch.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);
    assert.deepEqual(mismatch.reloads, []);
    assert.deepEqual(
      mismatch.events.map((event) => event.reason),
      ['url-mismatch']
    );

    const fragmentOnly = createAutoReloadHarness();
    startNavigation(fragmentOnly, 5, 'https://www.reddit.com/r/openpath');
    fragmentOnly.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    fragmentOnly.setCurrentUrl('https://www.reddit.com/r/openpath#comments');
    fragmentOnly.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);
    assert.deepEqual(fragmentOnly.reloads, [5], 'fragment-only changes must still reload');

    const excluded = createAutoReloadHarness({
      currentUrl: 'moz-extension://unit-test/blocked/blocked.html',
      excludedUrl: (url) => url.startsWith('moz-extension://'),
    });
    startNavigation(excluded, 5, 'moz-extension://unit-test/blocked/blocked.html');
    excluded.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    excluded.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);
    assert.deepEqual(excluded.reloads, []);
    assert.deepEqual(
      excluded.events.map((event) => event.reason),
      ['excluded-url']
    );

    const incapable = createAutoReloadHarness({ capable: () => false });
    startNavigation(incapable, 5);
    incapable.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    incapable.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);
    assert.deepEqual(incapable.reloads, []);
    assert.deepEqual(
      incapable.events.map((event) => event.reason),
      ['capability-absent']
    );
  });

  await test('drops a pending reload when the tab is disposed and reports unavailable tabs', async () => {
    const harness = createAutoReloadHarness({ coalesceMs: 40 });
    startNavigation(harness, 5);
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    harness.controller.disposeTab(5);
    await waitForMs(80);
    assert.deepEqual(harness.reloads, []);
  });

  await test('keeps working when the reload call fails', async () => {
    const harness = createAutoReloadHarness({
      reloadImpl: () => Promise.reject(new Error('tab gone')),
    });
    startNavigation(harness, 5);
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);

    assert.deepEqual(harness.reloads, [5]);
    assert.ok(harness.events.some((event) => event.reason.startsWith('reload-failed')));
  });
});
