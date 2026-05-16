import { getErrorMessage, logger } from './logger.js';
import { loadLegacyStoredRequestConfig } from './config-storage-legacy.js';
import { loadNativeRequestConfig } from './config-storage-native.js';
import { DEFAULT_REQUEST_CONFIG, sanitizeRequestConfigForSave } from './config-storage-shared.js';

export interface RequestConfig {
  requestApiUrl: string;
  fallbackApiUrls: string[];
  requestTimeout: number;
  enableRequests: boolean;
  // Deprecated legacy fallback; requests now authenticate with the machine token from the host.
  sharedSecret: string;
  debugMode: boolean;

  // Deprecated: the server now resolves group by calendar/default group.
  defaultGroup?: string;
}

export { DEFAULT_REQUEST_CONFIG };

export function getRequestApiEndpoints(config: RequestConfig): string[] {
  return [config.requestApiUrl, ...config.fallbackApiUrls].filter((url) => url.length > 0);
}

export function hasValidRequestConfig(config: RequestConfig): boolean {
  return config.enableRequests && getRequestApiEndpoints(config).length > 0;
}

export async function loadRequestConfigWithNativeFallback(
  nativeFallback: Partial<RequestConfig>
): Promise<RequestConfig> {
  const storedConfig = await loadLegacyStoredRequestConfig(nativeFallback);
  const mergedConfig = {
    ...DEFAULT_REQUEST_CONFIG,
    ...nativeFallback,
    ...storedConfig,
  };

  const nativeEndpoints = getRequestApiEndpoints({
    ...DEFAULT_REQUEST_CONFIG,
    ...nativeFallback,
  });

  if (nativeEndpoints.length === 0) {
    return mergedConfig;
  }

  return {
    ...mergedConfig,
    requestApiUrl: nativeFallback.requestApiUrl ?? DEFAULT_REQUEST_CONFIG.requestApiUrl,
    fallbackApiUrls: nativeFallback.fallbackApiUrls ?? DEFAULT_REQUEST_CONFIG.fallbackApiUrls,
    enableRequests: true,
  };
}

export async function loadRequestConfig(): Promise<RequestConfig> {
  const nativeFallback = await loadNativeRequestConfig();
  return loadRequestConfigWithNativeFallback(nativeFallback);
}

export async function saveRequestConfig(newConfig: Partial<RequestConfig>): Promise<void> {
  try {
    await browser.storage.local.set({ config: sanitizeRequestConfigForSave(newConfig) });
  } catch (error) {
    logger.error('[Config] Failed to save config', {
      error: getErrorMessage(error),
    });
    throw error;
  }
}
