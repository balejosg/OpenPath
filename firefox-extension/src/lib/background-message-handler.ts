import type { Runtime } from 'webextension-polyfill';

import {
  GET_RECENT_BLOCKED_DOMAIN_REQUEST_STATUS_ACTION,
  SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
  isGetRecentBlockedDomainRequestStatusMessage,
  isSubmitBlockedDomainRequestMessage,
} from './blocked-screen-contract.js';
import type { NativeResponse, VerifyResponse } from './native-messaging-client.js';
import type { SubmitBlockedDomainInput, SubmitBlockedDomainResult } from './request-api.js';

interface BackgroundMessage {
  action?: string;
  blockedAt?: number;
  domain?: string;
  domains?: string[];
  error?: string;
  hostname?: string;
  origin?: string;
  pageHost?: string;
  pagePath?: string;
  reason?: string;
  signals?: unknown;
  tabId: number;
  type?: string;
  url?: string;
}

const RECENT_BLOCKED_DOMAIN_REQUEST_STATUS_TTL_MS = 120_000;
const MAX_GOOGLE_SEARCH_GAME_GUARD_SIGNAL_LENGTH = 64;
const MAX_GOOGLE_SEARCH_GAME_GUARD_SIGNAL_COUNT = 12;

export interface GoogleSearchGameGuardEvent {
  blockedAt: number;
  pageHost: string;
  pagePath: string;
  reason: string;
  signals: string[];
}

interface RecentBlockedDomainRequestStatus {
  request: SubmitBlockedDomainResult;
  storedAt: number;
}

function normalizeRecentBlockedDomainKey(domain: unknown): string | null {
  const normalized = typeof domain === 'string' ? domain.trim().toLowerCase() : '';
  return normalized.length > 0 ? normalized : null;
}

export interface BackgroundMessageHandlerDeps {
  clearBlockedDomains: (tabId: number) => void;
  evaluateBlockedPathDebug: (input: { type: string; url: string }) => unknown;
  evaluateBlockedSubdomainDebug: (input: { type: string; url: string }) => unknown;
  forceBlockedPathRulesRefresh: () => Promise<{ success: boolean; error?: string }>;
  forceBlockedSubdomainRulesRefresh: () => Promise<{ success: boolean; error?: string }>;
  getBlockedDomainsForTab: (tabId: number) => Record<string, unknown>;
  getDomainStatusesForTab: (tabId: number) => Record<string, unknown>;
  getErrorMessage: (error: unknown) => string;
  getMachineToken: () => Promise<unknown>;
  getNativeBlockedPathsDebug: () => Promise<unknown>;
  getNativeBlockedSubdomainsDebug: () => Promise<unknown>;
  getPathRulesDebug: () => {
    compiledPatterns: string[];
    count: number;
    rawRules: string[];
    success: true;
    version: string;
  };
  getSubdomainRulesDebug: () => {
    count: number;
    rawRules: string[];
    success: true;
    version: string;
  };
  recordGoogleSearchGameGuardEvent: (event: GoogleSearchGameGuardEvent) => void;
  getOpenPathDiagnostics: (domains: string[]) => Promise<unknown>;
  getSystemHostname: () => Promise<unknown>;
  isNativeHostAvailable: () => Promise<boolean>;
  retryLocalUpdate: (tabId: number, hostname: string) => Promise<{ success: boolean }>;
  submitBlockedDomainRequest: (
    input: SubmitBlockedDomainInput
  ) => Promise<SubmitBlockedDomainResult>;
  triggerWhitelistUpdate: () => Promise<NativeResponse>;
  verifyDomains: (domains: string[]) => Promise<VerifyResponse>;
}

function sanitizeGoogleSearchGameGuardText(value: unknown, fallback: string, max: number): string {
  const raw = typeof value === 'string' ? value.trim() : '';
  if (!raw) {
    return fallback;
  }
  return raw.slice(0, max);
}

function sanitizeGoogleSearchGameGuardPath(value: unknown): string {
  const raw = sanitizeGoogleSearchGameGuardText(value, '/', 120);
  const path = raw.split(/[?#]/u, 1)[0] ?? '/';
  return path.startsWith('/') ? path : '/';
}

function sanitizeGoogleSearchGameGuardSignals(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .filter((signal): signal is string => typeof signal === 'string')
    .map((signal) => signal.trim())
    .filter((signal) => signal.length > 0)
    .slice(0, MAX_GOOGLE_SEARCH_GAME_GUARD_SIGNAL_COUNT)
    .map((signal) => signal.slice(0, MAX_GOOGLE_SEARCH_GAME_GUARD_SIGNAL_LENGTH));
}

export function buildGoogleSearchGameGuardEvent(
  message: BackgroundMessage
): GoogleSearchGameGuardEvent {
  return {
    blockedAt:
      typeof message.blockedAt === 'number' && Number.isFinite(message.blockedAt)
        ? message.blockedAt
        : Date.now(),
    pageHost: sanitizeGoogleSearchGameGuardText(message.pageHost, 'unknown', 120).toLowerCase(),
    pagePath: sanitizeGoogleSearchGameGuardPath(message.pagePath),
    reason: sanitizeGoogleSearchGameGuardText(
      message.reason,
      'GOOGLE_GAME_POLICY:search-widget',
      80
    ),
    signals: sanitizeGoogleSearchGameGuardSignals(message.signals),
  };
}

export function buildSubmitBlockedDomainInput(
  message: BackgroundMessage
): SubmitBlockedDomainInput {
  const input: SubmitBlockedDomainInput = {};
  if (message.domain !== undefined) {
    input.domain = message.domain;
  }
  if (message.reason !== undefined) {
    input.reason = message.reason;
  }
  if (message.origin !== undefined) {
    input.origin = message.origin;
  }
  if (message.error !== undefined) {
    input.error = message.error;
  }

  return input;
}

export function createBackgroundMessageHandler(
  deps: BackgroundMessageHandlerDeps
): (message: unknown, sender: Runtime.MessageSender) => Promise<unknown> {
  const recentBlockedDomainRequestStatuses = new Map<string, RecentBlockedDomainRequestStatus>();

  function saveRecentBlockedDomainRequestStatus(
    input: SubmitBlockedDomainInput,
    request: SubmitBlockedDomainResult
  ): void {
    const domainKey = normalizeRecentBlockedDomainKey(input.domain);
    if (!domainKey || !request.success) {
      return;
    }

    recentBlockedDomainRequestStatuses.set(domainKey, {
      request,
      storedAt: Date.now(),
    });
  }

  function readRecentBlockedDomainRequestStatus(domain: string): SubmitBlockedDomainResult | null {
    const domainKey = normalizeRecentBlockedDomainKey(domain);
    if (!domainKey) {
      return null;
    }

    const cached = recentBlockedDomainRequestStatuses.get(domainKey);
    if (!cached) {
      return null;
    }

    if (Date.now() - cached.storedAt > RECENT_BLOCKED_DOMAIN_REQUEST_STATUS_TTL_MS) {
      recentBlockedDomainRequestStatuses.delete(domainKey);
      return null;
    }

    return cached.request;
  }

  return async (message: unknown, _sender: Runtime.MessageSender): Promise<unknown> => {
    const msg = message as BackgroundMessage;

    switch (msg.action) {
      case 'openpathPageActivity':
        return { success: true };

      case 'openpathGoogleSearchGameBlocked':
        deps.recordGoogleSearchGameGuardEvent(buildGoogleSearchGameGuardEvent(msg));
        return { success: true };

      case 'getBlockedDomains':
        return {
          domains: deps.getBlockedDomainsForTab(msg.tabId),
        };

      case 'getDomainStatuses':
        return {
          statuses: deps.getDomainStatusesForTab(msg.tabId),
        };

      case 'getBlockedPathRulesDebug':
        return deps.getPathRulesDebug();

      case 'getBlockedSubdomainRulesDebug':
        return deps.getSubdomainRulesDebug();

      case 'getNativeBlockedPathsDebug':
        try {
          return await deps.getNativeBlockedPathsDebug();
        } catch (error) {
          return {
            success: false,
            error: deps.getErrorMessage(error),
          };
        }

      case 'getNativeBlockedSubdomainsDebug':
        try {
          return await deps.getNativeBlockedSubdomainsDebug();
        } catch (error) {
          return {
            success: false,
            error: deps.getErrorMessage(error),
          };
        }

      case 'getOpenPathDiagnostics':
        try {
          return await deps.getOpenPathDiagnostics(Array.isArray(msg.domains) ? msg.domains : []);
        } catch (error) {
          return {
            success: false,
            error: deps.getErrorMessage(error),
          };
        }

      case 'evaluateBlockedPathDebug':
        return {
          success: true,
          outcome: deps.evaluateBlockedPathDebug({
            type: msg.type ?? '',
            url: msg.url ?? '',
          }),
        };

      case 'evaluateBlockedSubdomainDebug':
        return {
          success: true,
          outcome: deps.evaluateBlockedSubdomainDebug({
            type: msg.type ?? '',
            url: msg.url ?? '',
          }),
        };

      case 'clearBlockedDomains':
        deps.clearBlockedDomains(msg.tabId);
        return { success: true };

      case 'checkWithNative':
      case 'verifyDomains':
        try {
          return await deps.verifyDomains(Array.isArray(msg.domains) ? msg.domains : []);
        } catch (error) {
          return {
            success: false,
            results: [],
            error: deps.getErrorMessage(error),
          };
        }

      case 'isNativeAvailable':
      case 'checkNative':
        try {
          const available = await deps.isNativeHostAvailable();
          return { available, success: available };
        } catch {
          return { available: false, success: false };
        }

      case 'getHostname':
        try {
          return await deps.getSystemHostname();
        } catch (error) {
          return { success: false, error: deps.getErrorMessage(error) };
        }

      case 'getMachineToken':
        try {
          return await deps.getMachineToken();
        } catch (error) {
          return { success: false, error: deps.getErrorMessage(error) };
        }

      case SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION:
        try {
          if (!isSubmitBlockedDomainRequestMessage(message)) {
            return { success: false, error: 'domain and reason are required' };
          }

          const input = buildSubmitBlockedDomainInput(msg);
          const result = await deps.submitBlockedDomainRequest(input);
          saveRecentBlockedDomainRequestStatus(input, result);
          return result;
        } catch (error) {
          return { success: false, error: deps.getErrorMessage(error) };
        }

      case GET_RECENT_BLOCKED_DOMAIN_REQUEST_STATUS_ACTION:
        if (!isGetRecentBlockedDomainRequestStatusMessage(message)) {
          return { success: false, error: 'domain is required' };
        }

        return {
          success: true,
          request: readRecentBlockedDomainRequestStatus(message.domain),
        };

      case 'triggerWhitelistUpdate':
        try {
          return await deps.triggerWhitelistUpdate();
        } catch (error) {
          return { success: false, error: deps.getErrorMessage(error) };
        }

      case 'refreshBlockedPathRules':
        return deps.forceBlockedPathRulesRefresh();

      case 'refreshBlockedSubdomainRules':
        return deps.forceBlockedSubdomainRulesRefresh();

      case 'retryLocalUpdate':
        if (!msg.hostname) {
          return { success: false, error: 'hostname is required' };
        }
        return deps.retryLocalUpdate(msg.tabId, msg.hostname);

      default:
        return { error: 'Unknown action' };
    }
  };
}
