import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { createPopupController } from '../src/lib/popup-controller.js';

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
  title = '';
  value = '';
  readonly children: FakeElement[] = [];
  readonly classList = new FakeClassList();
  readonly dataset: Record<string, string> = {};
  readonly listeners = new Map<string, ((event?: unknown) => void)[]>();
  ownerDocument: FakeDocument;

  constructor(ownerDocument: FakeDocument) {
    this.ownerDocument = ownerDocument;
  }

  addEventListener(type: string, listener: (event?: unknown) => void): void {
    const listeners = this.listeners.get(type) ?? [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  appendChild(child: FakeElement): void {
    this.children.push(child);
  }

  replaceChildren(...children: FakeElement[]): void {
    this.children.length = 0;
    this.children.push(...children);
  }

  setAttribute(name: string, value: string): void {
    if (name === 'title') {
      this.title = value;
    }
  }
}

class FakeDocument {
  readonly elements = new Map<string, FakeElement>();
  readonly listeners = new Map<string, (() => void)[]>();

  addEventListener(type: string, listener: () => void): void {
    const listeners = this.listeners.get(type) ?? [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  createElement(): FakeElement {
    return new FakeElement(this);
  }

  getElementById(id: string): FakeElement | null {
    return this.elements.get(id) ?? null;
  }

  querySelectorAll(): FakeElement[] {
    return [];
  }
}

function createDocument(): FakeDocument {
  const doc = new FakeDocument();
  [
    'tab-domain',
    'count',
    'domains-list',
    'empty-message',
    'btn-copy',
    'btn-verify',
    'btn-clear',
    'btn-request',
    'toast',
    'native-status',
    'verify-results',
    'verify-list',
    'request-section',
    'request-domain-select',
    'request-reason',
    'btn-submit-request',
    'request-status',
  ].forEach((id) => {
    doc.elements.set(id, new FakeElement(doc));
  });
  return doc;
}

function withDocument(doc: FakeDocument, callback: () => Promise<void>): Promise<void> {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'document');
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: doc,
  });

  return callback().finally(() => {
    if (previous) {
      Object.defineProperty(globalThis, 'document', previous);
    } else {
      Reflect.deleteProperty(globalThis, 'document');
    }
  });
}

await describe('popup controller', async () => {
  await test('mounts handlers and initializes active tab state', async () => {
    const doc = createDocument();
    const messages: unknown[] = [];
    const browser = {
      runtime: {
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
            return {};
          }
          if (action === 'isNativeAvailable') {
            return { available: true, version: '1.2.3' };
          }
          return {};
        },
      },
      tabs: {
        query: async (): Promise<{ id: number; url: string }[]> => [
          { id: 42, url: 'https://lesson.example/path' },
        ],
      },
    };

    await withDocument(doc, async () => {
      const controller = createPopupController(browser as never, {
        buildSubmitMessage: (payload) => payload,
      });
      controller.mount();
      await controller.init();
    });

    assert.equal(doc.getElementById('tab-domain')?.textContent, 'lesson.example');
    assert.equal(doc.getElementById('count')?.textContent, '1');
    assert.equal(doc.getElementById('btn-copy')?.disabled, false);
    assert.equal(doc.getElementById('btn-request')?.disabled, true);
    assert.equal(doc.getElementById('native-status')?.textContent, 'Host nativo v1.2.3');
    assert.equal(doc.listeners.get('DOMContentLoaded')?.length, 1);
    assert.deepEqual(
      messages.map((message) => (message as { action?: string }).action),
      ['getBlockedDomains', 'getDomainStatuses', 'isNativeAvailable']
    );
  });

  await test('renders active tab errors without loading domain state', async () => {
    const doc = createDocument();
    let sendCount = 0;
    const browser = {
      runtime: {
        sendMessage: async (): Promise<unknown> => {
          sendCount += 1;
          return {};
        },
      },
      tabs: {
        query: async (): Promise<[]> => [],
      },
    };

    await withDocument(doc, async () => {
      const controller = createPopupController(browser as never, {
        buildSubmitMessage: (payload) => payload,
      });
      await controller.init();
    });

    assert.equal(doc.getElementById('tab-domain')?.textContent, 'Sin pestaña activa');
    assert.equal(sendCount, 0);
  });
});
