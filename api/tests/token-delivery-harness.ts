import assert from 'node:assert';
import type { Server } from 'node:http';
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  bearerAuth,
  getAvailablePort,
  parseTRPC,
  resetDb,
  trpcMutate as _trpcMutate,
} from './test-utils.js';
import { closeConnection } from '../src/db/index.js';
import { clearLinuxAgentAptMetadataCache } from '../src/lib/server-assets.js';

const currentFilePath = fileURLToPath(import.meta.url);
const apiTestsDir = dirname(currentFilePath);
const apiRoot = resolve(apiTestsDir, '..');
const repoArtifactSources = {
  versionFile: resolve(apiRoot, '../VERSION'),
  windowsAgentRoot: resolve(apiRoot, '../windows'),
  sharedRuntimeRoot: resolve(apiRoot, '../runtime'),
  firefoxExtensionRoot: resolve(apiRoot, '../firefox-extension'),
};

export const tokenDeliveryArtifacts = {
  linuxAgentVersion: readFileSync(repoArtifactSources.versionFile, 'utf8').trim() || '0.0.0',
  tempRoot: '',
  windowsAgentRoot: '',
  sharedRuntimeRoot: '',
  windowsAgentVersionFile: '',
  linuxAgentBuildRoot: '',
  firefoxExtensionRoot: '',
};

export const linuxAgentPackageFileName = `openpath-dnsmasq_${tokenDeliveryArtifacts.linuxAgentVersion}-1_amd64.deb`;

function linuxAgentPackageFilePath(version = tokenDeliveryArtifacts.linuxAgentVersion): string {
  return resolve(
    tokenDeliveryArtifacts.linuxAgentBuildRoot,
    `openpath-dnsmasq_${version}-1_amd64.deb`
  );
}

function firefoxReleaseBuildRoot(): string {
  return resolve(tokenDeliveryArtifacts.firefoxExtensionRoot, 'build/firefox-release');
}

function firefoxReleaseMetadataPath(): string {
  return resolve(firefoxReleaseBuildRoot(), 'metadata.json');
}

function firefoxReleaseXpiPath(): string {
  return resolve(firefoxReleaseBuildRoot(), 'openpath-firefox-extension.xpi');
}

function chromiumManagedBuildRoot(): string {
  return resolve(tokenDeliveryArtifacts.firefoxExtensionRoot, 'build/chromium-managed');
}

function chromiumManagedMetadataPath(): string {
  return resolve(chromiumManagedBuildRoot(), 'metadata.json');
}

function chromiumManagedCrxPath(): string {
  return resolve(chromiumManagedBuildRoot(), 'openpath-chromium-extension.crx');
}

export interface TokenDeliveryHarness {
  apiUrl: string;
  adminEmail: string;
  adminPassword: string;
  registrationToken: string;
  close: () => Promise<void>;
  getEnrollmentToken: (classroomId: string) => Promise<string>;
  loginAdmin: () => Promise<string>;
  trpcMutate: (procedure: string, input: unknown) => Promise<Response>;
}

export function extractMachineToken(whitelistUrl: string): string {
  const match = /\/w\/([^/]+)\//.exec(whitelistUrl);
  assert.ok(match, `Expected tokenized whitelist URL, got: ${whitelistUrl}`);
  const token = match[1];
  assert.ok(token, `Expected machine token in URL: ${whitelistUrl}`);
  return token;
}

export function mockAptPackagesManifest(content: string, suite = 'stable'): () => void {
  const originalFetch = globalThis.fetch;
  clearLinuxAgentAptMetadataCache();

  globalThis.fetch = (async (
    input: string | URL | Request,
    init?: RequestInit
  ): Promise<Response> => {
    const url = input instanceof Request ? input.url : String(input);

    if (url.endsWith(`/dists/${suite}/main/binary-amd64/Packages`)) {
      return new Response(content, {
        status: 200,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      });
    }

    return originalFetch(input, init);
  }) as typeof fetch;

  return () => {
    globalThis.fetch = originalFetch;
    clearLinuxAgentAptMetadataCache();
  };
}

export function mockStableAptPackagesManifest(content: string): () => void {
  return mockAptPackagesManifest(content, 'stable');
}

function copyArtifactEntry(sourcePath: string, destinationPath: string): void {
  if (!existsSync(sourcePath)) {
    return;
  }

  cpSync(sourcePath, destinationPath, { recursive: true });
}

function prepareTokenDeliveryArtifactRoots(): void {
  tokenDeliveryArtifacts.tempRoot = mkdtempSync(join(tmpdir(), 'openpath-token-delivery-'));
  tokenDeliveryArtifacts.windowsAgentRoot = join(tokenDeliveryArtifacts.tempRoot, 'windows');
  tokenDeliveryArtifacts.sharedRuntimeRoot = join(tokenDeliveryArtifacts.tempRoot, 'runtime');
  tokenDeliveryArtifacts.windowsAgentVersionFile = join(tokenDeliveryArtifacts.tempRoot, 'VERSION');
  tokenDeliveryArtifacts.linuxAgentBuildRoot = join(tokenDeliveryArtifacts.tempRoot, 'build');
  tokenDeliveryArtifacts.firefoxExtensionRoot = join(
    tokenDeliveryArtifacts.tempRoot,
    'firefox-extension'
  );

  mkdirSync(tokenDeliveryArtifacts.tempRoot, { recursive: true });
  mkdirSync(tokenDeliveryArtifacts.linuxAgentBuildRoot, { recursive: true });
  mkdirSync(tokenDeliveryArtifacts.firefoxExtensionRoot, { recursive: true });

  copyArtifactEntry(repoArtifactSources.windowsAgentRoot, tokenDeliveryArtifacts.windowsAgentRoot);
  copyArtifactEntry(
    repoArtifactSources.sharedRuntimeRoot,
    tokenDeliveryArtifacts.sharedRuntimeRoot
  );
  writeFileSync(
    tokenDeliveryArtifacts.windowsAgentVersionFile,
    readFileSync(repoArtifactSources.versionFile, 'utf8')
  );

  for (const entry of ['manifest.json', 'dist', 'popup', 'icons', 'blocked', 'native'] as const) {
    copyArtifactEntry(
      resolve(repoArtifactSources.firefoxExtensionRoot, entry),
      resolve(tokenDeliveryArtifacts.firefoxExtensionRoot, entry)
    );
  }
}

export function cleanTokenDeliveryArtifacts(): void {
  if (tokenDeliveryArtifacts.tempRoot) {
    rmSync(tokenDeliveryArtifacts.tempRoot, { recursive: true, force: true });
  }
}

export function writeLinuxAgentPackage(
  content: string,
  version = tokenDeliveryArtifacts.linuxAgentVersion
): {
  packageFileName: string;
  packageFilePath: string;
} {
  const packageFileName = `openpath-dnsmasq_${version}-1_amd64.deb`;
  const packageFilePath = linuxAgentPackageFilePath(version);
  mkdirSync(tokenDeliveryArtifacts.linuxAgentBuildRoot, { recursive: true });
  writeFileSync(packageFilePath, content);
  return { packageFileName, packageFilePath };
}

export function writeFirefoxReleaseArtifacts(version: string, payload: string): void {
  mkdirSync(firefoxReleaseBuildRoot(), { recursive: true });
  writeFileSync(
    firefoxReleaseMetadataPath(),
    JSON.stringify({
      extensionId: 'openpath-block-monitor@openpath',
      version,
    })
  );
  writeFileSync(firefoxReleaseXpiPath(), payload);
}

export function writeChromiumManagedArtifacts(version: string, payload: string): void {
  mkdirSync(chromiumManagedBuildRoot(), { recursive: true });
  writeFileSync(
    chromiumManagedMetadataPath(),
    JSON.stringify({
      extensionId: 'abcdefghijklmnopabcdefghijklmnop',
      version,
    })
  );
  writeFileSync(chromiumManagedCrxPath(), payload);
}

export async function startTokenDeliveryHarness(): Promise<TokenDeliveryHarness> {
  await resetDb();
  prepareTokenDeliveryArtifactRoots();

  const port = await getAvailablePort();
  const apiUrl = `http://localhost:${String(port)}`;
  const previousPort = process.env.PORT;
  const previousSharedSecret = process.env.SHARED_SECRET;
  const previousArtifactEnv = new Map<string, string | undefined>(
    [
      'OPENPATH_WINDOWS_AGENT_ROOT',
      'OPENPATH_SHARED_RUNTIME_ROOT',
      'OPENPATH_AGENT_VERSION_FILE',
      'OPENPATH_LINUX_AGENT_BUILD_ROOT',
      'OPENPATH_FIREFOX_EXTENSION_ROOT',
      'OPENPATH_FIREFOX_RELEASE_ROOT',
      'OPENPATH_CHROMIUM_MANAGED_ROOT',
    ].map((key) => [key, process.env[key]])
  );

  process.env.PORT = String(port);
  process.env.SHARED_SECRET = 'test-shared-secret';
  process.env.OPENPATH_WINDOWS_AGENT_ROOT = tokenDeliveryArtifacts.windowsAgentRoot;
  process.env.OPENPATH_SHARED_RUNTIME_ROOT = tokenDeliveryArtifacts.sharedRuntimeRoot;
  process.env.OPENPATH_AGENT_VERSION_FILE = tokenDeliveryArtifacts.windowsAgentVersionFile;
  process.env.OPENPATH_LINUX_AGENT_BUILD_ROOT = tokenDeliveryArtifacts.linuxAgentBuildRoot;
  process.env.OPENPATH_FIREFOX_EXTENSION_ROOT = tokenDeliveryArtifacts.firefoxExtensionRoot;
  process.env.OPENPATH_FIREFOX_RELEASE_ROOT = firefoxReleaseBuildRoot();
  process.env.OPENPATH_CHROMIUM_MANAGED_ROOT = chromiumManagedBuildRoot();

  const { app } = await import('../src/server.js');
  const server = await new Promise<Server>((resolve) => {
    const listener = app.listen(port, () => {
      console.log(`Token delivery test server started on port ${String(port)}`);
      resolve(listener);
    });
  });

  const trpcMutate = (procedure: string, input: unknown): Promise<Response> =>
    _trpcMutate(apiUrl, procedure, input);

  const adminEmail = `token-admin-${String(Date.now())}@example.com`;
  const adminPassword = 'SecurePassword123!';
  const createAdminResponse = await trpcMutate('setup.createFirstAdmin', {
    email: adminEmail,
    name: 'Token Test Admin',
    password: adminPassword,
  });
  const createAdminParsed = await parseTRPC(createAdminResponse);
  const createAdminData = createAdminParsed.data as { registrationToken?: string };
  assert.ok(createAdminData.registrationToken);

  const loginAdmin = async (): Promise<string> => {
    const loginResponse = await trpcMutate('auth.login', {
      email: adminEmail,
      password: adminPassword,
    });
    assert.strictEqual(loginResponse.status, 200);

    const loginParsed = await parseTRPC(loginResponse);
    const loginData = loginParsed.data as { accessToken?: string };
    assert.ok(loginData.accessToken);
    return loginData.accessToken;
  };

  const getEnrollmentToken = async (classroomId: string): Promise<string> => {
    const accessToken = await loginAdmin();
    const ticketResponse = await fetch(`${apiUrl}/api/enroll/${classroomId}/ticket`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    assert.strictEqual(ticketResponse.status, 200);

    const ticketData = (await ticketResponse.json()) as {
      success: boolean;
      enrollmentToken?: string;
    };
    assert.strictEqual(ticketData.success, true);
    assert.ok(ticketData.enrollmentToken);
    return ticketData.enrollmentToken;
  };

  const restoreEnv = (): void => {
    if (previousPort === undefined) {
      delete process.env.PORT;
    } else {
      process.env.PORT = previousPort;
    }

    if (previousSharedSecret === undefined) {
      delete process.env.SHARED_SECRET;
    } else {
      process.env.SHARED_SECRET = previousSharedSecret;
    }

    for (const [key, value] of previousArtifactEnv.entries()) {
      if (value === undefined) {
        Reflect.deleteProperty(process.env, key);
      } else {
        process.env[key] = value;
      }
    }
  };

  return {
    apiUrl,
    adminEmail,
    adminPassword,
    registrationToken: createAdminData.registrationToken,
    trpcMutate,
    loginAdmin,
    getEnrollmentToken,
    close: async (): Promise<void> => {
      await resetDb();

      if ('closeAllConnections' in server && typeof server.closeAllConnections === 'function') {
        server.closeAllConnections();
      }

      await new Promise<void>((resolve) => {
        server.close(() => {
          console.log('Token delivery test server closed');
          resolve();
        });
      });

      restoreEnv();
      cleanTokenDeliveryArtifacts();
      await closeConnection();
    },
  };
}

export async function createBlockedSubdomainRule(options: {
  apiUrl: string;
  accessToken: string;
  groupId: string;
  value: string;
  comment: string;
}): Promise<void> {
  const response = await _trpcMutate(
    options.apiUrl,
    'groups.createRule',
    {
      groupId: options.groupId,
      type: 'blocked_subdomain',
      value: options.value,
      comment: options.comment,
    },
    bearerAuth(options.accessToken)
  );
  assert.strictEqual(response.status, 200);

  const parsed = await parseTRPC(response);
  const data = parsed.data as { id?: string };
  assert.ok(data.id);
}
