/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * Health Reports Module
 * Handles endpoint agent health status reporting
 * Storage: PostgreSQL via Drizzle ORM
 */

import { eq, desc, sql } from 'drizzle-orm';
import { db } from '../db/index.js';
import { healthReports, machines } from '../db/schema.js';
import { normalizeHealthActions, normalizeHealthStatus } from './health-status.js';

// =============================================================================
// Types
// =============================================================================

export interface HealthReport {
  timestamp: string;
  status: string;
  dnsmasqRunning: boolean | null;
  dnsResolving: boolean | null;
  firewallActive: boolean | null;
  whitelistAgeHours: number | null;
  captivePortalMode: boolean | null;
  failCount: number;
  actions: string;
  version: string;
}

export interface HostData {
  reports: HealthReport[];
  lastSeen: string | null;
  currentStatus: string | null;
  version?: string;
}

export interface ReportsData {
  hosts: Record<string, HostData>;
  lastUpdated: string | null;
}

// =============================================================================
// Constants
// =============================================================================

const MAX_REPORTS_PER_HOST = 100;

// =============================================================================
// Storage Functions (Postgres)
// =============================================================================

export async function saveHealthReport(
  hostname: string,
  reportData: Omit<HealthReport, 'timestamp'>
): Promise<void> {
  const now = new Date();
  const normalized = normalizeHealthStatus(reportData.status);
  const normalizedActions = normalizeHealthActions(reportData.actions, normalized);

  // Insert new health report
  await db.insert(healthReports).values({
    hostname,
    status: normalized.status,
    dnsmasqRunning: reportData.dnsmasqRunning === null ? null : reportData.dnsmasqRunning ? 1 : 0,
    dnsResolving: reportData.dnsResolving === null ? null : reportData.dnsResolving ? 1 : 0,
    firewallActive: reportData.firewallActive === null ? null : reportData.firewallActive ? 1 : 0,
    whitelistAgeHours: reportData.whitelistAgeHours ?? null,
    captivePortalMode:
      reportData.captivePortalMode === null ? null : reportData.captivePortalMode ? 1 : 0,
    failCount: reportData.failCount,
    actions: normalizedActions,
    version: reportData.version,
    reportedAt: now,
  });

  // Update machine's last_seen if it exists
  await db
    .update(machines)
    .set({
      lastSeen: now,
      version: reportData.version || undefined,
      updatedAt: now,
    })
    .where(eq(machines.hostname, hostname));

  // Clean up old reports (keep only MAX_REPORTS_PER_HOST per host)
  // Identify the oldest reportedAt we want to keep and delete anything older.
  const reportsToKeep = await db
    .select({ reportedAt: healthReports.reportedAt })
    .from(healthReports)
    .where(eq(healthReports.hostname, hostname))
    .orderBy(desc(healthReports.reportedAt))
    .limit(MAX_REPORTS_PER_HOST);

  if (reportsToKeep.length >= MAX_REPORTS_PER_HOST) {
    const oldestReportToKeep = reportsToKeep[reportsToKeep.length - 1];
    const oldestReportedAtToKeep = oldestReportToKeep?.reportedAt;

    if (oldestReportedAtToKeep) {
      await db
        .delete(healthReports)
        .where(
          sql`${healthReports.hostname} = ${hostname} AND ${healthReports.reportedAt} < ${oldestReportedAtToKeep}`
        );
    }
  }
}

export async function getAllReports(): Promise<ReportsData> {
  const reports = await db.select().from(healthReports).orderBy(desc(healthReports.reportedAt));

  // Group reports by hostname
  const hosts: Record<string, HostData> = {};
  let latestTimestamp: Date | null = null;

  for (const report of reports) {
    let host = hosts[report.hostname];
    if (!host) {
      host = {
        reports: [],
        lastSeen: null,
        currentStatus: null,
      };
      hosts[report.hostname] = host;
    }

    const timestamp = report.reportedAt?.toISOString() ?? new Date().toISOString();

    // First report for this host is the most recent (due to ordering)
    if (host.reports.length === 0) {
      host.lastSeen = timestamp;
      host.currentStatus = normalizeHealthStatus(report.status).status;
      if (report.version) {
        host.version = report.version;
      }
    }

    host.reports.push({
      timestamp,
      status: normalizeHealthStatus(report.status).status,
      dnsmasqRunning: report.dnsmasqRunning === null ? null : report.dnsmasqRunning === 1,
      dnsResolving: report.dnsResolving === null ? null : report.dnsResolving === 1,
      firewallActive: report.firewallActive === null ? null : report.firewallActive === 1,
      whitelistAgeHours: report.whitelistAgeHours ?? null,
      captivePortalMode: report.captivePortalMode === null ? null : report.captivePortalMode === 1,
      failCount: report.failCount ?? 0,
      actions: report.actions ?? '',
      version: report.version ?? '',
    });

    // Track overall latest timestamp
    if (report.reportedAt && (!latestTimestamp || report.reportedAt > latestTimestamp)) {
      latestTimestamp = report.reportedAt;
    }
  }

  return {
    hosts,
    lastUpdated: latestTimestamp?.toISOString() ?? null,
  };
}

export async function getHostReports(hostname: string): Promise<HostData | null> {
  const reports = await db
    .select()
    .from(healthReports)
    .where(eq(healthReports.hostname, hostname))
    .orderBy(desc(healthReports.reportedAt))
    .limit(MAX_REPORTS_PER_HOST);

  if (reports.length === 0) {
    return null;
  }

  const firstReport = reports[0];
  const currentStatus = firstReport ? normalizeHealthStatus(firstReport.status).status : null;
  const hostData: HostData = {
    reports: reports.map((report) => ({
      timestamp: report.reportedAt?.toISOString() ?? new Date().toISOString(),
      status: normalizeHealthStatus(report.status).status,
      dnsmasqRunning: report.dnsmasqRunning === null ? null : report.dnsmasqRunning === 1,
      dnsResolving: report.dnsResolving === null ? null : report.dnsResolving === 1,
      firewallActive: report.firewallActive === null ? null : report.firewallActive === 1,
      whitelistAgeHours: report.whitelistAgeHours ?? null,
      captivePortalMode: report.captivePortalMode === null ? null : report.captivePortalMode === 1,
      failCount: report.failCount ?? 0,
      actions: report.actions ?? '',
      version: report.version ?? '',
    })),
    lastSeen: firstReport?.reportedAt?.toISOString() ?? null,
    currentStatus,
  };

  if (firstReport?.version) {
    hostData.version = firstReport.version;
  }

  return hostData;
}
