import { getErrorMessage, logger } from './logger.js';
import {
  hidePopupRequestStatus,
  hidePopupVerifyResults,
  renderPopupVerifyResults,
  resetPopupVerifyButton,
  showPopupRequestStatus,
  showPopupVerifyCommunicationError,
  showPopupVerifyError,
  showPopupVerifyLoading,
} from './popup-feedback.js';
import { verifyPopupDomains } from './popup-native-actions.js';
import { retryPopupDomainLocalUpdate, submitPopupDomainRequest } from './popup-request-actions.js';
import { syncPopupSubmitButtonState, togglePopupRequestSection } from './popup-ui.js';
import type { PopupControllerState } from './popup-controller-state.js';
import {
  ensureBrowsingActivityConsent,
  type DataCollectionPermissionsApi,
} from './data-collection-consent.js';

interface PopupRequestControllerOptions {
  blockedDomainsData: () => PopupControllerState['blockedDomainsData'];
  btnSubmitRequest: HTMLButtonElement;
  btnVerify: HTMLButtonElement;
  buildSubmitMessage: (payload: {
    domain: string;
    error?: string;
    origin?: string;
    reason: string;
  }) => unknown;
  isRequestConfigured: () => boolean;
  loadDomainStatuses: () => Promise<void>;
  renderDomainsList: () => void;
  requestDomainSelectEl: HTMLSelectElement;
  requestReasonEl: HTMLInputElement;
  requestSectionEl: HTMLElement;
  requestStatusEl: HTMLElement;
  sendMessage: (message: unknown) => Promise<unknown>;
  showToast: (message: string, duration?: number) => void;
  state: PopupControllerState;
  verifyListEl: HTMLElement;
  verifyResultsEl: HTMLElement;
}

function getPopupDataCollectionPermissionsApi(): DataCollectionPermissionsApi | null {
  const browserWithPermissions = (globalThis as { browser?: unknown }).browser as
    | { permissions?: Partial<DataCollectionPermissionsApi> }
    | undefined;
  const permissions = browserWithPermissions?.permissions;
  if (typeof permissions?.contains === 'function' && typeof permissions.request === 'function') {
    return {
      contains: permissions.contains.bind(permissions),
      request: permissions.request.bind(permissions),
    };
  }

  return null;
}

interface PopupRequestController {
  retryDomainLocalUpdate: (hostname: string) => Promise<void>;
  submitDomainRequest: () => Promise<void>;
  toggleRequestSection: () => void;
  updateSubmitButtonState: () => void;
  verifyDomainsWithNative: () => Promise<void>;
}

export function createPopupRequestController(
  options: PopupRequestControllerOptions
): PopupRequestController {
  function updateSubmitButtonState(): void {
    syncPopupSubmitButtonState({
      btnSubmitRequest: options.btnSubmitRequest,
      hasSelectedDomain: options.requestDomainSelectEl.value !== '',
      hasValidReason: options.requestReasonEl.value.trim().length >= 3,
      isNativeAvailable: options.state.isNativeAvailable,
      isRequestConfigured: options.isRequestConfigured(),
    });
  }

  function toggleRequestSection(): void {
    togglePopupRequestSection({
      blockedDomainsData: options.blockedDomainsData(),
      onHide: () => {
        hidePopupRequestStatus(options.requestStatusEl);
      },
      onShow: () => {
        hidePopupVerifyResults({
          verifyListEl: options.verifyListEl,
          verifyResultsEl: options.verifyResultsEl,
        });
        updateSubmitButtonState();
      },
      requestDomainSelectEl: options.requestDomainSelectEl,
      requestSectionEl: options.requestSectionEl,
    });
  }

  async function verifyDomainsWithNative(): Promise<void> {
    const blockedDomainsData = options.blockedDomainsData();
    const hasHostnames = Object.keys(blockedDomainsData).length > 0;
    if (!hasHostnames || !options.state.isNativeAvailable) {
      return;
    }

    showPopupVerifyLoading({
      btnVerify: options.btnVerify,
      verifyListEl: options.verifyListEl,
      verifyResultsEl: options.verifyResultsEl,
    });

    try {
      const result = await verifyPopupDomains({
        blockedDomainsData,
        isNativeAvailable: options.state.isNativeAvailable,
        sendMessage: options.sendMessage,
      });

      if (result.ok) {
        renderPopupVerifyResults({
          results: result.results,
          verifyListEl: options.verifyListEl,
        });
      } else if ('errorMessage' in result) {
        showPopupVerifyError(options.verifyListEl, result.errorMessage);
      } else {
        hidePopupVerifyResults({
          verifyListEl: options.verifyListEl,
          verifyResultsEl: options.verifyResultsEl,
        });
      }
    } catch (error) {
      logger.error('[Popup] Error verifying domains', { error: getErrorMessage(error) });
      showPopupVerifyCommunicationError(options.verifyListEl);
    } finally {
      resetPopupVerifyButton(options.btnVerify);
    }
  }

  async function submitDomainRequest(): Promise<void> {
    const blockedDomainsData = options.blockedDomainsData();
    const domain = options.requestDomainSelectEl.value;
    const reason = options.requestReasonEl.value.trim();

    options.btnSubmitRequest.disabled = true;
    options.btnSubmitRequest.textContent = '⏳ Enviando...';
    showPopupRequestStatus({
      message: 'Enviando solicitud...',
      requestStatusEl: options.requestStatusEl,
      type: 'pending',
    });

    try {
      const result = await submitPopupDomainRequest({
        blockedDomainsData,
        buildSubmitMessage: options.buildSubmitMessage,
        domain,
        isNativeAvailable: options.state.isNativeAvailable,
        isRequestConfigured: options.isRequestConfigured(),
        requestBrowsingActivityConsent: () =>
          ensureBrowsingActivityConsent(getPopupDataCollectionPermissionsApi()),
        reason,
        sendMessage: options.sendMessage,
      });

      showPopupRequestStatus({
        message: result.userMessage,
        requestStatusEl: options.requestStatusEl,
        type: result.success ? 'success' : 'error',
      });

      if (result.success) {
        options.showToast('✅ Solicitud enviada');
        if (result.shouldResetForm) {
          options.requestDomainSelectEl.value = '';
          options.requestReasonEl.value = '';
        }
        if (result.shouldReloadDomainStatuses) {
          await options.loadDomainStatuses();
          options.renderDomainsList();
        }
      } else {
        options.showToast(result.userMessage);
      }
    } catch (error) {
      const errorMessage = getErrorMessage(error);

      showPopupRequestStatus({
        message: `❌ ${errorMessage}`,
        requestStatusEl: options.requestStatusEl,
        type: 'error',
      });
      options.showToast('❌ Error al enviar');

      if (options.state.config.debugMode) {
        logger.error('[Popup] Request error', { error: errorMessage });
      }
    } finally {
      options.btnSubmitRequest.disabled = false;
      options.btnSubmitRequest.textContent = 'Enviar Solicitud';
      updateSubmitButtonState();
    }
  }

  async function retryDomainLocalUpdate(hostname: string): Promise<void> {
    try {
      const result = await retryPopupDomainLocalUpdate({
        hostname,
        sendMessage: options.sendMessage,
        tabId: options.state.currentTabId,
      });
      options.showToast(
        result.success ? 'Whitelist local actualizada' : 'No se pudo actualizar whitelist local'
      );
      await options.loadDomainStatuses();
      options.renderDomainsList();
    } catch (error) {
      logger.error('[Popup] Error retrying local update', { error: getErrorMessage(error) });
      options.showToast('Error al reintentar actualización local');
    }
  }

  return {
    retryDomainLocalUpdate,
    submitDomainRequest,
    toggleRequestSection,
    updateSubmitButtonState,
    verifyDomainsWithNative,
  };
}
