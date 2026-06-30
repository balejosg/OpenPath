import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, test } from 'node:test';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, '..');
const manifestPath = path.join(projectRoot, 'native', 'whitelist_native_host.json');
const backgroundPath = path.join(projectRoot, 'src', 'background.ts');

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

void describe('Firefox native host contract', () => {
  void test('manifest template uses the Firefox host name expected by the extension', async () => {
    const manifest = JSON.parse(await readFile(manifestPath, 'utf8')) as {
      name?: string;
      allowed_extensions?: string[];
    };
    const backgroundSource = await readFile(backgroundPath, 'utf8');
    const hostNameMatch = /const NATIVE_HOST_NAME = '([^']+)'/.exec(backgroundSource);
    const hostName = hostNameMatch?.[1] ?? '';

    assert.ok(hostNameMatch, 'background.ts should declare NATIVE_HOST_NAME');
    assert.notEqual(hostName, '', 'background.ts should expose a non-empty native host name');
    assert.equal(
      path.basename(manifestPath),
      `${hostName}.json`,
      'native host manifest filename should stay in sync with background.ts'
    );
    assert.equal(
      manifest.name,
      hostName,
      'native host manifest name should stay in sync with background.ts'
    );
    assert.equal(manifest.name, 'whitelist_native_host');
  });

  void test('manifest template allows the signed Firefox extension id', async () => {
    const manifest = JSON.parse(await readFile(manifestPath, 'utf8')) as {
      allowed_extensions?: string[];
    };

    assert.deepEqual(manifest.allowed_extensions, ['openpath-block-monitor@openpath']);
  });
});

void test('get-allowed-paths returns ALLOWED-PATHS lines and get-blocked-paths excludes them', () => {
  const runtimeDir = mkdtempSync(join(tmpdir(), 'openpath-native-host-allowed-paths-'));
  const whitelistPath = join(runtimeDir, 'whitelist.txt');
  writeFileSync(
    whitelistPath,
    [
      '## WHITELIST',
      'youtube.com',
      '## BLOCKED-PATHS',
      'example.com/ads',
      '## ALLOWED-PATHS',
      'youtube.com/watch?v=abc',
      '',
    ].join('\n'),
    'utf8'
  );

  const env = {
    ...process.env,
    OPENPATH_WHITELIST_FILE: whitelistPath,
    XDG_DATA_HOME: runtimeDir,
  };

  const allowed = runNativeHostOnce(env, { action: 'get-allowed-paths' }) as {
    success?: boolean;
    action?: string;
    paths?: string[];
    count?: number;
    hash?: string;
  };

  assert.equal(allowed.success, true);
  assert.equal(allowed.action, 'get-allowed-paths');
  assert.deepEqual(allowed.paths, ['youtube.com/watch?v=abc']);
  assert.equal(allowed.count, 1);
  assert.equal(typeof allowed.hash, 'string');

  const blocked = runNativeHostOnce(env, { action: 'get-blocked-paths' }) as {
    success?: boolean;
    paths?: string[];
  };

  assert.equal(blocked.success, true);
  assert.deepEqual(blocked.paths, ['example.com/ads']);
});
