import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  LINUX_AUTO_ALLOW_DIAGNOSTIC_PHASES,
  buildLinuxAutoAllowArtifact,
  classifyLinuxAutoAllowBoundary,
} from './linux-auto-allow-diagnostics';

test('Linux auto-allow diagnostics expose the required ordered phases', () => {
  assert.deepEqual(LINUX_AUTO_ALLOW_DIAGNOSTIC_PHASES, [
    'firefox-extension-ready',
    'origin-page-load',
    'page-observer',
    'page-resource-candidates',
    'no-automatic-rule-creation',
    'explicit-whitelist-apply',
    'explicit-probe-traffic',
    'artifact-written',
  ]);
});

test('Linux auto-allow classifier reports the first failed phase as the boundary', () => {
  const boundary = classifyLinuxAutoAllowBoundary([
    { id: 'firefox-extension-ready', status: 'passed' },
    { id: 'origin-page-load', status: 'passed' },
    {
      id: 'explicit-whitelist-apply',
      status: 'failed',
      message: 'local whitelist missing api.example.test',
    },
    { id: 'explicit-probe-traffic', status: 'failed', message: 'dns did not converge' },
  ]);

  assert.deepEqual(boundary, {
    id: 'explicit-whitelist-apply',
    message: 'local whitelist missing api.example.test',
    recommendedNextAction:
      'Inspect explicit group rules, /var/lib/openpath/whitelist.txt, and openpath-update.service before changing browser behavior.',
  });
});

test('Linux auto-allow artifact preserves probes and diagnostics without changing behavior', () => {
  const artifact = buildLinuxAutoAllowArtifact({
    success: true,
    probes: [
      { id: 'fetch', host: 'api.fetch.example.test', url: 'http://api.fetch.example.test/fetch' },
      { id: 'xhr', host: 'api.xhr.example.test', url: 'http://api.xhr.example.test/xhr' },
      { id: 'image', host: 'image.example.test', url: 'http://image.example.test/pixel.png' },
      { id: 'script', host: 'cdn.example.test', url: 'http://cdn.example.test/asset.js' },
      { id: 'stylesheet', host: 'style.example.test', url: 'http://style.example.test/style.css' },
      { id: 'font', host: 'font.example.test', url: 'http://font.example.test/font.woff2' },
    ],
    diagnosticPhases: [
      { id: 'firefox-extension-ready', status: 'passed' },
      { id: 'origin-page-load', status: 'passed' },
      { id: 'page-observer', status: 'passed' },
      { id: 'page-resource-candidates', status: 'passed' },
      { id: 'no-automatic-rule-creation', status: 'passed' },
      { id: 'explicit-whitelist-apply', status: 'passed' },
      { id: 'explicit-probe-traffic', status: 'passed' },
      { id: 'artifact-written', status: 'passed' },
    ],
    diagnostics: {
      remoteWhitelist: 'api.fetch.example.test\n',
      localWhitelist: 'api.fetch.example.test\n',
      dnsmasqStatus: 'active',
      resolvConf: 'nameserver 127.0.0.1\n',
      nativeHostManifest: '{"name":"whitelist_native_host"}',
    },
  });

  assert.equal(artifact.platform, 'linux');
  assert.equal(artifact.success, true);
  assert.equal(artifact.failureBoundary.id, 'success');
  assert.equal(artifact.probes.length, 6);
  assert.deepEqual(
    artifact.probes.map((probe) => probe.id),
    ['fetch', 'xhr', 'image', 'script', 'stylesheet', 'font']
  );
  assert.equal(artifact.diagnostics.resolvConf, 'nameserver 127.0.0.1\n');
});
