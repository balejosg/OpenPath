import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  hidePopupRequestSection,
  populatePopupRequestDomainSelect,
  renderPopupDomainsList,
  syncPopupRequestButtonState,
  syncPopupSubmitButtonState,
  togglePopupRequestSection,
} from '../src/lib/popup-ui.js';

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

await describe('popup ui helpers', async () => {
  await test('syncs request button visibility based on request readiness', () => {
    const btnRequest = new FakeElement() as unknown as HTMLButtonElement;
    const requestSectionEl = new FakeElement() as unknown as HTMLElement;

    syncPopupRequestButtonState({
      btnRequest,
      hasDomains: true,
      nativeAvailable: true,
      requestConfigured: true,
      requestSectionEl,
    });

    assert.equal(btnRequest.disabled, false);
    assert.equal((btnRequest.classList as unknown as FakeClassList).contains('hidden'), false);

    syncPopupRequestButtonState({
      btnRequest,
      hasDomains: false,
      nativeAvailable: true,
      requestConfigured: true,
      requestSectionEl,
    });

    assert.equal(btnRequest.disabled, true);
    assert.equal((btnRequest.classList as unknown as FakeClassList).contains('hidden'), true);
    assert.equal((requestSectionEl.classList as unknown as FakeClassList).contains('hidden'), true);
  });

  await test('renders blocked domains list and empty state', () => {
    const btnCopy = new FakeElement() as unknown as HTMLButtonElement;
    const btnVerify = new FakeElement() as unknown as HTMLButtonElement;
    const countEl = new FakeElement() as unknown as HTMLElement;
    const domainsListEl = new FakeElement() as unknown as HTMLElement;
    const emptyMessageEl = new FakeElement() as unknown as HTMLElement;

    renderPopupDomainsList({
      blockedDomainsData: {},
      btnCopy,
      btnVerify,
      countEl,
      currentTabId: 2,
      domainStatusesData: {},
      domainsListEl,
      emptyMessageEl,
      isNativeAvailable: true,
    });

    assert.equal(countEl.textContent, '0');
    assert.equal(btnCopy.disabled, true);
    assert.equal(btnVerify.disabled, true);
    assert.equal((domainsListEl.classList as unknown as FakeClassList).contains('hidden'), true);

    renderPopupDomainsList({
      blockedDomainsData: {
        'cdn.example.com': {
          errors: ['NS_ERROR_UNKNOWN_HOST'],
          timestamp: 1,
        },
      },
      btnCopy,
      btnVerify,
      countEl,
      createListItem: () => new FakeElement() as unknown as HTMLLIElement,
      currentTabId: 2,
      domainStatusesData: {},
      domainsListEl,
      emptyMessageEl,
      isNativeAvailable: false,
    });

    assert.equal(countEl.textContent, '1');
    assert.equal(btnCopy.disabled, false);
    assert.equal(btnVerify.disabled, true);
    const domainItem = (domainsListEl as unknown as FakeElement).children[0];
    assert.equal((domainsListEl as unknown as FakeElement).children.length, 1);
    assert.ok(domainItem);
    const domainNameEl = domainItem.children[0];
    const domainMetaEl = domainItem.children[1];
    assert.ok(domainNameEl);
    assert.ok(domainMetaEl);
    const domainCountEl = domainMetaEl.children[0];
    const domainStatusEl = domainMetaEl.children[1];
    assert.ok(domainCountEl);
    assert.ok(domainStatusEl);

    assert.equal(domainItem.className, 'domain-item');
    assert.equal(domainNameEl.className, 'domain-name');
    assert.equal(domainNameEl.textContent, 'cdn.example.com');
    assert.equal(domainNameEl.title, 'cdn.example.com');
    assert.equal(domainMetaEl.className, 'domain-meta');
    assert.equal(domainCountEl.className, 'domain-count');
    assert.equal(domainCountEl.textContent, '1');
    assert.match(domainStatusEl.className, /domain-status/);
  });

  await test('populates request options and toggles the request section', () => {
    const requestDomainSelectEl = new FakeElement() as unknown as HTMLSelectElement;
    const requestSectionEl = new FakeElement() as unknown as HTMLElement;
    const calls: string[] = [];
    (requestSectionEl.classList as unknown as FakeClassList).add('hidden');

    populatePopupRequestDomainSelect({
      blockedDomainsData: {
        'cdn.example.com': {
          count: 1,
          origin: 'portal.school',
          timestamp: 1,
        },
      },
      createOption: () => new FakeElement() as unknown as HTMLOptionElement,
      requestDomainSelectEl,
    });

    assert.equal((requestDomainSelectEl as unknown as FakeElement).children.length, 2);
    assert.equal(
      (requestDomainSelectEl as unknown as FakeElement).children[0]?.textContent,
      'Select domain...'
    );
    assert.equal(
      (requestDomainSelectEl as unknown as FakeElement).children[1]?.dataset.origin,
      'portal.school'
    );

    togglePopupRequestSection({
      blockedDomainsData: {
        'cdn.example.com': {
          count: 1,
          origin: 'portal.school',
          timestamp: 1,
        },
      },
      createOption: () => new FakeElement() as unknown as HTMLOptionElement,
      onHide: () => calls.push('hide'),
      onShow: () => calls.push('show'),
      requestDomainSelectEl,
      requestSectionEl,
    });

    assert.equal(calls[0], 'show');
    assert.equal(
      (requestSectionEl.classList as unknown as FakeClassList).contains('hidden'),
      false
    );

    togglePopupRequestSection({
      blockedDomainsData: {},
      createOption: () => new FakeElement() as unknown as HTMLOptionElement,
      onHide: () => calls.push('hide'),
      onShow: () => calls.push('show'),
      requestDomainSelectEl,
      requestSectionEl,
    });

    assert.equal(calls[1], 'hide');
    assert.equal((requestSectionEl.classList as unknown as FakeClassList).contains('hidden'), true);
  });

  await test('syncs submit button state and hides request sections directly', () => {
    const btnSubmitRequest = new FakeElement() as unknown as HTMLButtonElement;
    const requestSectionEl = new FakeElement() as unknown as HTMLElement;

    syncPopupSubmitButtonState({
      btnSubmitRequest,
      hasSelectedDomain: true,
      hasValidReason: true,
      isNativeAvailable: true,
      isRequestConfigured: true,
    });

    assert.equal(btnSubmitRequest.disabled, false);

    syncPopupSubmitButtonState({
      btnSubmitRequest,
      hasSelectedDomain: false,
      hasValidReason: true,
      isNativeAvailable: true,
      isRequestConfigured: true,
    });

    assert.equal(btnSubmitRequest.disabled, true);

    hidePopupRequestSection(requestSectionEl);
    assert.equal((requestSectionEl.classList as unknown as FakeClassList).contains('hidden'), true);
  });
});
