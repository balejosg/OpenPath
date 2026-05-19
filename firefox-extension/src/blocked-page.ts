import {
  buildBlockedScreenContextFromSearch,
  buildGetBlockedPageContextMessage,
  buildGetRecentBlockedDomainRequestStatusMessage,
  buildSubmitBlockedDomainRequestMessage,
} from './lib/blocked-screen-contract.js';
import { buildBlockedDomainSubmitBody } from './lib/blocked-request.js';
import {
  getRequestApiEndpoints,
  loadRequestConfigWithNativeFallback,
} from './lib/config-storage.js';
import { loadNativeRequestConfigWithSender } from './lib/config-storage-native.js';
import {
  startBrowsingActivityConsentRequest,
  type DataCollectionPermissionsApi,
} from './lib/data-collection-consent.js';
import { submitBlockedDomainRequest as submitBlockedDomainRequestViaApi } from './lib/request-api.js';
import { fetchWithFallback } from './lib/request-api.js';
import { localizeDocument, t } from './lib/i18n.js';

interface BlockedPageRuntime {
  sendMessage(message: unknown): Promise<unknown>;
}

interface CallbackRuntime {
  lastError?: { message?: string } | null;
  sendMessage(message: unknown, callback: (response: unknown) => void): void;
}

interface NativeRuntime {
  getManifest?: () => { version?: string };
  sendNativeMessage?: (hostName: string, message: unknown) => Promise<unknown>;
}

interface BrowserPermissionsGlobal {
  permissions?: Partial<DataCollectionPermissionsApi>;
}

type RequestStatusType = 'success' | 'error' | 'pending';

const RECENT_REQUEST_STATUS_TTL_MS = 120_000;
const BACKGROUND_REQUEST_STATUS_RESTORE_WINDOW_MS = 30_000;
const BACKGROUND_REQUEST_STATUS_RESTORE_INTERVAL_MS = 500;
const SUBMIT_REQUEST_TIMEOUT_MS = 15_000;
const REQUEST_STATUS_POLL_INTERVAL_MS = 1_000;
const REQUEST_STATUS_POLL_TIMEOUT_MS = 30_000;
const NATIVE_HOST_NAME = 'whitelist_native_host';
const NATIVE_POLICY_BLOCKED_ERROR = 'OPENPATH_NATIVE_POLICY_BLOCKED';

interface RequestStatusResult {
  success?: boolean;
  status?: 'pending' | 'approved' | 'rejected';
  domain?: string;
  error?: string;
}

function getElement(id: string): HTMLElement | null {
  return document.getElementById(id);
}

function setText(id: string, value: string): void {
  const el = getElement(id);
  if (!el) return;
  el.textContent = value;
}

function setFeedback(text: string): void {
  setText('copy-feedback', text);
}

function setRequestStatus(text: string, type?: RequestStatusType): void {
  const el = getElement('request-status');
  if (!el) return;
  el.textContent = text;
  el.classList.remove('success', 'error', 'pending');
  if (type) {
    el.classList.add(type);
  }
}

function buildRecentRequestStatusKey(domain: string): string {
  return `openpath:blocked-request-status:${encodeURIComponent(domain)}`;
}

function getSessionStorage(): Storage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

function clearRecentRequestStatus(domain: string): void {
  try {
    getSessionStorage()?.removeItem(buildRecentRequestStatusKey(domain));
  } catch {
    // Best effort only; the visible page state is still updated directly.
  }
}

function saveRecentRequestStatus(domain: string, text: string, type: RequestStatusType): void {
  try {
    getSessionStorage()?.setItem(
      buildRecentRequestStatusKey(domain),
      JSON.stringify({
        storedAt: Date.now(),
        text,
        type,
      })
    );
  } catch {
    // Best effort only; the visible page state is still updated directly.
  }
}

function showSubmittedRequestStatus(domain: string): void {
  const message = t('blockedRequestSubmittedSuccess');
  setRequestStatus(message, 'success');
  saveRecentRequestStatus(domain, message, 'success');
}

function restoreRecentRequestStatus(domain: string): void {
  const storage = getSessionStorage();
  if (!storage) return;

  const key = buildRecentRequestStatusKey(domain);
  try {
    const rawStatus = storage.getItem(key);
    if (!rawStatus) return;

    const status = JSON.parse(rawStatus) as {
      storedAt?: unknown;
      text?: unknown;
      type?: unknown;
    };
    if (
      typeof status.storedAt !== 'number' ||
      Date.now() - status.storedAt > RECENT_REQUEST_STATUS_TTL_MS ||
      typeof status.text !== 'string' ||
      !['success', 'error', 'pending'].includes(String(status.type))
    ) {
      storage.removeItem(key);
      return;
    }

    setRequestStatus(status.text, status.type as RequestStatusType);
  } catch {
    storage.removeItem(key);
  }
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    window.setTimeout(resolve, ms);
  });
}

function getBrowserRuntime(): BlockedPageRuntime | null {
  const globalWithRuntime = globalThis as {
    browser?: { runtime?: Partial<BlockedPageRuntime> };
    chrome?: { runtime?: Partial<CallbackRuntime> };
  };

  const runtime = globalWithRuntime.browser?.runtime;
  if (typeof runtime?.sendMessage === 'function') {
    return { sendMessage: runtime.sendMessage.bind(runtime) };
  }

  const callbackRuntime = globalWithRuntime.chrome?.runtime;
  if (typeof callbackRuntime?.sendMessage === 'function') {
    const sendMessage = callbackRuntime.sendMessage.bind(callbackRuntime);
    return {
      sendMessage: (message: unknown) =>
        new Promise((resolve, reject) => {
          try {
            sendMessage(message, (response: unknown) => {
              const lastError = callbackRuntime.lastError;
              if (lastError) {
                reject(new Error(lastError.message ?? 'runtime.sendMessage failed'));
                return;
              }

              resolve(response);
            });
          } catch (error) {
            reject(error instanceof Error ? error : new Error(String(error)));
          }
        }),
    };
  }

  return null;
}

function getNativeRuntime(): NativeRuntime | null {
  const globalWithRuntime = globalThis as {
    browser?: { runtime?: NativeRuntime };
  };
  const runtime = globalWithRuntime.browser?.runtime;
  if (typeof runtime?.sendNativeMessage === 'function') {
    return runtime;
  }

  return null;
}

function getDataCollectionPermissionsApi(): DataCollectionPermissionsApi | null {
  const globalWithPermissions = globalThis as {
    browser?: BrowserPermissionsGlobal;
  };
  const permissions = globalWithPermissions.browser?.permissions;
  if (typeof permissions?.contains === 'function') {
    return {
      contains: permissions.contains.bind(permissions),
    };
  }

  return null;
}

async function copyText(text: string): Promise<boolean> {
  if (!text) {
    return false;
  }

  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

function buildFallbackMessage(error: unknown): string {
  void error;
  return t('blockedFallbackMessage', '');
}

function formatUnknownError(error: unknown, fallback: string): string {
  if (typeof error === 'string' && error.trim().length > 0) {
    return error;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return fallback;
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  let timeoutId: ReturnType<typeof setTimeout> | null = null;
  const timeoutPromise = new Promise<never>((_resolve, reject) => {
    timeoutId = setTimeout(() => {
      reject(new Error(message));
    }, timeoutMs);
  });

  return Promise.race([promise, timeoutPromise]).finally(() => {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
    }
  });
}

async function submitUnblockRequest(input: {
  domain: string;
  reason: string;
  origin: string | null;
  error: string;
}): Promise<unknown> {
  const nativeRuntime = getNativeRuntime();
  if (nativeRuntime?.sendNativeMessage) {
    return withTimeout(
      submitUnblockRequestWithNativeRuntime(input, nativeRuntime),
      SUBMIT_REQUEST_TIMEOUT_MS,
      t('blockedRequestTimeout')
    );
  }

  const runtime = getBrowserRuntime();
  if (runtime) {
    return withTimeout(
      runtime.sendMessage(buildSubmitBlockedDomainRequestMessage(input)),
      SUBMIT_REQUEST_TIMEOUT_MS,
      t('blockedExtensionTimeout')
    );
  }

  return {
    success: false,
    error: t('blockedExtensionUnavailable'),
  };
}

async function getBlockedPageOriginalUrl(domain: string): Promise<string | null> {
  const runtime = getBrowserRuntime();
  if (!runtime) {
    return null;
  }

  try {
    const response = (await runtime.sendMessage(buildGetBlockedPageContextMessage(domain))) as {
      success?: boolean;
      context?: { originalUrl?: unknown } | null;
    } | null;
    return response?.success === true && typeof response.context?.originalUrl === 'string'
      ? response.context.originalUrl
      : null;
  } catch {
    return null;
  }
}

function getHostnameFromUrl(url: string | null): string | null {
  if (!url) {
    return null;
  }

  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return null;
  }
}

async function pollRequestStatus(requestId: string): Promise<RequestStatusResult> {
  const nativeRuntime = getNativeRuntime();
  const sendNativeMessage = (message: unknown): Promise<unknown> =>
    nativeRuntime?.sendNativeMessage?.(NATIVE_HOST_NAME, message) ??
    Promise.reject(new Error('Native messaging unavailable'));
  const nativeFallback = nativeRuntime?.sendNativeMessage
    ? await loadNativeRequestConfigWithSender(sendNativeMessage)
    : {};
  const config = await loadRequestConfigWithNativeFallback(nativeFallback);
  const endpoints = getRequestApiEndpoints({
    ...config,
    debugMode: false,
    sharedSecret: '',
  });
  if (!config.enableRequests || endpoints.length === 0) {
    return { success: false, error: t('blockedRequestStatusConfigIncomplete') };
  }

  const expiresAt = Date.now() + REQUEST_STATUS_POLL_TIMEOUT_MS;
  do {
    const response = await fetchWithFallback(
      endpoints,
      `/api/requests/status/${encodeURIComponent(requestId)}`,
      { method: 'GET' },
      config.requestTimeout
    );
    const payload = (await response.json().catch(() => ({}))) as RequestStatusResult;
    if (!response.ok || payload.success === false) {
      return {
        success: false,
        error: payload.error ?? t('blockedRequestStatusFailed', response.status.toString()),
      };
    }

    if (payload.status === 'approved' || payload.status === 'rejected') {
      return {
        success: true,
        status: payload.status,
        ...(payload.domain ? { domain: payload.domain } : {}),
      };
    }

    if (Date.now() >= expiresAt) {
      break;
    }

    await delay(REQUEST_STATUS_POLL_INTERVAL_MS);
  } while (Date.now() < expiresAt);

  return {
    success: false,
    error: t('blockedRequestStillPendingRetry'),
  };
}

async function refreshAndVerifyLocalAccess(input: {
  originalUrl: string | null;
  approvedDomain: string;
}): Promise<{ success: boolean; error?: string }> {
  const runtime = getBrowserRuntime();
  if (!runtime) {
    return { success: false, error: t('blockedPermissionsExtensionUnavailable') };
  }

  const originalHost = getHostnameFromUrl(input.originalUrl);
  const approvedDomain = input.approvedDomain.trim().toLowerCase();
  const domains = Array.from(new Set([originalHost, approvedDomain].filter(Boolean))) as string[];
  const updateDomains = approvedDomain ? [approvedDomain] : domains;

  const update = (await runtime.sendMessage({
    action: 'triggerWhitelistUpdate',
    domains: updateDomains,
  })) as {
    success?: boolean;
    error?: unknown;
  } | null;
  if (update?.success !== true) {
    return {
      success: false,
      error: formatUnknownError(update?.error, t('blockedLocalAllowlistUpdateFailed')),
    };
  }

  const verify = (await runtime.sendMessage({ action: 'verifyDomains', domains })) as {
    success?: boolean;
    results?: { domain?: string; inWhitelist?: boolean }[];
    error?: unknown;
  } | null;
  if (verify?.success !== true) {
    return {
      success: false,
      error: formatUnknownError(verify?.error, t('blockedLocalAllowlistVerifyFailed')),
    };
  }

  const verified = domains.some((domain) =>
    verify.results?.some((result) => result.domain === domain && result.inWhitelist === true)
  );
  return verified
    ? { success: true }
    : { success: false, error: t('blockedLocalAllowlistStillBlocked') };
}

async function submitUnblockRequestWithNativeRuntime(
  input: {
    domain: string;
    reason: string;
    origin: string | null;
    error: string;
  },
  nativeRuntime: NativeRuntime
): Promise<unknown> {
  const submitInput = {
    domain: input.domain,
    reason: input.reason,
    ...(input.origin !== null ? { origin: input.origin } : {}),
    error: input.error,
  };

  const sendNativeMessage = (message: unknown): Promise<unknown> =>
    nativeRuntime.sendNativeMessage?.(NATIVE_HOST_NAME, message) ??
    Promise.reject(new Error('Native messaging unavailable'));

  return submitBlockedDomainRequestViaApi(submitInput, {
    buildBlockedDomainSubmitBody,
    getClientVersion: () => nativeRuntime.getManifest?.().version ?? 'unknown',
    getRequestApiEndpoints: (config) =>
      getRequestApiEndpoints({
        ...config,
        debugMode: false,
        sharedSecret: '',
      }),
    loadRequestConfig: async () =>
      loadRequestConfigWithNativeFallback(
        await loadNativeRequestConfigWithSender(sendNativeMessage)
      ),
    sendNativeMessage,
  });
}

async function restoreRecentRequestStatusFromBackground(domain: string): Promise<void> {
  const runtime = getBrowserRuntime();
  if (!runtime) {
    return;
  }

  const expiresAt = Date.now() + BACKGROUND_REQUEST_STATUS_RESTORE_WINDOW_MS;
  do {
    const response = (await runtime.sendMessage(
      buildGetRecentBlockedDomainRequestStatusMessage(domain)
    )) as { success?: boolean; request?: { success?: boolean } | null } | null;

    if (response?.success === true && response.request?.success === true) {
      showSubmittedRequestStatus(domain);
      return;
    }

    if (Date.now() >= expiresAt) {
      return;
    }

    await delay(BACKGROUND_REQUEST_STATUS_RESTORE_INTERVAL_MS);
  } while (Date.now() < expiresAt);
}

export function main(): void {
  localizeDocument();
  const context = buildBlockedScreenContextFromSearch(window.location.search);

  setText('blocked-domain', context.blockedDomain);
  setText('blocked-error', context.error);
  setText('blocked-origin', context.displayOrigin);

  getElement('go-back')?.addEventListener('click', () => {
    if (window.history.length > 1) {
      window.history.back();
      return;
    }

    window.location.replace('about:blank');
  });

  getElement('copy-domain')?.addEventListener('click', () => {
    void (async (): Promise<void> => {
      const ok = await copyText(context.blockedDomain);
      setFeedback(ok ? t('blockedDomainCopied') : t('blockedDomainCopyFailed'));
    })();
  });

  const reasonInput = getElement('request-reason') as HTMLInputElement | null;
  const submitBtn = getElement('submit-unblock-request') as HTMLButtonElement | null;
  if (!reasonInput || !submitBtn) {
    return;
  }

  restoreRecentRequestStatus(context.blockedDomain);
  if (context.error === NATIVE_POLICY_BLOCKED_ERROR) {
    void restoreRecentRequestStatusFromBackground(context.blockedDomain);
  }

  submitBtn.addEventListener('click', () => {
    void (async (): Promise<void> => {
      const reason = reasonInput.value.trim();
      if (reason.length < 3) {
        setRequestStatus(t('blockedBriefReasonRequired'), 'error');
        return;
      }

      const consentPromise = startBrowsingActivityConsentRequest(getDataCollectionPermissionsApi());

      submitBtn.disabled = true;
      clearRecentRequestStatus(context.blockedDomain);
      setRequestStatus(t('blockedCheckingFirefoxPermission'), 'pending');

      try {
        const consent = await consentPromise;
        if (!consent.granted) {
          clearRecentRequestStatus(context.blockedDomain);
          setRequestStatus(consent.error, 'error');
          return;
        }

        setRequestStatus(t('blockedSendingRequest'), 'pending');
        const response = (await submitUnblockRequest({
          domain: context.blockedDomain,
          reason,
          origin: context.origin,
          error: context.error,
        })) as {
          success?: boolean;
          id?: unknown;
          status?: string;
          domain?: string;
          error?: unknown;
        } | null;
        if (response?.success === true) {
          if (typeof response.id !== 'string' || response.id.length === 0) {
            if (response.status === 'pending') {
              showSubmittedRequestStatus(context.blockedDomain);
              reasonInput.value = '';
              return;
            }

            clearRecentRequestStatus(context.blockedDomain);
            setRequestStatus(t('blockedRequestSentWithoutId'), 'error');
            return;
          }

          const originalUrl = await getBlockedPageOriginalUrl(context.blockedDomain);
          setRequestStatus(t('blockedWaitingApproval'), 'pending');
          saveRecentRequestStatus(context.blockedDomain, t('blockedWaitingApproval'), 'pending');
          const status = await pollRequestStatus(response.id);
          if (status.status === 'rejected') {
            clearRecentRequestStatus(context.blockedDomain);
            setRequestStatus(t('blockedRequestRejected'), 'error');
            return;
          }
          if (status.status !== 'approved') {
            clearRecentRequestStatus(context.blockedDomain);
            setRequestStatus(status.error ?? t('blockedRequestStillPending'), 'pending');
            return;
          }

          setRequestStatus(t('blockedRequestApprovedUpdating'), 'pending');
          const approvedDomain = status.domain ?? response.domain ?? context.blockedDomain;
          const localAccess = await refreshAndVerifyLocalAccess({
            originalUrl,
            approvedDomain,
          });
          if (!localAccess.success) {
            clearRecentRequestStatus(context.blockedDomain);
            setRequestStatus(localAccess.error ?? t('blockedLocalPermissionVerifyFailed'), 'error');
            return;
          }

          const destination = originalUrl ?? `https://${approvedDomain}/`;
          showSubmittedRequestStatus(context.blockedDomain);
          reasonInput.value = '';
          window.location.replace(destination);
          return;
        }

        clearRecentRequestStatus(context.blockedDomain);
        setRequestStatus(buildFallbackMessage(response?.error), 'error');
      } catch (requestError) {
        clearRecentRequestStatus(context.blockedDomain);
        setRequestStatus(buildFallbackMessage(requestError), 'error');
      } finally {
        submitBtn.disabled = false;
      }
    })();
  });
}

if (typeof document !== 'undefined' && typeof window !== 'undefined') {
  main();
}
