import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { localizeDocument, t } from '../src/lib/i18n.js';

class FakeElement {
  textContent = '';
  readonly attributes = new Map<string, string>();
  readonly dataset: Record<string, string> = {};

  constructor(dataset: Record<string, string>) {
    this.dataset = dataset;
  }

  setAttribute(name: string, value: string): void {
    this.attributes.set(name, value);
  }
}

class FakeRoot {
  constructor(private readonly elementsBySelector: Map<string, FakeElement[]>) {}

  querySelectorAll(selector: string): FakeElement[] {
    return this.elementsBySelector.get(selector) ?? [];
  }
}

function withBrowserI18n(
  getMessage: (key: string, substitutions?: string | string[]) => string,
  callback: () => void
): void {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'browser');
  Object.defineProperty(globalThis, 'browser', {
    configurable: true,
    value: {
      i18n: {
        getMessage,
      },
    },
  });

  try {
    callback();
  } finally {
    if (previous) {
      Object.defineProperty(globalThis, 'browser', previous);
    } else {
      Reflect.deleteProperty(globalThis, 'browser');
    }
  }
}

await describe('Firefox i18n helpers', async () => {
  await test('returns runtime messages when available', () => {
    withBrowserI18n(
      (key) => (key === 'popupCopyButton' ? 'Copiar' : ''),
      () => {
        assert.equal(t('popupCopyButton'), 'Copiar');
      }
    );
  });

  await test('falls back to bundled English messages with substitutions', () => {
    assert.equal(
      t('requestSentForDomain', 'learning.example'),
      'Request sent for learning.example. It remains pending approval.'
    );
    assert.equal(t('missingMessageKey'), 'missingMessageKey');
  });

  await test('localizes text, title, placeholder, and aria-label attributes', () => {
    const textEl = new FakeElement({ i18n: 'popupCopyButton' });
    const titleEl = new FakeElement({ i18nTitle: 'popupCopyTitle' });
    const placeholderEl = new FakeElement({
      i18nPlaceholder: 'popupRequestReasonPlaceholder',
    });
    const ariaEl = new FakeElement({ i18nAriaLabel: 'blockedSecondaryActionsAria' });
    const root = new FakeRoot(
      new Map<string, FakeElement[]>([
        ['[data-i18n]', [textEl]],
        ['[data-i18n-title]', [titleEl]],
        ['[data-i18n-placeholder]', [placeholderEl]],
        ['[data-i18n-aria-label]', [ariaEl]],
      ])
    );

    localizeDocument(root as unknown as ParentNode);

    assert.equal(textEl.textContent, 'Copy');
    assert.equal(titleEl.attributes.get('title'), 'Copy list to clipboard');
    assert.equal(placeholderEl.attributes.get('placeholder'), 'Reason for the request...');
    assert.equal(ariaEl.attributes.get('aria-label'), 'Secondary actions');
  });
});
