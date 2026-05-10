#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const extensionRoot = path.dirname(__filename);
const defaultSourceArchive = path.join(
  extensionRoot,
  'build',
  'firefox-source-submission',
  'openpath-firefox-source.zip'
);
const defaultMetadataPath = path.join(extensionRoot, 'amo-review-metadata.json');

function fail(message) {
  throw new Error(message);
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function manifestRequiresReviewerPackage(manifestPath = path.join(extensionRoot, 'manifest.json')) {
  const manifest = readJson(manifestPath);
  const dataCollectionPermissions =
    manifest.browser_specific_settings?.gecko?.data_collection_permissions ?? {};
  const required =
    manifest.browser_specific_settings?.gecko?.data_collection_permissions?.required ?? [];
  const optional = dataCollectionPermissions.optional ?? [];
  return (
    (Array.isArray(required) && required.length > 0) ||
    (Array.isArray(optional) && optional.length > 0)
  );
}

function validateAmoMetadata(metadataPath) {
  if (!fs.existsSync(metadataPath)) {
    fail(`AMO metadata file is required: ${metadataPath}`);
  }

  const metadata = readJson(metadataPath);
  const approvalNotes = metadata.version?.approval_notes;
  if (typeof approvalNotes !== 'string' || approvalNotes.trim().length === 0) {
    fail(`AMO metadata must include version.approval_notes: ${metadataPath}`);
  }

  const releaseNotes = metadata.version?.release_notes;
  if (!releaseNotes || typeof releaseNotes !== 'object' || Array.isArray(releaseNotes)) {
    fail(`AMO metadata must include version.release_notes: ${metadataPath}`);
  }

  const normalizedReleaseNotes = Object.fromEntries(
    Object.entries(releaseNotes)
      .filter((entry) => typeof entry[1] === 'string' && entry[1].trim().length > 0)
      .map(([locale, text]) => [locale, text.trim()])
  );
  if (Object.keys(normalizedReleaseNotes).length === 0) {
    fail(`AMO metadata must include version.release_notes: ${metadataPath}`);
  }

  return {
    approvalNotes: approvalNotes.trim(),
    releaseNotes: normalizedReleaseNotes,
  };
}

export function verifyFirefoxAmoSubmission(options = {}) {
  const {
    manifestPath = path.join(extensionRoot, 'manifest.json'),
    sourceArchive = process.env.WEB_EXT_SIGN_SOURCE_CODE_ARCHIVE ||
      process.env.WEB_EXT_SIGN_SOURCE_CODE ||
      defaultSourceArchive,
    metadataPath = process.env.WEB_EXT_AMO_METADATA || defaultMetadataPath,
  } = options;

  if (!manifestRequiresReviewerPackage(manifestPath)) {
    return {
      required: false,
      sourceArchive,
      metadataPath,
    };
  }

  if (!fs.existsSync(sourceArchive)) {
    fail(`AMO source archive is required: ${sourceArchive}`);
  }

  const sourceStat = fs.statSync(sourceArchive);
  if (!sourceStat.isFile() || sourceStat.size === 0) {
    fail(`AMO source archive must be a non-empty file: ${sourceArchive}`);
  }

  const { approvalNotes, releaseNotes } = validateAmoMetadata(metadataPath);

  return {
    required: true,
    sourceArchive,
    metadataPath,
    approvalNotes,
    releaseNotes,
  };
}

function parseCliArgs(argv) {
  const parsed = {
    sourceArchive:
      process.env.WEB_EXT_SIGN_SOURCE_CODE_ARCHIVE ||
      process.env.WEB_EXT_SIGN_SOURCE_CODE ||
      defaultSourceArchive,
    metadataPath: process.env.WEB_EXT_AMO_METADATA || defaultMetadataPath,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? '';
    const next = argv[index + 1] ?? '';

    switch (arg) {
      case '--source':
        parsed.sourceArchive = path.resolve(next);
        index += 1;
        break;
      case '--metadata':
        parsed.metadataPath = path.resolve(next);
        index += 1;
        break;
      case '--help':
      case '-h':
        console.log(`Usage:
  node verify-firefox-amo-submission.mjs [--source openpath-firefox-source.zip] [--metadata amo-review-metadata.json]

Options:
  --source    Source archive that will be uploaded to AMO
  --metadata  web-ext AMO metadata JSON containing version.approval_notes and version.release_notes
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
    const options = parseCliArgs(process.argv.slice(2));
    const result = verifyFirefoxAmoSubmission(options);
    console.log(
      result.required
        ? `[verify:firefox-amo] Source archive and reviewer metadata are present for ${path.relative(
            extensionRoot,
            result.sourceArchive
          )}`
        : '[verify:firefox-amo] Manifest does not declare AMO data collection permissions'
    );
  } catch (error) {
    console.error(`[verify:firefox-amo] ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
