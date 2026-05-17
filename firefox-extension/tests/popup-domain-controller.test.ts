import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { createPopupDomainController } from '../src/lib/popup-domain-controller.js';
import type { PopupControllerState } from '../src/lib/popup-controller-state.js';

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
}

class FakeElement {
  className = '';
  disabled = false;
  textContent = '';
  readonly classList = new FakeClassList();

  replaceChildren(): void {
    this.textContent = '';
  }
}

function createState(): PopupControllerState {
  return {
    blockedDomainsData: {},
    config: {
      apiBaseUrl: 'https://api.example',
      enabled: true,
      fallbackBaseUrls: [],
    },
    currentTabId: 17,
    domainStatusesData: {},
    isNativeAvailable: false,
  };
}

await describe('popup domain controller', async () => {
  await test('loads domains, native availability, clipboard copy, and clear flow', async () => {
    const state = createState();
    const messages: unknown[] = [];
    const toasts: string[] = [];
    let renderCount = 0;
    let refreshCount = 0;
    let clipboardText = '';
    const previousNavigator = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
    Object.defineProperty(globalThis, 'navigator', {
      configurable: true,
      value: {
        clipboard: {
          writeText: async (text: string): Promise<void> => {
            clipboardText = text;
          },
        },
      },
    });

    const controller = createPopupDomainController({
      btnVerify: new FakeElement() as unknown as HTMLButtonElement,
      nativeStatusEl: new FakeElement() as unknown as HTMLElement,
      renderDomainsList: () => {
        renderCount += 1;
      },
      requestSectionEl: new FakeElement() as unknown as HTMLElement,
      requestStatusEl: new FakeElement() as unknown as HTMLElement,
      refreshRequestButtonState: () => {
        refreshCount += 1;
      },
      sendMessage: async (message: unknown): Promise<unknown> => {
        messages.push(message);
        const action = (message as { action?: string }).action;
        if (action === 'getBlockedDomains') {
          return {
            domains: {
              'blocked.example': {
                errors: ['NS_ERROR_UNKNOWN_HOST'],
                origin: 'lesson.example',
              },
            },
          };
        }
        if (action === 'getDomainStatuses') {
          return {
            statuses: {
              'blocked.example': {
                domain: 'blocked.example',
                requestId: 'req_1',
                state: 'autoApproved',
              },
            },
          };
        }
        if (action === 'isNativeAvailable') {
          return { available: true, version: '1.2.3' };
        }
        return { ok: true };
      },
      showToast: (message) => {
        toasts.push(message);
      },
      state,
      verifyListEl: new FakeElement() as unknown as HTMLElement,
      verifyResultsEl: new FakeElement() as unknown as HTMLElement,
    });

    try {
      await controller.loadBlockedDomains();
      assert.deepEqual(Object.keys(state.blockedDomainsData), ['blocked.example']);
      assert.equal(state.domainStatusesData['blocked.example']?.state, 'autoApproved');
      assert.equal(renderCount, 1);

      await controller.checkNativeAvailable();
      assert.equal(state.isNativeAvailable, true);
      assert.equal(refreshCount, 1);

      await controller.copyToClipboard();
      assert.equal(clipboardText, 'blocked.example');
      assert.deepEqual(toasts, ['Copied to clipboard']);

      await controller.clearDomains();
      assert.deepEqual(state.blockedDomainsData, {});
      assert.equal(renderCount, 2);
      assert.equal(toasts.at(-1), 'List cleared');
      assert.deepEqual(
        messages.map((message) => (message as { action?: string }).action),
        ['getBlockedDomains', 'getDomainStatuses', 'isNativeAvailable', 'clearBlockedDomains']
      );
    } finally {
      if (previousNavigator) {
        Object.defineProperty(globalThis, 'navigator', previousNavigator);
      } else {
        Reflect.deleteProperty(globalThis, 'navigator');
      }
    }
  });

  await test('handles absent tab and native availability failures', async () => {
    const state = createState();
    state.currentTabId = null;
    let sendCount = 0;
    let refreshCount = 0;
    const nativeStatusEl = new FakeElement() as unknown as HTMLElement;
    const btnVerify = new FakeElement() as unknown as HTMLButtonElement;
    const controller = createPopupDomainController({
      btnVerify,
      nativeStatusEl,
      renderDomainsList: () => undefined,
      requestSectionEl: new FakeElement() as unknown as HTMLElement,
      requestStatusEl: new FakeElement() as unknown as HTMLElement,
      refreshRequestButtonState: () => {
        refreshCount += 1;
      },
      sendMessage: async () => {
        sendCount += 1;
        throw new Error('native unavailable');
      },
      showToast: () => undefined,
      state,
      verifyListEl: new FakeElement() as unknown as HTMLElement,
      verifyResultsEl: new FakeElement() as unknown as HTMLElement,
    });

    await controller.loadBlockedDomains();
    await controller.loadDomainStatuses();
    await controller.clearDomains();
    assert.equal(sendCount, 0);

    await controller.checkNativeAvailable();
    assert.equal(state.isNativeAvailable, false);
    assert.equal(btnVerify.disabled, true);
    assert.equal(nativeStatusEl.textContent, 'Communication error');
    assert.equal(refreshCount, 1);
  });
});
