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
