import { t } from './i18n.js';

export const BROWSING_ACTIVITY_DATA_COLLECTION_PERMISSION = {
  data_collection: ['browsingActivity'],
} as const;

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
      error: t('popupFirefoxDataPermissionUnsupported'),
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
              error: t('popupFirefoxDataPermissionUnsupported'),
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
    error: `${t('popupFirefoxDataPermissionUnsupported')}${detail}`,
  };
}

export function ensureBrowsingActivityConsent(
  permissionsApi: DataCollectionPermissionsApi | null | undefined
): Promise<DataCollectionConsentResult> {
  return startBrowsingActivityConsentRequest(permissionsApi);
}
