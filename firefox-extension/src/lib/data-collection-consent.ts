export const BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION = {
  data_collection: ['browsingActivity'],
} as const;

const CONSENT_DENIED_MESSAGE =
  'Se necesita el permiso de actividad de navegacion para enviar la solicitud de desbloqueo.';
const CONSENT_UNSUPPORTED_MESSAGE =
  'Esta version de Firefox no es compatible con el permiso de datos requerido para enviar solicitudes.';

export interface DataCollectionPermissionsApi {
  contains(payload: typeof BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION): Promise<boolean>;
  request(payload: typeof BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION): Promise<boolean>;
}

export type DataCollectionConsentResult = { granted: true } | { error: string; granted: false };

export async function ensureBrowsingActivityConsent(
  permissionsApi: DataCollectionPermissionsApi | null | undefined
): Promise<DataCollectionConsentResult> {
  if (
    !permissionsApi ||
    typeof permissionsApi.contains !== 'function' ||
    typeof permissionsApi.request !== 'function'
  ) {
    return {
      granted: false,
      error: CONSENT_UNSUPPORTED_MESSAGE,
    };
  }

  try {
    if (await permissionsApi.request(BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION)) {
      return { granted: true };
    }

    if (await permissionsApi.contains(BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION)) {
      return { granted: true };
    }

    return {
      granted: false,
      error: CONSENT_DENIED_MESSAGE,
    };
  } catch (error) {
    try {
      if (await permissionsApi.contains(BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION)) {
        return { granted: true };
      }
    } catch {
      // Keep the original request failure detail below.
    }

    const detail = error instanceof Error ? ` ${error.message}` : '';
    return {
      granted: false,
      error: `${CONSENT_UNSUPPORTED_MESSAGE}${detail}`,
    };
  }
}
