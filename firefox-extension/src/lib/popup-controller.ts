import type { Browser } from 'webextension-polyfill';
import { logger, getErrorMessage } from './logger.js';
import { createPopupElements, registerPopupEventHandlers } from './popup-dom.js';
import { showPopupToast } from './popup-feedback.js';
import {
  DEFAULT_REQUEST_CONFIG,
  hasValidRequestConfig,
  loadRequestConfig,
  type RequestConfig,
} from './config-storage.js';
import { createPopupDomainController } from './popup-domain-controller.js';
import { createPopupRequestController } from './popup-request-controller.js';
import type { PopupControllerState } from './popup-controller-state.js';
import { renderPopupDomainsList, syncPopupRequestButtonState } from './popup-ui.js';
import { resolveActivePopupTab } from './popup-runtime.js';
import { localizeDocument } from './i18n.js';

interface PopupControllerOptions {
  buildSubmitMessage: (payload: {
    domain: string;
    error?: string;
    origin?: string;
    reason: string;
  }) => unknown;
}

interface PopupController {
  init: () => Promise<void>;
  mount: () => void;
}

export function createPopupController(
  browser: Browser,
  options: PopupControllerOptions
): PopupController {
  const {
    tabDomainEl,
    countEl,
    domainsListEl,
    emptyMessageEl,
    btnCopy,
    btnVerify,
    btnClear,
    btnRequest,
    toastEl,
    nativeStatusEl,
    verifyResultsEl,
    verifyListEl,
    requestSectionEl,
    requestDomainSelectEl,
    requestReasonEl,
    btnSubmitRequest,
    requestStatusEl,
  } = createPopupElements();

  const state: PopupControllerState = {
    blockedDomainsData: {},
    config: { ...DEFAULT_REQUEST_CONFIG } satisfies RequestConfig,
    currentTabId: null,
    domainStatusesData: {},
    isNativeAvailable: false,
  };
  const sendMessage = (message: unknown): Promise<unknown> => browser.runtime.sendMessage(message);

  function showToast(message: string, duration = 3000): void {
    showPopupToast({
      duration,
      message,
      toastEl,
    });
  }

  function isRequestConfigured(): boolean {
    return hasValidRequestConfig(state.config);
  }

  function refreshRequestButtonState(): void {
    syncPopupRequestButtonState({
      btnRequest,
      hasDomains: Object.keys(state.blockedDomainsData).length > 0,
      nativeAvailable: state.isNativeAvailable,
      requestConfigured: isRequestConfigured(),
      requestSectionEl,
    });
  }

  function renderDomainsList(): void {
    renderPopupDomainsList({
      blockedDomainsData: state.blockedDomainsData,
      btnCopy,
      btnVerify,
      countEl,
      currentTabId: state.currentTabId,
      domainStatusesData: state.domainStatusesData,
      domainsListEl,
      emptyMessageEl,
      isNativeAvailable: state.isNativeAvailable,
    });
    refreshRequestButtonState();
  }

  const domainController = createPopupDomainController({
    btnVerify,
    nativeStatusEl,
    renderDomainsList,
    requestSectionEl,
    requestStatusEl,
    refreshRequestButtonState,
    sendMessage,
    showToast,
    state,
    verifyListEl,
    verifyResultsEl,
  });
  const requestController = createPopupRequestController({
    blockedDomainsData: () => state.blockedDomainsData,
    btnSubmitRequest,
    btnVerify,
    buildSubmitMessage: options.buildSubmitMessage,
    isRequestConfigured,
    loadDomainStatuses: domainController.loadDomainStatuses,
    renderDomainsList,
    requestDomainSelectEl,
    requestReasonEl,
    requestSectionEl,
    requestStatusEl,
    sendMessage,
    showToast,
    state,
    verifyListEl,
    verifyResultsEl,
  });

  async function init(): Promise<void> {
    try {
      state.config = await loadRequestConfig();

      const tabs = await browser.tabs.query({ active: true, currentWindow: true });
      const activeTab = resolveActivePopupTab(tabs);
      if (activeTab.errorText) {
        tabDomainEl.textContent = activeTab.errorText;
        return;
      }

      state.currentTabId = activeTab.currentTabId ?? null;
      tabDomainEl.textContent = activeTab.currentTabHostname ?? 'Error';

      await domainController.loadBlockedDomains();
      await domainController.checkNativeAvailable();
      refreshRequestButtonState();
    } catch (error) {
      logger.error('[Popup] Initialization error', { error: getErrorMessage(error) });
      tabDomainEl.textContent = 'Error';
    }
  }

  function mount(): void {
    localizeDocument();
    registerPopupEventHandlers({
      elements: {
        btnCopy,
        btnClear,
        btnRequest,
        btnSubmitRequest,
        btnVerify,
        domainsListEl,
        requestDomainSelectEl,
        requestReasonEl,
      },
      onClear: () => {
        void domainController.clearDomains();
      },
      onCopy: () => {
        void domainController.copyToClipboard();
      },
      onDomReady: () => {
        void init();
      },
      onRequestInputChange: requestController.updateSubmitButtonState,
      onRetryUpdate: (hostname) => {
        void requestController.retryDomainLocalUpdate(hostname);
      },
      onSubmitRequest: () => {
        void requestController.submitDomainRequest();
      },
      onToggleRequest: requestController.toggleRequestSection,
      onVerify: () => {
        void requestController.verifyDomainsWithNative();
      },
    });
  }

  return {
    init,
    mount,
  };
}
