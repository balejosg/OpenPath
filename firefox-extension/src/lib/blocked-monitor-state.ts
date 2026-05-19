export interface BlockedDomainData {
  errors: Set<string>;
  origin: string | null;
  timestamp: number;
}

export interface SerializedBlockedDomain {
  errors: string[];
  origin: string | null;
  timestamp: number;
}

export interface DomainStatusPayload extends DomainStatus {
  hostname: string;
}

export type BlockedDomainsMap = Record<number, Map<string, BlockedDomainData>>;
export type DomainStatusesMap = Record<number, Map<string, DomainStatus>>;

export interface BadgeApi {
  setBadgeBackgroundColor: (options: { color: string; tabId: number }) => Promise<void> | void;
  setBadgeText: (options: { text: string; tabId: number }) => Promise<void> | void;
}

export interface BlockedMonitorState {
  blockedDomains: BlockedDomainsMap;
  clearBlockedDomains: (tabId: number) => void;
  clearTabRuntimeState: (tabId: number) => void;
  disposeTab: (tabId: number) => void;
  domainStatuses: DomainStatusesMap;
  ensureStatusStorage: (tabId: number) => void;
  ensureTabStorage: (tabId: number) => void;
  getBlockedDomainsForTab: (tabId: number) => Record<string, SerializedBlockedDomain>;
  getDomainStatusesForTab: (tabId: number) => Record<string, DomainStatusPayload>;
  setDomainStatus: (tabId: number, hostname: string, status: DomainStatus) => void;
  updateBadge: (tabId: number) => void;
  addBlockedDomain: (tabId: number, hostname: string, error: string, originUrl?: string) => void;
}

export function createBlockedMonitorState(
  badgeApi: BadgeApi,
  options: {
    extractHostname: (url: string) => string | null;
    inFlightAutoRequests?: Map<string, Promise<void>>;
    now?: () => number;
  }
): BlockedMonitorState {
  const blockedDomains: BlockedDomainsMap = {};
  const domainStatuses: DomainStatusesMap = {};
  const now: () => number = options.now ?? ((): number => Date.now());

  function ensureTabStorage(tabId: number): void {
    blockedDomains[tabId] ??= new Map();
  }

  function ensureStatusStorage(tabId: number): void {
    domainStatuses[tabId] ??= new Map();
  }

  function setDomainStatus(tabId: number, hostname: string, status: DomainStatus): void {
    ensureStatusStorage(tabId);
    domainStatuses[tabId]?.set(hostname, status);
  }

  function getDomainStatusesForTab(tabId: number): Record<string, DomainStatusPayload> {
    const result: Record<string, DomainStatusPayload> = {};
    const tabStatuses = domainStatuses[tabId];
    if (!tabStatuses) {
      return result;
    }

    tabStatuses.forEach((status, hostname) => {
      result[hostname] = {
        hostname,
        ...status,
      };
    });

    return result;
  }

  function updateBadge(tabId: number): void {
    const count = blockedDomains[tabId] ? blockedDomains[tabId].size : 0;

    void badgeApi.setBadgeText({
      text: count > 0 ? count.toString() : '',
      tabId,
    });

    void badgeApi.setBadgeBackgroundColor({
      color: '#FF0000',
      tabId,
    });
  }

  function clearInFlightRequests(tabId: number): void {
    if (!options.inFlightAutoRequests) {
      return;
    }

    const prefix = `${tabId.toString()}:`;
    Array.from(options.inFlightAutoRequests.keys()).forEach((key) => {
      if (key.startsWith(prefix)) {
        options.inFlightAutoRequests?.delete(key);
      }
    });
  }

  function clearTabRuntimeState(tabId: number): void {
    if (blockedDomains[tabId]) {
      blockedDomains[tabId].clear();
    }
    if (domainStatuses[tabId]) {
      domainStatuses[tabId].clear();
    }
    clearInFlightRequests(tabId);
    updateBadge(tabId);
  }

  function addBlockedDomain(
    tabId: number,
    hostname: string,
    error: string,
    originUrl?: string
  ): void {
    ensureTabStorage(tabId);

    const originHostname = originUrl ? options.extractHostname(originUrl) : null;

    if (!blockedDomains[tabId]?.has(hostname)) {
      blockedDomains[tabId]?.set(hostname, {
        errors: new Set(),
        origin: originHostname,
        timestamp: now(),
      });

      setDomainStatus(tabId, hostname, {
        state: 'detected',
        updatedAt: now(),
        messageKey: 'popupStatusDetected',
      });
    }
    blockedDomains[tabId]?.get(hostname)?.errors.add(error);

    updateBadge(tabId);
  }

  function clearBlockedDomains(tabId: number): void {
    clearTabRuntimeState(tabId);
  }

  function getBlockedDomainsForTab(tabId: number): Record<string, SerializedBlockedDomain> {
    const result: Record<string, SerializedBlockedDomain> = {};

    if (blockedDomains[tabId]) {
      blockedDomains[tabId].forEach((data, hostname) => {
        result[hostname] = {
          errors: Array.from(data.errors),
          origin: data.origin,
          timestamp: data.timestamp,
        };
      });
    }

    return result;
  }

  function disposeTab(tabId: number): void {
    clearInFlightRequests(tabId);
    Reflect.deleteProperty(blockedDomains, tabId);
    Reflect.deleteProperty(domainStatuses, tabId);
  }

  return {
    blockedDomains,
    clearBlockedDomains,
    clearTabRuntimeState,
    disposeTab,
    domainStatuses,
    ensureStatusStorage,
    ensureTabStorage,
    getBlockedDomainsForTab,
    getDomainStatusesForTab,
    setDomainStatus,
    updateBadge,
    addBlockedDomain,
  };
}
