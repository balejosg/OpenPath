import type { RequestConfig } from './config-storage.types.js';

export const DEFAULT_REQUEST_CONFIG: RequestConfig = {
  requestApiUrl: '',
  fallbackApiUrls: [],
  requestTimeout: 10000,
  enableRequests: true,
  sharedSecret: '',
  debugMode: false,
  defaultGroup: 'informatica-3',
};

export function normalizeApiUrl(url: string): string {
  return url.trim().replace(/\/+$/, '');
}

export function normalizeApiUrlList(urls: string[]): string[] {
  return urls.map(normalizeApiUrl).filter((url) => url.length > 0);
}

export function sanitizeRequestConfigForSave(newConfig: Partial<RequestConfig>): RequestConfig {
  return {
    ...DEFAULT_REQUEST_CONFIG,
    ...newConfig,
    requestApiUrl:
      typeof newConfig.requestApiUrl === 'string'
        ? normalizeApiUrl(newConfig.requestApiUrl)
        : DEFAULT_REQUEST_CONFIG.requestApiUrl,
    fallbackApiUrls: Array.isArray(newConfig.fallbackApiUrls)
      ? normalizeApiUrlList(newConfig.fallbackApiUrls)
      : DEFAULT_REQUEST_CONFIG.fallbackApiUrls,
  };
}
