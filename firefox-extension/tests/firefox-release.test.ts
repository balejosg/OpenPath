import { afterEach, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import type { SpawnSyncReturns } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
  utimesSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const extensionRoot = path.resolve(import.meta.dirname, '..');

interface FirefoxReleaseMetadata {
  extensionId: string;
  version: string;
  signatureSource: 'amo';
  signatureState: 'signed';
  installUrl?: string;
  payloadHash?: string;
}

interface PrepareFirefoxReleaseArtifactsResult {
  outputDir: string;
  outputXpiPath: string;
  metadataPath: string;
  metadata: FirefoxReleaseMetadata;
}

interface PrepareFirefoxReleaseArtifactsModule {
  prepareFirefoxReleaseArtifacts: (options: {
    extensionRoot?: string;
    signedXpiPath: string;
    installUrl?: string;
    outputDir?: string;
    manifestPath?: string;
    extensionId?: string;
    version?: string;
    payloadHash?: string;
  }) => PrepareFirefoxReleaseArtifactsResult;
}

interface SignFirefoxReleaseModule {
  buildAmoVersionDetailUrl: (options: {
    amoBaseUrl?: string;
    addonId: string;
    versionId?: string;
    version?: string;
  }) => URL;
  buildWebExtSignArgs: (options: {
    apiKey: string;
    apiSecret: string;
    artifactsDir: string;
    sourceDir?: string;
    approvalTimeoutMs?: number;
    requestTimeoutMs?: number;
    uploadSourceCode?: string;
    amoMetadata?: string;
  }) => string[];
  createAmoJwt: (options: {
    apiKey: string;
    apiSecret: string;
    nowMs?: number;
    jti?: string;
  }) => string;
  computeFirefoxReleasePayloadHash: (options: { sourceDir?: string }) => string;
  deriveAmoVersionFromPayloadHash: (payloadHash: string) => string;
  findSignedXpiArtifact: (artifactsDir: string) => string;
  isAmoVersionAlreadyExists: (output: string) => boolean;
  parseAmoVersionEditUrl: (output: string) => {
    addonId: string;
    versionId: string;
    editUrl: string;
  } | null;
  parseWebExtThrottleDelaySeconds: (output: string) => number | null;
  prepareSigningSourceDir: (options: { sourceDir?: string; version?: string }) => {
    sourceDir: string;
    effectiveVersion: string;
    cleanup: () => void;
  };
  resolveAmoRecoveryTiming: (options: {
    env?: NodeJS.ProcessEnv;
    deadlineMs?: number;
    nowMs?: number;
  }) => {
    timeoutMs: number;
    pollIntervalMs: number;
    remainingTotalMs?: number;
  };
  resolveWebExtSignTiming: (options: { env?: NodeJS.ProcessEnv; nowMs?: number }) => {
    totalTimeoutMs?: number;
    approvalTimeoutMs: number;
    requestTimeoutMs: number;
    processTimeoutBufferMs: number;
    processTimeoutMs?: number;
    deadlineMs?: number;
  };
  runWebExtSignWithRetry: (options: {
    args: string[];
    cwd: string;
    env?: NodeJS.ProcessEnv;
    spawnSyncImpl?: (
      command: string,
      args: string[],
      options: { cwd: string; encoding: 'utf8'; timeout?: number }
    ) => SpawnSyncReturns<string>;
    sleepSyncImpl?: (milliseconds: number) => void;
    nowImpl?: () => number;
    stdout?: { write: (chunk: string) => unknown };
    stderr?: { write: (chunk: string) => unknown };
    processTimeoutMs?: number;
    deadlineMs?: number;
  }) => SpawnSyncReturns<string> | { status: number };
  waitForAmoSignedXpi: (options: {
    apiKey: string;
    apiSecret: string;
    addonId: string;
    versionId?: string;
    version?: string;
    artifactsDir: string;
    timeoutMs: number;
    pollIntervalMs: number;
    fetchImpl: typeof fetch;
    sleepImpl?: (milliseconds: number) => Promise<void>;
    nowImpl?: () => number;
    stdout?: { write: (chunk: string) => unknown };
  }) => Promise<string>;
  writeAmoSigningStateArtifact: (options: {
    artifactsDir: string;
    state: string;
    addonId?: string;
    version?: string;
    versionId?: string;
    fileStatus?: string;
    lastPollAt?: string;
    message?: string;
  }) => {
    artifactPath: string;
    artifact: {
      state: string;
      addonId: string;
      version: string;
      versionId: string;
      fileStatus: string;
      lastPollAt: string;
      message?: string;
    };
  };
}

interface VerifyFirefoxReleaseArtifactsModule {
  verifyFirefoxReleaseArtifacts: (options: {
    releaseDir: string;
    payloadHash: string;
  }) => FirefoxReleaseMetadata;
}

interface BuildFirefoxSourceSubmissionModule {
  buildFirefoxSourceSubmission: (options?: {
    rootDir?: string;
    outputPath?: string;
    entries?: string[];
  }) => {
    outputPath: string;
    entries: string[];
  };
}

interface UploadFirefoxAmoSourceModule {
  parseAmoThrottleDelaySeconds: (body: unknown) => number | null;
  uploadFirefoxAmoSource: (options: {
    apiKey: string;
    apiSecret: string;
    addonId?: string;
    versionId?: string;
    version?: string;
    sourceArchive?: string;
    metadataPath?: string;
    amoBaseUrl?: string;
    fetchImpl?: typeof fetch;
    sourceOnly?: boolean;
    metadataOnly?: boolean;
    verify?: boolean;
    waitForThrottle?: boolean;
    maxThrottleWaitSeconds?: number;
    retryBufferSeconds?: number;
    maxRetries?: number;
    sleepImpl?: (milliseconds: number) => Promise<void>;
    stdout?: { write: (chunk: string) => unknown };
  }) => Promise<unknown>;
}

interface VerifyFirefoxAmoVersionModule {
  verifyFirefoxAmoVersion: (options: {
    apiKey: string;
    apiSecret: string;
    addonId?: string;
    versionId?: string;
    version?: string;
    amoBaseUrl?: string;
    requireSource?: boolean;
    requireApprovalNotes?: boolean;
    requireReleaseNotes?: boolean;
    fetchImpl?: typeof fetch;
  }) => Promise<{
    versionId: number | string;
    version: string;
    channel: string;
    fileStatus: string;
    sourcePresent: boolean;
    approvalNotesPresent: boolean;
    releaseNotesPresent: boolean;
  }>;
}

interface SyncFirefoxAmoPolicyModule {
  syncFirefoxAmoPolicy: (options: {
    apiKey: string;
    apiSecret: string;
    addonId?: string;
    privacyPath?: string;
    amoBaseUrl?: string;
    fetchImpl?: typeof fetch;
  }) => Promise<{ privacyPolicyPresent: boolean }>;
}

interface VerifyFirefoxAmoSubmissionModule {
  verifyFirefoxAmoSubmission: (options?: {
    manifestPath?: string;
    sourceArchive?: string;
    metadataPath?: string;
  }) => {
    required: boolean;
    sourceArchive: string;
    metadataPath: string;
    approvalNotes?: string;
    releaseNotes?: Record<string, string>;
  };
}

const { prepareFirefoxReleaseArtifacts } =
  (await import('../build-firefox-release.mjs')) as PrepareFirefoxReleaseArtifactsModule;
const { buildFirefoxSourceSubmission } =
  (await import('../build-firefox-source-submission.mjs')) as BuildFirefoxSourceSubmissionModule;
const { parseAmoThrottleDelaySeconds, uploadFirefoxAmoSource } =
  (await import('../upload-firefox-amo-source.mjs')) as UploadFirefoxAmoSourceModule;
const { verifyFirefoxAmoVersion } =
  (await import('../verify-firefox-amo-version.mjs')) as VerifyFirefoxAmoVersionModule;
const { syncFirefoxAmoPolicy } =
  (await import('../sync-firefox-amo-policy.mjs')) as SyncFirefoxAmoPolicyModule;
const { verifyFirefoxAmoSubmission } =
  (await import('../verify-firefox-amo-submission.mjs')) as VerifyFirefoxAmoSubmissionModule;
const {
  buildAmoVersionDetailUrl,
  buildWebExtSignArgs,
  createAmoJwt,
  computeFirefoxReleasePayloadHash,
  deriveAmoVersionFromPayloadHash,
  findSignedXpiArtifact,
  isAmoVersionAlreadyExists,
  parseAmoVersionEditUrl,
  parseWebExtThrottleDelaySeconds,
  prepareSigningSourceDir,
  resolveAmoRecoveryTiming,
  resolveWebExtSignTiming,
  runWebExtSignWithRetry,
  waitForAmoSignedXpi,
  writeAmoSigningStateArtifact,
} = (await import('../sign-firefox-release.mjs')) as SignFirefoxReleaseModule;
const { verifyFirefoxReleaseArtifacts } =
  (await import('../verify-firefox-release-artifacts.mjs')) as VerifyFirefoxReleaseArtifactsModule;

const tempDirectories: string[] = [];

function createTempDir(prefix: string): string {
  const dir = mkdtempSync(path.join(tmpdir(), prefix));
  tempDirectories.push(dir);
  return dir;
}

function requestInputToUrl(input: RequestInfo | URL): string {
  if (input instanceof Request) {
    return input.url;
  }
  if (input instanceof URL) {
    return input.href;
  }
  return input;
}

afterEach(() => {
  while (tempDirectories.length > 0) {
    const dir = tempDirectories.pop();
    if (dir) {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

void describe('Firefox release signing helpers', () => {
  void test('build-xpi.sh falls back when zip is unavailable', () => {
    const workingDir = createTempDir('openpath-build-xpi-');
    const fixtureDir = path.join(workingDir, 'extension');
    const fakeBinDir = path.join(workingDir, 'bin');
    const version = '9.9.9';
    const xpiPath = path.join(fixtureDir, `monitor-bloqueos-red-${version}.xpi`);

    mkdirSync(fixtureDir, { recursive: true });
    mkdirSync(fakeBinDir, { recursive: true });
    mkdirSync(path.join(fixtureDir, 'popup'), { recursive: true });
    mkdirSync(path.join(fixtureDir, 'icons'), { recursive: true });
    mkdirSync(path.join(fixtureDir, 'blocked'), { recursive: true });
    mkdirSync(path.join(fixtureDir, 'dist'), { recursive: true });

    writeFileSync(
      path.join(fixtureDir, 'manifest.json'),
      `${JSON.stringify({ version }, null, 2)}\n`
    );
    writeFileSync(path.join(fixtureDir, 'PRIVACY.md'), '# Privacy\n');
    writeFileSync(path.join(fixtureDir, 'popup', 'index.html'), '<html></html>\n');
    writeFileSync(path.join(fixtureDir, 'icons', 'icon.svg'), '<svg />\n');
    writeFileSync(path.join(fixtureDir, 'blocked', 'index.html'), '<html>blocked</html>\n');
    writeFileSync(path.join(fixtureDir, 'dist', 'background.js'), 'console.log("ok");\n');
    writeFileSync(
      path.join(fixtureDir, 'build-xpi.sh'),
      readFileSync(path.join(extensionRoot, 'build-xpi.sh'))
    );
    writeFileSync(
      path.join(fakeBinDir, 'zip'),
      '#!/bin/sh\necho "zip unavailable" >&2\nexit 127\n'
    );
    chmodSync(path.join(fakeBinDir, 'zip'), 0o755);

    execFileSync('bash', ['build-xpi.sh'], {
      cwd: fixtureDir,
      env: {
        ...process.env,
        PATH: `${fakeBinDir}:${process.env.PATH ?? ''}`,
      },
      encoding: 'utf8',
    });

    assert.ok(
      existsSync(xpiPath),
      'build-xpi.sh should still create the XPI when zip is unavailable'
    );
    assert.equal(readFileSync(xpiPath).subarray(0, 2).toString('utf8'), 'PK');
  });

  void test('prepareFirefoxReleaseArtifacts writes metadata and copies the signed XPI', () => {
    const workingDir = createTempDir('openpath-firefox-release-');
    const signedXpiPath = path.join(workingDir, 'signed-input.xpi');
    const outputDir = path.join(workingDir, 'firefox-release');

    writeFileSync(signedXpiPath, 'signed-xpi-payload');

    const result = prepareFirefoxReleaseArtifacts({
      extensionRoot,
      signedXpiPath,
      installUrl: 'https://downloads.example/openpath-firefox-extension.xpi',
      outputDir,
      payloadHash: 'a'.repeat(64),
    });

    assert.equal(result.metadata.extensionId, 'monitor-bloqueos@openpath');
    assert.equal(result.metadata.version, '2.0.0');
    assert.equal(
      result.metadata.installUrl,
      'https://downloads.example/openpath-firefox-extension.xpi'
    );
    assert.equal(result.metadata.payloadHash, 'a'.repeat(64));
    assert.equal(result.metadata.signatureSource, 'amo');
    assert.equal(result.metadata.signatureState, 'signed');
    assert.equal(result.outputXpiPath, path.join(outputDir, 'openpath-firefox-extension.xpi'));
    assert.equal(result.metadataPath, path.join(outputDir, 'metadata.json'));
  });

  void test('verifyFirefoxReleaseArtifacts accepts a matching signed release directory', () => {
    const workingDir = createTempDir('openpath-firefox-release-verify-');
    const releaseDir = path.join(workingDir, 'firefox-release');

    mkdirSync(releaseDir, { recursive: true });
    writeFileSync(path.join(releaseDir, 'openpath-firefox-extension.xpi'), 'signed');
    writeFileSync(
      path.join(releaseDir, 'metadata.json'),
      `${JSON.stringify(
        {
          extensionId: 'monitor-bloqueos@openpath',
          version: '2.0.0.123.1',
          payloadHash: 'b'.repeat(64),
          signatureSource: 'amo',
          signatureState: 'signed',
        },
        null,
        2
      )}\n`
    );

    const metadata = verifyFirefoxReleaseArtifacts({
      releaseDir,
      payloadHash: 'b'.repeat(64),
    });

    assert.equal(metadata.extensionId, 'monitor-bloqueos@openpath');
    assert.equal(metadata.version, '2.0.0.123.1');
    assert.equal(metadata.payloadHash, 'b'.repeat(64));
    assert.equal(metadata.signatureSource, 'amo');
    assert.equal(metadata.signatureState, 'signed');
  });

  void test('verifyFirefoxReleaseArtifacts rejects release metadata without AMO signature evidence', () => {
    const workingDir = createTempDir('openpath-firefox-release-verify-');
    const releaseDir = path.join(workingDir, 'firefox-release');

    mkdirSync(releaseDir, { recursive: true });
    writeFileSync(path.join(releaseDir, 'openpath-firefox-extension.xpi'), 'signed');
    writeFileSync(
      path.join(releaseDir, 'metadata.json'),
      `${JSON.stringify({
        extensionId: 'monitor-bloqueos@openpath',
        version: '2.0.0.123.1',
        payloadHash: 'b'.repeat(64),
      })}\n`
    );

    assert.throws(
      () =>
        verifyFirefoxReleaseArtifacts({
          releaseDir,
          payloadHash: 'b'.repeat(64),
        }),
      /signatureSource/
    );
  });

  void test('verifyFirefoxReleaseArtifacts rejects a mismatched payload hash', () => {
    const workingDir = createTempDir('openpath-firefox-release-verify-');
    const releaseDir = path.join(workingDir, 'firefox-release');

    mkdirSync(releaseDir, { recursive: true });
    writeFileSync(path.join(releaseDir, 'openpath-firefox-extension.xpi'), 'signed');
    writeFileSync(
      path.join(releaseDir, 'metadata.json'),
      `${JSON.stringify({
        extensionId: 'monitor-bloqueos@openpath',
        version: '2.0.0.123.1',
        signatureSource: 'amo',
        signatureState: 'signed',
        payloadHash: 'c'.repeat(64),
      })}\n`
    );

    assert.throws(
      () =>
        verifyFirefoxReleaseArtifacts({
          releaseDir,
          payloadHash: 'd'.repeat(64),
        }),
      /payloadHash mismatch/
    );
  });

  void test('verifyFirefoxReleaseArtifacts rejects missing signed XPI', () => {
    const workingDir = createTempDir('openpath-firefox-release-verify-');
    const releaseDir = path.join(workingDir, 'firefox-release');

    mkdirSync(releaseDir, { recursive: true });
    writeFileSync(
      path.join(releaseDir, 'metadata.json'),
      `${JSON.stringify({
        extensionId: 'monitor-bloqueos@openpath',
        version: '2.0.0.123.1',
        payloadHash: 'e'.repeat(64),
      })}\n`
    );

    assert.throws(
      () =>
        verifyFirefoxReleaseArtifacts({
          releaseDir,
          payloadHash: 'e'.repeat(64),
        }),
      /openpath-firefox-extension\.xpi not found/
    );
  });

  void test('buildWebExtSignArgs requests unlisted signing with explicit artifact output', () => {
    const args = buildWebExtSignArgs({
      apiKey: 'user:123:456',
      apiSecret: 'top-secret',
      artifactsDir: 'build/firefox-release/raw-signed',
      sourceDir: extensionRoot,
      approvalTimeoutMs: 2_700_000,
      requestTimeoutMs: 120_000,
    });

    assert.deepEqual(args, [
      '--yes',
      '--no-install',
      'web-ext',
      'sign',
      '--channel=unlisted',
      `--source-dir=${extensionRoot}`,
      '--artifacts-dir=build/firefox-release/raw-signed',
      '--api-key=user:123:456',
      '--api-secret=top-secret',
      '--approval-timeout=2700000',
      '--timeout=120000',
    ]);
  });

  void test('buildWebExtSignArgs preserves an explicit zero approval timeout', () => {
    const args = buildWebExtSignArgs({
      apiKey: 'user:123:456',
      apiSecret: 'top-secret',
      artifactsDir: 'build/firefox-release/raw-signed',
      sourceDir: extensionRoot,
      approvalTimeoutMs: 0,
      requestTimeoutMs: 120_000,
    });

    assert.ok(
      args.includes('--approval-timeout=0'),
      'approval-timeout=0 must reach web-ext so OpenPath can poll AMO explicitly'
    );
  });

  void test('buildWebExtSignArgs uploads AMO source and reviewer metadata when provided', () => {
    const args = buildWebExtSignArgs({
      apiKey: 'user:123:456',
      apiSecret: 'top-secret',
      artifactsDir: 'build/firefox-release/raw-signed',
      sourceDir: extensionRoot,
      uploadSourceCode: 'build/firefox-source-submission/openpath-firefox-source.zip',
      amoMetadata: 'amo-review-metadata.json',
    });

    assert.ok(
      args.includes(
        '--upload-source-code=build/firefox-source-submission/openpath-firefox-source.zip'
      )
    );
    assert.ok(args.includes('--amo-metadata=amo-review-metadata.json'));
  });

  void test('buildFirefoxSourceSubmission includes human-readable source and excludes generated output', () => {
    const workingDir = createTempDir('openpath-firefox-source-submission-');
    const outputPath = path.join(workingDir, 'openpath-firefox-source.zip');

    const result = buildFirefoxSourceSubmission({ outputPath });

    assert.equal(result.outputPath, outputPath);
    assert.ok(existsSync(outputPath));
    assert.equal(readFileSync(outputPath).subarray(0, 2).toString('utf8'), 'PK');

    for (const expected of [
      'package.json',
      'package-lock.json',
      'tsconfig.base.json',
      'firefox-extension/manifest.json',
      'firefox-extension/package.json',
      'firefox-extension/tsconfig.json',
      'firefox-extension/tsconfig.build.json',
      'firefox-extension/SOURCE_REVIEW_NOTES.md',
      'firefox-extension/AMO.md',
      'firefox-extension/PRIVACY.md',
      'firefox-extension/native/openpath-native-host.py',
      'firefox-extension/native/whitelist_native_host.json',
      'firefox-extension/src/background.ts',
      'firefox-extension/tests/manifest-policy.test.ts',
      'firefox-extension/popup/popup.html',
      'firefox-extension/blocked/blocked.html',
      'firefox-extension/icons/icon-48.png',
    ]) {
      assert.ok(result.entries.includes(expected), `source package should include ${expected}`);
    }

    for (const entry of result.entries) {
      assert.ok(!entry.includes('/dist/'), `source package should exclude dist files: ${entry}`);
      assert.ok(!entry.includes('/build/'), `source package should exclude build files: ${entry}`);
      assert.ok(
        !entry.includes('/node_modules/'),
        `source package should exclude node_modules files: ${entry}`
      );
      assert.ok(!entry.endsWith('.tsbuildinfo'), `source package should exclude ${entry}`);
    }
  });

  void test('resolveWebExtSignTiming keeps release signing under a finite process timeout', () => {
    const timing = resolveWebExtSignTiming({
      nowMs: 1_000,
      env: {
        WEB_EXT_SIGN_TOTAL_TIMEOUT_SECONDS: '1800',
        WEB_EXT_SIGN_APPROVAL_TIMEOUT_SECONDS: '1200',
        WEB_EXT_SIGN_PROCESS_TIMEOUT_BUFFER_SECONDS: '120',
      },
    });

    assert.equal(timing.totalTimeoutMs, 1_800_000);
    assert.equal(timing.approvalTimeoutMs, 1_200_000);
    assert.equal(timing.processTimeoutBufferMs, 120_000);
    assert.equal(timing.processTimeoutMs, 1_320_000);
    assert.equal(timing.deadlineMs, 1_801_000);
  });

  void test('resolveAmoRecoveryTiming limits recovery to the remaining total signing budget', () => {
    const timing = resolveAmoRecoveryTiming({
      nowMs: 1_500_000,
      deadlineMs: 1_800_000,
      env: {
        WEB_EXT_SIGN_RECOVERY_TIMEOUT_SECONDS: '1800',
        WEB_EXT_SIGN_RECOVERY_POLL_SECONDS: '30',
      },
    });

    assert.equal(timing.timeoutMs, 300_000);
    assert.equal(timing.remainingTotalMs, 300_000);
    assert.equal(timing.pollIntervalMs, 30_000);
  });

  void test('resolveAmoRecoveryTiming fails clearly when the total signing deadline is exhausted', () => {
    assert.throws(
      () =>
        resolveAmoRecoveryTiming({
          nowMs: 1_800_001,
          deadlineMs: 1_800_000,
          env: {
            WEB_EXT_SIGN_RECOVERY_TIMEOUT_SECONDS: '1800',
          },
        }),
      /AMO signing exhausted total timeout before signed XPI recovery could start/
    );
  });

  void test('findSignedXpiArtifact picks the newest XPI from the artifacts directory', () => {
    const artifactsDir = createTempDir('openpath-firefox-artifacts-');
    const olderXpiPath = path.join(artifactsDir, 'older.xpi');
    const newerXpiPath = path.join(artifactsDir, 'newer.xpi');

    writeFileSync(olderXpiPath, 'older');
    writeFileSync(newerXpiPath, 'newer');
    utimesSync(olderXpiPath, new Date('2026-03-26T10:00:00Z'), new Date('2026-03-26T10:00:00Z'));
    utimesSync(newerXpiPath, new Date('2026-03-26T11:00:00Z'), new Date('2026-03-26T11:00:00Z'));

    assert.equal(findSignedXpiArtifact(artifactsDir), newerXpiPath);
  });

  void test('parseWebExtThrottleDelaySeconds reads AMO throttling responses', () => {
    assert.equal(
      parseWebExtThrottleDelaySeconds(
        'WebExtError: Submission failed (2): Unknown Error\n' +
          '{ "detail": "Request was throttled. Expected available in 631 seconds." }'
      ),
      631
    );
    assert.equal(parseWebExtThrottleDelaySeconds('WebExtError: unrelated failure'), null);
  });

  void test('verifyFirefoxAmoVersion accepts a reviewed source and approval notes response', async () => {
    const requests: string[] = [];

    const result = await verifyFirefoxAmoVersion({
      apiKey: 'user:123:456',
      apiSecret: 'secret',
      addonId: 'monitor-bloqueos@openpath',
      version: '2.0.1',
      requireSource: true,
      requireApprovalNotes: true,
      fetchImpl: (input) => {
        requests.push(requestInputToUrl(input));
        return Promise.resolve(
          new Response(
            JSON.stringify({
              id: 6249209,
              version: '2.0.1',
              channel: 'unlisted',
              source: 'https://addons.mozilla.org/files/source.zip',
              approval_notes: 'Reviewer notes',
              release_notes: { 'en-US': 'Version notes' },
              file: { status: 'unreviewed' },
            }),
            { status: 200 }
          )
        );
      },
    });

    assert.equal(
      requests[0],
      'https://addons.mozilla.org/api/v5/addons/addon/monitor-bloqueos%40openpath/versions/v2.0.1/'
    );
    assert.deepEqual(result, {
      versionId: 6249209,
      version: '2.0.1',
      channel: 'unlisted',
      fileStatus: 'unreviewed',
      sourcePresent: true,
      approvalNotesPresent: true,
      releaseNotesPresent: true,
    });
  });

  void test('verifyFirefoxAmoVersion fails when required source is missing', async () => {
    await assert.rejects(
      verifyFirefoxAmoVersion({
        apiKey: 'user:123:456',
        apiSecret: 'secret',
        addonId: 'monitor-bloqueos@openpath',
        versionId: '6249209',
        requireSource: true,
        fetchImpl: () =>
          Promise.resolve(
            new Response(
              JSON.stringify({
                id: 6249209,
                version: '2.0.1',
                channel: 'unlisted',
                source: null,
                approval_notes: 'Reviewer notes',
                file: { status: 'unreviewed' },
              }),
              { status: 200 }
            )
          ),
      }),
      /AMO version 6249209 is missing source/
    );
  });

  void test('verifyFirefoxAmoVersion fails when required approval notes are missing', async () => {
    await assert.rejects(
      verifyFirefoxAmoVersion({
        apiKey: 'user:123:456',
        apiSecret: 'secret',
        addonId: 'monitor-bloqueos@openpath',
        versionId: '6249209',
        requireApprovalNotes: true,
        fetchImpl: () =>
          Promise.resolve(
            new Response(
              JSON.stringify({
                id: 6249209,
                version: '2.0.1',
                channel: 'unlisted',
                source: 'https://addons.mozilla.org/files/source.zip',
                approval_notes: ' ',
                file: { status: 'unreviewed' },
              }),
              { status: 200 }
            )
          ),
      }),
      /AMO version 6249209 is missing approval_notes/
    );
  });

  void test('verifyFirefoxAmoVersion fails when required release notes are missing', async () => {
    await assert.rejects(
      verifyFirefoxAmoVersion({
        apiKey: 'user:123:456',
        apiSecret: 'secret',
        addonId: 'monitor-bloqueos@openpath',
        versionId: '6249209',
        requireReleaseNotes: true,
        fetchImpl: () =>
          Promise.resolve(
            new Response(
              JSON.stringify({
                id: 6249209,
                version: '2.0.1',
                channel: 'unlisted',
                source: 'https://addons.mozilla.org/files/source.zip',
                approval_notes: 'Reviewer notes',
                release_notes: { 'en-US': ' ' },
                file: { status: 'unreviewed' },
              }),
              { status: 200 }
            )
          ),
      }),
      /AMO version 6249209 is missing release_notes/
    );
  });

  void test('uploadFirefoxAmoSource requires an explicit AMO version target', async () => {
    await assert.rejects(
      uploadFirefoxAmoSource({
        apiKey: 'user:123:456',
        apiSecret: 'secret',
        sourceOnly: true,
        verify: false,
      }),
      /AMO version id or version is required/
    );
  });

  void test('uploadFirefoxAmoSource rejects mutually exclusive upload modes', async () => {
    await assert.rejects(
      uploadFirefoxAmoSource({
        apiKey: 'user:123:456',
        apiSecret: 'secret',
        versionId: '6249209',
        sourceOnly: true,
        metadataOnly: true,
        verify: false,
      }),
      /--source-only and --metadata-only cannot be used together/
    );
  });

  void test('uploadFirefoxAmoSource patches reviewer and version notes together', async () => {
    const workingDir = createTempDir('openpath-firefox-upload-source-');
    const metadataPath = path.join(workingDir, 'amo-review-metadata.json');
    const requestBodies: unknown[] = [];

    writeFileSync(
      metadataPath,
      `${JSON.stringify({
        version: {
          approval_notes: 'Readable reviewer notes',
          release_notes: { 'en-US': 'Readable version notes' },
        },
      })}\n`
    );

    await uploadFirefoxAmoSource({
      apiKey: 'user:123:456',
      apiSecret: 'secret',
      versionId: '6249209',
      metadataPath,
      metadataOnly: true,
      verify: false,
      fetchImpl: (_input, init) => {
        const body = init?.body;
        if (typeof body !== 'string') {
          throw new TypeError('Expected JSON metadata request body');
        }
        requestBodies.push(JSON.parse(body));
        return Promise.resolve(new Response(JSON.stringify({ id: 6249209 }), { status: 200 }));
      },
    });

    assert.deepEqual(requestBodies, [
      {
        approval_notes: 'Readable reviewer notes',
        release_notes: { 'en-US': 'Readable version notes' },
      },
    ]);
  });

  void test('verifyFirefoxAmoSubmission requires localized version notes', () => {
    const workingDir = createTempDir('openpath-firefox-amo-submission-');
    const manifestPath = path.join(workingDir, 'manifest.json');
    const sourceArchive = path.join(workingDir, 'source.zip');
    const metadataPath = path.join(workingDir, 'amo-review-metadata.json');

    writeFileSync(
      manifestPath,
      `${JSON.stringify({
        browser_specific_settings: {
          gecko: {
            data_collection_permissions: {
              required: ['browsingActivity'],
            },
          },
        },
      })}\n`
    );
    writeFileSync(sourceArchive, 'zip');
    writeFileSync(
      metadataPath,
      `${JSON.stringify({
        version: {
          approval_notes: 'Readable reviewer notes',
          release_notes: { 'en-US': 'Readable version notes' },
        },
      })}\n`
    );

    assert.deepEqual(
      verifyFirefoxAmoSubmission({ manifestPath, sourceArchive, metadataPath }).releaseNotes,
      { 'en-US': 'Readable version notes' }
    );

    writeFileSync(
      metadataPath,
      `${JSON.stringify({ version: { approval_notes: 'Readable reviewer notes' } })}\n`
    );

    assert.throws(
      () => verifyFirefoxAmoSubmission({ manifestPath, sourceArchive, metadataPath }),
      /AMO metadata must include version.release_notes/
    );
  });

  void test('uploadFirefoxAmoSource waits for metadata throttles only when enabled', async () => {
    const workingDir = createTempDir('openpath-firefox-upload-source-');
    const metadataPath = path.join(workingDir, 'amo-review-metadata.json');
    const waits: number[] = [];
    let attempts = 0;

    writeFileSync(
      metadataPath,
      `${JSON.stringify({ version: { approval_notes: 'Reviewer notes' } })}\n`
    );

    await uploadFirefoxAmoSource({
      apiKey: 'user:123:456',
      apiSecret: 'secret',
      versionId: '6249209',
      metadataPath,
      metadataOnly: true,
      verify: false,
      waitForThrottle: true,
      maxThrottleWaitSeconds: 700,
      retryBufferSeconds: 3,
      maxRetries: 1,
      sleepImpl: (milliseconds) => {
        waits.push(milliseconds);
        return Promise.resolve();
      },
      fetchImpl: () => {
        attempts += 1;
        if (attempts === 1) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                detail: 'Request was throttled. Expected available in 631 seconds.',
              }),
              { status: 429, statusText: 'Too Many Requests' }
            )
          );
        }

        return Promise.resolve(new Response(JSON.stringify({ id: 6249209 }), { status: 200 }));
      },
    });

    assert.equal(attempts, 2);
    assert.deepEqual(waits, [634_000]);
  });

  void test('uploadFirefoxAmoSource defaults wait-for-throttle metadata retries to three', async () => {
    const workingDir = createTempDir('openpath-firefox-upload-source-');
    const metadataPath = path.join(workingDir, 'amo-review-metadata.json');
    const waits: number[] = [];
    let attempts = 0;

    writeFileSync(
      metadataPath,
      `${JSON.stringify({ version: { approval_notes: 'Reviewer notes' } })}\n`
    );

    await uploadFirefoxAmoSource({
      apiKey: 'user:123:456',
      apiSecret: 'secret',
      versionId: '6249209',
      metadataPath,
      metadataOnly: true,
      verify: false,
      waitForThrottle: true,
      maxThrottleWaitSeconds: 700,
      retryBufferSeconds: 3,
      sleepImpl: (milliseconds) => {
        waits.push(milliseconds);
        return Promise.resolve();
      },
      fetchImpl: () => {
        attempts += 1;
        if (attempts <= 3) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                detail: 'Request was throttled. Expected available in 631 seconds.',
              }),
              { status: 429, statusText: 'Too Many Requests' }
            )
          );
        }

        return Promise.resolve(new Response(JSON.stringify({ id: 6249209 }), { status: 200 }));
      },
    });

    assert.equal(attempts, 4);
    assert.deepEqual(waits, [634_000, 634_000, 634_000]);
  });

  void test('uploadFirefoxAmoSource preserves explicit zero metadata retries', async () => {
    const workingDir = createTempDir('openpath-firefox-upload-source-');
    const metadataPath = path.join(workingDir, 'amo-review-metadata.json');
    let attempts = 0;

    writeFileSync(
      metadataPath,
      `${JSON.stringify({ version: { approval_notes: 'Reviewer notes' } })}\n`
    );

    await assert.rejects(
      uploadFirefoxAmoSource({
        apiKey: 'user:123:456',
        apiSecret: 'secret',
        versionId: '6249209',
        metadataPath,
        metadataOnly: true,
        verify: false,
        waitForThrottle: true,
        maxThrottleWaitSeconds: 700,
        maxRetries: 0,
        fetchImpl: () => {
          attempts += 1;
          return Promise.resolve(
            new Response(
              JSON.stringify({
                detail: 'Request was throttled. Expected available in 631 seconds.',
              }),
              { status: 429, statusText: 'Too Many Requests' }
            )
          );
        },
      }),
      /--metadata-only --verify --wait-for-throttle --max-throttle-wait-seconds 10800 --max-retries 3/
    );

    assert.equal(attempts, 1);
  });

  void test('uploadFirefoxAmoSource surfaces a metadata-only retry command for long throttles', async () => {
    const workingDir = createTempDir('openpath-firefox-upload-source-');
    const metadataPath = path.join(workingDir, 'amo-review-metadata.json');

    writeFileSync(
      metadataPath,
      `${JSON.stringify({ version: { approval_notes: 'Reviewer notes' } })}\n`
    );

    await assert.rejects(
      uploadFirefoxAmoSource({
        apiKey: 'user:123:456',
        apiSecret: 'secret',
        versionId: '6249209',
        metadataPath,
        metadataOnly: true,
        verify: false,
        waitForThrottle: false,
        fetchImpl: () =>
          Promise.resolve(
            new Response(
              JSON.stringify({
                detail: 'Request was throttled. Expected available in 7200 seconds.',
              }),
              { status: 429, statusText: 'Too Many Requests' }
            )
          ),
      }),
      /Retry without re-uploading source: npm run upload:firefox-amo-source --workspace=@openpath\/firefox-extension -- --version-id 6249209 --metadata-only --verify --wait-for-throttle --max-throttle-wait-seconds 10800 --max-retries 3/
    );
  });

  void test('parseAmoThrottleDelaySeconds reads throttled AMO API bodies', () => {
    assert.equal(
      parseAmoThrottleDelaySeconds({
        detail: 'Request was throttled. Expected available in 631 seconds.',
      }),
      631
    );
    assert.equal(parseAmoThrottleDelaySeconds({ detail: 'unrelated' }), null);
  });

  void test('syncFirefoxAmoPolicy patches privacy policy and verifies readback', async () => {
    const workingDir = createTempDir('openpath-firefox-policy-');
    const privacyPath = path.join(workingDir, 'PRIVACY.md');
    const requests: { url: string; method: string; body?: string }[] = [];

    writeFileSync(privacyPath, '# Privacy\n\nOpenPath policy.\n');

    const result = await syncFirefoxAmoPolicy({
      apiKey: 'user:123:456',
      apiSecret: 'secret',
      addonId: 'monitor-bloqueos@openpath',
      privacyPath,
      fetchImpl: (input, init) => {
        const url = requestInputToUrl(input);
        const request: { url: string; method: string; body?: string } = {
          url,
          method: init?.method ?? 'GET',
        };
        if (typeof init?.body === 'string') {
          request.body = init.body;
        }
        requests.push(request);

        if (init?.method === 'PATCH') {
          return Promise.resolve(new Response(JSON.stringify({ ok: true }), { status: 200 }));
        }

        return Promise.resolve(
          new Response(
            JSON.stringify({
              privacy_policy: {
                'en-US': '# Privacy\n\nOpenPath policy.\n',
              },
            }),
            { status: 200 }
          )
        );
      },
    });

    assert.equal(result.privacyPolicyPresent, true);
    assert.deepEqual(
      requests.map((request) => `${request.method} ${request.url}`),
      [
        'PATCH https://addons.mozilla.org/api/v5/addons/addon/monitor-bloqueos%40openpath/eula_policy/',
        'GET https://addons.mozilla.org/api/v5/addons/addon/monitor-bloqueos%40openpath/eula_policy/',
      ]
    );
    assert.deepEqual(JSON.parse(requests[0]?.body ?? '{}'), {
      privacy_policy: { 'en-US': '# Privacy\n\nOpenPath policy.\n' },
    });
  });

  void test('parseAmoVersionEditUrl extracts the AMO add-on and version ids', () => {
    assert.deepEqual(
      parseAmoVersionEditUrl(
        'Approval: timeout exceeded. When approved the signed XPI file can be downloaded from https://addons.mozilla.org/en-US/developers/addon/b0694d0ac22b478c88f7/versions/6244849'
      ),
      {
        addonId: 'b0694d0ac22b478c88f7',
        versionId: '6244849',
        editUrl:
          'https://addons.mozilla.org/en-US/developers/addon/b0694d0ac22b478c88f7/versions/6244849',
      }
    );
    assert.equal(parseAmoVersionEditUrl('WebExtError: unrelated failure'), null);
  });

  void test('buildAmoVersionDetailUrl uses v-prefixed version lookups for reruns', () => {
    assert.equal(
      buildAmoVersionDetailUrl({
        addonId: 'monitor-bloqueos@openpath',
        version: '2.0.305419896.596069104',
      }).href,
      'https://addons.mozilla.org/api/v5/addons/addon/monitor-bloqueos%40openpath/versions/v2.0.305419896.596069104/'
    );
  });

  void test('deriveAmoVersionFromPayloadHash creates deterministic numeric AMO versions', () => {
    const payloadHash = `123456789abcdef0${'f'.repeat(48)}`;
    const version = deriveAmoVersionFromPayloadHash(payloadHash);

    assert.equal(version, deriveAmoVersionFromPayloadHash(payloadHash));
    assert.equal(version, '2.0.305419896.596069104');
    assert.match(version, /^2\.0\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/);
    assert.ok(
      version.split('.').every((component) => component === '0' || !component.startsWith('0'))
    );
  });

  void test('deriveAmoVersionFromPayloadHash keeps every AMO version component within 9 digits', () => {
    const payloadHash = 'c9bd04160f6b58b431dac833d42dfa76a5d7893271f82964bef1146943d72769';
    const version = deriveAmoVersionFromPayloadHash(payloadHash);

    assert.equal(version, '2.0.384607766.258693300');
    for (const component of version.split('.')) {
      assert.ok(component.length <= 9, `component ${component} exceeds AMO's 9 digit limit`);
      assert.ok(component === '0' || !component.startsWith('0'));
    }
  });

  void test('deriveAmoVersionFromPayloadHash changes only when the Firefox runtime payload changes', () => {
    const workingDir = createTempDir('openpath-firefox-amo-version-');
    const sourceDir = path.join(workingDir, 'extension');

    mkdirSync(path.join(sourceDir, 'dist'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'popup'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'blocked'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'icons'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'native'), { recursive: true });

    writeFileSync(
      path.join(sourceDir, 'manifest.json'),
      `${JSON.stringify({
        version: '3.2.1',
        browser_specific_settings: { gecko: { id: 'monitor-bloqueos@openpath' } },
      })}\n`
    );
    writeFileSync(path.join(sourceDir, 'dist', 'background.js'), 'console.log("runtime");\n');
    writeFileSync(path.join(sourceDir, 'popup', 'popup.html'), '<html></html>\n');
    writeFileSync(path.join(sourceDir, 'blocked', 'blocked.html'), '<html>blocked</html>\n');
    writeFileSync(path.join(sourceDir, 'icons', 'icon-48.png'), 'icon\n');
    writeFileSync(path.join(sourceDir, 'native', 'openpath-native-host.py'), 'native only\n');

    const originalVersion = deriveAmoVersionFromPayloadHash(
      computeFirefoxReleasePayloadHash({ sourceDir })
    );

    writeFileSync(path.join(sourceDir, 'native', 'openpath-native-host.py'), 'native changed\n');
    assert.equal(
      deriveAmoVersionFromPayloadHash(computeFirefoxReleasePayloadHash({ sourceDir })),
      originalVersion
    );

    writeFileSync(path.join(sourceDir, 'dist', 'background.js'), 'console.log("changed");\n');
    assert.notEqual(
      deriveAmoVersionFromPayloadHash(computeFirefoxReleasePayloadHash({ sourceDir })),
      originalVersion
    );
  });

  void test('deriveAmoVersionFromPayloadHash rejects malformed payload hashes', () => {
    assert.throws(() => deriveAmoVersionFromPayloadHash('abc'), /64-character SHA-256/);
  });

  void test('createAmoJwt builds an AMO-compatible HMAC token', () => {
    const token = createAmoJwt({
      apiKey: 'user:123:456',
      apiSecret: 'secret',
      nowMs: 1_700_000_000_000,
      jti: 'nonce-1',
    });
    const [encodedHeader, encodedPayload, encodedSignature] = token.split('.');

    assert.ok(encodedHeader);
    assert.ok(encodedPayload);
    assert.ok(encodedSignature);
    assert.deepEqual(JSON.parse(Buffer.from(encodedHeader, 'base64url').toString('utf8')), {
      alg: 'HS256',
      typ: 'JWT',
    });
    assert.deepEqual(JSON.parse(Buffer.from(encodedPayload, 'base64url').toString('utf8')), {
      iss: 'user:123:456',
      jti: 'nonce-1',
      iat: 1_700_000_000,
      exp: 1_700_000_300,
    });
  });

  void test('waitForAmoSignedXpi polls AMO status and downloads the public file', async () => {
    const artifactsDir = createTempDir('openpath-firefox-amo-download-');
    const requests: string[] = [];
    const stdoutChunks: string[] = [];
    const responses = [
      new Response(
        JSON.stringify({
          file: {
            status: 'unreviewed',
          },
        }),
        { status: 200 }
      ),
      new Response(
        JSON.stringify({
          file: {
            status: 'public',
            url: 'https://addons.mozilla.org/firefox/downloads/file/6244849/signed.xpi',
          },
        }),
        { status: 200 }
      ),
      new Response('signed-xpi', { status: 200 }),
    ];

    const signedXpiPath = await waitForAmoSignedXpi({
      apiKey: 'user:123:456',
      apiSecret: 'secret',
      addonId: 'b0694d0ac22b478c88f7',
      versionId: '6244849',
      artifactsDir,
      timeoutMs: 10_000,
      pollIntervalMs: 1,
      nowImpl: () => Date.parse('2026-05-03T05:00:00Z'),
      sleepImpl: () => Promise.resolve(),
      stdout: { write: (chunk) => stdoutChunks.push(chunk) },
      fetchImpl: (input) => {
        const requestUrl =
          input instanceof Request ? input.url : input instanceof URL ? input.href : input;
        requests.push(requestUrl);
        const response = responses.shift();
        if (!response) {
          throw new Error(`unexpected request ${requestUrl}`);
        }
        return Promise.resolve(response);
      },
    });

    assert.equal(readFileSync(signedXpiPath, 'utf8'), 'signed-xpi');
    assert.deepEqual(requests, [
      'https://addons.mozilla.org/api/v5/addons/addon/b0694d0ac22b478c88f7/versions/6244849/',
      'https://addons.mozilla.org/api/v5/addons/addon/b0694d0ac22b478c88f7/versions/6244849/',
      'https://addons.mozilla.org/firefox/downloads/file/6244849/signed.xpi',
    ]);
    assert.match(stdoutChunks.join(''), /AMO version status addonId=b0694d0ac22b478c88f7/);
  });

  void test('waitForAmoSignedXpi downloads unlisted files once AMO exposes a URL', async () => {
    const artifactsDir = createTempDir('openpath-firefox-amo-unlisted-download-');
    const requests: string[] = [];
    const responses = [
      new Response(
        JSON.stringify({
          file: {
            status: 'unreviewed',
            url: 'https://addons.mozilla.org/firefox/downloads/file/6250981/signed.xpi',
          },
        }),
        { status: 200 }
      ),
      new Response('signed-unlisted-xpi', { status: 200 }),
    ];

    const signedXpiPath = await waitForAmoSignedXpi({
      apiKey: 'user:123:456',
      apiSecret: 'secret',
      addonId: 'monitor-bloqueos@openpath',
      version: '2.0.81977786.682142437',
      artifactsDir,
      timeoutMs: 10_000,
      pollIntervalMs: 1,
      nowImpl: () => Date.parse('2026-05-07T05:00:00Z'),
      sleepImpl: () => Promise.resolve(),
      stdout: { write: () => undefined },
      fetchImpl: (input) => {
        const requestUrl =
          input instanceof Request ? input.url : input instanceof URL ? input.href : input;
        requests.push(requestUrl);
        const response = responses.shift();
        if (!response) {
          throw new Error(`unexpected request ${requestUrl}`);
        }
        return Promise.resolve(response);
      },
    });

    assert.equal(readFileSync(signedXpiPath, 'utf8'), 'signed-unlisted-xpi');
    assert.deepEqual(requests, [
      'https://addons.mozilla.org/api/v5/addons/addon/monitor-bloqueos%40openpath/versions/v2.0.81977786.682142437/',
      'https://addons.mozilla.org/firefox/downloads/file/6250981/signed.xpi',
    ]);
  });

  void test('waitForAmoSignedXpi reports manual-review-required when unreviewed outlives recovery', async () => {
    const artifactsDir = createTempDir('openpath-firefox-amo-manual-review-');
    const stdoutChunks: string[] = [];
    const nowValues = [
      Date.parse('2026-05-07T05:00:00Z'),
      Date.parse('2026-05-07T05:00:01Z'),
      Date.parse('2026-05-07T05:00:02Z'),
    ];

    await assert.rejects(
      waitForAmoSignedXpi({
        apiKey: 'user:123:456',
        apiSecret: 'secret',
        addonId: 'monitor-bloqueos@openpath',
        version: '2.0.81977786.682142437',
        artifactsDir,
        timeoutMs: 1_000,
        pollIntervalMs: 1,
        nowImpl: () => nowValues.shift() ?? Date.parse('2026-05-07T05:00:02Z'),
        sleepImpl: () => Promise.resolve(),
        stdout: { write: (chunk) => stdoutChunks.push(chunk) },
        fetchImpl: () =>
          Promise.resolve(
            new Response(
              JSON.stringify({
                id: 6250981,
                version: '2.0.81977786.682142437',
                file: { status: 'unreviewed' },
              }),
              { status: 200 }
            )
          ),
      }),
      /manual-review-required: AMO accepted version but fileStatus=unreviewed/
    );

    const artifact = JSON.parse(
      readFileSync(path.join(artifactsDir, 'amo-signing-state.json'), 'utf8')
    ) as Record<string, unknown>;
    assert.deepEqual(artifact, {
      state: 'manual-review-required',
      addonId: 'monitor-bloqueos@openpath',
      version: '2.0.81977786.682142437',
      versionId: '6250981',
      fileStatus: 'unreviewed',
      lastPollAt: '2026-05-07T05:00:01.000Z',
      message:
        'manual-review-required: AMO accepted version but fileStatus=unreviewed until recovery timeout addonId=monitor-bloqueos@openpath version=6250981',
    });
    assert.match(stdoutChunks.join(''), /manual-review-required/);
    assert.match(stdoutChunks.join(''), /artifact=.*amo-signing-state\.json/);
  });

  void test('writeAmoSigningStateArtifact records machine-readable terminal states', () => {
    const artifactsDir = createTempDir('openpath-firefox-amo-state-');

    const { artifactPath, artifact } = writeAmoSigningStateArtifact({
      artifactsDir,
      state: 'recovered-existing-version',
      addonId: 'monitor-bloqueos@openpath',
      version: '2.0.81977786.682142437',
      fileStatus: 'signed',
      lastPollAt: '2026-05-07T05:00:01.000Z',
    });

    assert.equal(artifactPath, path.join(artifactsDir, 'amo-signing-state.json'));
    assert.deepEqual(artifact, {
      state: 'recovered-existing-version',
      addonId: 'monitor-bloqueos@openpath',
      version: '2.0.81977786.682142437',
      versionId: '',
      fileStatus: 'signed',
      lastPollAt: '2026-05-07T05:00:01.000Z',
    });
    assert.deepEqual(JSON.parse(readFileSync(artifactPath, 'utf8')), artifact);
  });

  void test('runWebExtSignWithRetry waits and retries AMO throttling responses', () => {
    const attempts: string[] = [];
    const waits: number[] = [];
    const stdoutChunks: string[] = [];
    const stderrChunks: string[] = [];
    const spawnSyncImpl = (
      command: string,
      args: string[],
      options: { cwd: string; encoding: 'utf8'; timeout?: number }
    ): SpawnSyncReturns<string> => {
      attempts.push(
        `${command} ${args.join(' ')} ${options.cwd} ${options.encoding} ${String(options.timeout)}`
      );
      if (attempts.length === 1) {
        return {
          status: 1,
          signal: null,
          output: [],
          pid: 123,
          stdout: '',
          stderr:
            'WebExtError: Submission failed (2): Unknown Error\n' +
            '{ "detail": "Request was throttled. Expected available in 631 seconds." }\n',
        };
      }

      return {
        status: 0,
        signal: null,
        output: [],
        pid: 124,
        stdout: 'signed\n',
        stderr: '',
      };
    };

    const result = runWebExtSignWithRetry({
      args: ['--yes', 'web-ext', 'sign'],
      cwd: extensionRoot,
      env: {
        WEB_EXT_SIGN_MAX_RETRIES: '1',
        WEB_EXT_SIGN_RETRY_BUFFER_SECONDS: '2',
        WEB_EXT_SIGN_MAX_THROTTLE_WAIT_SECONDS: '900',
      },
      spawnSyncImpl,
      sleepSyncImpl: (milliseconds) => waits.push(milliseconds),
      stdout: { write: (chunk) => stdoutChunks.push(chunk) },
      stderr: { write: (chunk) => stderrChunks.push(chunk) },
      processTimeoutMs: 1_920_000,
    });

    assert.equal(result.status, 0);
    assert.equal(attempts.length, 2);
    assert.ok(attempts.every((attempt) => attempt.endsWith(' 1920000')));
    assert.deepEqual(waits, [633_000]);
    assert.deepEqual(stdoutChunks, ['signed\n']);
    assert.equal(stderrChunks.length, 1);
    assert.match(stderrChunks[0] ?? '', /Request was throttled/);
  });

  void test('runWebExtSignWithRetry accepts CI throttle waits up to the configured ceiling', () => {
    const waits: number[] = [];
    let attempts = 0;
    const spawnSyncImpl = (): SpawnSyncReturns<string> => {
      attempts += 1;
      if (attempts === 1) {
        return {
          status: 1,
          signal: null,
          output: [],
          pid: 123,
          stdout: '',
          stderr:
            'WebExtError: Submission failed (2): Unknown Error\n' +
            '{ "detail": "Request was throttled. Expected available in 1502 seconds." }\n',
        };
      }

      return {
        status: 0,
        signal: null,
        output: [],
        pid: 124,
        stdout: '',
        stderr: '',
      };
    };

    const result = runWebExtSignWithRetry({
      args: ['--yes', 'web-ext', 'sign'],
      cwd: extensionRoot,
      env: {
        WEB_EXT_SIGN_MAX_RETRIES: '2',
        WEB_EXT_SIGN_RETRY_BUFFER_SECONDS: '30',
        WEB_EXT_SIGN_MAX_THROTTLE_WAIT_SECONDS: '2700',
      },
      spawnSyncImpl,
      sleepSyncImpl: (milliseconds) => waits.push(milliseconds),
    });

    assert.equal(result.status, 0);
    assert.equal(attempts, 2);
    assert.deepEqual(waits, [1_532_000]);
  });

  void test('runWebExtSignWithRetry explains over-budget AMO throttles with version context', () => {
    const workingDir = createTempDir('openpath-firefox-throttle-context-');
    const sourceDir = path.join(workingDir, 'extension');
    const stderrChunks: string[] = [];

    mkdirSync(sourceDir, { recursive: true });
    writeFileSync(
      path.join(sourceDir, 'manifest.json'),
      `${JSON.stringify({ version: '2.0.1' })}\n`
    );

    const result = runWebExtSignWithRetry({
      args: ['--yes', '--no-install', 'web-ext', 'sign', `--source-dir=${sourceDir}`],
      cwd: extensionRoot,
      env: {
        WEB_EXT_SIGN_MAX_RETRIES: '1',
        WEB_EXT_SIGN_RETRY_BUFFER_SECONDS: '30',
        WEB_EXT_SIGN_MAX_THROTTLE_WAIT_SECONDS: '900',
      },
      spawnSyncImpl: (): SpawnSyncReturns<string> => ({
        status: 1,
        signal: null,
        output: [],
        pid: 123,
        stdout: '',
        stderr:
          'WebExtError: Submission failed (2): Unknown Error\n' +
          '{ "detail": "Request was throttled. Expected available in 1502 seconds." }\n',
      }),
      sleepSyncImpl: () => {
        throw new Error('over-budget throttle should not sleep');
      },
      stderr: { write: (chunk) => stderrChunks.push(chunk) },
    });

    assert.equal(result.status, 1);
    assert.match(
      stderrChunks.join(''),
      /AMO signing request was throttled for 1502 seconds \(25\.0 minutes\).*version=2\.0\.1/s
    );
  });

  void test('runWebExtSignWithRetry leaves Version already exists recoverable by rerun versioning', () => {
    const spawnSyncImpl = (): SpawnSyncReturns<string> => ({
      status: 1,
      signal: null,
      output: [],
      pid: 123,
      stdout: '',
      stderr: 'WebExtError: Version already exists.\n',
    });

    const result = runWebExtSignWithRetry({
      args: ['--yes', 'web-ext', 'sign'],
      cwd: extensionRoot,
      env: {
        WEB_EXT_SIGN_MAX_RETRIES: '2',
        WEB_EXT_SIGN_RETRY_BUFFER_SECONDS: '30',
        WEB_EXT_SIGN_MAX_THROTTLE_WAIT_SECONDS: '2700',
      },
      spawnSyncImpl,
      sleepSyncImpl: () => {
        throw new Error('Version already exists should not sleep/retry in-process');
      },
    });

    assert.equal(result.status, 1);
  });

  void test('isAmoVersionAlreadyExists detects AMO conflict payloads with the version embedded', () => {
    assert.equal(
      isAmoVersionAlreadyExists(`WebExtError: Submission failed (2): Conflict
{
  "version": [
    "Version 2.0.0.777908115 already exists."
  ]
}
`),
      true
    );
  });

  void test('runWebExtSignWithRetry fails explicitly when the parent process timeout fires', () => {
    const stderrChunks: string[] = [];
    const timeoutError = new Error('spawnSync npx ETIMEDOUT') as NodeJS.ErrnoException;
    timeoutError.code = 'ETIMEDOUT';

    const spawnSyncImpl = (): SpawnSyncReturns<string> => ({
      status: null,
      signal: 'SIGTERM',
      output: [],
      pid: 123,
      stdout: '',
      stderr: '',
      error: timeoutError,
    });

    const result = runWebExtSignWithRetry({
      args: ['--yes', '--no-install', 'web-ext', 'sign'],
      cwd: extensionRoot,
      env: {
        WEB_EXT_SIGN_MAX_RETRIES: '2',
        WEB_EXT_SIGN_RETRY_BUFFER_SECONDS: '30',
        WEB_EXT_SIGN_MAX_THROTTLE_WAIT_SECONDS: '2700',
      },
      spawnSyncImpl,
      sleepSyncImpl: () => {
        throw new Error('process timeouts should not sleep/retry');
      },
      stderr: { write: (chunk) => stderrChunks.push(chunk) },
      processTimeoutMs: 1_920_000,
    });

    assert.equal(result.status, 124);
    assert.match(stderrChunks.join(''), /parent process timeout of 1920000ms/);
  });

  void test('runWebExtSignWithRetry clamps web-ext to the remaining total signing budget', () => {
    const attempts: (number | undefined)[] = [];
    const spawnSyncImpl = (
      _command: string,
      _args: string[],
      options: { cwd: string; encoding: 'utf8'; timeout?: number }
    ): SpawnSyncReturns<string> => {
      attempts.push(options.timeout);
      return {
        status: 0,
        signal: null,
        output: [],
        pid: 123,
        stdout: '',
        stderr: '',
      };
    };

    const result = runWebExtSignWithRetry({
      args: ['--yes', '--no-install', 'web-ext', 'sign'],
      cwd: extensionRoot,
      spawnSyncImpl,
      nowImpl: () => 1_700_000,
      processTimeoutMs: 1_320_000,
      deadlineMs: 1_800_000,
    });

    assert.equal(result.status, 0);
    assert.deepEqual(attempts, [100_000]);
  });

  void test('prepareSigningSourceDir can override the manifest version in a temporary copy', () => {
    const signingSource = prepareSigningSourceDir({
      sourceDir: extensionRoot,
      version: '2.0.0.123.4',
    });

    try {
      assert.notEqual(
        signingSource.sourceDir,
        extensionRoot,
        'version override should use a temporary signing directory'
      );
      assert.equal(signingSource.effectiveVersion, '2.0.0.123.4');

      const manifest = JSON.parse(
        readFileSync(path.join(signingSource.sourceDir, 'manifest.json'), 'utf8')
      ) as { version?: string };
      assert.equal(manifest.version, '2.0.0.123.4');
    } finally {
      signingSource.cleanup();
    }
  });

  void test('prepareSigningSourceDir copies only the Firefox runtime signing payload', () => {
    const workingDir = createTempDir('openpath-firefox-signing-source-');
    const sourceDir = path.join(workingDir, 'extension');

    mkdirSync(path.join(sourceDir, 'dist'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'popup'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'blocked'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'icons'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'src'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'tests'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'native'), { recursive: true });

    writeFileSync(
      path.join(sourceDir, 'manifest.json'),
      `${JSON.stringify({
        version: '3.2.1',
        browser_specific_settings: { gecko: { id: 'monitor-bloqueos@openpath' } },
      })}\n`
    );
    writeFileSync(path.join(sourceDir, 'dist', 'background.js'), 'console.log("runtime");\n');
    writeFileSync(path.join(sourceDir, 'popup', 'popup.html'), '<html></html>\n');
    writeFileSync(path.join(sourceDir, 'blocked', 'blocked.html'), '<html>blocked</html>\n');
    writeFileSync(path.join(sourceDir, 'icons', 'icon-48.png'), 'icon\n');
    writeFileSync(path.join(sourceDir, 'src', 'background.ts'), 'source only\n');
    writeFileSync(path.join(sourceDir, 'tests', 'background.test.ts'), 'test only\n');
    writeFileSync(path.join(sourceDir, 'native', 'openpath-native-host.py'), 'native only\n');
    writeFileSync(path.join(sourceDir, 'README.md'), '# Docs\n');

    const signingSource = prepareSigningSourceDir({ sourceDir });

    try {
      assert.notEqual(signingSource.sourceDir, sourceDir);
      assert.equal(statSync(path.join(signingSource.sourceDir, 'dist')).isDirectory(), true);
      assert.equal(statSync(path.join(signingSource.sourceDir, 'popup')).isDirectory(), true);
      assert.equal(statSync(path.join(signingSource.sourceDir, 'blocked')).isDirectory(), true);
      assert.equal(statSync(path.join(signingSource.sourceDir, 'icons')).isDirectory(), true);
      assert.equal(existsSync(path.join(signingSource.sourceDir, 'src')), false);
      assert.equal(existsSync(path.join(signingSource.sourceDir, 'tests')), false);
      assert.equal(existsSync(path.join(signingSource.sourceDir, 'native')), false);
      assert.equal(existsSync(path.join(signingSource.sourceDir, 'README.md')), false);
    } finally {
      signingSource.cleanup();
    }
  });

  void test('computeFirefoxReleasePayloadHash ignores non-runtime extension files', () => {
    const workingDir = createTempDir('openpath-firefox-payload-hash-');
    const sourceDir = path.join(workingDir, 'extension');

    mkdirSync(path.join(sourceDir, 'dist'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'popup'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'blocked'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'icons'), { recursive: true });
    mkdirSync(path.join(sourceDir, 'native'), { recursive: true });

    writeFileSync(
      path.join(sourceDir, 'manifest.json'),
      `${JSON.stringify({
        version: '3.2.1',
        browser_specific_settings: { gecko: { id: 'monitor-bloqueos@openpath' } },
      })}\n`
    );
    writeFileSync(path.join(sourceDir, 'dist', 'background.js'), 'console.log("runtime");\n');
    writeFileSync(path.join(sourceDir, 'popup', 'popup.html'), '<html></html>\n');
    writeFileSync(path.join(sourceDir, 'blocked', 'blocked.html'), '<html>blocked</html>\n');
    writeFileSync(path.join(sourceDir, 'icons', 'icon-48.png'), 'icon\n');
    writeFileSync(path.join(sourceDir, 'native', 'openpath-native-host.py'), 'native only\n');
    writeFileSync(path.join(sourceDir, 'README.md'), '# Docs\n');

    const originalHash = computeFirefoxReleasePayloadHash({ sourceDir });

    writeFileSync(path.join(sourceDir, 'native', 'openpath-native-host.py'), 'native changed\n');
    writeFileSync(path.join(sourceDir, 'README.md'), '# Docs changed\n');

    assert.equal(computeFirefoxReleasePayloadHash({ sourceDir }), originalHash);

    writeFileSync(path.join(sourceDir, 'dist', 'background.js'), 'console.log("changed");\n');

    assert.notEqual(computeFirefoxReleasePayloadHash({ sourceDir }), originalHash);
  });
});
