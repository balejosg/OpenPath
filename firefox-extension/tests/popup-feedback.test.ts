import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  applyPopupNativeAvailability,
  applyPopupNativeError,
  hidePopupRequestStatus,
  hidePopupVerifyResults,
  renderPopupVerifyResults,
  resetPopupVerifyButton,
  showPopupRequestStatus,
  showPopupToast,
  showPopupVerifyCommunicationError,
  showPopupVerifyError,
  showPopupVerifyLoading,
} from '../src/lib/popup-feedback.js';

class FakeClassList {
  private readonly classes = new Set<string>();

  add(...classNames: string[]): void {
    classNames.forEach((className) => this.classes.add(className));
  }

  contains(className: string): boolean {
    return this.classes.has(className);
  }

  remove(...classNames: string[]): void {
    classNames.forEach((className) => this.classes.delete(className));
  }

  toString(): string[] {
    return [...this.classes].sort();
  }
}

class FakeElement {
  classList = new FakeClassList();
  className = '';
  ownerDocument = {
    createElement: (): FakeElement => new FakeElement(),
  };
  textContent = '';
  title = '';
  children: FakeElement[] = [];

  appendChild(child: FakeElement): void {
    this.children.push(child);
  }

  replaceChildren(...children: FakeElement[]): void {
    this.children = children;
  }
}

class FakeButton extends FakeElement {
  disabled = false;
}

await describe('popup feedback helpers', async () => {
  await test('shows toast messages and schedules cleanup', () => {
    const toastEl = new FakeElement() as unknown as HTMLElement;
    let capturedDelay = 0;
    let scheduled: (() => void) | undefined;

    showPopupToast({
      duration: 2500,
      message: 'Copiado',
      scheduleTimeout: (callback: () => void, delay: number) => {
        capturedDelay = delay;
        scheduled = callback;
        return 1;
      },
      toastEl,
    });

    assert.equal(toastEl.textContent, 'Copiado');
    assert.equal(capturedDelay, 2500);
    assert.equal((toastEl.classList as unknown as FakeClassList).contains('show'), true);
    scheduled?.();
    assert.equal((toastEl.classList as unknown as FakeClassList).contains('show'), false);
  });

  await test('applies native availability and fallback states', () => {
    const btnVerify = new FakeButton() as unknown as HTMLButtonElement;
    const nativeStatusEl = new FakeElement() as unknown as HTMLElement;

    applyPopupNativeAvailability({
      btnVerify,
      nativeState: {
        available: true,
        className: 'status-indicator available',
        label: 'Native host v1.2.3',
      },
      nativeStatusEl,
    });

    assert.equal(nativeStatusEl.textContent, 'Native host v1.2.3');
    assert.equal(nativeStatusEl.className, 'status-indicator available');
    assert.equal(btnVerify.disabled, false);

    applyPopupNativeError({
      btnVerify,
      nativeStatusEl,
    });

    assert.equal(nativeStatusEl.textContent, 'Communication error');
    assert.equal(nativeStatusEl.className, 'status-indicator unavailable');
    assert.equal(btnVerify.disabled, true);
  });

  await test('renders verify loading, results and reset state', () => {
    const btnVerify = new FakeButton() as unknown as HTMLButtonElement;
    const verifyListEl = new FakeElement() as unknown as HTMLElement;
    const verifyResultsEl = new FakeElement() as unknown as HTMLElement;

    showPopupVerifyLoading({
      btnVerify,
      verifyListEl,
      verifyResultsEl,
    });

    assert.equal(btnVerify.disabled, true);
    assert.equal(btnVerify.textContent, '⌛ Verifying...');
    assert.equal((verifyListEl as unknown as FakeElement).children[0]?.className, 'loading');
    assert.equal(
      (verifyListEl as unknown as FakeElement).children[0]?.textContent,
      'Checking native host...'
    );
    assert.equal((verifyResultsEl.classList as unknown as FakeClassList).contains('hidden'), false);

    renderPopupVerifyResults({
      createListItem: () => new FakeElement() as unknown as HTMLLIElement,
      results: [
        {
          domain: 'allowed.example.com',
          inWhitelist: true,
          resolvedIp: '127.0.0.1',
        },
      ],
      verifyListEl,
    });

    assert.equal((verifyListEl as unknown as FakeElement).children.length, 1);
    const resultItem = (verifyListEl as unknown as FakeElement).children[0];
    assert.ok(resultItem);
    const domainEl = resultItem.children[0];
    const metaEl = resultItem.children[1];
    assert.ok(domainEl);
    assert.ok(metaEl);
    const ipInfoEl = metaEl.children[0];
    const statusEl = metaEl.children[1];
    assert.ok(ipInfoEl);
    assert.ok(statusEl);

    assert.equal(resultItem.className, 'verify-item');
    assert.equal(domainEl.className, 'verify-domain');
    assert.equal(domainEl.textContent, 'allowed.example.com');
    assert.equal(metaEl.className, 'verify-meta');
    assert.equal(ipInfoEl.className, 'ip-info');
    assert.equal(ipInfoEl.textContent, '127.0.0.1');
    assert.match(statusEl.className, /verify-status/);
    assert.equal(statusEl.textContent, 'ALLOWED');

    hidePopupVerifyResults({
      verifyListEl,
      verifyResultsEl,
    });

    assert.equal((verifyResultsEl.classList as unknown as FakeClassList).contains('hidden'), true);
    assert.equal((verifyListEl as unknown as FakeElement).children.length, 0);

    showPopupVerifyError(verifyListEl, 'fallo');
    assert.equal((verifyListEl as unknown as FakeElement).children[0]?.className, 'error-text');
    assert.equal(
      (verifyListEl as unknown as FakeElement).children[0]?.textContent,
      'Error communicating with native host'
    );
    assert.equal((verifyListEl as unknown as FakeElement).children[0]?.title, 'fallo');
    showPopupVerifyCommunicationError(verifyListEl);
    assert.equal(
      (verifyListEl as unknown as FakeElement).children[0]?.textContent,
      'Error communicating with native host'
    );

    resetPopupVerifyButton(btnVerify);
    assert.equal(btnVerify.disabled, false);
    assert.equal(btnVerify.textContent, '🔍 Verify in Allowlist');
  });

  await test('shows and hides popup request status messages', () => {
    const requestStatusEl = new FakeElement() as unknown as HTMLElement;

    showPopupRequestStatus({
      message: 'Enviado',
      requestStatusEl,
      type: 'success',
    });

    assert.equal(requestStatusEl.textContent, 'Enviado');
    assert.deepEqual((requestStatusEl.classList as unknown as FakeClassList).toString(), [
      'success',
    ]);

    hidePopupRequestStatus(requestStatusEl);

    assert.equal((requestStatusEl.classList as unknown as FakeClassList).contains('hidden'), true);
    assert.equal(requestStatusEl.textContent, '');
  });
});
