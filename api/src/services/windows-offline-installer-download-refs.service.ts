import { createHash, randomBytes } from 'node:crypto';
import { existsSync, readdirSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';

import {
  and,
  eq,
  gt,
  gte,
  inArray,
  isNotNull,
  isNull,
  lt,
  lte,
  or,
  sql,
  type SQL,
} from 'drizzle-orm';

import { db } from '../db/index.js';
import * as schema from '../db/schema.js';
import { logger } from '../lib/logger.js';

type WindowsOfflineDownloadRef = typeof schema.windowsOfflineDownloadRefs.$inferSelect;

export interface DownloadRefRecord {
  id: string;
  classroomId: string;
  classroomName: string;
  createdBy: string | null;
  referenceHash: string;
  artifactFileName: string;
  artifactSha256: string;
  artifactSize: number;
  maxAttempts: number;
  usedAttempts: number;
  activeTransfers: number;
  expiresAt: Date;
  consumedAt: Date | null;
}

export type DownloadReferenceErrorCode = 'INVALID' | 'EXPIRED' | 'EXHAUSTED' | 'CONSUMED';

export class DownloadReferenceError extends Error {
  readonly code: DownloadReferenceErrorCode;

  constructor(code: DownloadReferenceErrorCode, message: string) {
    super(message);
    this.code = code;
    this.name = 'DownloadReferenceError';
  }
}

export interface RefsRepoDeps {
  db?: typeof db;
  now?: () => Date;
  randomToken?: (bytes: number) => string;
}

export interface MintWindowsOfflineDownloadReferenceInput {
  classroomId: string;
  classroomName: string;
  createdBy?: string | null;
  artifactFileName: string;
  artifactSha256: string;
  artifactSize: number;
  ttlMinutes: number;
  maxAttempts: number;
}

const RAW_REFERENCE_PATTERN = /^[A-Za-z0-9_-]{43}$/u;
const REFERENCE_HASH_PATTERN = /^[0-9a-f]{64}$/u;
const ARTIFACT_FILE_PATTERN = /^[0-9a-f]{32}\.exe$/u;
const ORPHAN_ARTIFACT_GRACE_MS = 5 * 60 * 1000;

export function isValidWindowsOfflineDownloadReference(value: string): boolean {
  return RAW_REFERENCE_PATTERN.test(value);
}

export function hashDownloadReference(rawToken: string): string {
  return createHash('sha256').update(rawToken).digest('hex');
}

export function artifactFileNameFromReferenceHash(referenceHash: string): string {
  if (!REFERENCE_HASH_PATTERN.test(referenceHash)) {
    throw new Error('Invalid Windows offline installer reference hash');
  }
  return `${referenceHash.slice(0, 32)}.exe`;
}

function defaultRandomToken(bytes: number): string {
  return randomBytes(bytes).toString('base64url');
}

function toRecord(row: WindowsOfflineDownloadRef): DownloadRefRecord {
  return {
    id: row.id,
    classroomId: row.classroomId,
    classroomName: row.classroomName,
    createdBy: row.createdBy,
    referenceHash: row.referenceHash,
    artifactFileName: row.artifactFileName,
    artifactSha256: row.artifactSha256,
    artifactSize: row.artifactSize,
    maxAttempts: row.maxAttempts,
    usedAttempts: row.usedAttempts,
    activeTransfers: row.activeTransfers,
    expiresAt: row.expiresAt,
    consumedAt: row.consumedAt,
  };
}

function classifyRow(row: DownloadOfflineInstallerRow | undefined, now: Date): never {
  if (!row) {
    throw new DownloadReferenceError('INVALID', 'Unknown download reference');
  }
  if (row.consumedAt) {
    throw new DownloadReferenceError('CONSUMED', 'Download reference already consumed');
  }
  if (row.expiresAt.getTime() <= now.getTime()) {
    throw new DownloadReferenceError('EXPIRED', 'Download reference expired');
  }
  if (row.usedAttempts >= row.maxAttempts) {
    throw new DownloadReferenceError('EXHAUSTED', 'Download attempt limit reached');
  }
  throw new DownloadReferenceError('EXPIRED', 'Download reference is no longer usable');
}

type DownloadOfflineInstallerRow = WindowsOfflineDownloadRef;

export interface WindowsOfflineDownloadRefsService {
  mintReference(
    input: MintWindowsOfflineDownloadReferenceInput
  ): Promise<{ ref: DownloadRefRecord; rawToken: string }>;
  consumeAttempt(rawToken: string): Promise<DownloadRefRecord>;
  releaseAttempt(rawToken: string): Promise<void>;
  /** Returns true when this completion released the final active transfer. */
  markConsumed(rawToken: string): Promise<boolean>;
  invalidateReference(rawToken: string): Promise<void>;
  cleanupExpired(artifactsDir: string): Promise<number>;
  now(): Date;
}

export function createWindowsOfflineDownloadRefsService(
  deps: RefsRepoDeps = {}
): WindowsOfflineDownloadRefsService {
  const database = deps.db ?? db;
  const now = deps.now ?? ((): Date => new Date());
  const randomToken = deps.randomToken ?? defaultRandomToken;

  async function mintReference(
    input: MintWindowsOfflineDownloadReferenceInput
  ): Promise<{ ref: DownloadRefRecord; rawToken: string }> {
    const rawToken = randomToken(32);
    if (!isValidWindowsOfflineDownloadReference(rawToken)) {
      throw new Error('Reference generator returned an invalid opaque reference');
    }

    const referenceHash = hashDownloadReference(rawToken);
    const expiresAt = new Date(now().getTime() + input.ttlMinutes * 60_000);
    const [row] = await database
      .insert(schema.windowsOfflineDownloadRefs)
      .values({
        classroomId: input.classroomId,
        classroomName: input.classroomName,
        createdBy: input.createdBy ?? null,
        referenceHash,
        artifactFileName: input.artifactFileName,
        artifactSha256: input.artifactSha256,
        artifactSize: input.artifactSize,
        maxAttempts: input.maxAttempts,
        expiresAt,
      })
      .returning();

    if (!row) {
      throw new Error('Download reference could not be persisted');
    }

    return { ref: toRecord(row), rawToken };
  }

  /**
   * Atomically reserves one attempt and marks one transfer active. Concurrent
   * transfers are allowed while the bounded retry budget remains; a completed
   * response calls markConsumed and an aborted transfer calls releaseAttempt.
   */
  async function consumeAttempt(rawToken: string): Promise<DownloadRefRecord> {
    if (!isValidWindowsOfflineDownloadReference(rawToken)) {
      throw new DownloadReferenceError('INVALID', 'Invalid download reference');
    }

    const referenceHash = hashDownloadReference(rawToken);
    const [row] = await database
      .select()
      .from(schema.windowsOfflineDownloadRefs)
      .where(eq(schema.windowsOfflineDownloadRefs.referenceHash, referenceHash))
      .limit(1);

    const currentTime = now();
    if (!row) classifyRow(undefined, currentTime);
    if (row.consumedAt) classifyRow(row, currentTime);
    if (row.expiresAt.getTime() <= currentTime.getTime()) classifyRow(row, currentTime);
    if (row.usedAttempts >= row.maxAttempts) classifyRow(row, currentTime);

    const [updated] = await database
      .update(schema.windowsOfflineDownloadRefs)
      .set({
        usedAttempts: sql`${schema.windowsOfflineDownloadRefs.usedAttempts} + 1`,
        activeTransfers: sql`${schema.windowsOfflineDownloadRefs.activeTransfers} + 1`,
      })
      .where(
        and(
          eq(schema.windowsOfflineDownloadRefs.id, row.id),
          isNull(schema.windowsOfflineDownloadRefs.consumedAt),
          gtNow(schema.windowsOfflineDownloadRefs.expiresAt, currentTime),
          lt(
            schema.windowsOfflineDownloadRefs.usedAttempts,
            schema.windowsOfflineDownloadRefs.maxAttempts
          )
        )
      )
      .returning();

    if (!updated) {
      const [latest] = await database
        .select()
        .from(schema.windowsOfflineDownloadRefs)
        .where(eq(schema.windowsOfflineDownloadRefs.id, row.id))
        .limit(1);
      classifyRow(latest, now());
    }

    return toRecord(updated);
  }

  async function releaseAttempt(rawToken: string): Promise<void> {
    if (!isValidWindowsOfflineDownloadReference(rawToken)) return;
    await database
      .update(schema.windowsOfflineDownloadRefs)
      .set({
        activeTransfers: sql`GREATEST(${schema.windowsOfflineDownloadRefs.activeTransfers} - 1, 0)`,
      })
      .where(
        and(
          eq(schema.windowsOfflineDownloadRefs.referenceHash, hashDownloadReference(rawToken)),
          gt(schema.windowsOfflineDownloadRefs.activeTransfers, 0)
        )
      );
  }

  async function markConsumed(rawToken: string): Promise<boolean> {
    if (!isValidWindowsOfflineDownloadReference(rawToken)) return false;
    const [row] = await database
      .update(schema.windowsOfflineDownloadRefs)
      .set({
        consumedAt: sql`COALESCE(${schema.windowsOfflineDownloadRefs.consumedAt}, ${now()})`,
        activeTransfers: sql`GREATEST(${schema.windowsOfflineDownloadRefs.activeTransfers} - 1, 0)`,
      })
      .where(
        and(
          eq(schema.windowsOfflineDownloadRefs.referenceHash, hashDownloadReference(rawToken)),
          or(
            isNull(schema.windowsOfflineDownloadRefs.consumedAt),
            gt(schema.windowsOfflineDownloadRefs.activeTransfers, 0)
          )
        )
      )
      .returning({ activeTransfers: schema.windowsOfflineDownloadRefs.activeTransfers });
    return row?.activeTransfers === 0;
  }

  async function invalidateReference(rawToken: string): Promise<void> {
    if (!isValidWindowsOfflineDownloadReference(rawToken)) return;
    await database
      .delete(schema.windowsOfflineDownloadRefs)
      .where(eq(schema.windowsOfflineDownloadRefs.referenceHash, hashDownloadReference(rawToken)));
  }

  /**
   * Removes only rows and files below the supplied writable artifact root.
   * Template storage is never derived from this path and is therefore outside
   * the cleanup boundary.
   */
  async function cleanupExpired(artifactsDir: string): Promise<number> {
    const currentTime = now();
    const staleRows = await database
      .select()
      .from(schema.windowsOfflineDownloadRefs)
      .where(
        and(
          or(
            isNotNull(schema.windowsOfflineDownloadRefs.consumedAt),
            lte(schema.windowsOfflineDownloadRefs.expiresAt, currentTime),
            gte(
              schema.windowsOfflineDownloadRefs.usedAttempts,
              schema.windowsOfflineDownloadRefs.maxAttempts
            )
          ),
          eq(schema.windowsOfflineDownloadRefs.activeTransfers, 0)
        )
      );

    const deletedRows =
      staleRows.length > 0
        ? await database
            .delete(schema.windowsOfflineDownloadRefs)
            .where(
              and(
                inArray(
                  schema.windowsOfflineDownloadRefs.id,
                  staleRows.map((row) => row.id)
                ),
                eq(schema.windowsOfflineDownloadRefs.activeTransfers, 0)
              )
            )
            .returning({ referenceHash: schema.windowsOfflineDownloadRefs.referenceHash })
        : [];

    const resolvedArtifactsDir = path.resolve(artifactsDir);
    const orphanCutoffMs = currentTime.getTime() - ORPHAN_ARTIFACT_GRACE_MS;
    const staleFileNames = new Set(
      deletedRows.map((row) => artifactFileNameFromReferenceHash(row.referenceHash))
    );
    const removeArtifact = (fileName: string, onlyIfOlderThanGrace = false): void => {
      const filePath = path.join(resolvedArtifactsDir, fileName);
      try {
        if (!existsSync(filePath)) return;
        const fileStat = statSync(filePath);
        if (!fileStat.isFile()) return;
        if (onlyIfOlderThanGrace && fileStat.mtimeMs > orphanCutoffMs) return;
        rmSync(filePath, { force: true });
      } catch {
        logger.warn('offline_installer_cleanup_failed', { code: 'artifact_remove_failed' });
      }
    };

    if (existsSync(resolvedArtifactsDir)) {
      for (const fileName of staleFileNames) removeArtifact(fileName);

      const activeFileNames = new Set(
        (
          await database
            .select({ referenceHash: schema.windowsOfflineDownloadRefs.referenceHash })
            .from(schema.windowsOfflineDownloadRefs)
        ).map((row) => artifactFileNameFromReferenceHash(row.referenceHash))
      );

      for (const fileName of readdirSync(resolvedArtifactsDir)) {
        if (ARTIFACT_FILE_PATTERN.test(fileName) && !activeFileNames.has(fileName)) {
          // A generator publishes the file immediately after inserting its
          // reference row. Keep a short grace window for that cross-process
          // publication gap; crashed generations are removed on a later pass.
          removeArtifact(fileName, true);
        }
      }
    }

    return deletedRows.length;
  }

  return {
    mintReference,
    consumeAttempt,
    releaseAttempt,
    markConsumed,
    invalidateReference,
    cleanupExpired,
    now,
  };
}

export function logReferenceFailure(code: DownloadReferenceErrorCode): void {
  logger.warn(`offline_installer_reference_${code.toLowerCase()}`);
}

function gtNow(column: typeof schema.windowsOfflineDownloadRefs.expiresAt, value: Date): SQL {
  return sql`${column} > ${value}`;
}
