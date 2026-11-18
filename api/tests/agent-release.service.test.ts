import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import express from 'express';
import type { Server } from 'node:http';
import { after, before, describe, test } from 'node:test';

import {
  publishAgentRelease,
  type PublishedAgentRelease,
  retireAgentRelease,
  type ActiveAgentRelease,
  type AgentReleaseFileRecord,
  type AgentReleaseManifestFile,
  type AgentReleaseRepository,
  type AgentRing,
} from '../src/services/agent-release.service.js';
import {
  getWindowsAgentFile,
  getWindowsAgentManifest,
} from '../src/services/machine-agent-delivery.service.js';
import { sendMachineServiceError } from '../src/routes/machines/helpers.js';
import { getAvailablePort } from './test-utils.js';

const noopSeen = (): Promise<void> => Promise.resolve();

class FakeRepository implements AgentReleaseRepository {
  ring: AgentRing | null = 'stable';
  active: ActiveAgentRelease | null = null;
  files = new Map<string, AgentReleaseFileRecord>();

  getActiveRelease(): Promise<ActiveAgentRelease | null> {
    return Promise.resolve(this.active);
  }

  getMachineRing(): Promise<AgentRing | null> {
    return Promise.resolve(this.ring);
  }

  getReleaseFile(build: string, path: string): Promise<AgentReleaseFileRecord | null> {
    return Promise.resolve(this.files.get(`${build}:${path}`) ?? null);
  }

  publishRelease(
    release: Omit<ActiveAgentRelease, 'files' | 'ring'> & { ring: AgentRing },
    files: (AgentReleaseManifestFile & { content: Buffer })[]
  ): Promise<void> {
    this.active = {
      build: release.build,
      ring: 'canary',
      sourceSha: release.sourceSha,
      signature: release.signature,
      files: files.map((file) => ({ path: file.path, sha256: file.sha256, size: file.size })),
    };
    for (const file of files) {
      this.files.set(`${release.build}:${file.path}`, {
        content: file.content,
        sha256: file.sha256,
        size: file.size,
      });
    }
    return Promise.resolve();
  }

  retireRelease(build: string): Promise<boolean> {
    if (this.active?.build === build) {
      this.active = null;
      return Promise.resolve(true);
    }
    return Promise.resolve(false);
  }

  setMachineRing(_hostname: string, ring: AgentRing): Promise<boolean> {
    this.ring = ring;
    return Promise.resolve(true);
  }
}

function fileInput(
  path: string,
  body: string
): { path: string; sha256: string; contentBase64: string } {
  const content = Buffer.from(body);
  return {
    path,
    sha256: createHash('sha256').update(content).digest('hex'),
    contentBase64: content.toString('base64'),
  };
}

async function publishFixture(repository: FakeRepository): Promise<PublishedAgentRelease> {
  const result = await publishAgentRelease(
    {
      sourceSha: '0123456789abcdef0123456789abcdef01234567',
      signature: 'test-signature',
      files: [fileInput('lib/Alpha.psm1', 'alpha'), fileInput('scripts/Run.ps1', 'run')],
    },
    repository
  );
  assert.ok(result.ok);
  return result.data;
}

let server: Server | undefined;
let baseUrl = '';

await describe('canary agent releases', { concurrency: false }, async () => {
  before(async () => {
    const { config, setConfigForTests } = await import('../src/config.js');
    setConfigForTests({ ...config, agentReleaseToken: 'release-token' });

    const { registerMachineDeliveryRoutes } = await import('../src/routes/machines/delivery.js');
    const app = express();
    app.use(express.json({ limit: '1mb' }));
    registerMachineDeliveryRoutes(app, { getCurrentEvaluationTime: () => new Date() });
    const port = await getAvailablePort();
    baseUrl = `http://127.0.0.1:${String(port)}`;
    server = app.listen(port);
    await new Promise<void>((resolve) => {
      server?.once('listening', () => {
        resolve();
      });
    });
  });

  after(async () => {
    await new Promise<void>((resolve, reject) => {
      if (!server) {
        resolve();
        return;
      }
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  });

  await test('a stable machine never sees a canary build', async () => {
    const repository = new FakeRepository();
    repository.ring = 'stable';
    await publishFixture(repository);

    const manifest = await getWindowsAgentManifest('pc-stable', {
      capabilityHeader: 'signed-release-v1',
      repository,
      onMachineSeen: noopSeen,
    });

    assert.ok(manifest.ok);
    assert.equal(manifest.data.ring, undefined);
    assert.equal(manifest.data.signature, undefined);
    assert.notEqual(manifest.data.build, repository.active?.build);
  });

  await test('a canary machine sees the active signed release', async () => {
    const repository = new FakeRepository();
    repository.ring = 'canary';
    const published = await publishFixture(repository);

    const manifest = await getWindowsAgentManifest('pc-canary', {
      capabilityHeader: 'signed-release-v1',
      repository,
      onMachineSeen: noopSeen,
    });

    assert.ok(manifest.ok);
    assert.equal(manifest.data.ring, 'canary');
    assert.equal(manifest.data.build, published.build);
    assert.equal(manifest.data.sourceSha, '0123456789abcdef0123456789abcdef01234567');
    assert.equal(manifest.data.signature, 'test-signature');
    assert.deepEqual(
      manifest.data.files.map((file) => file.path),
      ['lib/Alpha.psm1', 'scripts/Run.ps1']
    );
  });

  await test('a canary machine without an active release gets stable', async () => {
    const repository = new FakeRepository();
    repository.ring = 'canary';

    const manifest = await getWindowsAgentManifest('pc-canary', {
      capabilityHeader: 'signed-release-v1',
      repository,
      onMachineSeen: noopSeen,
    });

    assert.ok(manifest.ok);
    assert.equal(manifest.data.ring, undefined);
  });

  await test('an agent without the capability header stays on stable', async () => {
    const repository = new FakeRepository();
    repository.ring = 'canary';
    await publishFixture(repository);

    const manifest = await getWindowsAgentManifest('pc-canary', {
      repository,
      onMachineSeen: noopSeen,
    });

    assert.ok(manifest.ok);
    assert.equal(manifest.data.ring, undefined);
  });

  await test('a bad publish token is rejected before any release is read', async () => {
    const response = await fetch(`${baseUrl}/api/agent/windows/releases`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-openpath-release-token': 'wrong' },
      body: JSON.stringify({ sourceSha: 'a'.repeat(40), signature: 'x', files: [] }),
    });

    assert.equal(response.status, 403);
    assert.deepEqual(await response.json(), { success: false, error: 'Invalid release token' });
  });

  await test('a missing publish token is rejected', async () => {
    const response = await fetch(`${baseUrl}/api/agent/windows/releases`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sourceSha: 'a'.repeat(40), signature: 'x', files: [] }),
    });

    assert.equal(response.status, 403);
  });

  await test('a file hash mismatch at publish is rejected', async () => {
    const repository = new FakeRepository();
    const result = await publishAgentRelease(
      {
        sourceSha: '0123456789abcdef0123456789abcdef01234567',
        signature: 'test-signature',
        files: [
          {
            path: 'lib/Alpha.psm1',
            sha256: 'f'.repeat(64),
            contentBase64: Buffer.from('alpha').toString('base64'),
          },
        ],
      },
      repository
    );

    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'BAD_REQUEST');
    assert.match(result.error.message, /sha256 mismatch/);
    assert.equal(repository.active, null);
  });

  await test('retiring the active release returns its machines to stable', async () => {
    const repository = new FakeRepository();
    repository.ring = 'canary';
    const published = await publishFixture(repository);

    const retired = await retireAgentRelease(published.build, repository);
    assert.ok(retired.ok);

    const manifest = await getWindowsAgentManifest('pc-canary', {
      capabilityHeader: 'signed-release-v1',
      repository,
      onMachineSeen: noopSeen,
    });
    assert.ok(manifest.ok);
    assert.equal(manifest.data.ring, undefined);
  });

  await test('an old build during a download is a conflict and maps to 409', async () => {
    const repository = new FakeRepository();
    repository.ring = 'canary';
    const published = await publishFixture(repository);

    const result = await getWindowsAgentFile('pc-canary', 'lib/Alpha.psm1', {
      build: 'f'.repeat(64),
      capabilityHeader: 'signed-release-v1',
      repository,
      onMachineSeen: noopSeen,
    });

    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'CONFLICT');
    const status = { code: 0 };
    sendMachineServiceError(
      {
        status(code: number): { json: () => void } {
          status.code = code;
          return { json: (): void => undefined };
        },
      } as never,
      result.error
    );
    assert.equal(status.code, 409);

    const pinned = await getWindowsAgentFile('pc-canary', 'lib/Alpha.psm1', {
      build: published.build,
      capabilityHeader: 'signed-release-v1',
      repository,
      onMachineSeen: noopSeen,
    });
    assert.ok(pinned.ok);
    assert.equal(pinned.data.body.toString('utf8'), 'alpha');
  });

  await test('a file request for the stable build is served from the local package', async () => {
    const repository = new FakeRepository();
    repository.ring = 'stable';
    const stable = await getWindowsAgentManifest('pc-stable', {
      repository,
      onMachineSeen: noopSeen,
    });
    assert.ok(stable.ok);

    const result = await getWindowsAgentFile('pc-stable', 'OpenPath.ps1', {
      build: stable.data.build,
      repository,
      onMachineSeen: noopSeen,
    });

    assert.ok(result.ok);
    assert.ok(result.data.body.length > 0);
  });
});
