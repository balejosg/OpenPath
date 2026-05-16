import {
  buildBlockedScreenContextFromSearch,
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
const NATIVE_HOST_NAME = 'whitelist_native_host';
const NATIVE_POLICY_BLOCKED_ERROR = 'OPENPATH_NATIVE_POLICY_BLOCKED';
const REQUEST_SUBMITTED_SUCCESS_TEXT = 'Solicitud enviada. Quedara pendiente hasta que la revisen.';

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
  setRequestStatus(REQUEST_SUBMITTED_SUCCESS_TEXT, 'success');
  saveRecentRequestStatus(domain, REQUEST_SUBMITTED_SUCCESS_TEXT, 'success');
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
  const detail =
    typeof error === 'string' ? ` ${error}` : error instanceof Error ? ` ${error.message}` : '';
  return `No se pudo enviar la solicitud.${detail} Copia el dominio y avisa a tu profesor.`;
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
  const runtime = getBrowserRuntime();
  if (runtime) {
    return withTimeout(
      runtime.sendMessage(buildSubmitBlockedDomainRequestMessage(input)),
      SUBMIT_REQUEST_TIMEOUT_MS,
      'Tiempo de espera agotado al contactar con la extension.'
    );
  }

  const nativeRuntime = getNativeRuntime();
  if (nativeRuntime?.sendNativeMessage) {
    const submitInput = {
      domain: input.domain,
      reason: input.reason,
      ...(input.origin !== null ? { origin: input.origin } : {}),
      error: input.error,
    };
    return withTimeout(
      submitBlockedDomainRequestViaApi(submitInput, {
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
            await loadNativeRequestConfigWithSender(
              (message) =>
                nativeRuntime.sendNativeMessage?.(NATIVE_HOST_NAME, message) ??
                Promise.reject(new Error('Native messaging unavailable'))
            )
          ),
        sendNativeMessage: (message) =>
          nativeRuntime.sendNativeMessage?.(NATIVE_HOST_NAME, message) ??
          Promise.reject(new Error('Native messaging unavailable')),
      }),
      SUBMIT_REQUEST_TIMEOUT_MS,
      'Tiempo de espera agotado al enviar la solicitud.'
    );
  }

  return {
    success: false,
    error: 'La extension no esta disponible en esta pagina.',
  };
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
      setFeedback(ok ? 'Dominio copiado al portapapeles.' : 'No se pudo copiar el dominio.');
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
        setRequestStatus('Escribe una breve razon para la solicitud.', 'error');
        return;
      }

      const consentPromise = startBrowsingActivityConsentRequest(getDataCollectionPermissionsApi());

      submitBtn.disabled = true;
      clearRecentRequestStatus(context.blockedDomain);
      setRequestStatus('Comprobando permiso de Firefox...', 'pending');

      try {
        const consent = await consentPromise;
        if (!consent.granted) {
          clearRecentRequestStatus(context.blockedDomain);
          setRequestStatus(consent.error, 'error');
          return;
        }

        setRequestStatus('Enviando solicitud...', 'pending');
        const response = (await submitUnblockRequest({
          domain: context.blockedDomain,
          reason,
          origin: context.origin,
          error: context.error,
        })) as { success?: boolean; error?: unknown } | null;
        if (response?.success === true) {
          showSubmittedRequestStatus(context.blockedDomain);
          reasonInput.value = '';
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
