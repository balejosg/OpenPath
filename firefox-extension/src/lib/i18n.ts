interface I18nRuntime {
  getMessage?: (key: string, substitutions?: string | string[]) => string;
  getUILanguage?: () => string;
}

interface LocalizableRoot {
  querySelectorAll: <T extends HTMLElement>(selector: string) => NodeListOf<T>;
}

const fallbackMessages: Record<string, string> = {
  appName: 'OpenPath Block Monitor',
  appDescription:
    'Shows OpenPath network blocks, helps request access, and checks local allowlist state without analytics or telemetry.',
  actionTitle: 'Block Monitor',
  popupNativeMessagingAvailableTitle: 'Native Messaging available',
  popupTabLabel: 'Tab:',
  popupBlockedDomainsTitle: 'Blocked Domains',
  popupEmptyMessage: 'No blocked domains in this tab',
  popupVerifyResultsTitle: 'Verification Result',
  popupRequestTitle: 'Request Domain',
  popupSelectDomain: 'Select domain...',
  popupRequestReasonPlaceholder: 'Reason for the request...',
  popupSubmitRequest: 'Send Request',
  popupCopyTitle: 'Copy list to clipboard',
  popupCopyButton: 'Copy',
  popupVerifyTitle: 'Check domains in local allowlist',
  popupVerifyButton: 'Verify',
  popupRequestButtonTitle: 'Request adding domain to allowlist',
  popupRequestButton: 'Request',
  popupClearTitle: 'Clear blocked list',
  popupClearButton: 'Clear',
  popupCopiedToast: 'Copied to clipboard',
  popupConnectionAttemptsTitle: 'Connection attempts',
  popupRetryLocalUpdateTitle: 'Retry local update',
  popupRetryLocalUpdate: 'Retry',
  popupUnknownOrigin: 'unknown',
  popupUnknownTab: 'Unknown',
  popupLocalPage: 'Local page',
  popupNoActiveTab: 'No active tab',
  popupInvalidTab: 'Error: Invalid tab',
  popupSelectDomainAndReason: 'Select a domain and enter a reason',
  popupIncompleteRequestConfig: 'Incomplete configuration for domain requests',
  popupFirefoxDataPermissionUnsupported:
    'This Firefox version does not support the required data permission for sending requests.',
  popupUnknownError: 'Unknown error',
  popupTimeoutServerNoResponse: 'Timeout - server is not responding',
  popupConnectionError: 'Connection error',
  popupNativeCommunicationError: 'Communication error',
  popupVerifying: 'Verifying...',
  popupConsultingNativeHost: 'Checking native host...',
  popupNativeHostCommunicationError: 'Error communicating with native host',
  popupVerifyResetButton: 'Verify in Allowlist',
  popupNoResults: 'No results',
  popupRequestSendingButton: 'Sending...',
  popupSendingRequest: 'Sending request...',
  popupRequestSentToast: 'Request sent',
  popupRequestSendErrorToast: 'Error sending',
  popupLocalAllowlistUpdated: 'Local allowlist updated',
  popupLocalAllowlistUpdateFailed: 'Could not update local allowlist',
  popupLocalAllowlistRetryError: 'Error retrying local update',
  popupCopiedClipboard: 'Copied to clipboard',
  popupCopyError: 'Error copying',
  popupListCleared: 'List cleared',
  popupAllowed: 'ALLOWED',
  popupBlocked: 'BLOCKED',
  popupStatusPending: 'Pending',
  popupStatusAutoApproved: 'Auto-approved',
  popupStatusDuplicate: 'Duplicate',
  popupStatusLocalUpdateError: 'Local update error',
  popupStatusApiError: 'API error',
  popupStatusDetected: 'Detected',
  popupNativeHostUnavailable: 'Native host unavailable',
  popupNativeHostAvailable: 'Native host available',
  popupNativeHostVersion: 'Native host v$1',
  popupNativeHostConnectError: 'Could not connect to the native host',
  popupLocalUpdateRetrying: 'Retrying local update',
  popupLocalUpdateCompleted: 'Local update completed',
  popupLocalUpdateStillFailing: 'Local update is still failing',
  blockedUnknownDomain: 'unknown domain',
  requestSentForDomain: 'Request sent for {domain}. It remains pending approval.',
  blockedPageTitle: 'Site blocked',
  blockedPageHeading: 'This site is blocked for now',
  blockedPageMessage:
    'If it is part of your activity, you can request a review. The request will remain pending until it is approved.',
  blockedRequestedSiteAria: 'Requested site',
  blockedRequestedSiteLabel: 'Requested site',
  blockedReasonLabel: 'Why do you need it?',
  blockedReasonPlaceholder: 'Example: I need it for the class activity',
  blockedSubmit: 'Request unblock',
  blockedSecondaryActionsAria: 'Secondary actions',
  blockedGoBack: 'Back',
  blockedCopyDomain: 'Copy domain',
  blockedTechnicalDetails: 'Show technical details',
  blockedTechnicalReason: 'Technical reason',
  blockedOriginPage: 'Origin page',
  blockedRequestSubmittedSuccess: 'Request sent. It remains pending until reviewed.',
  blockedRequestApprovedUpdating: 'Request approved. Updating local permissions...',
  blockedFallbackMessage:
    'Could not send the request.{detail} Copy the domain and tell your teacher.',
  blockedRequestTimeout: 'Request timed out while sending.',
  blockedExtensionTimeout: 'Request timed out while contacting the extension.',
  blockedExtensionUnavailable: 'The extension is not available on this page.',
  blockedRequestStatusConfigIncomplete: 'Incomplete configuration for checking the request.',
  blockedRequestStatusFailed: 'Could not check the request ({status})',
  blockedRequestStillPendingRetry: 'The request is still pending. Try again in a moment.',
  blockedPermissionsExtensionUnavailable: 'The extension is not available to update permissions.',
  blockedLocalAllowlistUpdateFailed: 'Could not update the local allowlist.',
  blockedLocalAllowlistVerifyFailed: 'Could not verify the local allowlist.',
  blockedLocalAllowlistStillBlocked:
    'The local allowlist still does not allow the approved domain.',
  blockedBriefReasonRequired: 'Enter a brief reason for the request.',
  blockedCheckingFirefoxPermission: 'Checking Firefox permission...',
  blockedSendingRequest: 'Sending request...',
  blockedRequestSentWithoutId:
    'Request sent without an identifier. It will not reload automatically.',
  blockedWaitingApproval: 'Request sent. Waiting for approval...',
  blockedRequestRejected: 'Request rejected. The page will remain blocked.',
  blockedRequestStillPending: 'The request is still pending.',
  blockedLocalPermissionVerifyFailed: 'Could not verify the local permission.',
  blockedDomainCopied: 'Domain copied to clipboard.',
  blockedDomainCopyFailed: 'Could not copy the domain.',
  googleGameBlockedNotice: 'Game blocked by OpenPath',
};

function getRuntime(): I18nRuntime | null {
  const runtime =
    (globalThis as { browser?: { i18n?: I18nRuntime }; chrome?: { i18n?: I18nRuntime } }).browser
      ?.i18n ?? (globalThis as { chrome?: { i18n?: I18nRuntime } }).chrome?.i18n;
  return runtime ?? null;
}

function canLocalizeRoot(root: unknown): root is LocalizableRoot {
  const candidate = root as { querySelectorAll?: unknown };
  return typeof candidate.querySelectorAll === 'function';
}

export function t(key: string, substitutions?: string | string[]): string {
  const message = getRuntime()?.getMessage?.(key, substitutions);
  if (message) {
    return message;
  }

  let fallback = fallbackMessages[key] ?? key;
  const values = Array.isArray(substitutions)
    ? substitutions
    : substitutions !== undefined
      ? [substitutions]
      : [];
  values.forEach((value, index) => {
    const messageIndex = String(index + 1);
    const zeroBasedIndex = String(index);
    fallback = fallback
      .replaceAll(`$${messageIndex}`, value)
      .replaceAll(`{${zeroBasedIndex}}`, value);
  });
  if (values[0] !== undefined) {
    fallback = fallback.replace(/\{[a-zA-Z][a-zA-Z0-9_]*\}/g, values[0]);
  }
  return fallback;
}

export function getDocumentLanguage(): string {
  const uiLanguage = getRuntime()?.getUILanguage?.();
  const normalized = typeof uiLanguage === 'string' ? uiLanguage.trim().toLowerCase() : '';
  const [language = ''] = normalized.split('-');
  return language || 'en';
}

export function localizeDocument(root: ParentNode = document): void {
  const ownerDocument: Document | undefined =
    'documentElement' in root
      ? (root as Document)
      : ((root as Node).ownerDocument ??
        (typeof globalThis.document === 'undefined' ? undefined : globalThis.document));
  const documentElement = ownerDocument?.documentElement;
  if (documentElement) {
    documentElement.setAttribute('lang', getDocumentLanguage());
  }

  if (!canLocalizeRoot(root)) {
    return;
  }

  root.querySelectorAll<HTMLElement>('[data-i18n]').forEach((element) => {
    const key = element.dataset.i18n;
    if (key) {
      element.textContent = t(key);
    }
  });

  root.querySelectorAll<HTMLElement>('[data-i18n-title]').forEach((element) => {
    const key = element.dataset.i18nTitle;
    if (key) {
      element.setAttribute('title', t(key));
    }
  });

  root.querySelectorAll<HTMLElement>('[data-i18n-placeholder]').forEach((element) => {
    const key = element.dataset.i18nPlaceholder;
    if (key) {
      element.setAttribute('placeholder', t(key));
    }
  });

  root.querySelectorAll<HTMLElement>('[data-i18n-aria-label]').forEach((element) => {
    const key = element.dataset.i18nAriaLabel;
    if (key) {
      element.setAttribute('aria-label', t(key));
    }
  });
}
