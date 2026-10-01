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

  await test('ignores non-render types and sub-frame requests; reports unknown tabs', async () => {
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
    // Phase 2E E3: no silent discards; the unknown tab reports its reason while
    // non-render types and sub-frame requests never enter the repair path.
    assert.deepEqual(
      harness.events.map((event) => event.reason),
      ['navigation-unknown']
    );
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
    // Phase 2E E3: the superseded navigation reports its reason (no silent drop).
    assert.deepEqual(
      harness.events.map((event) => event.reason),
      ['navigation-mismatch']
    );
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

  await test('repairs a cancellation recorded before any navigation event (late background)', async () => {
    // Phase 2E E3 / S3: the background starts after the page load; no
    // onBeforeNavigate/onBeforeRequest/onCommitted ever reached it and the
    // cancellation only carries the frame-0 request's documentUrl.
    const harness = createAutoReloadHarness({ currentUrl: 'https://www.reddit.com/' });
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
      documentUrl: 'https://www.reddit.com/',
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

  await test('allows the reload when the main-frame method was never observed', async () => {
    const harness = createAutoReloadHarness({ currentUrl: 'https://www.reddit.com/' });
    harness.controller.noteNavigationStarted({ tabId: 5, url: 'https://www.reddit.com/' });
    harness.controller.noteNavigationCommitted({ tabId: 5, url: 'https://www.reddit.com/' });
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
  });

  await test('tolerates a replaceState path change after a history update', async () => {
    let currentNow = 1_000_000;
    const harness = createAutoReloadHarness({
      now: () => currentNow,
      currentUrl: 'https://www.reddit.com/r/openpath',
    });
    startNavigation(harness, 5);
    currentNow += 1_500;
    harness.controller.noteHistoryStateUpdated({
      tabId: 5,
      url: 'https://www.reddit.com/r/popular',
    });
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    harness.setCurrentUrl('https://www.reddit.com/r/popular');
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);

    assert.deepEqual(harness.reloads, [5]);
  });

  await test('never reloads another same-origin document without a history signal', async () => {
    const harness = createAutoReloadHarness();
    startNavigation(harness, 5, 'https://www.reddit.com/r/openpath');
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'stylesheet',
      tabId: 5,
    });
    // The tab moved to another same-origin path without any history update.
    harness.setCurrentUrl('https://www.reddit.com/r/other');
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'stylesheet',
    });
    await waitForMs(40);

    assert.deepEqual(harness.reloads, []);
    assert.deepEqual(
      harness.events.map((event) => event.reason),
      ['url-mismatch']
    );
  });

  await test('blocks form_submit commits even when the method is unknown', async () => {
    const harness = createAutoReloadHarness();
    harness.controller.noteNavigationStarted({ tabId: 5, url: 'https://www.reddit.com/search' });
    harness.controller.noteNavigationCommitted({
      tabId: 5,
      url: 'https://www.reddit.com/search',
      transitionType: 'form_submit',
    });
    harness.controller.noteDependencyCancelled({
      dependencyHost: 'www.redditstatic.com',
      frameId: 0,
      requestType: 'script',
      tabId: 5,
    });
    harness.controller.noteDependencyReady({
      anchorHost: 'www.reddit.com',
      dependencyHost: 'www.redditstatic.com',
      requestType: 'script',
    });
    await waitForMs(40);

    assert.deepEqual(harness.reloads, []);
    assert.deepEqual(
      harness.events.map((event) => event.reason),
      ['navigation-form-submit']
    );
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
