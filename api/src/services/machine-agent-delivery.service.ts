import fs from 'node:fs';
import path from 'node:path';

import * as classroomStorage from '../lib/classroom-storage.js';
import { config } from '../config.js';
import {
  buildLinuxAgentPackageManifest,
  buildLinuxAgentPackageManifestFromApt,
  downloadLinuxAgentPackageFromApt,
  buildWindowsBootstrapBundle,
  buildWindowsAgentFileManifest,
  readServerVersion,
  resolveLinuxAgentPackagePath,
  resolveWindowsAgentManifestFile,
} from '../lib/server-assets.js';

export type MachineAgentDeliveryError =
  | { code: 'BAD_REQUEST'; message: string }
  | { code: 'NOT_FOUND'; message: string }
  | { code: 'UNAVAILABLE'; message: string };

export type MachineAgentDeliveryResult<T> =
  | { ok: true; data: T }
  | { ok: false; error: MachineAgentDeliveryError };

interface ManifestFileDescriptor {
  path: string;
  sha256: string;
  size: number;
}

interface ManifestBundleDescriptor {
  fileCount: number;
  path: string;
  sha256: string;
  size: number;
}

export interface WindowsBootstrapManifestOutput {
  bundle: ManifestBundleDescriptor;
  classroomId: string;
  files: ManifestFileDescriptor[];
  generatedAt: string;
  version: string;
}

export interface WindowsAgentManifestOutput {
  files: ManifestFileDescriptor[];
  generatedAt: string;
  version: string;
}

export interface LinuxAgentManifestOutput {
  bridgeVersions: string[];
  downloadPath: string;
  generatedAt: string;
  minDirectUpgradeVersion: string;
  minSupportedVersion: string;
  packageFileName: string;
  sha256: string;
  size: number;
  version: string;
}

export interface TextFileOutput {
  body: Buffer;
}

export interface BinaryFileOutput {
  body: Buffer;
}

export interface LinuxAgentPackageOutput {
  body: Buffer;
  fileName: string;
}

function toManifestFiles(
  files: ReturnType<typeof buildWindowsAgentFileManifest>
): ManifestFileDescriptor[] {
  return files.map((file) => ({
    path: file.relativePath,
    sha256: file.sha256,
    size: file.size,
  }));
}

async function touchMachine(hostname: string): Promise<void> {
  await classroomStorage.updateMachineLastSeen(hostname);
}

export function getWindowsBootstrapManifest(
  classroomId: string
): MachineAgentDeliveryResult<WindowsBootstrapManifestOutput> {
  const files = buildWindowsAgentFileManifest({ includeBootstrapFiles: true });
  if (files.length === 0) {
    return {
      ok: false,
      error: { code: 'UNAVAILABLE', message: 'Windows bootstrap package unavailable' },
    };
  }
  const bundle = buildWindowsBootstrapBundle();

  return {
    ok: true,
    data: {
      bundle: {
        path: '/api/agent/windows/bootstrap/bundle.zip',
        fileCount: bundle.fileCount,
        sha256: bundle.sha256,
        size: bundle.size,
      },
      classroomId,
      version: readServerVersion(),
      generatedAt: new Date().toISOString(),
      files: toManifestFiles(files),
    },
  };
}

export function getWindowsBootstrapBundle(): MachineAgentDeliveryResult<BinaryFileOutput> {
  const bundle = buildWindowsBootstrapBundle();
  if (bundle.fileCount === 0) {
    return {
      ok: false,
      error: { code: 'UNAVAILABLE', message: 'Windows bootstrap package unavailable' },
    };
  }

  return {
    ok: true,
    data: {
      body: bundle.body,
    },
  };
}

export function getWindowsBootstrapFile(
  requestedPath: string
): MachineAgentDeliveryResult<TextFileOutput> {
  if (!requestedPath) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'file path required' },
    };
  }

  const file = resolveWindowsAgentManifestFile(requestedPath, {
    includeBootstrapFiles: true,
  });
  if (!file) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'File not found in bootstrap package' },
    };
  }

  return {
    ok: true,
    data: {
      body: fs.readFileSync(file.absolutePath),
    },
  };
}

export async function getWindowsAgentManifest(
  machineHostname: string
): Promise<MachineAgentDeliveryResult<WindowsAgentManifestOutput>> {
  const files = buildWindowsAgentFileManifest();
  if (files.length === 0) {
    return {
      ok: false,
      error: { code: 'UNAVAILABLE', message: 'Windows agent package unavailable' },
    };
  }

  await touchMachine(machineHostname);

  return {
    ok: true,
    data: {
      version: readServerVersion(),
      generatedAt: new Date().toISOString(),
      files: toManifestFiles(files),
    },
  };
}

export async function getWindowsAgentFile(
  machineHostname: string,
  requestedPath: string
): Promise<MachineAgentDeliveryResult<TextFileOutput>> {
  if (!requestedPath) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'file path required' },
    };
  }

  const file = resolveWindowsAgentManifestFile(requestedPath);
  if (!file) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'File not found in agent package' },
    };
  }

  await touchMachine(machineHostname);

  return {
    ok: true,
    data: {
      body: fs.readFileSync(file.absolutePath),
    },
  };
}

export async function getLinuxAgentManifest(
  machineHostname: string
): Promise<MachineAgentDeliveryResult<LinuxAgentManifestOutput>> {
  let packageEntry = buildLinuxAgentPackageManifest();
  if (!packageEntry && config.aptRepoUrl) {
    packageEntry = await buildLinuxAgentPackageManifestFromApt(config.aptRepoUrl);
  }

  if (!packageEntry) {
    return {
      ok: false,
      error: { code: 'UNAVAILABLE', message: 'Linux agent package unavailable' },
    };
  }

  await touchMachine(machineHostname);

  return {
    ok: true,
    data: {
      version: packageEntry.version,
      generatedAt: new Date().toISOString(),
      packageFileName: packageEntry.packageFileName,
      sha256: packageEntry.sha256,
      size: packageEntry.size,
      minSupportedVersion: packageEntry.minSupportedVersion,
      minDirectUpgradeVersion: packageEntry.minDirectUpgradeVersion,
      bridgeVersions: packageEntry.bridgeVersions,
      downloadPath: packageEntry.downloadPath,
    },
  };
}

export async function getLinuxAgentPackage(
  machineHostname: string,
  requestedVersion: string
): Promise<MachineAgentDeliveryResult<LinuxAgentPackageOutput>> {
  if (!requestedVersion) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'version path parameter required' },
    };
  }

  const absolutePath = resolveLinuxAgentPackagePath(requestedVersion);
  await touchMachine(machineHostname);

  if (!absolutePath) {
    if (config.aptRepoUrl) {
      const packageEntry = await downloadLinuxAgentPackageFromApt(
        config.aptRepoUrl,
        requestedVersion
      );
      if (packageEntry) {
        return {
          ok: true,
          data: packageEntry,
        };
      }
    }

    return {
      ok: false,
      error: { code: 'UNAVAILABLE', message: 'Linux agent package unavailable' },
    };
  }

  return {
    ok: true,
    data: {
      body: fs.readFileSync(absolutePath),
      fileName: path.basename(absolutePath),
    },
  };
}

export default {
  getLinuxAgentManifest,
  getLinuxAgentPackage,
  getWindowsAgentFile,
  getWindowsAgentManifest,
  getWindowsBootstrapBundle,
  getWindowsBootstrapFile,
  getWindowsBootstrapManifest,
};
