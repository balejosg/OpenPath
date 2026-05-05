import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

import {
  getAgentArtifactRoots,
  getChromiumManagedMetadataFile,
  getFirefoxReleaseMetadataFile,
  getFirefoxReleaseXpiFile,
  type WindowsAgentFileEntry,
} from './server-asset-roots.js';

const WINDOWS_AGENT_DIRECTORIES = ['lib', 'scripts'] as const;
const WINDOWS_AGENT_RUNTIME_ROOT_FILES = ['OpenPath.ps1', 'Rotate-Token.ps1'] as const;
const WINDOWS_AGENT_BOOTSTRAP_ROOT_FILES = [
  'Install-OpenPath.ps1',
  'Uninstall-OpenPath.ps1',
  'OpenPath.ps1',
  'Rotate-Token.ps1',
] as const;
const FIREFOX_EXTENSION_DIRECTORIES = ['dist', 'popup', 'icons', 'blocked', 'native'] as const;

function listFilesRecursively(directoryPath: string): string[] {
  if (!fs.existsSync(directoryPath)) {
    return [];
  }

  const files: string[] = [];
  const entries = fs.readdirSync(directoryPath, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(directoryPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...listFilesRecursively(fullPath));
      continue;
    }

    if (entry.isFile()) {
      files.push(fullPath);
    }
  }

  return files;
}

function normalizeManifestRelativePath(relativePath: string): string | null {
  const normalizedPath = relativePath.replaceAll('\\', '/');
  if (!normalizedPath || normalizedPath.startsWith('..') || path.isAbsolute(normalizedPath)) {
    return null;
  }

  return normalizedPath;
}

export function buildWindowsAgentFileManifest(options?: {
  includeBootstrapFiles?: boolean;
}): WindowsAgentFileEntry[] {
  const roots = getAgentArtifactRoots();
  const rootFiles = options?.includeBootstrapFiles
    ? WINDOWS_AGENT_BOOTSTRAP_ROOT_FILES
    : WINDOWS_AGENT_RUNTIME_ROOT_FILES;
  const manifestSources = new Map<string, string>();
  const sharedFiles = [
    {
      relativePath: 'runtime/browser-policy-spec.json',
      absolutePath: path.join(roots.sharedRuntimeRoot, 'browser-policy-spec.json'),
    },
  ] as const;

  const addManifestFile = (relativePath: string, absolutePath: string): void => {
    if (!fs.existsSync(absolutePath)) {
      return;
    }

    const normalizedRelativePath = normalizeManifestRelativePath(relativePath);
    if (!normalizedRelativePath) {
      return;
    }

    manifestSources.set(normalizedRelativePath, path.resolve(absolutePath));
  };

  const addManifestDirectory = (
    sourceRoot: string,
    targetRoot: string,
    allowedExtensions?: RegExp
  ): void => {
    for (const absolutePath of listFilesRecursively(sourceRoot)) {
      if (allowedExtensions && !allowedExtensions.exec(absolutePath)) {
        continue;
      }

      const relativePath = path.relative(sourceRoot, absolutePath).replaceAll('\\', '/');
      if (!relativePath || relativePath.startsWith('..')) {
        continue;
      }

      addManifestFile(path.posix.join(targetRoot, relativePath), absolutePath);
    }
  };

  for (const fileName of rootFiles) {
    addManifestFile(fileName, path.join(roots.windowsAgentRoot, fileName));
  }

  for (const fileEntry of sharedFiles) {
    addManifestFile(fileEntry.relativePath, fileEntry.absolutePath);
  }

  for (const relativeDirectory of WINDOWS_AGENT_DIRECTORIES) {
    const absoluteDirectory = path.join(roots.windowsAgentRoot, relativeDirectory);
    addManifestDirectory(absoluteDirectory, relativeDirectory, /\.(ps1|psm1|cmd)$/i);
  }

  addManifestFile(
    'browser-extension/firefox/manifest.json',
    path.join(roots.firefoxExtensionRoot, 'manifest.json')
  );
  for (const relativeDirectory of FIREFOX_EXTENSION_DIRECTORIES) {
    addManifestDirectory(
      path.join(roots.firefoxExtensionRoot, relativeDirectory),
      path.posix.join('browser-extension/firefox', relativeDirectory)
    );
  }
  addManifestFile(
    'browser-extension/firefox-release/metadata.json',
    getFirefoxReleaseMetadataFile()
  );
  addManifestFile(
    'browser-extension/firefox-release/openpath-firefox-extension.xpi',
    getFirefoxReleaseXpiFile()
  );

  addManifestFile(
    'browser-extension/chromium-managed/metadata.json',
    getChromiumManagedMetadataFile()
  );

  return Array.from(manifestSources.entries())
    .map(([relativePath, absolutePath]) => {
      const fileBuffer = fs.readFileSync(absolutePath);
      return {
        relativePath,
        absolutePath,
        sha256: createHash('sha256').update(fileBuffer).digest('hex'),
        size: fileBuffer.length,
      };
    })
    .sort((left, right) => left.relativePath.localeCompare(right.relativePath));
}

function buildCrc32Table(): Uint32Array {
  const table = new Uint32Array(256);
  for (let index = 0; index < table.length; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) {
      value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    table[index] = value >>> 0;
  }
  return table;
}

const CRC32_TABLE = buildCrc32Table();

function crc32(buffer: Buffer): number {
  let value = 0xffffffff;
  for (const byte of buffer) {
    const tableValue = CRC32_TABLE[(value ^ byte) & 0xff];
    if (tableValue === undefined) {
      throw new Error('CRC32 table lookup failed');
    }
    value = tableValue ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) >>> 0;
}

function uint16(value: number): Buffer {
  const buffer = Buffer.alloc(2);
  buffer.writeUInt16LE(value);
  return buffer;
}

function uint32(value: number): Buffer {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value);
  return buffer;
}

function buildStoredZip(entries: { relativePath: string; body: Buffer }[]): Buffer {
  const localParts: Buffer[] = [];
  const centralParts: Buffer[] = [];
  let offset = 0;

  for (const entry of entries) {
    const name = Buffer.from(entry.relativePath, 'utf8');
    const checksum = crc32(entry.body);
    const localHeader = Buffer.concat([
      uint32(0x04034b50),
      uint16(20),
      uint16(0),
      uint16(0),
      uint16(0),
      uint16(0),
      uint32(checksum),
      uint32(entry.body.length),
      uint32(entry.body.length),
      uint16(name.length),
      uint16(0),
      name,
    ]);

    localParts.push(localHeader, entry.body);
    centralParts.push(
      Buffer.concat([
        uint32(0x02014b50),
        uint16(20),
        uint16(20),
        uint16(0),
        uint16(0),
        uint16(0),
        uint16(0),
        uint32(checksum),
        uint32(entry.body.length),
        uint32(entry.body.length),
        uint16(name.length),
        uint16(0),
        uint16(0),
        uint16(0),
        uint16(0),
        uint32(0),
        uint32(offset),
        name,
      ])
    );
    offset += localHeader.length + entry.body.length;
  }

  const centralDirectory = Buffer.concat(centralParts);
  return Buffer.concat([
    ...localParts,
    centralDirectory,
    Buffer.concat([
      uint32(0x06054b50),
      uint16(0),
      uint16(0),
      uint16(entries.length),
      uint16(entries.length),
      uint32(centralDirectory.length),
      uint32(offset),
      uint16(0),
    ]),
  ]);
}

export function buildWindowsBootstrapBundle(): {
  body: Buffer;
  fileCount: number;
  sha256: string;
  size: number;
} {
  const files = buildWindowsAgentFileManifest({ includeBootstrapFiles: true });
  const body = buildStoredZip(
    files.map((file) => ({
      relativePath: file.relativePath,
      body: fs.readFileSync(file.absolutePath),
    }))
  );

  return {
    body,
    fileCount: files.length,
    sha256: createHash('sha256').update(body).digest('hex'),
    size: body.length,
  };
}

export function resolveWindowsAgentManifestFile(
  relativePath: string,
  options?: { includeBootstrapFiles?: boolean }
): WindowsAgentFileEntry | null {
  const normalizedPath = normalizeManifestRelativePath(relativePath.trim());
  if (!normalizedPath) {
    return null;
  }

  return (
    buildWindowsAgentFileManifest(options).find((entry) => entry.relativePath === normalizedPath) ??
    null
  );
}
