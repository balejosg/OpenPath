export interface SyncFirefoxAmoPolicyOptions {
  apiKey: string;
  apiSecret: string;
  addonId?: string;
  privacyPath?: string;
  amoBaseUrl?: string;
  fetchImpl?: typeof fetch;
}

export interface SyncFirefoxAmoPolicyResult {
  addonId: string;
  privacyPath: string;
  privacyPolicyPresent: boolean;
}

export function syncFirefoxAmoPolicy(
  options: SyncFirefoxAmoPolicyOptions
): Promise<SyncFirefoxAmoPolicyResult>;
