import { getErrorMessage, logger } from './logger.js';
import {
  applyPopupNativeAvailability,
  applyPopupNativeError,
  hidePopupVerifyResults,
} from './popup-feedback.js';
import { hidePopupRequestSection } from './popup-ui.js';
import {
  buildBlockedDomainsClipboardText,
  checkPopupNativeAvailability,
  clearPopupDomainsForTab,
  loadPopupDomainSnapshot,
  loadPopupDomainStatuses,
} from './popup-runtime.js';
import type { PopupControllerState } from './popup-controller-state.js';
import { t } from './i18n.js';

interface PopupDomainControllerOptions {
  btnVerify: HTMLButtonElement;
  nativeStatusEl: HTMLElement;
  renderDomainsList: () => void;
  requestSectionEl: HTMLElement;
  requestStatusEl: HTMLElement;
  refreshRequestButtonState: () => void;
  sendMessage: (message: unknown) => Promise<unknown>;
  showToast: (message: string, duration?: number) => void;
  state: PopupControllerState;
  verifyListEl: HTMLElement;
  verifyResultsEl: HTMLElement;
}

interface PopupDomainController {
  checkNativeAvailable: () => Promise<void>;
  clearDomains: () => Promise<void>;
  copyToClipboard: () => Promise<void>;
  loadBlockedDomains: () => Promise<void>;
  loadDomainStatuses: () => Promise<void>;
}

export function createPopupDomainController(
  options: PopupDomainControllerOptions
): PopupDomainController {
  async function loadBlockedDomains(): Promise<void> {
    if (options.state.currentTabId === null) {
      return;
    }

    try {
      const snapshot = await loadPopupDomainSnapshot(
        options.state.currentTabId,
        options.sendMessage
      );
      options.state.blockedDomainsData = snapshot.blockedDomainsData;
      options.state.domainStatusesData = snapshot.domainStatusesData;
      options.renderDomainsList();
    } catch (error) {
      logger.error('[Popup] Error loading blocked domains', { error: getErrorMessage(error) });
      options.state.blockedDomainsData = {};
      options.state.domainStatusesData = {};
      options.renderDomainsList();
    }
  }

  async function loadDomainStatuses(): Promise<void> {
    if (options.state.currentTabId === null) {
      return;
    }

    options.state.domainStatusesData = await loadPopupDomainStatuses(
      options.state.currentTabId,
      options.sendMessage
    );
  }

  async function copyToClipboard(): Promise<void> {
    const text = buildBlockedDomainsClipboardText(options.state.blockedDomainsData);
    if (!text) {
      return;
    }

    try {
      await navigator.clipboard.writeText(text);
      options.showToast(t('popupCopiedClipboard'));
    } catch (error) {
      logger.error('[Popup] Error copying to clipboard', { error: getErrorMessage(error) });
      options.showToast(t('popupCopyError'));
    }
  }

  async function clearDomains(): Promise<void> {
    if (options.state.currentTabId === null) {
      return;
    }

    try {
      await clearPopupDomainsForTab(options.state.currentTabId, options.sendMessage);
      options.state.blockedDomainsData = {};
      options.state.domainStatusesData = {};
      options.renderDomainsList();
      hidePopupVerifyResults({
        verifyListEl: options.verifyListEl,
        verifyResultsEl: options.verifyResultsEl,
      });
      hidePopupRequestSection(options.requestSectionEl);
      options.requestStatusEl.classList.add('hidden');
      options.requestStatusEl.textContent = '';
      options.showToast(t('popupListCleared'));
    } catch (error) {
      logger.error('[Popup] Error clearing domains', { error: getErrorMessage(error) });
    }
  }

  async function checkNativeAvailable(): Promise<void> {
    try {
      const nativeState = await checkPopupNativeAvailability(options.sendMessage);
      options.state.isNativeAvailable = nativeState.available;
      applyPopupNativeAvailability({
        btnVerify: options.btnVerify,
        nativeState,
        nativeStatusEl: options.nativeStatusEl,
      });
      options.refreshRequestButtonState();
    } catch {
      options.state.isNativeAvailable = false;
      applyPopupNativeError({
        btnVerify: options.btnVerify,
        nativeStatusEl: options.nativeStatusEl,
      });
      options.refreshRequestButtonState();
    }
  }

  return {
    checkNativeAvailable,
    clearDomains,
    copyToClipboard,
    loadBlockedDomains,
    loadDomainStatuses,
  };
}
