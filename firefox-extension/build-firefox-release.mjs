#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { assertFirefoxAmoSignedXpi } from './xpi-signature-evidence.mjs';

const __filename = fileURLToPath(import.meta.url);
const extensionRoot = path.dirname(__filename);
const defaultManifestPath = path.join(extensionRoot, 'manifest.json');
const defaultOutputDir = path.join(extensionRoot, 'build', 'firefox-release');
const defaultOutputXpiName = 'openpath-firefox-extension.xpi';
const releaseSignatureSource = 'amo';
const releaseSignatureState = 'signed';

function fail(message) {
  throw new Error(message);
}

function resetDirectory(directoryPath) {
  fs.rmSync(directoryPath, { recursive: true, force: true });
  fs.mkdirSync(directoryPath, { recursive: true });
}

function readManifest(manifestPath = defaultManifestPath) {
  if (!fs.existsSync(manifestPath)) {
    fail(`manifest.json not found at ${manifestPath}`);
  }

  return JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
}

function resolveExtensionId(manifest) {
  const extensionId = manifest?.browser_specific_settings?.gecko?.id;
  if (typeof extensionId !== 'string' || extensionId.trim().length === 0) {
    fail('Firefox extension manifest must define browser_specific_settings.gecko.id');
  }

  return extensionId.trim();
}

export function prepareFirefoxReleaseArtifacts(options) {
  const {
    extensionRoot: explicitExtensionRoot = extensionRoot,
    signedXpiPath,
    installUrl = '',
    outputDir = defaultOutputDir,
    manifestPath = path.join(explicitExtensionRoot, 'manifest.json'),
    extensionId = '',
    version = '',
    payloadHash = '',
  } = options;

  if (!signedXpiPath) {
    fail('signedXpiPath is required');
  }

  const resolvedSignedXpiPath = path.resolve(signedXpiPath);
  if (!fs.existsSync(resolvedSignedXpiPath)) {
    fail(`Signed Firefox XPI not found: ${resolvedSignedXpiPath}`);
  }
  assertFirefoxAmoSignedXpi(resolvedSignedXpiPath);

  const manifest = readManifest(manifestPath);
  const effectiveExtensionId = extensionId || resolveExtensionId(manifest);
  const effectiveVersion =
    version || (typeof manifest.version === 'string' && manifest.version.trim()) || '0.0.0';

  const resolvedOutputDir = path.resolve(outputDir);
  const outputXpiPath = path.join(resolvedOutputDir, defaultOutputXpiName);
  const metadataPath = path.join(resolvedOutputDir, 'metadata.json');

  resetDirectory(resolvedOutputDir);
  fs.copyFileSync(resolvedSignedXpiPath, outputXpiPath);

  const metadata = {
    extensionId: effectiveExtensionId,
    version: effectiveVersion,
    signatureSource: releaseSignatureSource,
    signatureState: releaseSignatureState,
    ...(installUrl ? { installUrl } : {}),
    ...(payloadHash ? { payloadHash } : {}),
  };

  fs.writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`, 'utf8');

  return {
    outputDir: resolvedOutputDir,
    outputXpiPath,
    metadataPath,
    metadata,
  };
}

function parseCliArgs(argv) {
  const parsed = {
    signedXpiPath: '',
    installUrl: '',
    outputDir: defaultOutputDir,
    extensionId: '',
    version: '',
    payloadHash: '',
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? '';
    const next = argv[index + 1] ?? '';

    switch (arg) {
      case '--signed-xpi':
        parsed.signedXpiPath = next;
        index += 1;
        break;
      case '--install-url':
        parsed.installUrl = next;
        index += 1;
        break;
      case '--output-dir':
        parsed.outputDir = next;
        index += 1;
        break;
      case '--extension-id':
        parsed.extensionId = next;
        index += 1;
        break;
      case '--version':
        parsed.version = next;
        index += 1;
        break;
      case '--payload-hash':
        parsed.payloadHash = next;
        index += 1;
        break;
      case '--help':
      case '-h':
        console.log(`Usage:
  node build-firefox-release.mjs --signed-xpi /path/to/signed.xpi [--install-url https://...]

Options:
  --signed-xpi    Path to the AMO-signed XPI (required)
  --install-url   Optional managed install URL to store in metadata.json
  --output-dir    Override output directory (default: build/firefox-release)
  --extension-id  Override extension ID (default: manifest gecko id)
  --version       Override version (default: manifest version)
  --payload-hash  Expected payload hash to store in metadata.json
`);
        process.exit(0);
        break;
      default:
        if (arg.startsWith('-')) {
          fail(`Unknown argument: ${arg}`);
        }
    }
  }

  return parsed;
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  try {
    const args = parseCliArgs(process.argv.slice(2));
    const result = prepareFirefoxReleaseArtifacts(args);
    console.log(
      `[build:firefox-release] Prepared signed Firefox Release artifacts in ${path.relative(
        extensionRoot,
        result.outputDir
      )}`
    );
  } catch (error) {
    console.error(
      `[build:firefox-release] ${error instanceof Error ? error.message : String(error)}`
    );
    process.exitCode = 1;
  }
}
