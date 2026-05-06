#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const extensionRoot = path.dirname(__filename);
const repoRoot = path.resolve(extensionRoot, '..');
const defaultOutputDir = path.join(extensionRoot, 'build', 'firefox-source-submission');
const defaultOutputPath = path.join(defaultOutputDir, 'openpath-firefox-source.zip');
const fixedZipDate = new Date('2026-01-01T00:00:00Z');

const excludedSegments = new Set(['node_modules', 'dist', 'build', 'coverage', '.turbo']);
const sourceSubmissionRoots = [
  'package.json',
  'package-lock.json',
  'tsconfig.base.json',
  'tsconfig.json',
  'turbo.json',
  'firefox-extension/manifest.json',
  'firefox-extension/package.json',
  'firefox-extension/tsconfig.json',
  'firefox-extension/tsconfig.build.json',
  'firefox-extension/README.md',
  'firefox-extension/amo-review-metadata.json',
  'firefox-extension/build-xpi.sh',
  'firefox-extension/build-firefox-release.mjs',
  'firefox-extension/build-firefox-source-submission.d.mts',
  'firefox-extension/build-firefox-source-submission.mjs',
  'firefox-extension/sign-firefox-release.mjs',
  'firefox-extension/verify-firefox-amo-submission.mjs',
  'firefox-extension/verify-firefox-release-artifacts.mjs',
  'firefox-extension/src',
  'firefox-extension/tests',
  'firefox-extension/native',
  'firefox-extension/popup',
  'firefox-extension/blocked',
  'firefox-extension/icons',
  'firefox-extension/AMO.md',
  'firefox-extension/PRIVACY.md',
  'firefox-extension/SOURCE_REVIEW_NOTES.md',
];

function fail(message) {
  throw new Error(message);
}

function normalizePath(relativePath) {
  return relativePath.split(path.sep).join(path.posix.sep);
}

function shouldExclude(relativePath) {
  const normalized = normalizePath(relativePath);
  const segments = normalized.split('/');
  return (
    segments.some((segment) => excludedSegments.has(segment)) ||
    normalized.endsWith('.tsbuildinfo') ||
    normalized.endsWith('.tmp') ||
    normalized.endsWith('~')
  );
}

function collectFiles(rootDir, relativePath, files) {
  if (shouldExclude(relativePath)) {
    return;
  }

  const absolutePath = path.join(rootDir, relativePath);
  if (!fs.existsSync(absolutePath)) {
    fail(`Source submission entry missing: ${relativePath}`);
  }

  const stat = fs.statSync(absolutePath);
  if (stat.isDirectory()) {
    const entries = fs
      .readdirSync(absolutePath, { withFileTypes: true })
      .sort((left, right) => left.name.localeCompare(right.name));

    for (const entry of entries) {
      collectFiles(rootDir, path.join(relativePath, entry.name), files);
    }
    return;
  }

  if (!stat.isFile()) {
    fail(`Source submission entry is not a file or directory: ${relativePath}`);
  }

  files.push(normalizePath(relativePath));
}

function collectSourceSubmissionFiles(rootDir = repoRoot) {
  const files = [];

  for (const entry of sourceSubmissionRoots) {
    collectFiles(rootDir, entry, files);
  }

  return [...new Set(files)].sort();
}

const crcTable = new Uint32Array(256);
for (let index = 0; index < crcTable.length; index += 1) {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) {
    value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  crcTable[index] = value >>> 0;
}

function crc32(buffer) {
  let value = 0xffffffff;
  for (const byte of buffer) {
    value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) >>> 0;
}

function dosDateTime(date) {
  const year = Math.max(1980, date.getUTCFullYear());
  const dosTime =
    (date.getUTCHours() << 11) | (date.getUTCMinutes() << 5) | Math.floor(date.getUTCSeconds() / 2);
  const dosDate = ((year - 1980) << 9) | ((date.getUTCMonth() + 1) << 5) | date.getUTCDate();
  return { dosTime, dosDate };
}

function uint16(value) {
  const buffer = Buffer.alloc(2);
  buffer.writeUInt16LE(value);
  return buffer;
}

function uint32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value);
  return buffer;
}

function createZipArchive(entries) {
  const localParts = [];
  const centralParts = [];
  const { dosTime, dosDate } = dosDateTime(fixedZipDate);
  let offset = 0;

  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    const data = entry.data;
    const checksum = crc32(data);

    const localHeader = Buffer.concat([
      uint32(0x04034b50),
      uint16(20),
      uint16(0x0800),
      uint16(0),
      uint16(dosTime),
      uint16(dosDate),
      uint32(checksum),
      uint32(data.length),
      uint32(data.length),
      uint16(name.length),
      uint16(0),
      name,
    ]);
    localParts.push(localHeader, data);

    const centralHeader = Buffer.concat([
      uint32(0x02014b50),
      uint16(20),
      uint16(20),
      uint16(0x0800),
      uint16(0),
      uint16(dosTime),
      uint16(dosDate),
      uint32(checksum),
      uint32(data.length),
      uint32(data.length),
      uint16(name.length),
      uint16(0),
      uint16(0),
      uint16(0),
      uint16(0),
      uint32(0o100644 * 0x10000),
      uint32(offset),
      name,
    ]);
    centralParts.push(centralHeader);

    offset += localHeader.length + data.length;
  }

  const centralDirectory = Buffer.concat(centralParts);
  const endOfCentralDirectory = Buffer.concat([
    uint32(0x06054b50),
    uint16(0),
    uint16(0),
    uint16(entries.length),
    uint16(entries.length),
    uint32(centralDirectory.length),
    uint32(offset),
    uint16(0),
  ]);

  return Buffer.concat([...localParts, centralDirectory, endOfCentralDirectory]);
}

export function buildFirefoxSourceSubmission(options = {}) {
  const {
    rootDir = repoRoot,
    outputPath = defaultOutputPath,
    entries = collectSourceSubmissionFiles(rootDir),
  } = options;
  const archiveEntries = entries.map((entry) => ({
    name: entry,
    data: fs.readFileSync(path.join(rootDir, entry)),
  }));
  const archive = createZipArchive(archiveEntries);

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, archive);

  return {
    outputPath,
    entries: archiveEntries.map((entry) => entry.name),
  };
}

function parseCliArgs(argv) {
  const parsed = {
    outputPath: defaultOutputPath,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? '';
    const next = argv[index + 1] ?? '';

    switch (arg) {
      case '--output':
        parsed.outputPath = path.resolve(next);
        index += 1;
        break;
      case '--help':
      case '-h':
        console.log(`Usage:
  node build-firefox-source-submission.mjs [--output build/firefox-source-submission/openpath-firefox-source.zip]

Options:
  --output  Override the source archive output path
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
    const { outputPath } = parseCliArgs(process.argv.slice(2));
    const result = buildFirefoxSourceSubmission({ outputPath });
    console.log(
      `[build:firefox-source] Prepared AMO source archive ${path.relative(
        extensionRoot,
        result.outputPath
      )} with ${result.entries.length} files`
    );
  } catch (error) {
    console.error(
      `[build:firefox-source] ${error instanceof Error ? error.message : String(error)}`
    );
    process.exitCode = 1;
  }
}
