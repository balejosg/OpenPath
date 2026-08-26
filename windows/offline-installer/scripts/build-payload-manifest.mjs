#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';

const REQUIRED_REPO_PATHS = ['VERSION'];
const REQUIRED_EXTENSION_ARTIFACTS = [
  'firefox-release/openpath-firefox-extension.xpi',
  'firefox-release/metadata.json',
  'chromium-managed/metadata.json',
];
const REQUIRED_PAYLOAD_FILES = [
  'payloads/acrylic/Acrylic-Portable.zip',
  'payloads/firefox-esr/Firefox-Setup-esr.exe',
];

function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function listFilesRecursive(root, excludedPaths = new Set()) {
  const entries = [];
  if (!existsSync(root)) {
    return entries;
  }
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const fullPath = join(root, entry.name);
    if (excludedPaths.has(fullPath)) continue;
    if (entry.isDirectory()) {
      entries.push(...listFilesRecursive(fullPath, excludedPaths));
    } else if (entry.isFile()) {
      entries.push(fullPath);
    }
  }
  return entries;
}

function toManifestEntry(absolutePath, packageRoot, origin, packagePrefix = '') {
  const relativePath = relative(packageRoot, absolutePath).split('\\').join('/');
  const packagePath = packagePrefix ? `${packagePrefix}/${relativePath}` : relativePath;
  const stats = statSync(absolutePath);
  return {
    path: packagePath,
    size: stats.size,
    sha256: sha256File(absolutePath),
    origin,
  };
}

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = {};
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith('--')) continue;
    const key = arg.slice(2);
    const value = argv[index + 1];
    args[key] = value;
    index += 1;
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv);

  const repoRoot = resolve(args['repo-root'] ?? '.');
  // The pin paths intentionally include the `payloads/` prefix because that
  // is also the path used inside the NSIS package. Resolve them from the
  // offline-installer build root, not from build/payloads/, or a clean build
  // would look for build/payloads/payloads/<file>.
  const payloadsDir = args['payloads-dir']
    ? resolve(args['payloads-dir'])
    : join(repoRoot, 'windows', 'offline-installer', 'build');
  const extensionBuildDir =
    args['extension-build-dir'] ?? join(repoRoot, 'firefox-extension', 'build');
  const outputPath = args['out']
    ? resolve(args['out'])
    : join(repoRoot, 'windows', 'offline-installer', 'build', 'payload-manifest.json');

  if (!existsSync(repoRoot)) {
    fail(`repo root not found: ${repoRoot}`);
  }

  const errors = [];
  const entries = [];

  for (const requiredPath of REQUIRED_REPO_PATHS) {
    const fullPath = join(repoRoot, requiredPath);
    if (!existsSync(fullPath)) {
      errors.push(`missing required file: ${requiredPath}`);
      continue;
    }
    entries.push(toManifestEntry(fullPath, repoRoot, 'repo'));
  }

  for (const tree of ['windows', 'runtime']) {
    const treeRoot = join(repoRoot, tree);
    if (!existsSync(treeRoot)) {
      errors.push(`missing required source tree: ${tree}/`);
      continue;
    }
    const excludedPaths =
      tree === 'windows' ? new Set([join(treeRoot, 'offline-installer', 'build')]) : undefined;
    const packagePrefix = tree === 'runtime' ? 'runtime' : '';
    for (const filePath of listFilesRecursive(treeRoot, excludedPaths)) {
      entries.push(toManifestEntry(filePath, treeRoot, `repo:${tree}`, packagePrefix));
    }
  }

  for (const artifact of REQUIRED_EXTENSION_ARTIFACTS) {
    const fullPath = join(extensionBuildDir, artifact);
    if (!existsSync(fullPath)) {
      errors.push(`missing extension artifact: ${artifact} (build the firefox extension first)`);
      continue;
    }
    if (artifact.endsWith('.xpi')) {
      const xpiBytes = readFileSync(fullPath);
      const signatureOffset = xpiBytes.indexOf(Buffer.from('META-INF/mozilla.rsa'));
      if (signatureOffset === -1) {
        errors.push(`${artifact} is not AMO-signed (META-INF/mozilla.rsa absent)`);
        continue;
      }
    }
    entries.push(toManifestEntry(fullPath, extensionBuildDir, 'build'));
  }

  let pins = {};
  const pinsPath = args['pins']
    ? resolve(args['pins'])
    : join(repoRoot, 'windows', 'offline-installer', 'payload-pins.json');
  try {
    pins = JSON.parse(readFileSync(pinsPath, 'utf8'));
  } catch (error) {
    fail(`unreadable payload pins (${pinsPath}): ${error.message}`);
  }

  const pinnedPaths = new Set(Object.values(pins).map((pin) => pin.manifestPath));
  for (const requiredPayload of REQUIRED_PAYLOAD_FILES) {
    if (!pinnedPaths.has(requiredPayload)) {
      errors.push(`missing pin definition for required payload: ${requiredPayload}`);
    }
  }

  for (const [pinName, pin] of Object.entries(pins)) {
    const payloadPath = join(payloadsDir, pin.manifestPath);
    if (!existsSync(payloadPath)) {
      errors.push(`missing pinned payload ${pinName}: ${pin.manifestPath}`);
      continue;
    }
    const actualHash = sha256File(payloadPath);
    if (actualHash !== String(pin.sha256).toLowerCase()) {
      errors.push(
        `sha256 mismatch for pinned payload ${pinName}: expected ${pin.sha256}, got ${actualHash}`
      );
      continue;
    }
    const entry = toManifestEntry(payloadPath, payloadsDir, `pinned:${pinName}`);
    entry.path = pin.manifestPath;
    entry.version = pin.version ?? null;
    entries.push(entry);
  }

  if (errors.length > 0) {
    console.error('Offline installer payload inventory incomplete:');
    for (const error of errors) {
      console.error(`  - ${error}`);
    }
    process.exit(1);
  }

  entries.sort((left, right) => left.path.localeCompare(right.path));

  const manifest = {
    schemaVersion: 1,
    generatedFor: 'OpenPath-Windows-Setup-Template',
    payloads: entries,
  };

  mkdirSync(resolve(outputPath, '..'), { recursive: true });
  writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`Wrote payload manifest with ${entries.length} entries to ${outputPath}`);
}

main();
