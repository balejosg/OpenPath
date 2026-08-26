#!/usr/bin/env node
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const SHA256_PATTERN = /^[0-9a-f]{64}$/u;

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function parseArgs(argv) {
  const args = {};
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) continue;
    const key = argument.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`${argument} requires a value`);
    args[key] = value;
    index += 1;
  }
  return args;
}

function resolvePayloadPath(payloadsDir, manifestPath) {
  if (typeof manifestPath !== 'string' || !manifestPath.trim()) {
    throw new Error('Pinned payload manifestPath must be a non-empty relative path');
  }

  const normalized = manifestPath.replaceAll('\\', '/');
  if (isAbsolute(normalized) || normalized === '..' || normalized.startsWith('../')) {
    throw new Error(`Pinned payload path escapes the payload root: ${manifestPath}`);
  }

  const payloadPath = resolve(payloadsDir, normalized);
  const rootRelative = relative(resolve(payloadsDir), payloadPath);
  if (rootRelative === '..' || rootRelative.startsWith(`..${sep}`) || isAbsolute(rootRelative)) {
    throw new Error(`Pinned payload path escapes the payload root: ${manifestPath}`);
  }
  return payloadPath;
}

function validatePinnedUrl(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new Error('Pinned payload download URL must be an absolute URL');
  }
  if (url.protocol !== 'https:') {
    throw new Error('Pinned payload download URL must use HTTPS');
  }
  if (
    url.pathname.toLowerCase().includes('/latest') ||
    /\/(?:main|master)(?:\/|$)/u.test(url.pathname)
  ) {
    throw new Error('Pinned payload download URL must identify an immutable release asset');
  }
  return url.href;
}

function readPins(pinsPath) {
  const parsed = JSON.parse(readFileSync(pinsPath, 'utf8'));
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Pinned payload file must contain an object');
  }
  return parsed;
}

function existingDigest(payloadPath) {
  if (!existsSync(payloadPath) || !statSync(payloadPath).isFile()) return null;
  return sha256(readFileSync(payloadPath));
}

async function fetchPayload(fetchImpl, urls, expectedSha256, label) {
  let lastFailure = 'no download URL';
  for (const rawUrl of urls) {
    let url;
    try {
      url = validatePinnedUrl(rawUrl);
    } catch (error) {
      lastFailure = error instanceof Error ? error.message : String(error);
      continue;
    }

    try {
      const response = await fetchImpl(url, { redirect: 'follow' });
      if (!response.ok) {
        lastFailure = `HTTP ${String(response.status)}`;
        continue;
      }
      const bytes = Buffer.from(await response.arrayBuffer());
      const actualSha256 = sha256(bytes);
      if (actualSha256 !== expectedSha256) {
        lastFailure = `sha256 mismatch for ${label}`;
        continue;
      }
      return bytes;
    } catch (error) {
      lastFailure = error instanceof Error ? error.message : String(error);
    }
  }

  throw new Error(`Pinned payload ${label} could not be downloaded: ${lastFailure}`);
}

export async function downloadPinnedPayloads({
  pinsPath,
  payloadsDir,
  fetchImpl = globalThis.fetch,
}) {
  const pins = readPins(pinsPath);
  const results = [];
  for (const [name, pin] of Object.entries(pins).sort(([left], [right]) =>
    left.localeCompare(right)
  )) {
    if (!pin || typeof pin !== 'object' || Array.isArray(pin)) {
      throw new Error(`Pinned payload ${name} must be an object`);
    }
    const expectedSha256 = String(pin.sha256 ?? '').toLowerCase();
    if (!SHA256_PATTERN.test(expectedSha256)) {
      throw new Error(`Pinned payload ${name} must contain a lowercase SHA-256 digest`);
    }
    const urls = Array.isArray(pin.downloadUrls) ? pin.downloadUrls : [];
    if (urls.length === 0) throw new Error(`Pinned payload ${name} has no download URL`);

    const payloadPath = resolvePayloadPath(payloadsDir, pin.manifestPath);
    const cachedSha256 = existingDigest(payloadPath);
    if (cachedSha256 === expectedSha256) {
      results.push({ name, status: 'cached', path: payloadPath, sha256: expectedSha256 });
      continue;
    }

    const bytes = await fetchPayload(fetchImpl, urls, expectedSha256, name);
    mkdirSync(dirname(payloadPath), { recursive: true });
    const temporaryPath = join(
      dirname(payloadPath),
      `.${payloadPath.split(/[\\/]/u).pop()}.${process.pid}.${Date.now()}.tmp`
    );
    try {
      writeFileSync(temporaryPath, bytes, { flag: 'wx', mode: 0o644 });
      rmSync(payloadPath, { force: true });
      renameSync(temporaryPath, payloadPath);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
    results.push({ name, status: 'downloaded', path: payloadPath, sha256: expectedSha256 });
  }
  return results;
}

async function main() {
  const args = parseArgs(process.argv);
  const repoRoot = resolve(args['repo-root'] ?? '.');
  const pinsPath = resolve(
    args.pins ?? join(repoRoot, 'windows', 'offline-installer', 'payload-pins.json')
  );
  const payloadsDir = resolve(
    args['payloads-dir'] ?? join(repoRoot, 'windows', 'offline-installer', 'build')
  );
  const results = await downloadPinnedPayloads({ pinsPath, payloadsDir });
  for (const result of results) {
    console.log(`${result.status}: ${result.name} ${result.sha256}`);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
