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
  artifactStorageFileName: string;
  artifactSha256: string;
  artifactSize: number;
  maxAttempts: number;
  usedAttempts: number;
  activeTransfers: number;
  transferId?: string;
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
  transferLeaseMs?: number;
}

export interface MintWindowsOfflineDownloadReferenceInput {
  classroomId: string;
  classroomName: string;
  createdBy?: string | null;
  artifactFileName: string;
  artifactStorageFileName?: string;
  artifactSha256: string;
  artifactSize: number;
  ttlMinutes: number;
  maxAttempts: number;
}

const RAW_REFERENCE_PATTERN = /^[A-Za-z0-9_-]{43}$/u;
const REFERENCE_HASH_PATTERN = /^[0-9a-f]{64}$/u;
const STORAGE_ARTIFACT_FILE_PATTERN =
  /^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.exe$/u;
const STAGING_ARTIFACT_FILE_PATTERN =
  /^\.\d+-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.staging\.exe$/u;
const ORPHAN_ARTIFACT_GRACE_MS = 5 * 60 * 1000;
export const DEFAULT_WINDOWS_OFFLINE_TRANSFER_LEASE_MS = 15 * 60 * 1000;

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

export function validateArtifactStorageFileName(fileName: string): string {
  if (!STORAGE_ARTIFACT_FILE_PATTERN.test(fileName)) {
    throw new Error('Invalid Windows offline installer artifact storage filename');
  }
  return fileName;
}

function defaultRandomToken(bytes: number): string {
  return randomBytes(bytes).toString('base64url');
}

export interface CleanupExpiredOptions {
  artifactRetentionHours?: number;
}

function toRecord(row: WindowsOfflineDownloadRef, transferId?: string): DownloadRefRecord {
  return {
    id: row.id,
    classroomId: row.classroomId,
    classroomName: row.classroomName,
    createdBy: row.createdBy,
    referenceHash: row.referenceHash,
    artifactFileName: row.artifactFileName,
    artifactStorageFileName: row.artifactStorageFileName,
    artifactSha256: row.artifactSha256,
    artifactSize: row.artifactSize,
    maxAttempts: row.maxAttempts,
    usedAttempts: row.usedAttempts,
    activeTransfers: row.activeTransfers,
    ...(transferId ? { transferId } : {}),
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
  renewAttempt(rawToken: string, transferId: string): Promise<boolean>;
  releaseAttempt(rawToken: string, transferId: string): Promise<void>;
  /** Returns true when this completion released the final active transfer. */
  markConsumed(rawToken: string, transferId: string): Promise<boolean>;
  invalidateReference(rawToken: string): Promise<void>;
  /**
   * Revokes every reference for an artifact when no active transfer protects it.
   * Returns true only when no reference remains and the artifact may be removed.
   */
  revokeReferencesForArtifact(artifactStorageFileName: string): Promise<boolean>;
  cleanupExpired(artifactsDir: string, options?: CleanupExpiredOptions): Promise<number>;
  readonly transferLeaseMs: number;
  now(): Date;
}

export function createWindowsOfflineDownloadRefsService(
  deps: RefsRepoDeps = {}
): WindowsOfflineDownloadRefsService {
  const database = deps.db ?? db;
  const now = deps.now ?? ((): Date => new Date());
  const randomToken = deps.randomToken ?? defaultRandomToken;
  const transferLeaseMs = deps.transferLeaseMs ?? DEFAULT_WINDOWS_OFFLINE_TRANSFER_LEASE_MS;

  async function mintReference(
    input: MintWindowsOfflineDownloadReferenceInput
  ): Promise<{ ref: DownloadRefRecord; rawToken: string }> {
    const rawToken = randomToken(32);
    if (!isValidWindowsOfflineDownloadReference(rawToken)) {
      throw new Error('Reference generator returned an invalid opaque reference');
    }

    const referenceHash = hashDownloadReference(rawToken);
    const artifactStorageFileName = validateArtifactStorageFileName(
      input.artifactStorageFileName ?? artifactFileNameFromReferenceHash(referenceHash)
    );
    const expiresAt = new Date(now().getTime() + input.ttlMinutes * 60_000);
    const [row] = await database
      .insert(schema.windowsOfflineDownloadRefs)
      .values({
        classroomId: input.classroomId,
        classroomName: input.classroomName,
        createdBy: input.createdBy ?? null,
        referenceHash,
        artifactFileName: input.artifactFileName,
        artifactStorageFileName,
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
   * Atomically reserves one attempt and creates one expiring transfer lease.
   * Concurrent transfers are allowed while the bounded retry budget remains;
   * completion/release must identify the lease they created.
   */
  async function consumeAttempt(rawToken: string): Promise<DownloadRefRecord> {
    if (!isValidWindowsOfflineDownloadReference(rawToken)) {
      throw new DownloadReferenceError('INVALID', 'Invalid download reference');
    }

    const referenceHash = hashDownloadReference(rawToken);
    return database.transaction(async (transaction) => {
      const [row] = await transaction
        .select()
        .from(schema.windowsOfflineDownloadRefs)
        .where(eq(schema.windowsOfflineDownloadRefs.referenceHash, referenceHash))
        .limit(1);

      const currentTime = now();
      if (!row) classifyRow(undefined, currentTime);
      if (row.consumedAt) classifyRow(row, currentTime);
      if (row.expiresAt.getTime() <= currentTime.getTime()) classifyRow(row, currentTime);
      if (row.usedAttempts >= row.maxAttempts) classifyRow(row, currentTime);

      const [updated] = await transaction
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
        const [latest] = await transaction
          .select()
          .from(schema.windowsOfflineDownloadRefs)
          .where(eq(schema.windowsOfflineDownloadRefs.id, row.id))
          .limit(1);
        classifyRow(latest, now());
      }

      const [lease] = await transaction
        .insert(schema.windowsOfflineDownloadTransferLeases)
        .values({
          downloadRefId: updated.id,
          // Keep a legitimate transfer protected through the reference TTL
          // plus one recovery window. Abandoned transfers are still bounded,
          // while a slow active stream cannot be mistaken for a crashed one.
          expiresAt: new Date(
            Math.max(
              currentTime.getTime() + transferLeaseMs,
              row.expiresAt.getTime() + transferLeaseMs
            )
          ),
        })
        .returning({ id: schema.windowsOfflineDownloadTransferLeases.id });

      if (!lease) throw new Error('Download transfer lease could not be persisted');
      return toRecord(updated, lease.id);
    });
  }

  async function renewAttempt(rawToken: string, transferId: string): Promise<boolean> {
    if (!isValidWindowsOfflineDownloadReference(rawToken)) return false;
    return database.transaction(async (transaction) => {
      const [reference] = await transaction
        .select({
          id: schema.windowsOfflineDownloadRefs.id,
          expiresAt: schema.windowsOfflineDownloadRefs.expiresAt,
        })
        .from(schema.windowsOfflineDownloadRefs)
        .where(eq(schema.windowsOfflineDownloadRefs.referenceHash, hashDownloadReference(rawToken)))
        .limit(1);
      if (!reference) return false;

      const currentTime = now();
      const [lease] = await transaction
        .update(schema.windowsOfflineDownloadTransferLeases)
        .set({
          expiresAt: sql`GREATEST(
            ${schema.windowsOfflineDownloadTransferLeases.expiresAt},
            ${new Date(currentTime.getTime() + transferLeaseMs)}
          )`,
        })
        .where(
          and(
            eq(schema.windowsOfflineDownloadTransferLeases.id, transferId),
            eq(schema.windowsOfflineDownloadTransferLeases.downloadRefId, reference.id),
            gt(schema.windowsOfflineDownloadTransferLeases.expiresAt, currentTime)
          )
        )
        .returning({ id: schema.windowsOfflineDownloadTransferLeases.id });
      return lease !== undefined;
    });
  }

  async function releaseAttempt(rawToken: string, transferId: string): Promise<void> {
    if (!isValidWindowsOfflineDownloadReference(rawToken)) return;
    await database.transaction(async (transaction) => {
      const [reference] = await transaction
        .select({ id: schema.windowsOfflineDownloadRefs.id })
        .from(schema.windowsOfflineDownloadRefs)
        .where(eq(schema.windowsOfflineDownloadRefs.referenceHash, hashDownloadReference(rawToken)))
        .limit(1);
      if (!reference) return;

      const [lease] = await transaction
        .delete(schema.windowsOfflineDownloadTransferLeases)
        .where(
          and(
            eq(schema.windowsOfflineDownloadTransferLeases.id, transferId),
            eq(schema.windowsOfflineDownloadTransferLeases.downloadRefId, reference.id)
          )
        )
        .returning({ downloadRefId: schema.windowsOfflineDownloadTransferLeases.downloadRefId });
      if (!lease) return;

      await transaction
        .update(schema.windowsOfflineDownloadRefs)
        .set({
          activeTransfers: sql`GREATEST(${schema.windowsOfflineDownloadRefs.activeTransfers} - 1, 0)`,
        })
        .where(
          and(
            eq(schema.windowsOfflineDownloadRefs.id, lease.downloadRefId),
            gt(schema.windowsOfflineDownloadRefs.activeTransfers, 0)
          )
        );
    });
  }

  async function markConsumed(rawToken: string, transferId: string): Promise<boolean> {
    if (!isValidWindowsOfflineDownloadReference(rawToken)) return false;
    return database.transaction(async (transaction) => {
      const [reference] = await transaction
        .select()
        .from(schema.windowsOfflineDownloadRefs)
        .where(eq(schema.windowsOfflineDownloadRefs.referenceHash, hashDownloadReference(rawToken)))
        .limit(1);
      if (!reference) return false;

      const [lease] = await transaction
        .delete(schema.windowsOfflineDownloadTransferLeases)
        .where(
          and(
            eq(schema.windowsOfflineDownloadTransferLeases.id, transferId),
            eq(schema.windowsOfflineDownloadTransferLeases.downloadRefId, reference.id)
          )
        )
        .returning({ downloadRefId: schema.windowsOfflineDownloadTransferLeases.downloadRefId });
      if (!lease) return false;

      const [row] = await transaction
        .update(schema.windowsOfflineDownloadRefs)
        .set({
          consumedAt: sql`COALESCE(${schema.windowsOfflineDownloadRefs.consumedAt}, ${now()})`,
          activeTransfers: sql`GREATEST(${schema.windowsOfflineDownloadRefs.activeTransfers} - 1, 0)`,
        })
        .where(eq(schema.windowsOfflineDownloadRefs.id, lease.downloadRefId))
        .returning({ activeTransfers: schema.windowsOfflineDownloadRefs.activeTransfers });
      return row?.activeTransfers === 0;
    });
  }

  async function invalidateReference(rawToken: string): Promise<void> {
    if (!isValidWindowsOfflineDownloadReference(rawToken)) return;
    await database
      .delete(schema.windowsOfflineDownloadRefs)
      .where(eq(schema.windowsOfflineDownloadRefs.referenceHash, hashDownloadReference(rawToken)));
  }

  async function revokeReferencesForArtifact(artifactStorageFileName: string): Promise<boolean> {
    const validatedFileName = validateArtifactStorageFileName(artifactStorageFileName);
    return database.transaction(async (transaction) => {
      await transaction
        .delete(schema.windowsOfflineDownloadRefs)
        .where(
          and(
            eq(schema.windowsOfflineDownloadRefs.artifactStorageFileName, validatedFileName),
            eq(schema.windowsOfflineDownloadRefs.activeTransfers, 0)
          )
        );

      const [remaining] = await transaction
        .select({ id: schema.windowsOfflineDownloadRefs.id })
        .from(schema.windowsOfflineDownloadRefs)
        .where(eq(schema.windowsOfflineDownloadRefs.artifactStorageFileName, validatedFileName))
        .limit(1);
      return remaining === undefined;
    });
  }

  async function recoverExpiredTransferLeases(currentTime: Date): Promise<void> {
    await database.transaction(async (transaction) => {
      const expiredLeases = await transaction
        .delete(schema.windowsOfflineDownloadTransferLeases)
        .where(lte(schema.windowsOfflineDownloadTransferLeases.expiresAt, currentTime))
        .returning({ downloadRefId: schema.windowsOfflineDownloadTransferLeases.downloadRefId });

      for (const lease of expiredLeases) {
        await transaction
          .update(schema.windowsOfflineDownloadRefs)
          .set({
            activeTransfers: sql`GREATEST(${schema.windowsOfflineDownloadRefs.activeTransfers} - 1, 0)`,
          })
          .where(
            and(
              eq(schema.windowsOfflineDownloadRefs.id, lease.downloadRefId),
              gt(schema.windowsOfflineDownloadRefs.activeTransfers, 0)
            )
          );
      }
    });
  }

  /**
   * Removes only rows and files below the supplied writable artifact root.
   * Template storage is never derived from this path and is therefore outside
   * the cleanup boundary.
   */
  async function cleanupExpired(
    artifactsDir: string,
    options: CleanupExpiredOptions = {}
  ): Promise<number> {
    const currentTime = now();
    await recoverExpiredTransferLeases(currentTime);
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
            .returning({
              artifactStorageFileName: schema.windowsOfflineDownloadRefs.artifactStorageFileName,
            })
        : [];

    const resolvedArtifactsDir = path.resolve(artifactsDir);
    const orphanRetentionMs =
      options.artifactRetentionHours === undefined
        ? ORPHAN_ARTIFACT_GRACE_MS
        : options.artifactRetentionHours * 60 * 60 * 1000;
    const orphanCutoffMs = currentTime.getTime() - orphanRetentionMs;
    const staleFileNames = new Set(deletedRows.map((row) => row.artifactStorageFileName));
    const removeArtifact = (fileName: string, onlyIfOlderThanGrace = false): void => {
      try {
        const isStoredArtifact = STORAGE_ARTIFACT_FILE_PATTERN.test(fileName);
        const isStagingArtifact = STAGING_ARTIFACT_FILE_PATTERN.test(fileName);
        if (!isStoredArtifact && !isStagingArtifact) return;
        if (isStoredArtifact) validateArtifactStorageFileName(fileName);
        const filePath = path.join(resolvedArtifactsDir, fileName);
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
      const activeFileNames = new Set(
        (
          await database
            .select({
              artifactStorageFileName: schema.windowsOfflineDownloadRefs.artifactStorageFileName,
            })
            .from(schema.windowsOfflineDownloadRefs)
        ).map((row) => row.artifactStorageFileName)
      );

      // A storage artifact may be referenced by more than one row (for
      // example, when a caller retries issuance for an already personalized
      // artifact). Never remove a filename returned by the stale batch if a
      // surviving reference still points at it.
      for (const fileName of staleFileNames) {
        if (!activeFileNames.has(fileName)) removeArtifact(fileName);
      }

      for (const fileName of readdirSync(resolvedArtifactsDir)) {
        if (
          (STORAGE_ARTIFACT_FILE_PATTERN.test(fileName) ||
            STAGING_ARTIFACT_FILE_PATTERN.test(fileName)) &&
          !activeFileNames.has(fileName)
        ) {
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
    revokeReferencesForArtifact,
    cleanupExpired,
    renewAttempt,
    transferLeaseMs,
    now,
  };
}

export function logReferenceFailure(code: DownloadReferenceErrorCode): void {
  logger.warn(`offline_installer_reference_${code.toLowerCase()}`);
}

function gtNow(column: typeof schema.windowsOfflineDownloadRefs.expiresAt, value: Date): SQL {
  return sql`${column} > ${value}`;
}
