import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  clearLinuxAgentAptMetadataCache,
  getAgentArtifactRoots,
  stableAptMetadataAdvertisesLinuxAgentVersion,
} from '../src/lib/server-asset-artifacts.js';
import { buildWindowsAgentFileManifest } from '../src/lib/server-asset-windows.js';

void test('server-asset-artifacts exposes roots and parses apt metadata', () => {
  clearLinuxAgentAptMetadataCache();

  const roots = getAgentArtifactRoots();
  assert.equal(typeof roots.windowsAgentRoot, 'string');
  assert.equal(
    stableAptMetadataAdvertisesLinuxAgentVersion(
      'Package: openpath-dnsmasq\nVersion: 1.2.3-1\n',
      '1.2.3'
    ),
    true
  );
});

void test('the Windows agent file set ships the canary release public key', () => {
  const files = buildWindowsAgentFileManifest();
  const publicKey = files.find((file) => file.relativePath === 'lib/agent-release-public-key.xml');

  assert.ok(publicKey, 'lib/agent-release-public-key.xml must be part of the agent file set');
  assert.ok(publicKey.size > 0);
});
