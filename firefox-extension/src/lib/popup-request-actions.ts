import type { BlockedDomainsData } from './popup-state.js';
import {
  BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION,
  type DataCollectionConsentResult,
} from './data-collection-consent.js';

export interface SubmitRequestResult {
  success: boolean;
  id?: string;
  domain?: string;
  status?: 'pending' | 'approved' | 'rejected';
  groupId?: string;
  source?: string;
  error?: string;
}

export function buildRequestDomainOptions(
  blockedDomainsData: BlockedDomainsData
): { hostname: string; origin: string }[] {
  return Object.keys(blockedDomainsData)
    .sort()
    .flatMap((hostname) => {
      const data = blockedDomainsData[hostname];
      if (!data) {
        return [];
      }

      return [
        {
          hostname,
          origin: data.origin ?? 'desconocido',
        },
      ];
    });
}

export function shouldEnableSubmitRequest(input: {
  hasSelectedDomain: boolean;
  hasValidReason: boolean;
  isNativeAvailable: boolean;
  isRequestConfigured: boolean;
}): boolean {
  return (
    input.hasSelectedDomain &&
    input.hasValidReason &&
    input.isNativeAvailable &&
    input.isRequestConfigured
  );
}

export async function submitPopupDomainRequest(input: {
  blockedDomainsData: BlockedDomainsData;
  buildSubmitMessage: (payload: {
    domain: string;
    error?: string;
    origin?: string;
    reason: string;
  }) => unknown;
  domain: string;
  isNativeAvailable: boolean;
  isRequestConfigured: boolean;
  reason: string;
  requestBrowsingActivityConsent?: (
    payload: typeof BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION
  ) => Promise<DataCollectionConsentResult>;
  sendMessage: (message: unknown) => Promise<unknown>;
}): Promise<{
  errorMessage?: string;
  shouldReloadDomainStatuses: boolean;
  shouldResetForm: boolean;
  success: boolean;
  userMessage: string;
}> {
  const reason = input.reason.trim();
  const selectedInfo = input.blockedDomainsData[input.domain];

  if (!input.domain || reason.length < 3) {
    return {
      success: false,
      shouldReloadDomainStatuses: false,
      shouldResetForm: false,
      userMessage: '❌ Selecciona un dominio y escribe un motivo',
    };
  }

  if (!input.isRequestConfigured || !input.isNativeAvailable) {
    return {
      success: false,
      shouldReloadDomainStatuses: false,
      shouldResetForm: false,
      userMessage: '❌ Configuración incompleta para solicitar dominios',
    };
  }

  try {
    const consent = input.requestBrowsingActivityConsent
      ? await input.requestBrowsingActivityConsent(BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION)
      : {
          granted: false as const,
          error:
            'Esta version de Firefox no es compatible con el permiso de datos requerido para enviar solicitudes.',
        };
    if (!consent.granted) {
      return {
        success: false,
        errorMessage: consent.error,
        shouldReloadDomainStatuses: false,
        shouldResetForm: false,
        userMessage: `❌ ${consent.error}`,
      };
    }

    const payload = (await input.sendMessage(
      input.buildSubmitMessage({
        domain: input.domain,
        reason,
        ...(selectedInfo?.origin !== undefined && selectedInfo.origin !== null
          ? { origin: selectedInfo.origin }
          : {}),
        ...(selectedInfo?.errors?.[0] !== undefined ? { error: selectedInfo.errors[0] } : {}),
      })
    )) as Partial<SubmitRequestResult>;

    if (payload.success === true && payload.id) {
      return {
        success: true,
        shouldReloadDomainStatuses: true,
        shouldResetForm: true,
        userMessage: `✅ Solicitud enviada para ${input.domain}. Queda pendiente de aprobación.`,
      };
    }

    const errorMessage = payload.error ?? 'Error desconocido';
    return {
      success: false,
      errorMessage,
      shouldReloadDomainStatuses: false,
      shouldResetForm: false,
      userMessage: `❌ ${errorMessage}`,
    };
  } catch (error) {
    const err = error instanceof Error ? error : new Error(String(error));
    const errorMessage =
      err.name === 'AbortError'
        ? 'Timeout - servidor no responde'
        : err.message || 'Error de conexión';

    return {
      success: false,
      errorMessage,
      shouldReloadDomainStatuses: false,
      shouldResetForm: false,
      userMessage: `❌ ${errorMessage}`,
    };
  }
}

export async function retryPopupDomainLocalUpdate(input: {
  hostname: string;
  sendMessage: (message: unknown) => Promise<unknown>;
  tabId: number | null;
}): Promise<{ success: boolean }> {
  if (input.tabId === null) {
    return { success: false };
  }

  const response = await input.sendMessage({
    action: 'retryLocalUpdate',
    tabId: input.tabId,
    hostname: input.hostname,
  });

  return response as { success: boolean };
}
