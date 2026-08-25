import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  provisionWindowsOfflineInstallerTemplate,
  WindowsOfflineInstallerProvisionError,
} from '../src/services/windows-offline-installer-provision.service.js';

void test('provisioning verify-only fails safely without contacting the network for invalid config', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'openpath-provision-service-'));
  let fetchCalled = false;

  try {
    await assert.rejects(
      () =>
        provisionWindowsOfflineInstallerTemplate({
          env: {
            OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR: path.join(root, 'templates'),
            OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR: path.join(root, 'artifacts'),
            OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: '4.1.0',
            OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: 'e'.repeat(40),
            OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: 'f'.repeat(64),
          },
          verifyOnly: true,
          fetchImpl: () => {
            fetchCalled = true;
            return Promise.resolve(new Response('unexpected'));
          },
        }),
      (error: unknown) =>
        error instanceof WindowsOfflineInstallerProvisionError && error.code === 'TEMPLATE_MISSING'
    );
    assert.equal(fetchCalled, false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
