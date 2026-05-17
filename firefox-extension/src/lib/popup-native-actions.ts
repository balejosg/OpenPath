import { formatNativeHostStatusLabel } from './native-status-label.js';
import type { BlockedDomainsData } from './popup-state.js';
import { t } from './i18n.js';

export interface VerifyResult {
  domain: string;
  inWhitelist?: boolean;
  resolvedIp?: string;
  in_whitelist?: boolean;
  resolved_ip?: string;
  error?: string;
}

export interface VerifyResponse {
  success: boolean;
  results: VerifyResult[];
  error?: string;
}

export interface NativeAvailabilityState {
  available: boolean;
  className: string;
  label: string;
}

export function resolveNativeAvailabilityState(response: {
  available?: boolean;
  success?: boolean;
  version?: string;
}): NativeAvailabilityState {
  const available = response.available ?? response.success ?? false;
  return available
    ? {
        available: true,
        className: 'status-indicator available',
        label: formatNativeHostStatusLabel({
          available: true,
          version: response.version,
        }),
      }
    : {
        available: false,
        className: 'status-indicator unavailable',
        label: formatNativeHostStatusLabel({ available: false }),
      };
}

export function getBlockedHostnames(blockedDomainsData: BlockedDomainsData): string[] {
  return Object.keys(blockedDomainsData).sort();
}

export async function verifyPopupDomains(input: {
  blockedDomainsData: BlockedDomainsData;
  isNativeAvailable: boolean;
  sendMessage: (message: unknown) => Promise<unknown>;
}): Promise<
  | { ok: true; results: VerifyResult[] }
  | { ok: false; errorMessage: string }
  | { ok: false; skipped: true }
> {
  const hostnames = getBlockedHostnames(input.blockedDomainsData);
  if (hostnames.length === 0 || !input.isNativeAvailable) {
    return { ok: false, skipped: true };
  }

  const response = (await input.sendMessage({
    action: 'checkWithNative',
    domains: hostnames,
  })) as VerifyResponse;

  if (!response.success) {
    return {
      ok: false,
      errorMessage: response.error ?? t('popupUnknownError'),
    };
  }

  return {
    ok: true,
    results: response.results,
  };
}

export function buildVerifyResultViewModels(results: VerifyResult[]): {
  domain: string;
  resolvedIp?: string;
  statusClass: string;
  statusText: string;
}[] {
  return results.map((result) => {
    const inWhitelist = result.in_whitelist ?? result.inWhitelist;
    const resolvedIp = result.resolvedIp ?? result.resolved_ip;

    return {
      domain: result.domain,
      ...(resolvedIp !== undefined ? { resolvedIp } : {}),
      statusClass: inWhitelist ? 'status-allowed' : 'status-blocked',
      statusText: inWhitelist ? t('popupAllowed') : t('popupBlocked'),
    };
  });
}
