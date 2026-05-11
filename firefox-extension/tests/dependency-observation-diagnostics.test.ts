import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  clearOpenPathDependencyObservationDiagnostics,
  configureOpenPathDependencyObservationDiagnostics,
  getOpenPathDependencyObservationDiagnostics,
  recordOpenPathDependencyObservationEvent,
} from '../src/lib/dependency-observation-diagnostics';

void describe('dependency observation diagnostics', () => {
  void test('records host-only dependency observations with bounded retention', async () => {
    const verifiedHosts: string[] = [];
    configureOpenPathDependencyObservationDiagnostics({
      enabled: true,
      phase: 'runtime-overlay',
      maxEvents: 1,
      verifyHost: (hostname) => {
        verifiedHosts.push(hostname);
        return Promise.resolve({ success: true, results: [{ hostname }] });
      },
    });

    recordOpenPathDependencyObservationEvent({
      source: 'webRequest.onBeforeRequest',
      tabId: 7,
      anchorHost: 'WWW.Reddit.COM',
      dependencyHost: 'WWW.RedditStatic.COM',
      type: 'script',
    });
    recordOpenPathDependencyObservationEvent({
      source: 'webNavigation.onBeforeNavigate',
      tabId: 7,
      hostname: 'WWW.Reddit.COM',
      type: 'main_frame',
    });

    await new Promise((resolve) => setTimeout(resolve, 0));

    const diagnostics = getOpenPathDependencyObservationDiagnostics();
    assert.equal(diagnostics.enabled, true);
    assert.equal(diagnostics.phase, 'runtime-overlay');
    assert.equal(diagnostics.events.length, 1);
    const [latestEvent] = diagnostics.events;
    assert.ok(latestEvent);
    assert.equal(latestEvent.hostname, 'www.reddit.com');
    assert.equal(latestEvent.nativeVerify?.success, true);
    assert.deepEqual(verifiedHosts, ['www.redditstatic.com', 'www.reddit.com']);
  });

  void test('does not record observations while disabled', () => {
    configureOpenPathDependencyObservationDiagnostics({ enabled: false });
    clearOpenPathDependencyObservationDiagnostics();

    recordOpenPathDependencyObservationEvent({
      source: 'webRequest.onBeforeRequest',
      dependencyHost: 'cdn.example',
      type: 'image',
    });

    assert.equal(getOpenPathDependencyObservationDiagnostics().events.length, 0);
  });
});
