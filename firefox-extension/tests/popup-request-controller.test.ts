import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { DEFAULT_REQUEST_CONFIG } from '../src/lib/config-storage.js';
import { createPopupRequestController } from '../src/lib/popup-request-controller.js';
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
  classList = new FakeClassList();
  className = '';
  dataset: { origin?: string } = {};
  disabled = false;
  ownerDocument = {
    createElement: (): FakeElement => new FakeElement(),
  };
  textContent = '';
  title = '';
  value = '';
  children: FakeElement[] = [];

  appendChild(child: FakeElement): void {
    this.children.push(child);
  }

  replaceChildren(...children: FakeElement[]): void {
    this.children = children;
  }
}

function createState(): PopupControllerState {
  return {
    blockedDomainsData: {},
    config: {
      ...DEFAULT_REQUEST_CONFIG,
      debugMode: false,
      enableRequests: true,
      requestApiUrl: '/cp',
    },
    currentTabId: 7,
    domainStatusesData: {},
    isNativeAvailable: true,
  };
}

await describe('popup request controller', async () => {
  await test('coordinates verify, request submission and local retry flows', async () => {
    const globalRecord = globalThis as typeof globalThis & { browser?: unknown };
    const previousBrowser = globalRecord.browser;
    const previousDocument = (globalRecord as { document?: unknown }).document;
    const permissionEvents: string[] = [];
    globalRecord.browser = {
      permissions: {
        contains: (): Promise<boolean> => {
          permissionEvents.push('contains');
          return Promise.resolve(true);
        },
        request: (): Promise<boolean> => {
          permissionEvents.push('request');
          return Promise.resolve(true);
        },
      },
    };
    (globalRecord as { document?: unknown }).document = {
      createElement: (): FakeElement => new FakeElement(),
    };

    try {
      const state = createState();
      const blockedDomainsData = {
        'cdn.example.com': {
          errors: ['NS_ERROR_UNKNOWN_HOST'],
          origin: 'portal.school',
          timestamp: 1,
        },
      };
      const btnSubmitRequest = new FakeElement() as unknown as HTMLButtonElement;
      const btnVerify = new FakeElement() as unknown as HTMLButtonElement;
      const requestDomainSelectEl = new FakeElement() as unknown as HTMLSelectElement;
      const requestReasonEl = new FakeElement() as unknown as HTMLInputElement;
      const requestSectionEl = new FakeElement() as unknown as HTMLElement;
      const requestStatusEl = new FakeElement() as unknown as HTMLElement;
      const verifyListEl = new FakeElement() as unknown as HTMLElement;
      const verifyResultsEl = new FakeElement() as unknown as HTMLElement;
      const messages: unknown[] = [];
      const toasts: string[] = [];
      let loadDomainStatusesCalls = 0;
      let renderDomainsListCalls = 0;

      requestDomainSelectEl.value = 'cdn.example.com';
      requestReasonEl.value = ' needed for class ';
      (requestSectionEl.classList as unknown as FakeClassList).add('hidden');

      const controller = createPopupRequestController({
        blockedDomainsData: () => blockedDomainsData,
        btnSubmitRequest,
        btnVerify,
        buildSubmitMessage: (payload) => ({ action: 'submitBlockedDomain', ...payload }),
        isRequestConfigured: () => true,
        loadDomainStatuses: (): Promise<void> => {
          loadDomainStatusesCalls += 1;
          return Promise.resolve();
        },
        renderDomainsList: () => {
          renderDomainsListCalls += 1;
        },
        requestDomainSelectEl,
        requestReasonEl,
        requestSectionEl,
        requestStatusEl,
        sendMessage: (message): Promise<{ success: boolean; results?: unknown[]; id?: string }> => {
          messages.push(message);
          if ((message as { action?: string }).action === 'checkWithNative') {
            return Promise.resolve({
              success: true,
              results: [{ domain: 'cdn.example.com', inWhitelist: false }],
            });
          }
          return Promise.resolve({ success: true, id: 'req-1' });
        },
        showToast: (message) => {
          toasts.push(message);
        },
        state,
        verifyListEl,
        verifyResultsEl,
      });

      controller.updateSubmitButtonState();
      assert.equal(btnSubmitRequest.disabled, false);

      controller.toggleRequestSection();
      assert.equal(
        (requestSectionEl.classList as unknown as FakeClassList).contains('hidden'),
        false
      );
      assert.equal((requestDomainSelectEl as unknown as FakeElement).children.length, 2);

      await controller.verifyDomainsWithNative();
      assert.deepEqual(messages[0], {
        action: 'checkWithNative',
        domains: ['cdn.example.com'],
      });
      assert.equal(btnVerify.disabled, false);
      const verifyItem = (verifyListEl as unknown as FakeElement).children[0];
      assert.ok(verifyItem);
      assert.equal(verifyItem.children[0]?.textContent, 'cdn.example.com');

      const submitPromise = controller.submitDomainRequest();
      assert.deepEqual(permissionEvents, ['contains']);
      await Promise.resolve();
      assert.equal(messages.length, 1);
      await submitPromise;
      assert.deepEqual(messages[1], {
        action: 'submitBlockedDomain',
        domain: 'cdn.example.com',
        error: 'NS_ERROR_UNKNOWN_HOST',
        origin: 'portal.school',
        reason: 'needed for class',
      });
      assert.equal(requestDomainSelectEl.value, '');
      assert.equal(requestReasonEl.value, '');
      assert.equal(
        requestStatusEl.textContent,
        '✅ Request sent for cdn.example.com. It remains pending approval.'
      );
      assert.equal(loadDomainStatusesCalls, 1);
      assert.equal(renderDomainsListCalls, 1);

      await controller.retryDomainLocalUpdate('cdn.example.com');
      assert.deepEqual(messages[2], {
        action: 'retryLocalUpdate',
        hostname: 'cdn.example.com',
        tabId: 7,
      });
      assert.deepEqual(toasts, ['✅ Request sent', 'Local allowlist updated']);
      assert.equal(loadDomainStatusesCalls, 2);
      assert.equal(renderDomainsListCalls, 2);
    } finally {
      globalRecord.browser = previousBrowser;
      (globalRecord as { document?: unknown }).document = previousDocument;
    }
  });

  await test('does not request browsing activity consent for invalid popup input', async () => {
    const globalRecord = globalThis as typeof globalThis & { browser?: unknown };
    const previousBrowser = globalRecord.browser;
    let permissionRequests = 0;
    globalRecord.browser = {
      permissions: {
        contains: (): Promise<boolean> => Promise.resolve(false),
        request: (): Promise<boolean> => {
          permissionRequests += 1;
          return Promise.resolve(true);
        },
      },
    };

    try {
      const state = createState();
      const btnSubmitRequest = new FakeElement() as unknown as HTMLButtonElement;
      const btnVerify = new FakeElement() as unknown as HTMLButtonElement;
      const requestDomainSelectEl = new FakeElement() as unknown as HTMLSelectElement;
      const requestReasonEl = new FakeElement() as unknown as HTMLInputElement;
      const requestSectionEl = new FakeElement() as unknown as HTMLElement;
      const requestStatusEl = new FakeElement() as unknown as HTMLElement;
      const verifyListEl = new FakeElement() as unknown as HTMLElement;
      const verifyResultsEl = new FakeElement() as unknown as HTMLElement;
      const messages: unknown[] = [];

      requestDomainSelectEl.value = 'cdn.example.com';
      requestReasonEl.value = 'no';

      const controller = createPopupRequestController({
        blockedDomainsData: () => ({
          'cdn.example.com': {
            errors: ['NS_ERROR_UNKNOWN_HOST'],
            origin: 'portal.school',
            timestamp: 1,
          },
        }),
        btnSubmitRequest,
        btnVerify,
        buildSubmitMessage: (payload) => ({ action: 'submitBlockedDomain', ...payload }),
        isRequestConfigured: () => true,
        loadDomainStatuses: () => Promise.resolve(),
        renderDomainsList: () => undefined,
        requestDomainSelectEl,
        requestReasonEl,
        requestSectionEl,
        requestStatusEl,
        sendMessage: (message) => {
          messages.push(message);
          return Promise.resolve({ success: true, id: 'req-1' });
        },
        showToast: () => undefined,
        state,
        verifyListEl,
        verifyResultsEl,
      });

      await controller.submitDomainRequest();

      assert.equal(permissionRequests, 0);
      assert.deepEqual(messages, []);
      assert.match(requestStatusEl.textContent, /Select a domain and enter a reason/);
    } finally {
      globalRecord.browser = previousBrowser;
    }
  });
});
