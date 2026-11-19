import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import express from 'express';
import type { Server } from 'node:http';
import { after, before, describe, test } from 'node:test';

import {
  computeAgentBuild,
  getActiveAgentRelease,
  getAgentReleaseFile,
  listAgentRingHostnames,
  publishAgentRelease,
  type PublishedAgentRelease,
  retireAgentRelease,
  setMachineAgentRing,
  validateAgentReleaseInput,
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
import { buildAgentReleaseCanonicalText } from '../src/lib/agent-release-signature.js';
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

  listMachineHostnamesByRing(ring: AgentRing): Promise<string[]> {
    return Promise.resolve(this.ring === ring ? ['PC-Canary'] : []);
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

const SOURCE_SHA = '0123456789abcdef0123456789abcdef01234567';
const { privateKey: testPrivateKey, publicKey: testPublicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
});
const { publicKey: otherPublicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });

function signRelease(
  files: { path: string; sha256: string }[],
  privateKey: KeyObject = testPrivateKey
): string {
  const canonical = buildAgentReleaseCanonicalText({
    ring: 'canary',
    build: computeAgentBuild(files),
    sourceSha: SOURCE_SHA,
    files,
  });
  return sign('sha256', Buffer.from(canonical, 'utf8'), privateKey).toString('base64');
}

function fixtureFiles(): { path: string; sha256: string; contentBase64: string }[] {
  return [fileInput('lib/Alpha.psm1', 'alpha'), fileInput('scripts/Run.ps1', 'run')];
}

async function publishFixture(repository: FakeRepository): Promise<PublishedAgentRelease> {
  const files = fixtureFiles();
  const signature = signRelease(files);
  const result = await publishAgentRelease(
    { sourceSha: SOURCE_SHA, signature, files },
    repository,
    { publicKey: testPublicKey }
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
    assert.equal(manifest.data.signature, signRelease(fixtureFiles()));
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
      repository,
      { publicKey: testPublicKey }
    );

    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'BAD_REQUEST');
    assert.match(result.error.message, /sha256 mismatch/);
    assert.equal(repository.active, null);
  });

  await test('a signature that does not verify is rejected at publish', async () => {
    const repository = new FakeRepository();
    const files = fixtureFiles();
    const result = await publishAgentRelease(
      { sourceSha: SOURCE_SHA, signature: signRelease(files), files },
      repository,
      { publicKey: otherPublicKey }
    );

    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'BAD_REQUEST');
    assert.match(result.error.message, /signature/);
    assert.equal(repository.active, null);
  });

  await test('a signature signed over another file set is rejected at publish', async () => {
    const repository = new FakeRepository();
    const files = fixtureFiles();
    const tampered = [
      fileInput('lib/Alpha.psm1', 'alpha-changed'),
      fileInput('scripts/Run.ps1', 'run'),
    ];
    const result = await publishAgentRelease(
      { sourceSha: SOURCE_SHA, signature: signRelease(files), files: tampered },
      repository,
      { publicKey: testPublicKey }
    );

    assert.equal(result.ok, false);
    assert.equal(repository.active, null);
  });

  await test('a base64-encoded-twice signature is rejected at publish', async () => {
    const repository = new FakeRepository();
    const files = fixtureFiles();
    const doubleEncoded = Buffer.from(signRelease(files), 'utf8').toString('base64');
    const result = await publishAgentRelease(
      { sourceSha: SOURCE_SHA, signature: doubleEncoded, files },
      repository,
      { publicKey: testPublicKey }
    );

    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'BAD_REQUEST');
    assert.equal(repository.active, null);
  });

  await test('a publish without a usable public key is refused as unavailable', async () => {
    const repository = new FakeRepository();
    const files = fixtureFiles();
    const result = await publishAgentRelease(
      { sourceSha: SOURCE_SHA, signature: signRelease(files), files },
      repository,
      { publicKey: null }
    );

    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'UNAVAILABLE');
    assert.equal(repository.active, null);
  });

  await test('the shipped public key verifies nothing signed by a test key', async () => {
    const repository = new FakeRepository();
    const files = fixtureFiles();
    const result = await publishAgentRelease(
      { sourceSha: SOURCE_SHA, signature: signRelease(files), files },
      repository
    );

    assert.equal(result.ok, false);
    assert.equal(result.error.code, 'BAD_REQUEST');
  });

  await test('the canary ring hostnames are listed lower-cased', async () => {
    const repository = new FakeRepository();
    repository.ring = 'canary';
    assert.deepEqual(await listAgentRingHostnames('canary', repository), ['pc-canary']);
    assert.deepEqual(await listAgentRingHostnames('stable', repository), []);
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

  await test('release validation rejects every malformed input branch', async () => {
    const validFile = fileInput('lib/Alpha.psm1', 'alpha');
    const cases: {
      input: Parameters<typeof validateAgentReleaseInput>[0];
      message: RegExp;
    }[] = [
      {
        input: { sourceSha: 'not-a-commit', signature: 'sig', files: [validFile] },
        message: /sourceSha/,
      },
      {
        input: { sourceSha: SOURCE_SHA, signature: '   ', files: [validFile] },
        message: /signature/,
      },
      {
        input: { sourceSha: SOURCE_SHA, signature: 'sig', files: [] },
        message: /files/,
      },
      {
        input: {
          sourceSha: SOURCE_SHA,
          signature: 'sig',
          files: [{ ...validFile, path: '../escape' }],
        },
        message: /unsafe release path/,
      },
      {
        input: {
          sourceSha: SOURCE_SHA,
          signature: 'sig',
          files: [{ ...validFile, path: '/absolute' }],
        },
        message: /unsafe release path/,
      },
      {
        input: {
          sourceSha: SOURCE_SHA,
          signature: 'sig',
          files: [{ ...validFile, path: 'lib//nested' }],
        },
        message: /unsafe release path/,
      },
      {
        input: {
          sourceSha: SOURCE_SHA,
          signature: 'sig',
          files: [validFile, { ...validFile }],
        },
        message: /duplicate release path/,
      },
      {
        input: {
          sourceSha: SOURCE_SHA,
          signature: 'sig',
          files: [{ ...validFile, sha256: 'zz' }],
        },
        message: /invalid sha256/,
      },
      {
        input: {
          sourceSha: SOURCE_SHA,
          signature: 'sig',
          files: [{ ...validFile, contentBase64: '' }],
        },
        message: /empty content/,
      },
      {
        input: {
          sourceSha: SOURCE_SHA,
          signature: 'sig',
          files: [validFile],
          build: 'not-hex',
        },
        message: /invalid build fingerprint/,
      },
      {
        input: {
          sourceSha: SOURCE_SHA,
          signature: 'sig',
          files: [validFile],
          build: 'f'.repeat(64),
        },
        message: /declared build does not match/,
      },
    ];

    for (const { input, message } of cases) {
      const result = validateAgentReleaseInput(input);
      assert.equal(result.ok, false);
      if (!result.ok) {
        assert.match(result.error.message, message);
      }
    }
  });

  await test('release and ring helpers report unknown builds and machines', async () => {
    const repository = new FakeRepository();
    repository.ring = 'canary';
    const published = await publishFixture(repository);

    const active = await getActiveAgentRelease('canary', repository);
    assert.equal(active?.build, published.build);

    const file = await getAgentReleaseFile(
      published.build.toUpperCase(),
      'lib/Alpha.psm1',
      repository
    );
    assert.ok(file.ok);
    assert.equal(file.data.content.toString('utf8'), 'alpha');

    const missingFile = await getAgentReleaseFile(published.build, 'missing.ps1', repository);
    assert.equal(missingFile.ok, false);
    if (!missingFile.ok) {
      assert.equal(missingFile.error.code, 'NOT_FOUND');
    }

    const invalidBuild = await retireAgentRelease('not-a-build', repository);
    assert.equal(invalidBuild.ok, false);

    const missingBuild = await retireAgentRelease('f'.repeat(64), repository);
    assert.equal(missingBuild.ok, false);
    if (!missingBuild.ok) {
      assert.equal(missingBuild.error.code, 'NOT_FOUND');
    }

    const updated = await setMachineAgentRing('  PC-Canary  ', 'canary', repository);
    assert.ok(updated.ok);
    assert.deepEqual(updated.data, { hostname: 'pc-canary', ring: 'canary' });

    const blankHostname = await setMachineAgentRing('   ', 'canary', repository);
    assert.equal(blankHostname.ok, false);

    const badRing = await setMachineAgentRing('pc-canary', 'beta', repository);
    assert.equal(badRing.ok, false);

    repository.setMachineRing = () => Promise.resolve(false);
    const unknownMachine = await setMachineAgentRing('pc-ghost', 'stable', repository);
    assert.equal(unknownMachine.ok, false);
    if (!unknownMachine.ok) {
      assert.equal(unknownMachine.error.code, 'NOT_FOUND');
    }
  });
});
