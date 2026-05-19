import { statusMeta, type BlockedDomainsData } from './popup-state.js';
import { t } from './i18n.js';

export interface BlockedDomainListItemViewModel {
  attempts: number;
  hostname: string;
  retryHostname?: string;
  statusClassName: string;
  statusLabel: string;
  statusTitle: string;
}

export function buildBlockedDomainListItems(input: {
  blockedDomainsData: BlockedDomainsData;
  currentTabId: number | null;
  domainStatusesData: Record<string, DomainStatus>;
}): BlockedDomainListItemViewModel[] {
  return Object.keys(input.blockedDomainsData)
    .sort()
    .flatMap((hostname) => {
      const info = input.blockedDomainsData[hostname];
      if (!info) {
        return [];
      }

      const meta = statusMeta(input.domainStatusesData[hostname]);
      const status = input.domainStatusesData[hostname];
      return [
        {
          attempts: info.count ?? info.errors?.length ?? 1,
          hostname,
          ...(meta.retryable && input.currentTabId !== null ? { retryHostname: hostname } : {}),
          statusClassName: meta.className,
          statusLabel: meta.label,
          statusTitle: status?.message ?? (status?.messageKey ? t(status.messageKey) : meta.label),
        },
      ];
    });
}

export function buildRequestStatusPresentation(type: string): {
  classesToAdd: string[];
  classesToRemove: string[];
} {
  return {
    classesToAdd: [type],
    classesToRemove: ['hidden', 'success', 'error', 'pending'],
  };
}
