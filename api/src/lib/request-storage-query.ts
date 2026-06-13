/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 */

import { and, count, desc, eq, sql } from 'drizzle-orm';
import { db, requests } from '../db/index.js';
import type { DomainRequest, RequestStatus } from '../types/index.js';
import type { RequestStats } from '../types/storage.js';
import {
  hasRequestMetadataColumns,
  normalizeRequestDomain,
  toStorageType,
} from './request-storage-shared.js';
import { readLegacyRequest, readLegacyRequests } from './request-storage-legacy.js';

export async function getAllRequests(
  status: RequestStatus | null = null
): Promise<DomainRequest[]> {
  if (!(await hasRequestMetadataColumns())) {
    return readLegacyRequests(sql`
      SELECT id, domain, reason, requester_email, group_id, status,
             created_at, updated_at, resolved_at, resolved_by, resolution_note
      FROM requests
      ${status !== null ? sql`WHERE status = ${status}` : sql``}
      ORDER BY created_at DESC
    `);
  }

  const conditions = status !== null ? eq(requests.status, status) : undefined;
  const result = await db
    .select()
    .from(requests)
    .where(conditions)
    .orderBy(desc(requests.createdAt));
  return result.map(toStorageType);
}

export async function getRequestsByGroup(groupId: string): Promise<DomainRequest[]> {
  if (!(await hasRequestMetadataColumns())) {
    return readLegacyRequests(sql`
      SELECT id, domain, reason, requester_email, group_id, status,
             created_at, updated_at, resolved_at, resolved_by, resolution_note
      FROM requests
      WHERE group_id = ${groupId}
      ORDER BY created_at DESC
    `);
  }

  const result = await db
    .select()
    .from(requests)
    .where(eq(requests.groupId, groupId))
    .orderBy(desc(requests.createdAt));

  return result.map(toStorageType);
}

export async function getRequestById(id: string): Promise<DomainRequest | null> {
  if (!(await hasRequestMetadataColumns())) {
    return readLegacyRequest(sql`
      SELECT id, domain, reason, requester_email, group_id, status,
             created_at, updated_at, resolved_at, resolved_by, resolution_note
      FROM requests
      WHERE id = ${id}
      LIMIT 1
    `);
  }

  const result = await db.select().from(requests).where(eq(requests.id, id)).limit(1);
  return result[0] ? toStorageType(result[0]) : null;
}

export async function hasPendingRequest(domain: string, groupId?: string): Promise<boolean> {
  // Dedupe is scoped per group: a pending request in one group must not suppress
  // (or be discoverable via CONFLICT from) another group's request for the same
  // domain. Callers that already resolved the request-eligible group pass it in;
  // a missing groupId falls back to the legacy global check.
  const conditions = [
    eq(requests.domain, normalizeRequestDomain(domain)),
    eq(requests.status, 'pending'),
  ];
  if (groupId !== undefined && groupId !== '') {
    conditions.push(eq(requests.groupId, groupId));
  }

  const result = await db
    .select({ id: requests.id })
    .from(requests)
    .where(and(...conditions))
    .limit(1);

  return result.length > 0;
}

export async function getStats(): Promise<RequestStats> {
  const result = await db
    .select({
      status: requests.status,
      count: count(),
    })
    .from(requests)
    .groupBy(requests.status);

  const stats: RequestStats = {
    total: 0,
    pending: 0,
    approved: 0,
    rejected: 0,
  };

  result.forEach((row) => {
    const countValue = row.count;
    stats.total += countValue;
    if (row.status === 'pending') stats.pending = countValue;
    if (row.status === 'approved') stats.approved = countValue;
    if (row.status === 'rejected') stats.rejected = countValue;
  });

  return stats;
}
