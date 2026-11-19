/**
 * Canary agent releases: publication, retirement, ring assignment and reading
 * the file set stored in PostgreSQL.
 *
 * A release carries a complete Windows agent file set. Its build fingerprint is
 * SHA-256 over the sorted `path<TAB>sha256` lines, the same value the agent
 * pins for every file request. Only one release per ring is active; publishing
 * retires the previous one and retiring returns its machines to stable.
 *
 * A publish is rejected unless the declared hashes match the uploaded bytes and
 * the signature verifies against the public key the agents ship. An active
 * release that every agent would refuse would otherwise keep canaries on
 * neither the canary build nor stable.
 */
import { createHash, type KeyObject } from 'node:crypto';

import { and, asc, desc, eq } from 'drizzle-orm';

import { agentReleaseFiles, agentReleases, db, machines, withTransaction } from '../db/index.js';
import {
  readAgentReleasePublicKey,
  verifyAgentReleaseSignature,
} from '../lib/agent-release-signature.js';

export type AgentRing = 'stable' | 'canary';

export interface AgentReleaseManifestFile {
  path: string;
  sha256: string;
  size: number;
}

export interface ActiveAgentRelease {
  build: string;
  ring: 'canary';
  sourceSha: string;
  signature: string;
  files: AgentReleaseManifestFile[];
}

export interface PublishedAgentRelease {
  build: string;
  ring: 'canary';
  sourceSha: string;
  fileCount: number;
  publishedAt: string | null;
}

export interface PublishAgentReleaseFileInput {
  path: string;
  sha256: string;
  contentBase64: string;
}

export interface PublishAgentReleaseInput {
  build?: string | undefined;
  sourceSha: string;
  signature: string;
  files: PublishAgentReleaseFileInput[];
}

export interface AgentReleaseFileRecord {
  content: Buffer;
  sha256: string;
  size: number;
}

export interface AgentReleaseRepository {
  getActiveRelease(ring: AgentRing): Promise<ActiveAgentRelease | null>;
  getMachineRing(hostname: string): Promise<AgentRing | null>;
  listMachineHostnamesByRing(ring: AgentRing): Promise<string[]>;
  getReleaseFile(build: string, path: string): Promise<AgentReleaseFileRecord | null>;
  publishRelease(
    release: Omit<ActiveAgentRelease, 'files' | 'ring'> & { ring: AgentRing },
    files: (AgentReleaseManifestFile & { content: Buffer })[]
  ): Promise<void>;
  retireRelease(build: string): Promise<boolean>;
  setMachineRing(hostname: string, ring: AgentRing): Promise<boolean>;
}

export type AgentReleaseErrorCode = 'BAD_REQUEST' | 'CONFLICT' | 'NOT_FOUND' | 'UNAVAILABLE';

export interface AgentReleaseError {
  code: AgentReleaseErrorCode;
  message: string;
}

export type AgentReleaseResult<T> = { ok: true; data: T } | { ok: false; error: AgentReleaseError };

const SHA256_PATTERN = /^[0-9a-f]{64}$/i;
const SOURCE_SHA_PATTERN = /^[0-9a-f]{7,64}$/i;

function normalizeReleasePath(value: string): string | null {
  const normalized = value.trim().replaceAll('\\', '/');
  if (!normalized || normalized.startsWith('..') || normalized.startsWith('/')) {
    return null;
  }
  if (normalized.split('/').some((segment) => segment === '..' || segment === '')) {
    return null;
  }
  return normalized;
}

/** SHA-256 over the sorted `path<TAB>sha256` lines, the agent's build fingerprint. */
export function computeAgentBuild(files: readonly { path: string; sha256: string }[]): string {
  return createHash('sha256')
    .update(files.map((file) => `${file.path}\t${file.sha256}\n`).join(''))
    .digest('hex');
}

export function validateAgentReleaseInput(input: PublishAgentReleaseInput):
  | {
      ok: true;
      build: string;
      files: (AgentReleaseManifestFile & { content: Buffer })[];
    }
  | { ok: false; error: AgentReleaseError } {
  const sourceSha = input.sourceSha.trim();
  if (!SOURCE_SHA_PATTERN.test(sourceSha)) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'sourceSha must be a 7-64 character hex commit' },
    };
  }

  const signature = input.signature.trim();
  if (!signature) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'signature is required for a canary release' },
    };
  }

  if (!Array.isArray(input.files) || input.files.length === 0) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'files must contain the complete agent file set' },
    };
  }

  const seen = new Set<string>();
  const files: (AgentReleaseManifestFile & { content: Buffer })[] = [];
  for (const file of input.files) {
    const path = normalizeReleasePath(file.path);
    if (!path) {
      return {
        ok: false,
        error: { code: 'BAD_REQUEST', message: `unsafe release path: ${file.path}` },
      };
    }
    if (seen.has(path)) {
      return {
        ok: false,
        error: { code: 'BAD_REQUEST', message: `duplicate release path: ${path}` },
      };
    }
    seen.add(path);

    const sha256 = file.sha256.trim().toLowerCase();
    if (!SHA256_PATTERN.test(sha256)) {
      return {
        ok: false,
        error: { code: 'BAD_REQUEST', message: `invalid sha256 for ${path}` },
      };
    }

    let content: Buffer;
    try {
      content = Buffer.from(file.contentBase64, 'base64');
    } catch {
      return {
        ok: false,
        error: { code: 'BAD_REQUEST', message: `invalid content for ${path}` },
      };
    }
    if (content.length === 0) {
      return {
        ok: false,
        error: { code: 'BAD_REQUEST', message: `empty content for ${path}` },
      };
    }

    const actual = createHash('sha256').update(content).digest('hex');
    if (actual !== sha256) {
      return {
        ok: false,
        error: { code: 'BAD_REQUEST', message: `sha256 mismatch at publish for ${path}` },
      };
    }

    files.push({ path, sha256, size: content.length, content });
  }

  files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const build = computeAgentBuild(files);
  const declaredBuild = input.build?.trim().toLowerCase() ?? '';
  if (declaredBuild && !SHA256_PATTERN.test(declaredBuild)) {
    return { ok: false, error: { code: 'BAD_REQUEST', message: 'invalid build fingerprint' } };
  }
  if (declaredBuild && declaredBuild !== build) {
    return {
      ok: false,
      error: { code: 'BAD_REQUEST', message: 'declared build does not match the file set' },
    };
  }

  return { ok: true, build, files };
}

export const agentReleaseRepository: AgentReleaseRepository = {
  async getActiveRelease(ring) {
    const [release] = await db
      .select()
      .from(agentReleases)
      .where(and(eq(agentReleases.ring, ring), eq(agentReleases.status, 'active')))
      .orderBy(desc(agentReleases.publishedAt))
      .limit(1);
    if (!release) {
      return null;
    }

    const files = await db
      .select({
        path: agentReleaseFiles.path,
        sha256: agentReleaseFiles.sha256,
        size: agentReleaseFiles.size,
      })
      .from(agentReleaseFiles)
      .where(eq(agentReleaseFiles.build, release.build))
      .orderBy(asc(agentReleaseFiles.path));

    return {
      build: release.build,
      ring: 'canary',
      sourceSha: release.sourceSha,
      signature: release.signature,
      files,
    };
  },

  async getMachineRing(hostname) {
    const [machine] = await db
      .select({ agentRing: machines.agentRing })
      .from(machines)
      .where(eq(machines.hostname, hostname.trim().toLowerCase()))
      .limit(1);
    return (machine?.agentRing as AgentRing | undefined) ?? null;
  },

  async listMachineHostnamesByRing(ring) {
    const rows = await db
      .select({ hostname: machines.hostname })
      .from(machines)
      .where(eq(machines.agentRing, ring));
    return rows.map((row) => row.hostname);
  },

  async getReleaseFile(build, path) {
    const [file] = await db
      .select({
        content: agentReleaseFiles.content,
        sha256: agentReleaseFiles.sha256,
        size: agentReleaseFiles.size,
      })
      .from(agentReleaseFiles)
      .where(and(eq(agentReleaseFiles.build, build), eq(agentReleaseFiles.path, path)))
      .limit(1);
    return file ?? null;
  },

  async publishRelease(release, files) {
    await withTransaction(async (tx) => {
      const now = new Date();
      await tx
        .update(agentReleases)
        .set({ status: 'retired', retiredAt: now })
        .where(and(eq(agentReleases.ring, release.ring), eq(agentReleases.status, 'active')));
      await tx.delete(agentReleases).where(eq(agentReleases.build, release.build));
      await tx.insert(agentReleases).values({
        build: release.build,
        ring: release.ring,
        sourceSha: release.sourceSha,
        signature: release.signature,
        status: 'active',
        fileCount: files.length,
        publishedAt: now,
      });
      for (let index = 0; index < files.length; index += 25) {
        const chunk = files.slice(index, index + 25);
        await tx.insert(agentReleaseFiles).values(
          chunk.map((file) => ({
            build: release.build,
            path: file.path,
            sha256: file.sha256,
            size: file.size,
            content: file.content,
          }))
        );
      }
    });
  },

  async retireRelease(build) {
    const retired = await db
      .update(agentReleases)
      .set({ status: 'retired', retiredAt: new Date() })
      .where(and(eq(agentReleases.build, build), eq(agentReleases.status, 'active')))
      .returning({ build: agentReleases.build });
    return retired.length > 0;
  },

  async setMachineRing(hostname, ring) {
    const updated = await db
      .update(machines)
      .set({ agentRing: ring, updatedAt: new Date() })
      .where(eq(machines.hostname, hostname.trim().toLowerCase()))
      .returning({ hostname: machines.hostname });
    return updated.length > 0;
  },
};

export async function publishAgentRelease(
  input: PublishAgentReleaseInput,
  repository: AgentReleaseRepository = agentReleaseRepository,
  options: { publicKey?: KeyObject | null } = {}
): Promise<AgentReleaseResult<PublishedAgentRelease>> {
  const validated = validateAgentReleaseInput(input);
  if (!validated.ok) {
    return validated;
  }

  const publicKey =
    options.publicKey === undefined ? readAgentReleasePublicKey() : options.publicKey;
  if (!publicKey) {
    return {
      ok: false,
      error: { code: 'UNAVAILABLE', message: 'the agent release public key is unavailable' },
    };
  }
  const signatureValid = verifyAgentReleaseSignature(
    {
      ring: 'canary',
      build: validated.build,
      sourceSha: input.sourceSha.trim(),
      files: validated.files,
      signature: input.signature,
    },
    publicKey
  );
  if (!signatureValid) {
    return {
      ok: false,
      error: {
        code: 'BAD_REQUEST',
        message: 'signature does not verify against the agent release public key',
      },
    };
  }

  await repository.publishRelease(
    {
      build: validated.build,
      ring: 'canary',
      sourceSha: input.sourceSha.trim(),
      signature: input.signature.trim(),
    },
    validated.files
  );

  return {
    ok: true,
    data: {
      build: validated.build,
      ring: 'canary',
      sourceSha: input.sourceSha.trim(),
      fileCount: validated.files.length,
      publishedAt: new Date().toISOString(),
    },
  };
}

export async function retireAgentRelease(
  build: string,
  repository: AgentReleaseRepository = agentReleaseRepository
): Promise<AgentReleaseResult<{ build: string; retired: true }>> {
  const normalizedBuild = build.trim().toLowerCase();
  if (!SHA256_PATTERN.test(normalizedBuild)) {
    return { ok: false, error: { code: 'BAD_REQUEST', message: 'invalid build fingerprint' } };
  }

  const retired = await repository.retireRelease(normalizedBuild);
  if (!retired) {
    return {
      ok: false,
      error: { code: 'NOT_FOUND', message: 'no active release with that build' },
    };
  }

  return { ok: true, data: { build: normalizedBuild, retired: true } };
}

export async function setMachineAgentRing(
  hostname: string,
  ring: string,
  repository: AgentReleaseRepository = agentReleaseRepository
): Promise<AgentReleaseResult<{ hostname: string; ring: AgentRing }>> {
  const normalizedHostname = hostname.trim().toLowerCase();
  if (!normalizedHostname) {
    return { ok: false, error: { code: 'BAD_REQUEST', message: 'hostname is required' } };
  }
  if (ring !== 'stable' && ring !== 'canary') {
    return { ok: false, error: { code: 'BAD_REQUEST', message: 'ring must be stable or canary' } };
  }

  const updated = await repository.setMachineRing(normalizedHostname, ring);
  if (!updated) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'machine not found' } };
  }

  return { ok: true, data: { hostname: normalizedHostname, ring: ring as AgentRing } };
}

export async function resolveAgentReleaseForMachine(params: {
  hostname: string;
  capabilityHeader?: string | undefined;
  repository?: AgentReleaseRepository | undefined;
}): Promise<
  | { ring: 'stable' }
  | {
      ring: 'canary';
      release: ActiveAgentRelease;
    }
> {
  const repository = params.repository ?? agentReleaseRepository;
  const capabilities = (params.capabilityHeader ?? '')
    .split(',')
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
  if (!capabilities.includes('signed-release-v1')) {
    return { ring: 'stable' };
  }

  const machineRing = (await repository.getMachineRing(params.hostname)) ?? 'stable';
  if (machineRing !== 'canary') {
    return { ring: 'stable' };
  }

  const release = await repository.getActiveRelease('canary');
  if (!release) {
    return { ring: 'stable' };
  }

  return { ring: 'canary', release };
}

/** Hostnames of the machines assigned to a ring, lower-cased. */
export async function listAgentRingHostnames(
  ring: AgentRing,
  repository: AgentReleaseRepository = agentReleaseRepository
): Promise<string[]> {
  const hostnames = await repository.listMachineHostnamesByRing(ring);
  return hostnames.map((hostname) => hostname.trim().toLowerCase()).filter(Boolean);
}

export async function getActiveAgentRelease(
  ring: AgentRing = 'canary',
  repository: AgentReleaseRepository = agentReleaseRepository
): Promise<ActiveAgentRelease | null> {
  return repository.getActiveRelease(ring);
}

export async function getAgentReleaseFile(
  build: string,
  path: string,
  repository: AgentReleaseRepository = agentReleaseRepository
): Promise<AgentReleaseResult<AgentReleaseFileRecord>> {
  const record = await repository.getReleaseFile(build.trim().toLowerCase(), path);
  if (!record) {
    return { ok: false, error: { code: 'NOT_FOUND', message: 'file not found in the release' } };
  }
  return { ok: true, data: record };
}
