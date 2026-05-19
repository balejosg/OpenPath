import assert from 'node:assert/strict';
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { test } from 'node:test';

function encodeNativeMessage(payload: unknown): Buffer {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
}

function decodeNativeMessage(output: Buffer): unknown {
  assert.ok(output.length >= 4, 'native host did not write a response header');
  const bodyLength = output.readUInt32LE(0);
  const body = output.subarray(4, 4 + bodyLength).toString('utf8');
  return JSON.parse(body);
}

function runNativeHostOnce(env: NodeJS.ProcessEnv, payload: unknown): unknown {
  const scriptPath = new URL('../native/openpath-native-host.py', import.meta.url);
  const result = spawnSync('python3', [scriptPath.pathname], {
    env,
    input: encodeNativeMessage(payload),
  });

  assert.equal(result.status, 0, result.stderr.toString('utf8'));
  return decodeNativeMessage(result.stdout);
}

function runNativeHostCheck(env: NodeJS.ProcessEnv, domains: string[]): unknown {
  return runNativeHostOnce(env, { action: 'check', domains });
}

function runNativeHostAsync(env: NodeJS.ProcessEnv, payload: unknown): Promise<unknown> {
  const scriptPath = new URL('../native/openpath-native-host.py', import.meta.url);

  return new Promise((resolve, reject) => {
    const child = spawn('python3', [scriptPath.pathname], { env });
    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];

    child.stdout.on('data', (chunk: Buffer) => stdoutChunks.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderrChunks.push(chunk));
    child.on('error', reject);
    child.on('close', (code) => {
      const stderr = Buffer.concat(stderrChunks).toString('utf8');
      if (code !== 0) {
        const exitCode = code === null ? 'unknown' : String(code);
        reject(new Error(stderr || `native host exited with code ${exitCode}`));
        return;
      }

      try {
        resolve(decodeNativeMessage(Buffer.concat(stdoutChunks)));
      } catch (error) {
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });

    child.stdin.end(encodeNativeMessage(payload));
  });
}

void test('native host confirms local DNS blocks when OpenPath CLI is unavailable', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  writeFileSync(whitelistPath, '## WHITELIST\nallowed.example\n', 'utf8');

  const response = runNativeHostCheck(
    {
      ...process.env,
      OPENPATH_SYSTEM_DISABLED_FLAG: join(runtimeDir, 'system-disabled.flag'),
      OPENPATH_WHITELIST_CMD: '',
      OPENPATH_WHITELIST_FILE: whitelistPath,
      XDG_DATA_HOME: runtimeDir,
    },
    ['blocked.example']
  ) as {
    results?: {
      domain?: string;
      error?: string;
      in_whitelist?: boolean;
      policy_active?: boolean;
      resolves?: boolean;
    }[];
    success?: boolean;
  };

  assert.equal(response.success, true);
  assert.deepEqual(response.results, [
    {
      domain: 'blocked.example',
      in_whitelist: false,
      policy_active: true,
      resolves: false,
      resolved_ip: null,
    },
  ]);
});

function readQueuedRuntimeDependency(queueDir: string): Record<string, unknown> {
  const files = readdirSync(queueDir).filter((entry) => entry.endsWith('.json'));
  assert.equal(files.length, 1);
  const [queueFile] = files;
  assert.ok(queueFile);
  return JSON.parse(readFileSync(join(queueDir, queueFile), 'utf8')) as Record<string, unknown>;
}

void test('linux native host queues a local runtime dependency request', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-runtime-dependency-'));
  const queueDir = join(runtimeDir, 'queue');
  mkdirSync(queueDir, { recursive: true });

  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
      OPENPATH_RUNTIME_DEPENDENCY_QUEUE_DIR: queueDir,
    },
    {
      action: 'allow-local-runtime-dependency',
      anchorHost: 'Allowed.Example.',
      dependencyHost: 'CDN.Example',
      requestType: 'FETCH',
    }
  ) as {
    action?: string;
    anchorHost?: string;
    dependencyHost?: string;
    queued?: boolean;
    requestType?: string;
    success?: boolean;
  };

  assert.equal(response.success, true);
  assert.equal(response.action, 'allow-local-runtime-dependency');
  assert.equal(response.anchorHost, 'allowed.example');
  assert.equal(response.dependencyHost, 'cdn.example');
  assert.equal(response.requestType, 'fetch');
  assert.equal(response.queued, true);

  const queued = readQueuedRuntimeDependency(queueDir);
  assert.deepEqual(Object.keys(queued).sort(), [
    'anchorHost',
    'dependencyHost',
    'queuedAt',
    'requestType',
    'source',
    'version',
  ]);
  assert.equal(queued.version, 1);
  assert.match(String(queued.queuedAt), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.equal(queued.anchorHost, 'allowed.example');
  assert.equal(queued.dependencyHost, 'cdn.example');
  assert.equal(queued.requestType, 'fetch');
  assert.equal(queued.source, 'firefox-webrequest-local');
  const queuedFile = readdirSync(queueDir).find((entry) => entry.endsWith('.json'));
  assert.ok(queuedFile);
  assert.equal(statSync(join(queueDir, queuedFile)).mode & 0o777, 0o600);
});

void test('linux native host queues runtime dependency batches', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-runtime-dependency-batch-'));
  const queueDir = join(runtimeDir, 'queue');
  mkdirSync(queueDir, { recursive: true });

  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
      OPENPATH_RUNTIME_DEPENDENCY_QUEUE_DIR: queueDir,
    },
    {
      action: 'allow-local-runtime-dependency-batch',
      entries: [
        { anchorHost: 'allowed.example', dependencyHost: 'cdn1.example', requestType: 'fetch' },
        { anchorHost: 'allowed.example', dependencyHost: 'cdn2.example', requestType: 'script' },
      ],
    }
  ) as {
    action?: string;
    count?: number;
    queuedCount?: number;
    results?: { dependencyHost?: string; success?: boolean }[];
    success?: boolean;
  };

  assert.equal(response.success, true);
  assert.equal(response.action, 'allow-local-runtime-dependency-batch');
  assert.equal(response.count, 2);
  assert.equal(response.queuedCount, 2);
  assert.deepEqual(
    response.results?.map((entry) => entry.dependencyHost),
    ['cdn1.example', 'cdn2.example']
  );
  assert.equal(readdirSync(queueDir).filter((entry) => entry.endsWith('.json')).length, 2);
});

void test('linux native host fails when runtime dependency queue is not provisioned', () => {
  const runtimeDir = mkdtempSync(
    join(tmpdir(), 'openpath-native-host-runtime-dependency-missing-')
  );
  const queueDir = join(runtimeDir, 'missing-queue');

  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
      OPENPATH_RUNTIME_DEPENDENCY_QUEUE_DIR: queueDir,
    },
    {
      action: 'allow-local-runtime-dependency',
      anchorHost: 'allowed.example',
      dependencyHost: 'cdn.example',
      requestType: 'fetch',
    }
  ) as {
    error?: string;
    success?: boolean;
  };

  assert.equal(response.success, false);
  assert.match(response.error ?? '', /Queue directory not configured/);
  assert.equal(readdirSync(runtimeDir).includes('missing-queue'), false);
});

void test('linux native host rejects runtime dependency batches over the limit', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-runtime-dependency-limit-'));
  const queueDir = join(runtimeDir, 'queue');
  mkdirSync(queueDir, { recursive: true });
  const entries = Array.from({ length: 21 }, (_, index) => ({
    anchorHost: 'allowed.example',
    dependencyHost: `cdn${index.toString()}.example`,
    requestType: 'fetch',
  }));

  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
      OPENPATH_RUNTIME_DEPENDENCY_QUEUE_DIR: queueDir,
    },
    {
      action: 'allow-local-runtime-dependency-batch',
      entries,
    }
  ) as {
    count?: number;
    queuedCount?: number;
    results?: { error?: string; success?: boolean }[];
    success?: boolean;
  };

  assert.equal(response.success, false);
  assert.equal(response.count, 21);
  assert.equal(response.queuedCount, 20);
  assert.equal(
    response.results?.some((entry) => entry.error === 'Runtime dependency batch limit exceeded'),
    true
  );
  assert.equal(readdirSync(queueDir).filter((entry) => entry.endsWith('.json')).length, 20);
});

void test('linux native host keeps queueing when stale overlay contains dependency', () => {
  const runtimeDir = mkdtempSync(
    join(tmpdir(), 'openpath-native-host-runtime-dependency-overlay-')
  );
  const queueDir = join(runtimeDir, 'queue');
  const overlayPath = join(runtimeDir, 'runtime-dependency-overlay.json');
  mkdirSync(queueDir, { recursive: true });
  writeFileSync(
    overlayPath,
    JSON.stringify({
      version: 1,
      entries: [
        {
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn.example',
          requestTypes: ['fetch'],
          expiresAt: '2000-01-02T00:00:00Z',
        },
      ],
    }),
    'utf8'
  );

  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
      OPENPATH_RUNTIME_DEPENDENCY_QUEUE_DIR: queueDir,
      OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_FILE: overlayPath,
    },
    {
      action: 'allow-local-runtime-dependency',
      anchorHost: 'allowed.example',
      dependencyHost: 'cdn.example',
      requestType: 'fetch',
    }
  ) as {
    queued?: boolean;
    success?: boolean;
  };

  assert.equal(response.success, true);
  assert.equal(response.queued, true);
  assert.equal(readdirSync(queueDir).filter((entry) => entry.endsWith('.json')).length, 1);
});

void test('linux native host validates runtime dependency schema before queueing', () => {
  const runtimeDir = mkdtempSync(
    join(tmpdir(), 'openpath-native-host-runtime-dependency-invalid-')
  );
  const queueDir = join(runtimeDir, 'queue');
  mkdirSync(queueDir, { recursive: true });

  const cases = [
    { anchorHost: 'allowed.local', dependencyHost: 'cdn.example', requestType: 'fetch' },
    { anchorHost: 'allowed.example', dependencyHost: 'cdn.example', requestType: 'main_frame' },
    { anchorHost: 'allowed.example', dependencyHost: 'bad_host.example', requestType: 'script' },
  ];

  for (const entry of cases) {
    const response = runNativeHostOnce(
      {
        ...process.env,
        XDG_DATA_HOME: runtimeDir,
        OPENPATH_RUNTIME_DEPENDENCY_QUEUE_DIR: queueDir,
      },
      {
        action: 'allow-local-runtime-dependency',
        ...entry,
      }
    ) as {
      action?: string;
      error?: string;
      success?: boolean;
    };

    assert.equal(response.success, false);
    assert.equal(response.action, 'allow-local-runtime-dependency');
    assert.match(
      response.error ?? '',
      /Invalid runtime dependency payload|main_frame dependencies are not supported/
    );
  }

  assert.equal(readdirSync(queueDir).filter((entry) => entry.endsWith('.json')).length, 0);
});

void test('native host treats CLI sinkhole responses as blocked', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  const fakeOpenPath = join(runtimeDir, 'openpath');
  writeFileSync(whitelistPath, '## WHITELIST\nallowed.example\n', 'utf8');
  writeFileSync(
    fakeOpenPath,
    [
      '#!/bin/sh',
      'if [ "$1" = "check" ]; then',
      '  printf "Verificando: %s\\n\\n" "$2"',
      '  printf "  En whitelist: ✗ NO\\n"',
      '  printf "  Resuelve: ✓ → 192.0.2.1\\n"',
      '  exit 0',
      'fi',
      'exit 1',
      '',
    ].join('\n'),
    'utf8'
  );
  chmodSync(fakeOpenPath, 0o755);

  const response = runNativeHostCheck(
    {
      ...process.env,
      OPENPATH_SYSTEM_DISABLED_FLAG: join(runtimeDir, 'system-disabled.flag'),
      OPENPATH_WHITELIST_CMD: fakeOpenPath,
      OPENPATH_WHITELIST_FILE: whitelistPath,
      XDG_DATA_HOME: runtimeDir,
    },
    ['blocked.example']
  ) as {
    results?: {
      domain?: string;
      in_whitelist?: boolean;
      policy_active?: boolean;
      resolved_ip?: string | null;
      resolves?: boolean;
    }[];
    success?: boolean;
  };

  assert.equal(response.success, true);
  assert.deepEqual(response.results, [
    {
      domain: 'blocked.example',
      in_whitelist: false,
      policy_active: true,
      resolves: false,
      resolved_ip: '192.0.2.1',
    },
  ]);
});

void test('native host returns blocked subdomains from the local whitelist file', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  writeFileSync(
    whitelistPath,
    [
      '## WHITELIST',
      'allowed.example',
      '## BLOCKED-SUBDOMAINS',
      'ads.example.org',
      'cdn.example.org',
      '## BLOCKED-PATHS',
      'example.org/private',
      '',
    ].join('\n'),
    'utf8'
  );

  const response = runNativeHostOnce(
    {
      ...process.env,
      OPENPATH_WHITELIST_FILE: whitelistPath,
      XDG_DATA_HOME: runtimeDir,
    },
    { action: 'get-blocked-subdomains' }
  ) as {
    success?: boolean;
    subdomains?: string[];
    action?: string;
    count?: number;
    hash?: string;
  };

  assert.equal(response.success, true);
  assert.equal(response.action, 'get-blocked-subdomains');
  assert.deepEqual(response.subdomains, ['ads.example.org', 'cdn.example.org']);
  assert.equal(response.count, 2);
  assert.equal(typeof response.hash, 'string');
});

void test('native host update-whitelist without domains preserves legacy trigger behavior', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  const updateScript = join(runtimeDir, 'openpath-update.sh');
  const markerPath = join(runtimeDir, 'update-invocations.txt');
  const lockPath = join(runtimeDir, 'native-update.lock');
  writeFileSync(whitelistPath, '## WHITELIST\nallowed.example\n', 'utf8');
  writeFileSync(
    updateScript,
    ['#!/bin/sh', 'printf "triggered\\n" >> "$OPENPATH_UPDATE_MARKER"', 'exit 0', ''].join('\n'),
    'utf8'
  );
  chmodSync(updateScript, 0o755);

  const response = runNativeHostOnce(
    {
      ...process.env,
      OPENPATH_NATIVE_HOST_UPDATE_SCRIPT: updateScript,
      OPENPATH_NATIVE_HOST_UPDATE_LOCK: lockPath,
      OPENPATH_NATIVE_HOST_UPDATE_TIMEOUT_MS: '4000',
      OPENPATH_UPDATE_MARKER: markerPath,
      OPENPATH_WHITELIST_FILE: whitelistPath,
      XDG_DATA_HOME: runtimeDir,
    },
    { action: 'update-whitelist' }
  ) as {
    success?: boolean;
    action?: string;
    message?: string;
    domains?: string[];
  };

  assert.equal(response.success, true);
  assert.equal(response.action, 'update-whitelist');
  assert.equal(response.message, 'OpenPath update triggered');
  assert.deepEqual(response.domains, []);
  assert.match(readFileSync(markerPath, 'utf8'), /triggered/);
});

void test('native host update-whitelist waits until requested domains reach the local whitelist', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  const updateScript = join(runtimeDir, 'openpath-update.sh');
  const markerPath = join(runtimeDir, 'update-invocations.txt');
  const lockPath = join(runtimeDir, 'native-update.lock');
  writeFileSync(whitelistPath, '## WHITELIST\nallowed.example\n', 'utf8');
  writeFileSync(
    updateScript,
    [
      '#!/bin/sh',
      'printf "triggered\\n" >> "$OPENPATH_UPDATE_MARKER"',
      '(sleep 1; printf "## WHITELIST\\nallowed.example\\ncdn.redditstatic.com\\n" > "$OPENPATH_WHITELIST_FILE") &',
      'exit 0',
      '',
    ].join('\n'),
    'utf8'
  );
  chmodSync(updateScript, 0o755);

  const response = runNativeHostOnce(
    {
      ...process.env,
      OPENPATH_NATIVE_HOST_UPDATE_SCRIPT: updateScript,
      OPENPATH_NATIVE_HOST_UPDATE_TIMEOUT_MS: '4000',
      OPENPATH_UPDATE_MARKER: markerPath,
      OPENPATH_WHITELIST_FILE: whitelistPath,
      OPENPATH_NATIVE_HOST_UPDATE_LOCK: lockPath,
      XDG_DATA_HOME: runtimeDir,
    },
    { action: 'update-whitelist', domains: ['cdn.redditstatic.com'] }
  ) as {
    success?: boolean;
    action?: string;
    message?: string;
    domains?: string[];
    error?: string;
  };

  assert.equal(response.success, true);
  assert.equal(response.action, 'update-whitelist');
  assert.equal(response.message, 'OpenPath update wrote expected domains');
  assert.deepEqual(response.domains, ['cdn.redditstatic.com']);
  assert.match(readFileSync(whitelistPath, 'utf8'), /cdn\.redditstatic\.com/);
  assert.match(readFileSync(markerPath, 'utf8'), /triggered/);
});

void test('native host update-whitelist times out when requested domains never reach the local whitelist', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  const updateScript = join(runtimeDir, 'openpath-update.sh');
  writeFileSync(whitelistPath, '## WHITELIST\nallowed.example\n', 'utf8');
  writeFileSync(updateScript, ['#!/bin/sh', 'exit 0', ''].join('\n'), 'utf8');
  chmodSync(updateScript, 0o755);

  const response = runNativeHostOnce(
    {
      ...process.env,
      OPENPATH_NATIVE_HOST_UPDATE_SCRIPT: updateScript,
      OPENPATH_NATIVE_HOST_UPDATE_TIMEOUT_MS: '1200',
      OPENPATH_WHITELIST_FILE: whitelistPath,
      XDG_DATA_HOME: runtimeDir,
    },
    { action: 'update-whitelist', domains: ['cdn.redditstatic.com'] }
  ) as {
    success?: boolean;
    action?: string;
    domains?: string[];
    error?: string;
  };

  assert.equal(response.success, false);
  assert.equal(response.action, 'update-whitelist');
  assert.deepEqual(response.domains, ['cdn.redditstatic.com']);
  assert.match(response.error ?? '', /did not write expected domains/i);
});

void test('native host update-whitelist coalesces concurrent requests behind a single trigger', async () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  const updateScript = join(runtimeDir, 'openpath-update.sh');
  const markerPath = join(runtimeDir, 'update-invocations.txt');
  const lockPath = join(runtimeDir, 'native-update.lock');
  writeFileSync(whitelistPath, '## WHITELIST\nallowed.example\n', 'utf8');
  writeFileSync(
    updateScript,
    [
      '#!/bin/sh',
      'printf "triggered\\n" >> "$OPENPATH_UPDATE_MARKER"',
      '(sleep 1; printf "## WHITELIST\\nallowed.example\\nemoji.redditmedia.com\\n" > "$OPENPATH_WHITELIST_FILE") &',
      'exit 0',
      '',
    ].join('\n'),
    'utf8'
  );
  chmodSync(updateScript, 0o755);

  const env = {
    ...process.env,
    OPENPATH_NATIVE_HOST_UPDATE_SCRIPT: updateScript,
    OPENPATH_NATIVE_HOST_UPDATE_LOCK: lockPath,
    OPENPATH_NATIVE_HOST_UPDATE_TIMEOUT_MS: '4000',
    OPENPATH_UPDATE_MARKER: markerPath,
    OPENPATH_WHITELIST_FILE: whitelistPath,
    XDG_DATA_HOME: runtimeDir,
  };
  const [firstResponse, secondResponse] = (await Promise.all([
    runNativeHostAsync(env, {
      action: 'update-whitelist',
      domains: ['emoji.redditmedia.com'],
    }),
    runNativeHostAsync(env, {
      action: 'update-whitelist',
      domains: ['emoji.redditmedia.com'],
    }),
  ])) as [{ success?: boolean }, { success?: boolean }];

  assert.equal(firstResponse.success, true);
  assert.equal(secondResponse.success, true);
  assert.equal(
    readFileSync(markerPath, 'utf8')
      .split('\n')
      .filter((line) => line === 'triggered').length,
    1
  );
});
