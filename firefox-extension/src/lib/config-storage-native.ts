import { getErrorMessage, logger } from './logger.js';
import { normalizeApiUrl, normalizeApiUrlList } from './config-storage-shared.js';
import type { RequestConfig } from './config-storage.js';

const NATIVE_HOST_NAME = 'whitelist_native_host';

interface NativeHostConfigResponse {
  success: boolean;
  action?: string;
  apiUrl?: string;
  requestApiUrl?: string;
  fallbackApiUrls?: string[];
  error?: string;
}

export type NativeConfigMessageSender = (message: { action: 'get-config' }) => Promise<unknown>;

function normalizeNativeRequestConfigResponse(
  response: NativeHostConfigResponse
): Partial<RequestConfig> {
  if (!response.success) {
    logger.warn('[Config] Native host config unavailable', {
      error: response.error ?? 'Unknown native host error',
    });
    return {};
  }

  const primaryApiUrl = response.requestApiUrl ?? response.apiUrl ?? '';
  const fallbackApiUrls = Array.isArray(response.fallbackApiUrls)
    ? response.fallbackApiUrls.map((url) => url.trim()).filter((url) => url.length > 0)
    : [];

  if (primaryApiUrl.trim() === '' && fallbackApiUrls.length === 0) {
    return {};
  }

  return {
    requestApiUrl: normalizeApiUrl(primaryApiUrl),
    fallbackApiUrls: normalizeApiUrlList(fallbackApiUrls),
    enableRequests: true,
  };
}

export async function loadNativeRequestConfigWithSender(
  sendNativeMessage: NativeConfigMessageSender
): Promise<Partial<RequestConfig>> {
  try {
    const response = (await sendNativeMessage({
      action: 'get-config',
    })) as NativeHostConfigResponse;

    return normalizeNativeRequestConfigResponse(response);
  } catch (error) {
    logger.warn('[Config] Failed to load native config fallback', {
      error: getErrorMessage(error),
    });
    return {};
  }
}

export async function loadNativeRequestConfig(): Promise<Partial<RequestConfig>> {
  return loadNativeRequestConfigWithSender((message) =>
    browser.runtime.sendNativeMessage(NATIVE_HOST_NAME, message)
  );
}
