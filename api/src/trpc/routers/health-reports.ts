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

// =============================================================================
// Enforcement-telemetry alerting constants
// =============================================================================

/**
 * Agents at or above this version are expected to report enforcement telemetry
 * (firewallState et al). A capable agent that omits firewallState is treated as
 * suspicious (enforcement-unknown) rather than given a free pass; a legacy agent
 * below this version that omits the field is not flagged (it never reported it).
 */
const ENFORCEMENT_TELEMETRY_MIN_VERSION = '1.3.0';

/**
 * Whitelist freshness ceiling for alerting. The endpoint default is a 24h max
 * age (linux WHITELIST_MAX_AGE_HOURS); we alert at twice that so transient fetch
 * delays do not false-alarm, but a genuinely stuck whitelist is surfaced.
 */
const WHITELIST_STALE_ALERT_HOURS = 48;

/**
 * Parse a dotted numeric version (e.g. "1.3.0", "1.4.2-rc1") into comparable
 * numeric segments. Non-numeric or empty input yields null (treated as
 * not-capable so legacy/unknown agents are never flagged enforcement-unknown).
 */
function parseVersionSegments(version: string | null | undefined): number[] | null {
  if (version === null || version === undefined) {
    return null;
  }
  const trimmed = version.trim();
  if (trimmed === '' || trimmed.toLowerCase() === 'unknown') {
    return null;
  }
  const core = trimmed.split(/[-+]/)[0] ?? '';
  const segments = core.split('.').map((segment) => Number.parseInt(segment, 10));
  if (segments.length === 0 || segments.some((segment) => Number.isNaN(segment))) {
    return null;
  }
  return segments;
}

/** True when `version` is a parseable version >= ENFORCEMENT_TELEMETRY_MIN_VERSION. */
function reportsEnforcementTelemetry(version: string | null | undefined): boolean {
  const actual = parseVersionSegments(version);
  if (actual === null) {
    return false;
  }
  const minimum = parseVersionSegments(ENFORCEMENT_TELEMETRY_MIN_VERSION) ?? [];
  const length = Math.max(actual.length, minimum.length);
  for (let i = 0; i < length; i += 1) {
    const a = actual[i] ?? 0;
    const m = minimum[i] ?? 0;
    if (a > m) return true;
    if (a < m) return false;
  }
  return true;
}

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

    // Flag posture + delivery fail streak (canonical-only; null = not reported).
    const resolvedConfigPosture = input.configPosture ?? null;
    const resolvedHealthReportFailStreak = input.healthReportFailStreak ?? null;

    // Firefox registration state (canonical-only; null = the agent did not report it).
    const resolvedFirefoxRegistration = input.firefoxRegistration ?? null;

    await healthReports.saveHealthReport(
      machine.hostname,
      stripUndefined({
        status: input.status,
        dnsmasqRunning: resolvedDnsmasqRunning,
        dnsResolving: resolvedDnsResolving,
        firewallActive: resolvedFirewallActive,
        whitelistAgeHours: resolvedWhitelistAgeHours,
        captivePortalMode: resolvedCaptivePortalMode,
        configPosture: resolvedConfigPosture,
        healthReportFailStreak: resolvedHealthReportFailStreak,
        firefoxRegistration: resolvedFirefoxRegistration,
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

        // Enforcement unknown: a self-attesting gap. An agent recent enough to
        // report enforcement telemetry but that OMITS firewallState (null) must
        // not be a silent pass — a disabled-enforcement host can hide by omitting
        // the field. Distinct from enforcement-down (which needs an explicit
        // false). Legacy agents (no/unknown version) never reported it, so they
        // are intentionally not flagged here.
        if (latest?.firewallActive === null && reportsEnforcementTelemetry(latest.version)) {
          alerts.push({
            hostname,
            type: 'enforcement-unknown',
            status: host.currentStatus ?? 'UNKNOWN',
            lastSeen: host.lastSeen,
            message:
              'Host did not report firewall enforcement state despite running an ' +
              'enforcement-capable agent version',
          });
        }

        // Whitelist staleness: a host whose last successful whitelist fetch is far
        // beyond the freshness ceiling is enforcing an outdated policy.
        if (
          latest?.whitelistAgeHours != null &&
          latest.whitelistAgeHours > WHITELIST_STALE_ALERT_HOURS
        ) {
          alerts.push({
            hostname,
            type: 'whitelist-stale',
            status: host.currentStatus ?? 'UNKNOWN',
            lastSeen: host.lastSeen,
            message:
              `Host whitelist is ${String(latest.whitelistAgeHours)}h old ` +
              `(exceeds ${String(WHITELIST_STALE_ALERT_HOURS)}h freshness ceiling)`,
          });
        }

        // Captive-portal mode active: enforcement is intentionally relaxed for
        // portal sign-in. Surface it so operators can confirm it is expected and
        // not a stuck bypass.
        if (latest?.captivePortalMode === true) {
          alerts.push({
            hostname,
            type: 'captive-portal',
            status: host.currentStatus ?? 'UNKNOWN',
            lastSeen: host.lastSeen,
            message: 'Host reports captive-portal bypass mode is currently active',
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
