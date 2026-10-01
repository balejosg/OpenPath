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
      policy_decision?: string;
      policy_reason?: string;
      policy_version?: string;
      resolves?: boolean;
    }[];
    success?: boolean;
  };

  assert.equal(response.success, true);
  const [blockedResult] = response.results ?? [];
  assert.ok(blockedResult);
  assert.equal(blockedResult.domain, 'blocked.example');
  assert.equal(blockedResult.in_whitelist, false);
  assert.equal(blockedResult.policy_active, true);
  assert.equal(blockedResult.policy_decision, 'blocked');
  assert.equal(blockedResult.policy_reason, 'default-deny');
  assert.match(blockedResult.policy_version ?? '', /^[a-f0-9]{64}$/);
  assert.equal(blockedResult.resolves, false);

  const allowed = runNativeHostCheck(
    {
      ...process.env,
      OPENPATH_SYSTEM_DISABLED_FLAG: join(runtimeDir, 'system-disabled.flag'),
      OPENPATH_WHITELIST_CMD: '',
      OPENPATH_WHITELIST_FILE: whitelistPath,
      XDG_DATA_HOME: runtimeDir,
    },
    ['WWW.Allowed.Example.']
  ) as { results?: Record<string, unknown>[] };
  const [allowedResult] = allowed.results ?? [];
  assert.ok(allowedResult);
  assert.equal(allowedResult.in_whitelist, true);
  assert.equal(allowedResult.policy_decision, 'allowed');
});

void test('linux native host distinguishes inactive and unreadable policy snapshots', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-policy-state-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  writeFileSync(whitelistPath, '#DESACTIVADO\n## WHITELIST\n', 'utf8');
  const env = {
    ...process.env,
    OPENPATH_SYSTEM_DISABLED_FLAG: join(runtimeDir, 'system-disabled.flag'),
    OPENPATH_WHITELIST_CMD: '',
    OPENPATH_WHITELIST_FILE: whitelistPath,
    XDG_DATA_HOME: runtimeDir,
  };
  const inactive = runNativeHostCheck(env, ['blocked.example']) as {
    results?: Record<string, unknown>[];
    success?: boolean;
  };
  assert.equal(inactive.success, true);
  const [inactiveResult] = inactive.results ?? [];
  assert.ok(inactiveResult);
  assert.equal(inactiveResult.in_whitelist, true);
  assert.equal(inactiveResult.policy_active, false);
  assert.equal(inactiveResult.policy_decision, 'allowed');

  const missing = runNativeHostCheck(
    { ...env, OPENPATH_WHITELIST_FILE: join(runtimeDir, 'missing.txt') },
    ['blocked.example']
  ) as { results?: Record<string, unknown>[]; success?: boolean };
  assert.equal(missing.success, false);
  const [missingResult] = missing.results ?? [];
  assert.ok(missingResult);
  assert.equal(missingResult.policy_decision, 'unknown');
});

void test('linux native host applies protected hosts and exact runtime dependencies', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-policy-inputs-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  const overlayPath = join(runtimeDir, 'runtime-dependency-overlay.json');
  writeFileSync(
    whitelistPath,
    '## WHITELIST\nallowed.example\n## BLOCKED-SUBDOMAINS\nblocked.allowed.example\n',
    'utf8'
  );
  writeFileSync(
    overlayPath,
    JSON.stringify({
      version: 1,
      entries: [{ anchorHost: 'allowed.example', dependencyHost: 'cdn.dependency.example' }],
    }),
    'utf8'
  );
  const response = runNativeHostCheck(
    {
      ...process.env,
      OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_FILE: overlayPath,
      OPENPATH_SYSTEM_DISABLED_FLAG: join(runtimeDir, 'system-disabled.flag'),
      OPENPATH_WHITELIST_CMD: '',
      OPENPATH_WHITELIST_FILE: whitelistPath,
      XDG_DATA_HOME: runtimeDir,
    },
    [
      'sub.download.mozilla.org',
      'blocked.allowed.example',
      'cdn.dependency.example',
      'child.cdn.dependency.example',
    ]
  ) as { results?: Record<string, unknown>[]; success?: boolean };

  assert.equal(response.success, true);
  assert.deepStrictEqual(
    (response.results ?? []).map((result) => [result.policy_decision, result.policy_reason]),
    [
      ['allowed', 'protected-infrastructure'],
      ['blocked', 'blocked-subdomain'],
      ['allowed', 'runtime-dependency-exact'],
      ['blocked', 'default-deny'],
    ]
  );
});

void test('linux policy revision changes when an exact runtime dependency changes', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-policy-version-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  const overlayPath = join(runtimeDir, 'runtime-dependency-overlay.json');
  writeFileSync(whitelistPath, '## WHITELIST\nallowed.example\n', 'utf8');
  writeFileSync(overlayPath, JSON.stringify({ version: 1, entries: [] }), 'utf8');
  const env = {
    ...process.env,
    OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_FILE: overlayPath,
    OPENPATH_SYSTEM_DISABLED_FLAG: join(runtimeDir, 'system-disabled.flag'),
    OPENPATH_WHITELIST_CMD: '',
    OPENPATH_WHITELIST_FILE: whitelistPath,
    XDG_DATA_HOME: runtimeDir,
  };
  const before = runNativeHostCheck(env, ['blocked.example']) as {
    results?: { policy_version?: string }[];
  };
  writeFileSync(
    overlayPath,
    JSON.stringify({
      version: 1,
      entries: [{ anchorHost: 'allowed.example', dependencyHost: 'cdn.dependency.example' }],
    }),
    'utf8'
  );
  const after = runNativeHostCheck(env, ['blocked.example']) as {
    results?: { policy_version?: string }[];
  };

  const beforeVersion = before.results?.[0]?.policy_version ?? '';
  const afterVersion = after.results?.[0]?.policy_version ?? '';
  assert.match(beforeVersion, /^[a-f0-9]{64}$/);
  assert.match(afterVersion, /^[a-f0-9]{64}$/);
  assert.notEqual(afterVersion, beforeVersion);
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
  const [result] = response.results ?? [];
  assert.ok(result);
  assert.equal(result.domain, 'blocked.example');
  assert.equal(result.in_whitelist, false);
  assert.equal(result.policy_active, true);
  assert.equal(result.resolves, false);
  assert.equal(result.resolved_ip, '192.0.2.1');
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

void test('linux native host reports per-entry readiness while a later batch is pending', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-entry-ready-'));
  const overlayPath = join(runtimeDir, 'runtime-dependency-overlay.json');
  writeFileSync(
    overlayPath,
    JSON.stringify({
      version: 1,
      generation: 2,
      appliedGeneration: 1,
      entries: [
        { anchorHost: 'allowed.example', dependencyHost: 'cdn.example', generation: 1 },
        { anchorHost: 'allowed.example', dependencyHost: 'cdn2.example', generation: 2 },
      ],
    }),
    'utf8'
  );

  const env = {
    ...process.env,
    XDG_DATA_HOME: runtimeDir,
    OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_FILE: overlayPath,
  };

  // The first entry was applied in generation 1; the document generation moved on
  // because cdn2 was learned later. Per-entry readiness must keep cdn ready.
  const applied = runNativeHostOnce(env, {
    action: 'check-local-runtime-dependency',
    anchorHost: 'allowed.example',
    dependencyHost: 'cdn.example',
  }) as { ready?: boolean; runtimeDependencyState?: string };
  assert.equal(applied.ready, true, JSON.stringify(applied));
  assert.equal(applied.runtimeDependencyState, 'ready');

  const pending = runNativeHostOnce(env, {
    action: 'check-local-runtime-dependency',
    anchorHost: 'allowed.example',
    dependencyHost: 'cdn2.example',
  }) as { ready?: boolean; runtimeDependencyState?: string };
  assert.equal(pending.ready, false);
  assert.equal(pending.runtimeDependencyState, 'pending');
});

void test('linux native host answers check batches from one overlay read and echoes the id', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-check-batch-'));
  const overlayPath = join(runtimeDir, 'runtime-dependency-overlay.json');
  writeFileSync(
    overlayPath,
    JSON.stringify({
      version: 1,
      generation: 3,
      appliedGeneration: 3,
      entries: [{ anchorHost: 'allowed.example', dependencyHost: 'cdn.example', generation: 1 }],
    }),
    'utf8'
  );

  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
      OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_FILE: overlayPath,
    },
    {
      action: 'check-local-runtime-dependency',
      id: 'port-7',
      entries: [
        { anchorHost: 'allowed.example', dependencyHost: 'cdn.example' },
        { anchorHost: 'allowed.example', dependencyHost: 'cdn2.example' },
      ],
    }
  ) as {
    count?: number;
    id?: string;
    results?: { dependencyHost?: string; ready?: boolean; runtimeDependencyState?: string }[];
    success?: boolean;
  };

  assert.equal(response.success, true);
  assert.equal(response.id, 'port-7');
  assert.equal(response.count, 2);
  assert.deepStrictEqual(
    (response.results ?? []).map((result) => [
      result.dependencyHost,
      result.ready,
      result.runtimeDependencyState,
    ]),
    [
      ['cdn.example', true, 'ready'],
      ['cdn2.example', false, 'pending'],
    ]
  );
});

void test('linux native host enqueue mode answers immediately without waiting for the apply', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-enqueue-'));
  const queueDir = join(runtimeDir, 'queue');
  const overlayPath = join(runtimeDir, 'runtime-dependency-overlay.json');
  mkdirSync(queueDir, { recursive: true });

  const env = {
    ...process.env,
    XDG_DATA_HOME: runtimeDir,
    OPENPATH_RUNTIME_DEPENDENCY_QUEUE_DIR: queueDir,
    OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_FILE: overlayPath,
  };

  const started = Date.now();
  const pending = runNativeHostOnce(env, {
    action: 'allow-local-runtime-dependency',
    id: 'req-1',
    mode: 'enqueue',
    anchorHost: 'Allowed.Example.',
    dependencyHost: 'CDN.Example',
    requestType: 'FETCH',
  }) as {
    dependencyHost?: string;
    id?: string;
    mode?: string;
    queued?: boolean;
    ready?: boolean;
    runtimeDependencyState?: string;
    success?: boolean;
  };
  const elapsed = Date.now() - started;

  assert.equal(pending.success, true);
  assert.equal(pending.mode, 'enqueue');
  assert.equal(pending.id, 'req-1');
  assert.equal(pending.dependencyHost, 'cdn.example');
  assert.equal(pending.queued, true);
  assert.equal(pending.ready, false);
  assert.equal(pending.runtimeDependencyState, 'pending');
  // The historical blocking path waits up to the ready timeout (8s default).
  assert.ok(elapsed < 5000, `enqueue answered too slowly: ${String(elapsed)}ms`);
  assert.equal(readdirSync(queueDir).filter((entry) => entry.endsWith('.json')).length, 1);

  // Same pair once applied: answered ready without queueing another request.
  writeFileSync(
    overlayPath,
    JSON.stringify({
      version: 1,
      generation: 1,
      appliedGeneration: 1,
      entries: [{ anchorHost: 'allowed.example', dependencyHost: 'cdn.example', generation: 1 }],
    }),
    'utf8'
  );
  const ready = runNativeHostOnce(env, {
    action: 'allow-local-runtime-dependency',
    id: 2,
    mode: 'enqueue',
    anchorHost: 'allowed.example',
    dependencyHost: 'cdn.example',
    requestType: 'fetch',
  }) as {
    id?: number;
    queued?: boolean;
    ready?: boolean;
    runtimeDependencyState?: string;
  };

  assert.equal(ready.ready, true);
  assert.equal(ready.queued, false);
  assert.equal(ready.runtimeDependencyState, 'ready');
  assert.equal(ready.id, 2);
  assert.equal(readdirSync(queueDir).filter((entry) => entry.endsWith('.json')).length, 1);
});

void test('linux native host enqueue mode answers per-entry states for a batch', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-enqueue-batch-'));
  const queueDir = join(runtimeDir, 'queue');
  const overlayPath = join(runtimeDir, 'runtime-dependency-overlay.json');
  mkdirSync(queueDir, { recursive: true });
  writeFileSync(
    overlayPath,
    JSON.stringify({
      version: 1,
      generation: 1,
      appliedGeneration: 1,
      entries: [
        { anchorHost: 'allowed.example', dependencyHost: 'cdn-ready.example', generation: 1 },
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
      action: 'allow-local-runtime-dependency-batch',
      mode: 'enqueue',
      entries: [
        {
          anchorHost: 'allowed.example',
          dependencyHost: 'cdn-ready.example',
          requestType: 'fetch',
        },
        { anchorHost: 'allowed.example', dependencyHost: 'cdn-new.example', requestType: 'script' },
      ],
    }
  ) as {
    queuedCount?: number;
    results?: {
      dependencyHost?: string;
      queued?: boolean;
      ready?: boolean;
      runtimeDependencyState?: string;
    }[];
    success?: boolean;
  };

  assert.equal(response.success, true);
  assert.equal(response.queuedCount, 1);
  assert.deepStrictEqual(
    (response.results ?? []).map((result) => [
      result.dependencyHost,
      result.queued,
      result.ready,
      result.runtimeDependencyState,
    ]),
    [
      ['cdn-ready.example', false, true, 'ready'],
      ['cdn-new.example', true, false, 'pending'],
    ]
  );
  assert.equal(readdirSync(queueDir).filter((entry) => entry.endsWith('.json')).length, 1);
});

interface PersistentNativeHost {
  close: () => Promise<void>;
  send: (payload: unknown) => Promise<unknown>;
}

function startPersistentNativeHost(env: NodeJS.ProcessEnv): PersistentNativeHost {
  const scriptPath = new URL('../native/openpath-native-host.py', import.meta.url);
  const child = spawn('python3', [scriptPath.pathname], { env });
  let buffer = Buffer.alloc(0);
  const waiters: ((response: unknown) => void)[] = [];
  const stderrChunks: Buffer[] = [];

  child.stderr.on('data', (chunk: Buffer) => stderrChunks.push(chunk));
  child.stdout.on('data', (chunk: Buffer) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const bodyLength = buffer.readUInt32LE(0);
      if (buffer.length < 4 + bodyLength) {
        break;
      }
      const body = buffer.subarray(4, 4 + bodyLength).toString('utf8');
      buffer = buffer.subarray(4 + bodyLength);
      const waiter = waiters.shift();
      if (waiter) {
        waiter(JSON.parse(body));
      }
    }
  });

  return {
    send: (payload: unknown) =>
      new Promise((resolve) => {
        waiters.push(resolve);
        child.stdin.write(encodeNativeMessage(payload));
      }),
    close: async (): Promise<void> => {
      await new Promise<void>((resolve) => {
        child.on('close', () => {
          resolve();
        });
        child.stdin.end();
        const timer = setTimeout(() => {
          child.kill();
          resolve();
        }, 2_000);
        timer.unref();
      });
      const stderr = Buffer.concat(stderrChunks).toString('utf8');
      assert.equal(stderr, '', `native host wrote to stderr: ${stderr}`);
    },
  };
}

void test('linux native host announces the persistent transport protocol and capabilities', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-capabilities-'));
  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
    },
    { action: 'ping' }
  ) as {
    capabilities?: string[];
    protocolVersion?: number;
    success?: boolean;
  };

  assert.equal(response.success, true);
  assert.equal(response.protocolVersion, 2);
  assert.deepEqual(response.capabilities, [
    'runtime-dependency-enqueue',
    'runtime-dependency-check-batch',
    'message-id-echo',
    'runtime-dependency-auto-reload',
    'extension-diagnostics',
  ]);
});

void test('linux native host extension-diagnostics switch retires only that action', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-diag-switch-'));
  const switchPath = join(runtimeDir, 'extension-diagnostics.conf');
  writeFileSync(switchPath, 'disabled\n', 'utf8');

  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
      OPENPATH_EXTENSION_DIAGNOSTICS_CONF: switchPath,
    },
    { action: 'ping' }
  ) as {
    capabilities?: string[];
    protocolVersion?: number;
  };

  assert.equal(response.protocolVersion, 2);
  assert.deepEqual(response.capabilities, [
    'runtime-dependency-enqueue',
    'runtime-dependency-check-batch',
    'message-id-echo',
    'runtime-dependency-auto-reload',
  ]);
});

void test('linux native host writes sanitized extension diagnostics and caps the batch', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-diag-log-'));
  const events = [];
  for (let index = 0; index < 60; index += 1) {
    events.push({
      kind: 'hold',
      dependencyHost: 'cdn.example',
      anchorHost: 'https://evil.example/private?token=secret',
      reason: 'https://tracker.example/pixel?id=1',
      tabId: index,
      ms: 12,
      unexpected: 'must-be-dropped',
    });
  }

  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
    },
    { id: 42, action: 'report-extension-diagnostics', events }
  ) as {
    dropped?: number;
    id?: number;
    success?: boolean;
    written?: number;
  };

  assert.equal(response.success, true);
  assert.equal(response.written, 50);
  assert.equal(response.dropped, 10);
  // The id echo is what makes the persistent-port batch correlate.
  assert.equal(response.id, 42);

  const logContent = readFileSync(join(runtimeDir, 'openpath', 'native-host.log'), 'utf8');
  const lines = logContent
    .split('\n')
    .filter((line) => line.includes('stage=extension-diagnostic'));
  assert.equal(lines.length, 50);
  const first = lines[0] ?? '';
  assert.match(first, /"kind":"hold"/);
  assert.match(first, /cdn\.example/);
  assert.match(first, /"ms":12/);
  assert.doesNotMatch(first, /evil\.example/);
  assert.doesNotMatch(first, /tracker\.example/);
  assert.doesNotMatch(first, /unexpected/);
  assert.doesNotMatch(first, /must-be-dropped/);
});

void test('linux native host retirement switch drops enqueue and auto-reload', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-switch-'));
  const switchPath = join(runtimeDir, 'runtime-dependency-persistent-transport.conf');
  writeFileSync(switchPath, 'disabled\n', 'utf8');

  const response = runNativeHostOnce(
    {
      ...process.env,
      XDG_DATA_HOME: runtimeDir,
      OPENPATH_RUNTIME_DEPENDENCY_TRANSPORT_CONF: switchPath,
    },
    { action: 'ping' }
  ) as {
    capabilities?: string[];
    protocolVersion?: number;
  };

  assert.equal(response.protocolVersion, 2);
  assert.deepEqual(response.capabilities, ['runtime-dependency-check-batch', 'message-id-echo']);
});

void test('a persistent linux host process picks up whitelist changes between messages', async () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-freshness-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  writeFileSync(whitelistPath, '## WHITELIST\nallowed.example\n', 'utf8');

  const host = startPersistentNativeHost({
    ...process.env,
    XDG_DATA_HOME: runtimeDir,
    OPENPATH_WHITELIST_FILE: whitelistPath,
  });
  try {
    const before = (await host.send({
      action: 'check',
      domains: ['freshness.example'],
    })) as { results?: { in_whitelist?: boolean }[] };
    assert.equal(before.results?.[0]?.in_whitelist, false);

    writeFileSync(whitelistPath, '## WHITELIST\nallowed.example\nfreshness.example\n', 'utf8');

    const after = (await host.send({
      action: 'check',
      domains: ['freshness.example'],
    })) as { results?: { in_whitelist?: boolean }[] };
    assert.equal(after.results?.[0]?.in_whitelist, true);
  } finally {
    await host.close();
  }
});

void test('a persistent linux host logs ready transitions but not every poll', async () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-poll-log-'));
  const overlayPath = join(runtimeDir, 'runtime-dependency-overlay.json');
  const queueDir = join(runtimeDir, 'queue');
  mkdirSync(queueDir, { recursive: true });
  writeFileSync(
    overlayPath,
    JSON.stringify({ version: 1, generation: 1, appliedGeneration: 1, entries: [] }),
    'utf8'
  );

  const host = startPersistentNativeHost({
    ...process.env,
    XDG_DATA_HOME: runtimeDir,
    OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_FILE: overlayPath,
    OPENPATH_RUNTIME_DEPENDENCY_QUEUE_DIR: queueDir,
  });
  try {
    await host.send({ action: 'ping' });
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const poll = (await host.send({
        action: 'check-local-runtime-dependency',
        anchorHost: 'allowed.example',
        dependencyHost: 'cdn.example',
      })) as { ready?: boolean };
      assert.equal(poll.ready, false);
    }

    writeFileSync(
      overlayPath,
      JSON.stringify({
        version: 1,
        generation: 1,
        appliedGeneration: 2,
        entries: [
          {
            anchorHost: 'allowed.example',
            dependencyHost: 'cdn.example',
            generation: 1,
          },
        ],
      }),
      'utf8'
    );
    const applied = (await host.send({
      action: 'check-local-runtime-dependency',
      anchorHost: 'allowed.example',
      dependencyHost: 'cdn.example',
    })) as { ready?: boolean };
    assert.equal(applied.ready, true);
  } finally {
    await host.close();
  }

  const logPath = join(runtimeDir, 'openpath', 'native-host.log');
  const logContent = readFileSync(logPath, 'utf8');
  assert.match(logContent, /runtime-dependency-ready-transition/);
  const checkLines = logContent
    .split('\n')
    .filter(
      (line) => line.includes('Received:') && line.includes('check-local-runtime-dependency')
    );
  assert.deepEqual(checkLines, [], 'poll messages must not be logged one per message');
});
