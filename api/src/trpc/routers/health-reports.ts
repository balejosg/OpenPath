import { z } from 'zod';
import {
  router,
  publicProcedure,
  adminProcedure,
  requireMachineTokenAccess,
  machineMatchesHostname,
} from '../trpc.js';
import { TRPCError } from '@trpc/server';
import * as healthReports from '../../lib/health-reports.js';
import { HealthReport } from '../../lib/health-reports.js';
import { PROBLEM_HEALTH_STATUSES } from '../../lib/health-status.js';
import { stripUndefined } from '../../lib/utils.js';
import { HealthReportSubmitInput } from '@openpath/shared';

export const healthReportsRouter = router({
  submit: publicProcedure.input(HealthReportSubmitInput).mutation(async ({ input, ctx }) => {
    const machine = await requireMachineTokenAccess(ctx.req);
    if (!machineMatchesHostname(machine, input.hostname)) {
      throw new TRPCError({
        code: 'FORBIDDEN',
        message: 'Machine token is not valid for this hostname',
      });
    }

    // Resolve canonical `agentVersion` — new agents send `agentVersion`;
    // deployed agents send legacy `version`.  Accept both; canonical wins.
    const resolvedVersion = input.agentVersion ?? input.version ?? 'unknown';

    // Resolve DNS fields — the specific legacy fields win when present
    // (agents that send both keep the daemon-vs-resolution distinction);
    // canonical `dnsState` is the fallback for agents that send only it.
    const resolvedDnsResolving = input.dnsResolving ?? input.dnsState ?? null;
    const resolvedDnsmasqRunning = input.dnsmasqRunning ?? input.dnsState ?? null;

    // Enforcement telemetry (canonical-only; null = the agent did not report it).
    const resolvedFirewallActive = input.firewallState ?? null;
    const resolvedWhitelistAgeHours =
      input.whitelistAgeHours === undefined ? null : Math.round(input.whitelistAgeHours);
    const resolvedCaptivePortalMode = input.captivePortalMode ?? null;

    await healthReports.saveHealthReport(
      machine.hostname,
      stripUndefined({
        status: input.status,
        dnsmasqRunning: resolvedDnsmasqRunning,
        dnsResolving: resolvedDnsResolving,
        firewallActive: resolvedFirewallActive,
        whitelistAgeHours: resolvedWhitelistAgeHours,
        captivePortalMode: resolvedCaptivePortalMode,
        failCount: input.failCount ?? 0,
        actions: input.actions ?? '',
        version: resolvedVersion,
      }) as Omit<HealthReport, 'timestamp'>
    );

    return { success: true, message: 'Health report received' };
  }),

  list: adminProcedure.query(async () => {
    const data = await healthReports.getAllReports();
    const summary: {
      totalHosts: number;
      lastUpdated: string | null;
      byStatus: Record<string, number>;
      hosts: {
        hostname: string;
        status: string | null;
        lastSeen: string | null;
        version?: string;
        recentFailCount: number;
      }[];
    } = {
      totalHosts: Object.keys(data.hosts).length,
      lastUpdated: data.lastUpdated,
      byStatus: {},
      hosts: [],
    };

    for (const [hostname, host] of Object.entries(data.hosts)) {
      const status = host.currentStatus ?? 'UNKNOWN';
      summary.byStatus[status] = (summary.byStatus[status] ?? 0) + 1;

      const lastReport = host.reports[host.reports.length - 1];

      summary.hosts.push({
        hostname,
        status: host.currentStatus,
        lastSeen: host.lastSeen,
        ...(host.version !== undefined && { version: host.version }),
        recentFailCount: lastReport?.failCount ?? 0,
      });
    }
    return summary;
  }),

  getAlerts: adminProcedure
    .input(z.object({ staleThreshold: z.number().default(10) }))
    .query(async ({ input }) => {
      const data = await healthReports.getAllReports();
      const now = new Date();
      const alerts: {
        hostname: string;
        type: string;
        status: string;
        lastSeen: string | null;
        message: string;
      }[] = [];

      for (const [hostname, host] of Object.entries(data.hosts)) {
        const lastSeen = new Date(host.lastSeen ?? 0);
        const minutesSinceLastSeen = (now.getTime() - lastSeen.getTime()) / 1000 / 60;

        if (
          host.currentStatus !== null &&
          host.currentStatus !== '' &&
          PROBLEM_HEALTH_STATUSES.has(host.currentStatus)
        ) {
          alerts.push({
            hostname,
            type: 'status',
            status: host.currentStatus,
            lastSeen: host.lastSeen,
            message: `Host reporting ${host.currentStatus} status`,
          });
        }

        if (minutesSinceLastSeen > input.staleThreshold) {
          alerts.push({
            hostname,
            type: 'stale',
            status: 'STALE',
            lastSeen: host.lastSeen,
            message: `Host hasn't reported in ${String(Math.round(minutesSinceLastSeen))} minutes`,
          });
        }

        // Enforcement down: the newest report explicitly says the firewall or DNS
        // resolution is off. Only an explicit false alarms — null means the agent
        // did not report the field (old agent / pre-migration), which must NOT
        // false-alarm the fleet.
        const latest = host.reports[0];
        if (latest && (latest.firewallActive === false || latest.dnsResolving === false)) {
          const down = [
            latest.firewallActive === false ? 'firewall' : null,
            latest.dnsResolving === false ? 'dns' : null,
          ]
            .filter(Boolean)
            .join('+');
          alerts.push({
            hostname,
            type: 'enforcement-down',
            status: host.currentStatus ?? 'UNKNOWN',
            lastSeen: host.lastSeen,
            message: `Host reports enforcement DOWN (${down})`,
          });
        }
      }
      return { alertCount: alerts.length, alerts };
    }),

  getByHost: adminProcedure.input(z.object({ hostname: z.string() })).query(async ({ input }) => {
    const host = await healthReports.getHostReports(input.hostname);
    if (!host) throw new TRPCError({ code: 'NOT_FOUND', message: 'Host not found' });

    return {
      hostname: input.hostname,
      currentStatus: host.currentStatus,
      lastSeen: host.lastSeen,
      version: host.version,
      reportCount: host.reports.length,
      reports: host.reports.slice(-20),
    };
  }),
});
