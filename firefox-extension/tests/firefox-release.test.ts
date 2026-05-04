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
  }) => string[];
  createAmoJwt: (options: {
    apiKey: string;
    apiSecret: string;
    nowMs?: number;
    jti?: string;
  }) => string;
  computeFirefoxReleasePayloadHash: (options: { sourceDir?: string }) => string;
  findSignedXpiArtifact: (artifactsDir: string) => string;
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
}

interface VerifyFirefoxReleaseArtifactsModule {
  verifyFirefoxReleaseArtifacts: (options: {
    releaseDir: string;
    payloadHash: string;
  }) => FirefoxReleaseMetadata;
}

const { prepareFirefoxReleaseArtifacts } =
  (await import('../build-firefox-release.mjs')) as PrepareFirefoxReleaseArtifactsModule;
const {
  buildAmoVersionDetailUrl,
  buildWebExtSignArgs,
  createAmoJwt,
  computeFirefoxReleasePayloadHash,
  findSignedXpiArtifact,
  parseAmoVersionEditUrl,
  parseWebExtThrottleDelaySeconds,
  prepareSigningSourceDir,
  resolveAmoRecoveryTiming,
  resolveWebExtSignTiming,
  runWebExtSignWithRetry,
  waitForAmoSignedXpi,
} = (await import('../sign-firefox-release.mjs')) as SignFirefoxReleaseModule;
const { verifyFirefoxReleaseArtifacts } =
  (await import('../verify-firefox-release-artifacts.mjs')) as VerifyFirefoxReleaseArtifactsModule;

const tempDirectories: string[] = [];

function createTempDir(prefix: string): string {
  const dir = mkdtempSync(path.join(tmpdir(), prefix));
  tempDirectories.push(dir);
  return dir;
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
        version: '2.0.0.777766400',
      }).href,
      'https://addons.mozilla.org/api/v5/addons/addon/monitor-bloqueos%40openpath/versions/v2.0.0.777766400/'
    );
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
