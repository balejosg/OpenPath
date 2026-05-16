export const BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION = {
  data_collection: ['browsingActivity'],
} as const;

const CONSENT_DENIED_MESSAGE =
  'El permiso de actividad de navegacion requerido no esta concedido. Actualiza o reinstala la extension gestionada de Firefox.';
const CONSENT_UNSUPPORTED_MESSAGE =
  'Esta version de Firefox no permite comprobar el permiso de datos requerido para enviar solicitudes.';

export interface DataCollectionPermissionsApi {
  contains(payload: typeof BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION): Promise<boolean>;
  request?(payload: typeof BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION): Promise<boolean>;
}

export type DataCollectionConsentResult = { granted: true } | { error: string; granted: false };

export function startBrowsingActivityConsentRequest(
  permissionsApi: DataCollectionPermissionsApi | null | undefined
): Promise<DataCollectionConsentResult> {
  if (!permissionsApi || typeof permissionsApi.contains !== 'function') {
    return Promise.resolve({
      granted: false,
      error: CONSENT_UNSUPPORTED_MESSAGE,
    });
  }

  try {
    return permissionsApi
      .contains(BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION)
      .then((granted) =>
        granted
          ? { granted: true as const }
          : {
              granted: false as const,
              error: CONSENT_DENIED_MESSAGE,
            }
      )
      .catch((error: unknown) => resolveBrowsingActivityConsentCheckFailure(error));
  } catch (error) {
    return Promise.resolve(resolveBrowsingActivityConsentCheckFailure(error));
  }
}

function resolveBrowsingActivityConsentCheckFailure(error: unknown): DataCollectionConsentResult {
  const detail = error instanceof Error ? ` ${error.message}` : '';
  return {
    granted: false,
    error: `${CONSENT_UNSUPPORTED_MESSAGE}${detail}`,
  };
}

export function ensureBrowsingActivityConsent(
  permissionsApi: DataCollectionPermissionsApi | null | undefined
): Promise<DataCollectionConsentResult> {
  return startBrowsingActivityConsentRequest(permissionsApi);
}
