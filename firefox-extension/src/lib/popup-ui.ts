import { buildRequestDomainOptions, shouldEnableSubmitRequest } from './popup-request-actions.js';
import { shouldEnableRequestAction, type BlockedDomainsData } from './popup-state.js';
import { buildBlockedDomainListItems } from './popup-view-models.js';

function createElementFor<K extends keyof HTMLElementTagNameMap>(
  parent: HTMLElement,
  tagName: K
): HTMLElementTagNameMap[K] {
  return parent.ownerDocument.createElement(tagName);
}

export function hidePopupRequestSection(requestSectionEl: HTMLElement): void {
  requestSectionEl.classList.add('hidden');
}

export function syncPopupRequestButtonState(input: {
  btnRequest: HTMLButtonElement;
  hasDomains: boolean;
  nativeAvailable: boolean;
  requestConfigured: boolean;
  requestSectionEl: HTMLElement;
}): void {
  const canRequest = shouldEnableRequestAction({
    hasDomains: input.hasDomains,
    nativeAvailable: input.nativeAvailable,
    requestConfigured: input.requestConfigured,
  });

  if (canRequest) {
    input.btnRequest.classList.remove('hidden');
    input.btnRequest.disabled = false;
    return;
  }

  input.btnRequest.classList.add('hidden');
  input.btnRequest.disabled = true;
  hidePopupRequestSection(input.requestSectionEl);
}

export function renderPopupDomainsList(input: {
  blockedDomainsData: BlockedDomainsData;
  btnCopy: HTMLButtonElement;
  btnVerify: HTMLButtonElement;
  countEl: HTMLElement;
  createListItem?: () => HTMLLIElement;
  currentTabId: number | null;
  domainStatusesData: Record<string, DomainStatus>;
  domainsListEl: HTMLElement;
  emptyMessageEl: HTMLElement;
  isNativeAvailable: boolean;
}): void {
  const hostnames = Object.keys(input.blockedDomainsData).sort();

  if (hostnames.length === 0) {
    input.countEl.textContent = '0';
    input.domainsListEl.classList.add('hidden');
    input.emptyMessageEl.classList.remove('hidden');
    input.btnCopy.disabled = true;
    input.btnVerify.disabled = true;
    return;
  }

  input.countEl.textContent = hostnames.length.toString();
  input.domainsListEl.classList.remove('hidden');
  input.emptyMessageEl.classList.add('hidden');
  input.btnCopy.disabled = false;
  input.btnVerify.disabled = !input.isNativeAvailable;

  const createListItem =
    input.createListItem ?? ((): HTMLLIElement => document.createElement('li'));

  input.domainsListEl.replaceChildren();
  buildBlockedDomainListItems({
    blockedDomainsData: input.blockedDomainsData,
    currentTabId: input.currentTabId,
    domainStatusesData: input.domainStatusesData,
  }).forEach((viewModel) => {
    const item = createListItem();
    item.className = 'domain-item';

    const domainName = createElementFor(item, 'span');
    domainName.className = 'domain-name';
    domainName.title = viewModel.hostname;
    domainName.textContent = viewModel.hostname;

    const domainMeta = createElementFor(item, 'span');
    domainMeta.className = 'domain-meta';

    const domainCount = createElementFor(item, 'span');
    domainCount.className = 'domain-count';
    domainCount.title = 'Intentos de conexión';
    domainCount.textContent = viewModel.attempts.toString();

    const domainStatus = createElementFor(item, 'span');
    domainStatus.className = `domain-status ${viewModel.statusClassName}`;
    domainStatus.title = viewModel.statusTitle;
    domainStatus.textContent = viewModel.statusLabel;

    domainMeta.appendChild(domainCount);
    domainMeta.appendChild(domainStatus);

    if (viewModel.retryHostname) {
      const retryButton = createElementFor(item, 'button');
      retryButton.className = 'retry-update-btn';
      retryButton.dataset.hostname = viewModel.retryHostname;
      retryButton.title = 'Reintentar actualización local';
      retryButton.textContent = 'Reintentar';
      domainMeta.appendChild(retryButton);
    }

    item.appendChild(domainName);
    item.appendChild(domainMeta);
    input.domainsListEl.appendChild(item);
  });
}

export function populatePopupRequestDomainSelect(input: {
  blockedDomainsData: BlockedDomainsData;
  createOption?: () => HTMLOptionElement;
  requestDomainSelectEl: HTMLSelectElement;
}): void {
  const createOption =
    input.createOption ?? ((): HTMLOptionElement => document.createElement('option'));

  const defaultOption = createOption();
  defaultOption.value = '';
  defaultOption.textContent = 'Seleccionar dominio...';

  const options = buildRequestDomainOptions(input.blockedDomainsData).map(
    ({ hostname, origin }) => {
      const option = createOption();
      option.value = hostname;
      option.textContent = hostname;
      option.dataset.origin = origin;
      return option;
    }
  );

  input.requestDomainSelectEl.replaceChildren(defaultOption, ...options);
}

export function syncPopupSubmitButtonState(input: {
  btnSubmitRequest: HTMLButtonElement;
  hasSelectedDomain: boolean;
  hasValidReason: boolean;
  isNativeAvailable: boolean;
  isRequestConfigured: boolean;
}): void {
  input.btnSubmitRequest.disabled = !shouldEnableSubmitRequest({
    hasSelectedDomain: input.hasSelectedDomain,
    hasValidReason: input.hasValidReason,
    isNativeAvailable: input.isNativeAvailable,
    isRequestConfigured: input.isRequestConfigured,
  });
}

export function togglePopupRequestSection(input: {
  blockedDomainsData: BlockedDomainsData;
  createOption?: () => HTMLOptionElement;
  onHide: () => void;
  onShow: () => void;
  requestDomainSelectEl: HTMLSelectElement;
  requestSectionEl: HTMLElement;
}): void {
  const isHidden = input.requestSectionEl.classList.contains('hidden');

  if (isHidden) {
    input.requestSectionEl.classList.remove('hidden');
    populatePopupRequestDomainSelect({
      blockedDomainsData: input.blockedDomainsData,
      ...(input.createOption ? { createOption: input.createOption } : {}),
      requestDomainSelectEl: input.requestDomainSelectEl,
    });
    input.onShow();
    return;
  }

  hidePopupRequestSection(input.requestSectionEl);
  input.onHide();
}
