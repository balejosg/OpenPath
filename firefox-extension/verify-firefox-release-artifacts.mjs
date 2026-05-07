#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const extensionRoot = path.dirname(__filename);
const defaultReleaseDir = path.join(extensionRoot, 'build', 'firefox-release');
const releaseXpiName = 'openpath-firefox-extension.xpi';

function fail(message) {
  throw new Error(message);
}

function readJsonFile(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    fail(`Unable to read Firefox Release metadata at ${filePath}: ${reason}`);
  }
}

function requireNonEmptyString(value, fieldName) {
  if (typeof value !== 'string' || value.trim().length === 0) {
    fail(`Firefox Release metadata must define ${fieldName}`);
  }

  return value.trim();
}

export function verifyFirefoxReleaseArtifacts(options) {
  const { releaseDir = defaultReleaseDir, payloadHash } = options;
  const resolvedReleaseDir = path.resolve(releaseDir);
  const metadataPath = path.join(resolvedReleaseDir, 'metadata.json');
  const xpiPath = path.join(resolvedReleaseDir, releaseXpiName);

  if (!fs.existsSync(metadataPath)) {
    fail(`Firefox Release metadata.json not found: ${metadataPath}`);
  }
  if (!fs.existsSync(xpiPath)) {
    fail(`Firefox Release ${releaseXpiName} not found: ${xpiPath}`);
  }

  const xpiStat = fs.statSync(xpiPath);
  if (!xpiStat.isFile() || xpiStat.size <= 0) {
    fail(`Firefox Release ${releaseXpiName} must be a non-empty file: ${xpiPath}`);
  }

  const metadata = readJsonFile(metadataPath);
  const extensionId = requireNonEmptyString(metadata.extensionId, 'extensionId');
  const version = requireNonEmptyString(metadata.version, 'version');
  const signatureSource = requireNonEmptyString(metadata.signatureSource, 'signatureSource');
  const signatureState = requireNonEmptyString(metadata.signatureState, 'signatureState');
  const metadataPayloadHash = requireNonEmptyString(metadata.payloadHash, 'payloadHash');
  const expectedPayloadHash = requireNonEmptyString(payloadHash, 'expected payloadHash');

  if (signatureSource !== 'amo') {
    fail(`Firefox Release signatureSource must be amo, found ${signatureSource}`);
  }

  if (signatureState !== 'signed') {
    fail(`Firefox Release signatureState must be signed, found ${signatureState}`);
  }

  if (metadataPayloadHash !== expectedPayloadHash) {
    fail(
      `Firefox Release payloadHash mismatch: expected ${expectedPayloadHash}, found ${metadataPayloadHash}`
    );
  }

  return {
    ...metadata,
    extensionId,
    version,
    signatureSource,
    signatureState,
    payloadHash: metadataPayloadHash,
  };
}

function parseCliArgs(argv) {
  const parsed = {
    releaseDir: defaultReleaseDir,
    payloadHash: '',
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? '';
    const next = argv[index + 1] ?? '';

    switch (arg) {
      case '--release-dir':
        parsed.releaseDir = next;
        index += 1;
        break;
      case '--payload-hash':
        parsed.payloadHash = next;
        index += 1;
        break;
      case '--help':
      case '-h':
        console.log(`Usage:
  node verify-firefox-release-artifacts.mjs --payload-hash <sha256> [--release-dir build/firefox-release]

Options:
  --payload-hash  Expected Firefox Release payload hash (required)
  --release-dir   Directory containing metadata.json and openpath-firefox-extension.xpi
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
    const metadata = verifyFirefoxReleaseArtifacts(args);
    console.log(
      `[verify:firefox-release] Verified signed Firefox Release artifacts for ${metadata.extensionId} ${metadata.version}`
    );
  } catch (error) {
    console.error(
      `[verify:firefox-release] ${error instanceof Error ? error.message : String(error)}`
    );
    process.exitCode = 1;
  }
}
