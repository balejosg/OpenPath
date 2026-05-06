import {
  buildVerifyResultViewModels,
  type NativeAvailabilityState,
  type VerifyResult,
} from './popup-native-actions.js';
import { buildRequestStatusPresentation } from './popup-view-models.js';

function createElementFor<K extends keyof HTMLElementTagNameMap>(
  parent: HTMLElement,
  tagName: K
): HTMLElementTagNameMap[K] {
  return parent.ownerDocument.createElement(tagName);
}

export function showPopupToast(input: {
  duration?: number;
  message: string;
  scheduleTimeout?: (callback: () => void, delay: number) => unknown;
  toastEl: HTMLElement;
}): void {
  input.toastEl.textContent = input.message;
  input.toastEl.classList.add('show');
  (input.scheduleTimeout ?? setTimeout)(() => {
    input.toastEl.classList.remove('show');
  }, input.duration ?? 3000);
}

export function applyPopupNativeAvailability(input: {
  btnVerify: HTMLButtonElement;
  nativeState: NativeAvailabilityState;
  nativeStatusEl: HTMLElement;
}): void {
  input.nativeStatusEl.textContent = input.nativeState.label;
  input.nativeStatusEl.className = input.nativeState.className;
  input.btnVerify.disabled = !input.nativeState.available;
}

export function applyPopupNativeError(input: {
  btnVerify: HTMLButtonElement;
  nativeStatusEl: HTMLElement;
}): void {
  input.nativeStatusEl.textContent = 'Error de comunicación';
  input.nativeStatusEl.className = 'status-indicator unavailable';
  input.btnVerify.disabled = true;
}

export function showPopupVerifyLoading(input: {
  btnVerify: HTMLButtonElement;
  verifyListEl: HTMLElement;
  verifyResultsEl: HTMLElement;
}): void {
  input.btnVerify.disabled = true;
  input.btnVerify.textContent = '⌛ Verificando...';
  const loadingEl = createElementFor(input.verifyListEl, 'div');
  loadingEl.className = 'loading';
  loadingEl.textContent = 'Consultando host nativo...';
  input.verifyListEl.replaceChildren(loadingEl);
  input.verifyResultsEl.classList.remove('hidden');
}

export function showPopupVerifyError(verifyListEl: HTMLElement, message: string): void {
  const errorEl = createElementFor(verifyListEl, 'div');
  errorEl.className = 'error-text';
  errorEl.textContent = `Error: ${message}`;
  verifyListEl.replaceChildren(errorEl);
}

export function showPopupVerifyCommunicationError(verifyListEl: HTMLElement): void {
  const errorEl = createElementFor(verifyListEl, 'div');
  errorEl.className = 'error-text';
  errorEl.textContent = 'Error al comunicar con el host nativo';
  verifyListEl.replaceChildren(errorEl);
}

export function resetPopupVerifyButton(btnVerify: HTMLButtonElement): void {
  btnVerify.disabled = false;
  btnVerify.textContent = '🔍 Verificar en Whitelist';
}

export function renderPopupVerifyResults(input: {
  createListItem?: () => HTMLLIElement;
  results: VerifyResult[];
  verifyListEl: HTMLElement;
}): void {
  if (input.results.length === 0) {
    const emptyEl = createElementFor(input.verifyListEl, 'div');
    emptyEl.textContent = 'No hay resultados';
    input.verifyListEl.replaceChildren(emptyEl);
    return;
  }

  input.verifyListEl.replaceChildren();
  const createListItem =
    input.createListItem ?? ((): HTMLLIElement => document.createElement('li'));

  buildVerifyResultViewModels(input.results).forEach((result) => {
    const item = createListItem();
    item.className = 'verify-item';

    const domainEl = createElementFor(item, 'span');
    domainEl.className = 'verify-domain';
    domainEl.textContent = result.domain;

    const metaEl = createElementFor(item, 'div');
    metaEl.className = 'verify-meta';

    if (result.resolvedIp) {
      const ipInfo = createElementFor(item, 'span');
      ipInfo.className = 'ip-info';
      ipInfo.textContent = result.resolvedIp;
      metaEl.appendChild(ipInfo);
    }

    const statusEl = createElementFor(item, 'span');
    statusEl.className = `verify-status ${result.statusClass}`;
    statusEl.textContent = result.statusText;
    metaEl.appendChild(statusEl);

    item.appendChild(domainEl);
    item.appendChild(metaEl);
    input.verifyListEl.appendChild(item);
  });
}

export function hidePopupVerifyResults(input: {
  verifyListEl: HTMLElement;
  verifyResultsEl: HTMLElement;
}): void {
  input.verifyResultsEl.classList.add('hidden');
  input.verifyListEl.replaceChildren();
}

export function showPopupRequestStatus(input: {
  message: string;
  requestStatusEl: HTMLElement;
  type?: string;
}): void {
  const presentation = buildRequestStatusPresentation(input.type ?? 'info');
  input.requestStatusEl.classList.remove(...presentation.classesToRemove);
  input.requestStatusEl.classList.add(...presentation.classesToAdd);
  input.requestStatusEl.textContent = input.message;
}

export function hidePopupRequestStatus(requestStatusEl: HTMLElement): void {
  requestStatusEl.classList.add('hidden');
  requestStatusEl.textContent = '';
}
