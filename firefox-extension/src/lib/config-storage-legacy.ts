import { getErrorMessage, logger } from './logger.js';
import { normalizeApiUrl, normalizeApiUrlList } from './config-storage-shared.js';
import type { RequestConfig } from './config-storage.types.js';

function readStoredConfig(source: unknown): {
  config?: Partial<RequestConfig>;
  hasConfig: boolean;
} {
  const maybeRecord =
    source !== null && typeof source === 'object' ? (source as Record<string, unknown>) : null;
  if (!maybeRecord || !('config' in maybeRecord)) {
    return { hasConfig: false };
  }

  const candidate = maybeRecord.config;
  if (candidate === null || typeof candidate !== 'object') {
    return { hasConfig: true };
  }

  return {
    config: candidate as Partial<RequestConfig>,
    hasConfig: true,
  };
}

function sanitizeStoredRequestConfig(
  incoming: Partial<RequestConfig> | undefined,
  nativeFallback: Partial<RequestConfig>
): Partial<RequestConfig> {
  if (!incoming) {
    return {};
  }

  const sanitized: Partial<RequestConfig> = { ...incoming };
  const hasNativeEndpoint =
    (typeof nativeFallback.requestApiUrl === 'string' && nativeFallback.requestApiUrl.length > 0) ||
    (nativeFallback.fallbackApiUrls?.length ?? 0) > 0;

  if (hasNativeEndpoint) {
    delete sanitized.requestApiUrl;
    delete sanitized.fallbackApiUrls;
  }

  if (typeof incoming.requestApiUrl === 'string') {
    const normalizedRequestApiUrl = normalizeApiUrl(incoming.requestApiUrl);
    if (hasNativeEndpoint) {
      delete sanitized.requestApiUrl;
    } else if (normalizedRequestApiUrl.length > 0) {
      sanitized.requestApiUrl = normalizedRequestApiUrl;
    } else if (nativeFallback.requestApiUrl) {
      delete sanitized.requestApiUrl;
    } else {
      sanitized.requestApiUrl = '';
    }
  }

  if (Array.isArray(incoming.fallbackApiUrls)) {
    const normalizedFallbackApiUrls = normalizeApiUrlList(incoming.fallbackApiUrls);
    if (hasNativeEndpoint) {
      delete sanitized.fallbackApiUrls;
    } else if (normalizedFallbackApiUrls.length > 0) {
      sanitized.fallbackApiUrls = normalizedFallbackApiUrls;
    } else if ((nativeFallback.fallbackApiUrls?.length ?? 0) > 0) {
      delete sanitized.fallbackApiUrls;
    } else {
      sanitized.fallbackApiUrls = [];
    }
  }

  if (hasNativeEndpoint && incoming.enableRequests === false) {
    delete sanitized.enableRequests;
  }

  return sanitized;
}

export async function loadLegacyStoredRequestConfig(
  nativeFallback: Partial<RequestConfig>
): Promise<Partial<RequestConfig>> {
  let syncStored: Partial<RequestConfig> | undefined;

  try {
    const localStored = readStoredConfig(await browser.storage.local.get('config'));
    if (localStored.hasConfig) {
      return sanitizeStoredRequestConfig(localStored.config, nativeFallback);
    }
  } catch (error) {
    logger.warn('[Config] Failed to load local stored config', {
      error: getErrorMessage(error),
    });
  }

  try {
    const syncStoredRecord = readStoredConfig(await browser.storage.sync.get('config'));
    syncStored = syncStoredRecord.config;
    return sanitizeStoredRequestConfig(syncStored, nativeFallback);
  } catch (error) {
    logger.warn('[Config] Failed to load sync stored config', {
      error: getErrorMessage(error),
    });
    return {};
  }
}
