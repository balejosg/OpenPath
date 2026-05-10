import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';

const extensionRoot = path.resolve(import.meta.dirname, '..');

async function readContentEntrypoint(): Promise<string> {
  return readFile(path.join(extensionRoot, 'src', 'page-activity-content.ts'), 'utf8');
}

void describe('page activity content script', () => {
  void test('uses a classic-script entrypoint loadable from manifest content_scripts', async () => {
    const source = await readContentEntrypoint();

    assert.doesNotMatch(source, /^\s*import\s/m);
    assert.doesNotMatch(source, /^\s*export\s/m);
    assert.match(source, /\(\(\): void => \{/);
    assert.match(source, /browser\?\.runtime/);
    assert.match(source, /chrome\?\.runtime/);
  });

  void test('reports page activity and page resource candidates through runtime messaging', async () => {
    const source = await readContentEntrypoint();

    assert.match(source, /openpathPageActivity/);
    assert.match(source, /openpathPageResourceCandidate/);
    assert.match(source, /openpath-page-resource-candidate/);
    assert.match(source, /window\.addEventListener\('message'/);
    assert.match(source, /window\.addEventListener\('openpath-page-resource-candidate'/);
  });

  void test('relays page-world observers without inline script injection', async () => {
    const source = await readContentEntrypoint();

    assert.match(source, /MutationObserver/);
    assert.doesNotMatch(source, /script\.textContent/);
    assert.doesNotMatch(source, /appendChild\(script\)/);
  });

  void test('executes the manifest entrypoint and relays observed resources', async () => {
    const testGlobal = globalThis as unknown as Record<string, unknown>;
    const originalBrowser = testGlobal.browser;
    const originalChrome = testGlobal.chrome;
    const originalDocument = testGlobal.document;
    const originalMutationObserver = testGlobal.MutationObserver;
    const originalWindow = testGlobal.window;

    const sentMessages: unknown[] = [];
    let messageListener:
      | ((event: { data?: unknown; origin?: string; source?: unknown }) => void)
      | undefined;
    let candidateListener: ((event: { detail?: unknown }) => void) | undefined;
    let mutationCallback:
      | ((records: { addedNodes: unknown[]; attributeName?: string; target: unknown }[]) => void)
      | undefined;

    class FakeMutationObserver {
      constructor(
        callback: (
          records: { addedNodes: unknown[]; attributeName?: string; target: unknown }[]
        ) => void
      ) {
        mutationCallback = callback;
      }

      observe(target: unknown, options: unknown): void {
        assert.equal(target, fakeDocument);
        assert.deepEqual(options, {
          attributeFilter: ['src', 'srcset', 'href', 'rel', 'as'],
          attributes: true,
          childList: true,
          subtree: true,
        });
      }
    }

    const fakeDocument = {};
    const fakeWindow = {
      addEventListener(
        type: string,
        callback:
          | ((event: { data?: unknown; origin?: string; source?: unknown }) => void)
          | ((event: { detail?: unknown }) => void)
      ): void {
        if (type === 'message') {
          messageListener = callback as (event: {
            data?: unknown;
            origin?: string;
            source?: unknown;
          }) => void;
        }
        if (type === 'openpath-page-resource-candidate') {
          candidateListener = callback as (event: { detail?: unknown }) => void;
        }
      },
      location: { href: 'https://allowed.example/app' },
    };

    Object.assign(testGlobal, {
      browser: {
        runtime: {
          sendMessage(message: unknown): Promise<void> {
            sentMessages.push(message);
            return Promise.resolve();
          },
        },
      },
      document: fakeDocument,
      MutationObserver: FakeMutationObserver,
      window: fakeWindow,
    });

    try {
      // @ts-expect-error page-activity-content is intentionally a classic script for manifest loading.
      await import('../src/page-activity-content.ts');

      assert.deepEqual(sentMessages, [
        {
          action: 'openpathPageActivity',
          url: 'https://allowed.example/app',
        },
      ]);

      messageListener?.({
        data: {
          kind: 'fetch',
          source: 'openpath-page-resource-candidate',
          url: 'https://api.example/data.json',
        },
        origin: 'null',
        source: null,
      });
      candidateListener?.({
        detail: {
          source: 'openpath-page-resource-candidate',
          kind: 'script',
          url: 'https://cdn.example/dom-event.js',
        },
      });
      mutationCallback?.([
        {
          addedNodes: [
            { src: 'https://cdn.example/pixel.png', tagName: 'IMG' },
            { href: 'https://cdn.example/app.css', rel: 'stylesheet', tagName: 'LINK' },
            {
              as: 'font',
              href: 'https://fonts.gstatic.com/s/inter/v12/font.woff2',
              rel: 'preload',
              tagName: 'LINK',
            },
            {
              currentSrc:
                'https://preview.redd.it/my-paprika-had-no-seeds-v0-0q7k5y7403yg1.jpeg?width=1080',
              src: '',
              srcset:
                'https://preview.redd.it/my-paprika-had-no-seeds-v0-0q7k5y7403yg1.jpeg?width=640 640w, https://preview.redd.it/my-paprika-had-no-seeds-v0-0q7k5y7403yg1.jpeg?width=1080 1080w',
              tagName: 'IMG',
            },
          ],
          target: {},
        },
        {
          addedNodes: [],
          attributeName: 'src',
          target: { src: 'https://cdn.example/changed.js', tagName: 'SCRIPT' },
        },
        {
          addedNodes: [],
          attributeName: 'srcset',
          target: {
            currentSrc:
              'https://preview.redd.it/my-paprika-had-no-seeds-v0-0q7k5y7403yg1.jpeg?width=1080&crop=smart',
            src: '',
            srcset:
              'https://preview.redd.it/my-paprika-had-no-seeds-v0-0q7k5y7403yg1.jpeg?width=1080&crop=smart 1080w',
            tagName: 'IMG',
          },
        },
      ]);

      assert.deepEqual(sentMessages.slice(1), [
        {
          action: 'openpathPageResourceCandidate',
          kind: 'fetch',
          pageUrl: 'https://allowed.example/app',
          resourceUrl: 'https://api.example/data.json',
        },
        {
          action: 'openpathPageResourceCandidate',
          kind: 'script',
          pageUrl: 'https://allowed.example/app',
          resourceUrl: 'https://cdn.example/dom-event.js',
        },
        {
          action: 'openpathPageResourceCandidate',
          kind: 'image',
          pageUrl: 'https://allowed.example/app',
          resourceUrl: 'https://cdn.example/pixel.png',
        },
        {
          action: 'openpathPageResourceCandidate',
          kind: 'stylesheet',
          pageUrl: 'https://allowed.example/app',
          resourceUrl: 'https://cdn.example/app.css',
        },
        {
          action: 'openpathPageResourceCandidate',
          kind: 'font',
          pageUrl: 'https://allowed.example/app',
          resourceUrl: 'https://fonts.gstatic.com/s/inter/v12/font.woff2',
        },
        {
          action: 'openpathPageResourceCandidate',
          kind: 'image',
          pageUrl: 'https://allowed.example/app',
          resourceUrl:
            'https://preview.redd.it/my-paprika-had-no-seeds-v0-0q7k5y7403yg1.jpeg?width=1080',
        },
        {
          action: 'openpathPageResourceCandidate',
          kind: 'script',
          pageUrl: 'https://allowed.example/app',
          resourceUrl: 'https://cdn.example/changed.js',
        },
        {
          action: 'openpathPageResourceCandidate',
          kind: 'image',
          pageUrl: 'https://allowed.example/app',
          resourceUrl:
            'https://preview.redd.it/my-paprika-had-no-seeds-v0-0q7k5y7403yg1.jpeg?width=1080&crop=smart',
        },
      ]);
    } finally {
      Object.assign(testGlobal, {
        browser: originalBrowser,
        chrome: originalChrome,
        document: originalDocument,
        MutationObserver: originalMutationObserver,
        window: originalWindow,
      });
    }
  });
});
