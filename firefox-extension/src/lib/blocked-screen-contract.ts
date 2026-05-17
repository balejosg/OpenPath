import { t } from './i18n.js';

export const SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION = 'submitBlockedDomainRequest' as const;
export const GET_RECENT_BLOCKED_DOMAIN_REQUEST_STATUS_ACTION =
  'getRecentBlockedDomainRequestStatus' as const;
export const GET_BLOCKED_PAGE_CONTEXT_ACTION = 'getBlockedPageContext' as const;

export interface BlockedScreenContext {
  blockedDomain: string;
  error: string;
  origin: string | null;
  displayOrigin: string;
}

export interface SubmitBlockedDomainRequestMessageInput {
  domain: string;
  reason: string;
  origin?: string | null | undefined;
  error?: string | null | undefined;
}

export interface SubmitBlockedDomainRequestMessage {
  action: typeof SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION;
  domain: string;
  reason: string;
  origin?: string | undefined;
  error?: string | undefined;
}

export interface GetRecentBlockedDomainRequestStatusMessage {
  action: typeof GET_RECENT_BLOCKED_DOMAIN_REQUEST_STATUS_ACTION;
  domain: string;
}

export interface GetBlockedPageContextMessage {
  action: typeof GET_BLOCKED_PAGE_CONTEXT_ACTION;
  domain: string;
}

export interface BlockedMonitorNavigation {
  frameId: number;
  url: string;
}

function getSearchParam(params: URLSearchParams, key: string): string | null {
  const value = params.get(key);
  return value && value.trim().length > 0 ? value : null;
}

function extractDomainFromUrl(rawUrl: string | null): string | null {
  if (!rawUrl) return null;
  try {
    return new URL(rawUrl).hostname || null;
  } catch {
    return null;
  }
}

function normalizeOptionalValue(value: string | null | undefined): string | undefined {
  const normalized = value?.trim();
  return normalized && normalized.length > 0 ? normalized : undefined;
}

function isOptionalString(value: unknown): boolean {
  return value === undefined || typeof value === 'string';
}

export function buildBlockedScreenContextFromSearch(search: string): BlockedScreenContext {
  const params = new URLSearchParams(search);
  const blockedUrl = getSearchParam(params, 'blockedUrl');
  const queryDomain = getSearchParam(params, 'domain');
  const origin = getSearchParam(params, 'origin');

  return {
    blockedDomain: queryDomain ?? extractDomainFromUrl(blockedUrl) ?? 'unknown domain',
    error: getSearchParam(params, 'error') ?? 'network/policy block',
    origin,
    displayOrigin: origin ?? t('popupUnknownOrigin'),
  };
}

export function buildSubmitBlockedDomainRequestMessage(
  input: SubmitBlockedDomainRequestMessageInput
): SubmitBlockedDomainRequestMessage {
  const message: SubmitBlockedDomainRequestMessage = {
    action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
    domain: input.domain,
    reason: input.reason,
  };

  const origin = normalizeOptionalValue(input.origin);
  if (origin) {
    message.origin = origin;
  }

  const error = normalizeOptionalValue(input.error);
  if (error) {
    message.error = error;
  }

  return message;
}

export function buildGetRecentBlockedDomainRequestStatusMessage(
  domain: string
): GetRecentBlockedDomainRequestStatusMessage {
  return {
    action: GET_RECENT_BLOCKED_DOMAIN_REQUEST_STATUS_ACTION,
    domain,
  };
}

export function buildGetBlockedPageContextMessage(domain: string): GetBlockedPageContextMessage {
  return {
    action: GET_BLOCKED_PAGE_CONTEXT_ACTION,
    domain,
  };
}

export function isSubmitBlockedDomainRequestMessage(
  message: unknown
): message is SubmitBlockedDomainRequestMessage {
  const record = message as Partial<SubmitBlockedDomainRequestMessage> | null;
  return (
    typeof record === 'object' &&
    record !== null &&
    record.action === SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION &&
    typeof record.domain === 'string' &&
    typeof record.reason === 'string' &&
    isOptionalString(record.origin) &&
    isOptionalString(record.error)
  );
}

export function isGetRecentBlockedDomainRequestStatusMessage(
  message: unknown
): message is GetRecentBlockedDomainRequestStatusMessage {
  const record = message as Partial<GetRecentBlockedDomainRequestStatusMessage> | null;
  return (
    typeof record === 'object' &&
    record !== null &&
    record.action === GET_RECENT_BLOCKED_DOMAIN_REQUEST_STATUS_ACTION &&
    typeof record.domain === 'string'
  );
}

export function isGetBlockedPageContextMessage(
  message: unknown
): message is GetBlockedPageContextMessage {
  const record = message as Partial<GetBlockedPageContextMessage> | null;
  return (
    typeof record === 'object' &&
    record !== null &&
    record.action === GET_BLOCKED_PAGE_CONTEXT_ACTION &&
    typeof record.domain === 'string'
  );
}

export function shouldClearBlockedMonitorStateOnNavigate(
  navigation: BlockedMonitorNavigation,
  blockedScreenUrl: string
): boolean {
  if (navigation.frameId !== 0) {
    return false;
  }

  try {
    const target = new URL(navigation.url);
    const blockedScreen = new URL(blockedScreenUrl);
    return target.origin !== blockedScreen.origin || target.pathname !== blockedScreen.pathname;
  } catch {
    return true;
  }
}
