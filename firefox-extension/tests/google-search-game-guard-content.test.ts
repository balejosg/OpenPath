import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';

const extensionRoot = path.resolve(import.meta.dirname, '..');
let importCounter = 0;

async function readContentEntrypoint(): Promise<string> {
  return readFile(path.join(extensionRoot, 'src', 'google-search-game-guard-content.ts'), 'utf8');
}

class FakeElement {
  public parentElement: FakeElement | null = null;
  public readonly children: FakeElement[] = [];
  private readonly attributes = new Map<string, string>();

  public constructor(
    public readonly tagName: string,
    public textContent = ''
  ) {}

  public appendChild(child: FakeElement): FakeElement {
    child.parentElement = this;
    this.children.push(child);
    return child;
  }

  public replaceWith(next: FakeElement): void {
    if (!this.parentElement) {
      return;
    }
    const index = this.parentElement.children.indexOf(this);
    if (index >= 0) {
      next.parentElement = this.parentElement;
      this.parentElement.children.splice(index, 1, next);
      this.parentElement = null;
    }
  }

  public setAttribute(name: string, value: string): void {
    this.attributes.set(name.toLowerCase(), value);
  }

  public getAttribute(name: string): string | null {
    return this.attributes.get(name.toLowerCase()) ?? null;
  }

  public matches(selector: string): boolean {
    if (selector === 'html, body, main, form, [role="main"], [role="search"], #search, #rso') {
      return (
        this.tagName.toLowerCase() === 'html' ||
        this.tagName.toLowerCase() === 'body' ||
        this.tagName.toLowerCase() === 'main' ||
        this.tagName.toLowerCase() === 'form' ||
        this.getAttribute('role') === 'main' ||
        this.getAttribute('role') === 'search' ||
        this.getAttribute('id') === 'search' ||
        this.getAttribute('id') === 'rso'
      );
    }
    if (selector === '[data-openpath-google-game-guard]') {
      return this.getAttribute('data-openpath-google-game-guard') !== null;
    }
    return false;
  }

  public closest(selector: string): FakeElement | null {
    if (this.matches(selector)) {
      return this;
    }
    let current = this.parentElement;
    while (current) {
      if (current.matches(selector)) {
        return current;
      }
      current = current.parentElement;
    }
    return null;
  }

  public querySelector(selector: string): FakeElement | null {
    return this.querySelectorAll(selector)[0] ?? null;
  }

  public querySelectorAll(selector: string): FakeElement[] {
    const results: FakeElement[] = [];
    const visit = (element: FakeElement): void => {
      if (matchesSelector(element, selector)) {
        results.push(element);
      }
      for (const child of element.children) {
        visit(child);
      }
    };
    for (const child of this.children) {
      visit(child);
    }
    return results;
  }
}

function matchesSelector(element: FakeElement, selector: string): boolean {
  const tag = element.tagName.toLowerCase();
  if (selector === 'html, body, main, form, [role="main"], [role="search"], #search, #rso') {
    return element.matches(selector);
  }
  if (selector === 'canvas, iframe, object, embed') {
    return tag === 'canvas' || tag === 'iframe' || tag === 'object' || tag === 'embed';
  }
  if (selector === 'button, a[href], [role="button"], input[type="button"], input[type="submit"]') {
    return (
      tag === 'button' ||
      (tag === 'a' && element.getAttribute('href') !== null) ||
      element.getAttribute('role') === 'button' ||
      (tag === 'input' &&
        (element.getAttribute('type') === 'button' || element.getAttribute('type') === 'submit'))
    );
  }
  return true;
}

async function importGuardWithFakePage(options: {
  host: string;
  path: string;
  query?: string;
  root: FakeElement;
}): Promise<unknown[]> {
  const testGlobal = globalThis as unknown as Record<string, unknown>;
  const originalBrowser = testGlobal.browser;
  const originalDocument = testGlobal.document;
  const originalLocation = testGlobal.location;
  const originalMutationObserver = testGlobal.MutationObserver;
  const originalWindow = testGlobal.window;

  const sentMessages: unknown[] = [];
  class FakeMutationObserver {
    public observe(): void {
      return undefined;
    }
  }

  const fakeDocument = {
    body: options.root,
    createElement(tagName: string): FakeElement {
      return new FakeElement(tagName);
    },
    querySelectorAll(selector: string): FakeElement[] {
      return options.root.querySelectorAll(selector);
    },
  };
  const fakeLocation = {
    hostname: options.host,
    pathname: options.path,
    search: options.query ?? '',
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
    location: fakeLocation,
    MutationObserver: FakeMutationObserver,
    window: {
      addEventListener: () => undefined,
      location: fakeLocation,
      setTimeout: (_callback: () => void) => undefined,
    },
  });

  try {
    importCounter += 1;
    await import(`../src/google-search-game-guard-content.ts?case=${importCounter.toString()}`);
    return sentMessages;
  } finally {
    Object.assign(testGlobal, {
      browser: originalBrowser,
      document: originalDocument,
      location: originalLocation,
      MutationObserver: originalMutationObserver,
      window: originalWindow,
    });
  }
}

void describe('Google Search game guard content script', () => {
  void test('uses a classic-script entrypoint loadable from manifest content_scripts', async () => {
    const source = await readContentEntrypoint();

    assert.doesNotMatch(source, /^\s*import\s/m);
    assert.doesNotMatch(source, /^\s*export\s/m);
    assert.match(source, /\(\(\): void => \{/);
    assert.match(source, /openpathGoogleSearchGameBlocked/);
  });

  void test('neutralizes a Google Search game widget without replacing search result roots', async () => {
    const root = new FakeElement('div');
    root.setAttribute('id', 'rso');
    const widget = root.appendChild(new FakeElement('div', 'Solitaire Play new game'));
    widget.appendChild(new FakeElement('canvas'));
    widget.appendChild(new FakeElement('button', 'Play'));

    const sentMessages = await importGuardWithFakePage({
      host: 'www.google.com',
      path: '/search',
      query: '?q=solitaire',
      root,
    });

    assert.equal(root.getAttribute('data-openpath-google-game-guard'), null);
    assert.equal(root.children.length, 1);
    assert.equal(root.children[0]?.getAttribute('data-openpath-google-game-guard'), 'blocked');
    assert.equal(sentMessages.length, 1);
    assert.deepEqual(
      {
        ...(sentMessages[0] as Record<string, unknown>),
        blockedAt: typeof (sentMessages[0] as { blockedAt?: unknown }).blockedAt,
      },
      {
        action: 'openpathGoogleSearchGameBlocked',
        blockedAt: 'number',
        pageHost: 'www.google.com',
        pagePath: '/search',
        reason: 'GOOGLE_GAME_POLICY:search-widget',
        signals: ['interactive-surface', 'play-control', 'game-text'],
      }
    );
  });

  void test('leaves ordinary Google Search results untouched', async () => {
    const root = new FakeElement('div', 'math revision worksheet');
    root.setAttribute('id', 'rso');
    root.appendChild(new FakeElement('a', 'Fractions worksheet'));

    const sentMessages = await importGuardWithFakePage({
      host: 'www.google.es',
      path: '/search',
      query: '?q=fractions+worksheet',
      root,
    });

    assert.equal(root.children[0]?.getAttribute('data-openpath-google-game-guard'), null);
    assert.deepEqual(sentMessages, []);
  });

  void test('does not treat the Google account sign-in control as a game widget', async () => {
    const root = new FakeElement('body');
    const header = root.appendChild(new FakeElement('div', 'Gmail Imágenes Iniciar sesión'));
    const signIn = header.appendChild(new FakeElement('a', 'Iniciar sesión'));
    signIn.setAttribute('href', 'https://accounts.google.com/');
    header.appendChild(new FakeElement('iframe'));
    const results = root.appendChild(new FakeElement('div', 'Resultado normal de búsqueda'));
    results.setAttribute('id', 'rso');
    const result = results.appendChild(new FakeElement('a', 'Historia de Roma'));
    result.setAttribute('href', 'https://example.org/roma');

    const sentMessages = await importGuardWithFakePage({
      host: 'www.google.es',
      path: '/search',
      query: '?q=historia+de+roma',
      root,
    });

    assert.equal(header.getAttribute('data-openpath-google-game-guard'), null);
    assert.deepEqual(sentMessages, []);
  });

  void test('never replaces a container that encloses the search results region', async () => {
    const root = new FakeElement('body');
    const wrapper = root.appendChild(new FakeElement('div', 'snake game online play now'));
    const nav = wrapper.appendChild(new FakeElement('div'));
    nav.appendChild(new FakeElement('button', 'Play'));
    const results = wrapper.appendChild(new FakeElement('div', 'snake game results'));
    results.setAttribute('id', 'rso');
    const result = results.appendChild(new FakeElement('a', 'snake game online'));
    result.setAttribute('href', 'https://example.org/snake');
    wrapper.appendChild(new FakeElement('iframe'));

    const sentMessages = await importGuardWithFakePage({
      host: 'www.google.com',
      path: '/search',
      query: '?q=snake+game',
      root,
    });

    assert.equal(wrapper.getAttribute('data-openpath-google-game-guard'), null);
    assert.equal(results.getAttribute('data-openpath-google-game-guard'), null);
    assert.deepEqual(sentMessages, []);
  });

  void test('blocks Google logo game embeds even when no play label is exposed', async () => {
    const root = new FakeElement('div');
    root.setAttribute('id', 'rso');
    const widget = root.appendChild(new FakeElement('div'));
    const iframe = widget.appendChild(new FakeElement('iframe'));
    iframe.setAttribute('src', 'https://www.google.com/logos/2026/snake/snake.html');

    const sentMessages = await importGuardWithFakePage({
      host: 'www.google.com',
      path: '/search',
      query: '?q=snake',
      root,
    });

    assert.equal(root.children[0]?.getAttribute('data-openpath-google-game-guard'), 'blocked');
    assert.equal(
      (sentMessages[0] as { reason?: string } | undefined)?.reason,
      'GOOGLE_GAME_POLICY:search-widget'
    );
    assert.deepEqual((sentMessages[0] as { signals?: string[] } | undefined)?.signals, [
      'interactive-surface',
      'google-game-resource',
    ]);
  });
});
