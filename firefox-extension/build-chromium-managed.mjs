#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

const extensionRoot = process.cwd();
const buildRoot = path.join(extensionRoot, 'build');
const unpackedDir = path.join(buildRoot, 'chromium-unpacked');
const managedDir = path.join(buildRoot, 'chromium-managed');
const packageDir = path.join(managedDir, 'openpath-chromium-extension');
const manifestPath = path.join(extensionRoot, 'manifest.json');
const crxPath = path.join(managedDir, 'openpath-chromium-extension.crx');
const keyPath = path.join(managedDir, 'openpath-chromium-extension.pem');
const metadataPath = path.join(managedDir, 'metadata.json');
const requiredEntries = ['_locales', 'dist', 'popup', 'icons', 'blocked'];
const requireManaged =
  process.argv.includes('--require-managed') ||
  process.env.OPENPATH_CHROMIUM_REQUIRE_MANAGED === 'true';

function log(message) {
  console.log(`[build:chromium-managed] ${message}`);
}

function fail(message) {
  throw new Error(message);
}

function resetDirectory(directoryPath) {
  fs.rmSync(directoryPath, { recursive: true, force: true });
  fs.mkdirSync(directoryPath, { recursive: true });
}

function copyRecursive(sourcePath, destinationPath) {
  fs.cpSync(sourcePath, destinationPath, {
    recursive: true,
    force: true,
    errorOnExist: false,
  });
}

function findExecutable(name) {
  const pathEntries = (process.env.PATH ?? '').split(path.delimiter).filter(Boolean);
  const extensions =
    process.platform === 'win32'
      ? (process.env.PATHEXT ?? '.EXE;.CMD;.BAT;.COM').split(';').filter(Boolean)
      : [''];

  for (const directory of pathEntries) {
    for (const extension of extensions) {
      const candidate = path.join(directory, `${name}${extension}`);
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
        return candidate;
      } catch {
        // Keep looking.
      }
    }
  }

  return null;
}

function detectPackager() {
  const configured = process.env.OPENPATH_CHROMIUM_PACKAGER?.trim();
  if (configured) {
    const explicit = findExecutable(configured) ?? (fs.existsSync(configured) ? configured : null);
    if (explicit) {
      return explicit;
    }
  }

  const candidates = [
    'google-chrome',
    'google-chrome-stable',
    'chromium-browser',
    'chromium',
    'microsoft-edge',
    'microsoft-edge-stable',
    'microsoft-edge-beta',
    'microsoft-edge-dev',
  ];

  for (const candidate of candidates) {
    const resolved = findExecutable(candidate);
    if (resolved) {
      return resolved;
    }
  }

  return null;
}

function deriveExtensionIdFromKey(pemFilePath) {
  const privateKeyPem = fs.readFileSync(pemFilePath, 'utf8');
  const publicKeyDer = crypto.createPublicKey(privateKeyPem).export({
    type: 'spki',
    format: 'der',
  });
  const digest = crypto.createHash('sha256').update(publicKeyDer).digest('hex').slice(0, 32);
  const alphabet = 'abcdefghijklmnop';

  return Array.from(digest, (char) => alphabet[Number.parseInt(char, 16)]).join('');
}

function loadManifest() {
  if (!fs.existsSync(manifestPath)) {
    fail(`manifest.json not found at ${manifestPath}`);
  }

  return JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
}

function prepareUnpackedBundle(manifest) {
  resetDirectory(unpackedDir);

  for (const entry of requiredEntries) {
    const sourcePath = path.join(extensionRoot, entry);
    if (!fs.existsSync(sourcePath)) {
      fail(`Required extension entry missing: ${entry}`);
    }
    copyRecursive(sourcePath, path.join(unpackedDir, entry));
  }

  const chromiumManifest = { ...manifest };
  delete chromiumManifest.browser_specific_settings;
  chromiumManifest.background = {
    service_worker: 'dist/background.js',
    type: 'module',
  };

  fs.writeFileSync(
    path.join(unpackedDir, 'manifest.json'),
    `${JSON.stringify(chromiumManifest, null, 2)}\n`,
    'utf8'
  );
}

function writeManagedMetadata(manifestVersion, extensionId) {
  const metadata = {
    extensionId,
    version: typeof manifestVersion === 'string' && manifestVersion ? manifestVersion : '0.0.0',
  };

  fs.writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`, 'utf8');
}

function packageManagedArtifacts(manifest) {
  const existingKey = fs.existsSync(keyPath) ? fs.readFileSync(keyPath) : null;
  resetDirectory(managedDir);
  if (existingKey) {
    fs.writeFileSync(keyPath, existingKey);
  }

  const packager = detectPackager();
  if (!packager) {
    const message = 'No Chromium-compatible browser detected for managed CRX packaging';
    if (requireManaged) {
      fail(message);
    }

    log(`${message}; leaving unpacked bundle only`);
    return;
  }

  copyRecursive(unpackedDir, packageDir);

  const packArgs = fs.existsSync(keyPath)
    ? [`--pack-extension=${packageDir}`, `--pack-extension-key=${keyPath}`]
    : [`--pack-extension=${packageDir}`];
  const result = spawnSync(packager, packArgs, {
    cwd: extensionRoot,
    encoding: 'utf8',
  });

  fs.rmSync(packageDir, { recursive: true, force: true });

  if (result.status !== 0 || !fs.existsSync(crxPath) || !fs.existsSync(keyPath)) {
    const stderr = [result.stdout, result.stderr].filter(Boolean).join('\n').trim();
    const message = stderr
      ? `Chromium CRX packaging failed: ${stderr}`
      : 'Chromium CRX packaging failed';

    fs.rmSync(managedDir, { recursive: true, force: true });
    fs.mkdirSync(managedDir, { recursive: true });

    if (requireManaged) {
      fail(message);
    }

    log(`${message}; leaving unpacked bundle only`);
    return;
  }

  const extensionId = deriveExtensionIdFromKey(keyPath);
  writeManagedMetadata(manifest.version, extensionId);
  log(`Prepared managed Chromium artifacts for ${extensionId}`);
}

try {
  const manifest = loadManifest();
  prepareUnpackedBundle(manifest);
  packageManagedArtifacts(manifest);
  log(`Prepared unpacked Chromium bundle in ${path.relative(extensionRoot, unpackedDir)}`);
} catch (error) {
  console.error(
    `[build:chromium-managed] ${error instanceof Error ? error.message : String(error)}`
  );
  process.exitCode = 1;
}
