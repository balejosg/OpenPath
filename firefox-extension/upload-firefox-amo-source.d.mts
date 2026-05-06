export function parseAmoThrottleDelaySeconds(body: unknown): number | null;

export interface UploadFirefoxAmoSourceOptions {
  apiKey: string;
  apiSecret: string;
  addonId?: string;
  versionId?: string;
  version?: string;
  sourceArchive?: string;
  metadataPath?: string;
  amoBaseUrl?: string;
  fetchImpl?: typeof fetch;
  sourceOnly?: boolean;
  metadataOnly?: boolean;
  verify?: boolean;
  waitForThrottle?: boolean;
  maxThrottleWaitSeconds?: number;
  retryBufferSeconds?: number;
  maxRetries?: number;
  sleepImpl?: (milliseconds: number) => Promise<void>;
  stdout?: { write: (chunk: string) => unknown };
}

export interface UploadFirefoxAmoSourceResult {
  addonId: string;
  versionId: string;
  version: string;
  sourceArchive: string;
  source: unknown;
  metadata: unknown;
  verification: unknown;
}

export function uploadFirefoxAmoSource(
  options: UploadFirefoxAmoSourceOptions
): Promise<UploadFirefoxAmoSourceResult>;
