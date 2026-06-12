export const CANONICAL_HEALTH_STATUSES = [
  'HEALTHY',
  'DEGRADED',
  'CRITICAL',
  'FAIL_OPEN',
  'STALE_FAILSAFE',
  'TAMPERED',
  'PROTECTED',
] as const;

export type CanonicalHealthStatus = (typeof CANONICAL_HEALTH_STATUSES)[number];

const CANONICAL_STATUS_SET = new Set<string>(CANONICAL_HEALTH_STATUSES);

const LEGACY_STATUS_MAP: Record<string, CanonicalHealthStatus> = {
  healthy: 'HEALTHY',
  warning: 'DEGRADED',
  error: 'CRITICAL',
  ok: 'HEALTHY',
  recovered: 'DEGRADED',
  failed: 'CRITICAL',
  unknown: 'DEGRADED',
};

export const PROBLEM_HEALTH_STATUSES = new Set<string>([
  'DEGRADED',
  'CRITICAL',
  'FAIL_OPEN',
  'STALE_FAILSAFE',
  'TAMPERED',
]);

export interface NormalizedHealthStatus {
  status: CanonicalHealthStatus;
  source: string;
  wasNormalized: boolean;
}

export function normalizeHealthStatus(status: string): NormalizedHealthStatus {
  const source = status.trim();
  const upper = source.toUpperCase();

  if (CANONICAL_STATUS_SET.has(upper)) {
    return {
      status: upper as CanonicalHealthStatus,
      source,
      wasNormalized: upper !== source,
    };
  }

  const mapped = LEGACY_STATUS_MAP[source] ?? LEGACY_STATUS_MAP[source.toLowerCase()];
  if (mapped) {
    return {
      status: mapped,
      source,
      wasNormalized: true,
    };
  }

  return {
    status: 'DEGRADED',
    source: source || 'UNKNOWN',
    wasNormalized: true,
  };
}

export function normalizeHealthActions(
  actions: string | undefined,
  normalized: NormalizedHealthStatus
): string {
  const trimmedActions = (actions ?? '').trim();
  if (!normalized.wasNormalized) {
    return trimmedActions;
  }

  const reason = `status_normalized:${normalized.source}->${normalized.status}`;
  if (!trimmedActions) {
    return reason;
  }

  return `${trimmedActions}; ${reason}`;
}
