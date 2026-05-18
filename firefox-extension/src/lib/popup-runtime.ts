import type { Tabs } from 'webextension-polyfill';

import {
  resolveNativeAvailabilityState,
  type NativeAvailabilityState,
} from './popup-native-actions.js';
import { t } from './i18n.js';
import {
  extractTabHostname,
  normalizeBlockedDomains,
  normalizeDomainStatuses,
  type BlockedDomainsData,
} from './popup-state.js';

export interface PopupDomainSnapshot {
  blockedDomainsData: BlockedDomainsData;
  domainStatusesData: Record<string, DomainStatus>;
}

type SendMessage = (message: unknown) => Promise<unknown>;

export async function loadPopupDomainStatuses(
  tabId: number,
  sendMessage: SendMessage
): Promise<Record<string, DomainStatus>> {
  try {
    const response = await sendMessage({
      action: 'getDomainStatuses',
      tabId,
    });
    return normalizeDomainStatuses(response);
  } catch {
    return {};
  }
}

export async function loadPopupDomainSnapshot(
  tabId: number,
  sendMessage: SendMessage
): Promise<PopupDomainSnapshot> {
  const response = await sendMessage({
    action: 'getBlockedDomains',
    tabId,
  });

  return {
    blockedDomainsData: normalizeBlockedDomains(response),
    domainStatusesData: await loadPopupDomainStatuses(tabId, sendMessage),
  };
}

export function buildBlockedDomainsClipboardText(blockedDomainsData: BlockedDomainsData): string {
  return Object.keys(blockedDomainsData).sort().join('\n');
}

export async function clearPopupDomainsForTab(
  tabId: number,
  sendMessage: SendMessage
): Promise<void> {
  await sendMessage({
    action: 'clearBlockedDomains',
    tabId,
  });
}

export async function checkPopupNativeAvailability(
  sendMessage: SendMessage
): Promise<NativeAvailabilityState> {
  const response = await sendMessage({ action: 'isNativeAvailable' });
  return resolveNativeAvailabilityState(
    response as { available?: boolean; success?: boolean; version?: string }
  );
}

export function resolveActivePopupTab(tabs: Tabs.Tab[]): {
  currentTabId?: number;
  currentTabHostname?: string;
  errorText?: string;
} {
  if (tabs.length === 0) {
    return { errorText: t('popupNoActiveTab') };
  }

  const tab = tabs[0];
  if (!tab?.id) {
    return { errorText: t('popupInvalidTab') };
  }

  return {
    currentTabId: tab.id,
    currentTabHostname: extractTabHostname(tab.url ?? ''),
  };
}
