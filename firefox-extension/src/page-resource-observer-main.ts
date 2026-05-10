/* eslint-disable @typescript-eslint/explicit-function-return-type, @typescript-eslint/no-confusing-void-expression, @typescript-eslint/no-unsafe-return, @typescript-eslint/unbound-method */
// MAIN-world monkey patches must preserve browser-native descriptors and call receivers.
type OpenPathMainResourceKind =
  | 'fetch'
  | 'xmlhttprequest'
  | 'image'
  | 'script'
  | 'stylesheet'
  | 'font'
  | 'other';

interface OpenPathObserverState {
  attempts: number;
  installed: boolean;
  lastError: string | null;
  lastNotification: { kind: OpenPathMainResourceKind; url: string } | null;
  notifications: Partial<Record<OpenPathMainResourceKind, number>>;
  patched: {
    fetch: boolean;
    font: boolean;
    image: boolean;
    imageSrcset: boolean;
    linkHref: boolean;
    script: boolean;
    setAttribute: boolean;
    stylesheet: boolean;
    xhrOpen: boolean;
  };
}

((): void => {
  const installedKey = '__openpathPageResourceObserverInstalled';
  const stateKey = '__openpathPageResourceObserverState';
  const source = 'openpath-page-resource-candidate';
  const observerWindow = window as Window &
    typeof globalThis & {
      [installedKey]?: boolean;
      [stateKey]?: OpenPathObserverState;
    };

  function createState(): OpenPathObserverState {
    return {
      attempts: 0,
      installed: false,
      lastError: null,
      lastNotification: null,
      notifications: {},
      patched: {
        fetch: false,
        xhrOpen: false,
        image: false,
        imageSrcset: false,
        script: false,
        stylesheet: false,
        font: false,
        linkHref: false,
        setAttribute: false,
      },
    };
  }

  function getState(): OpenPathObserverState {
    let state = observerWindow[stateKey];
    if (!state) {
      state = createState();
      try {
        Object.defineProperty(observerWindow, stateKey, { configurable: true, value: state });
      } catch {
        observerWindow[stateKey] = state;
      }
    }
    return state;
  }

  const state = getState();
  state.attempts += 1;
  state.installed = true;
  if (!observerWindow[installedKey]) {
    try {
      Object.defineProperty(observerWindow, installedKey, { configurable: true, value: true });
    } catch {
      observerWindow[installedKey] = true;
    }
  }

  function markPatched(target: object | null | undefined, key: string): boolean {
    const patchTarget = target as Record<string, unknown> | null | undefined;
    if (!patchTarget || patchTarget[key]) {
      return false;
    }

    try {
      Object.defineProperty(patchTarget, key, { configurable: true, value: true });
    } catch {
      patchTarget[key] = true;
    }
    return true;
  }

  function clearPatched(target: object, key: string): void {
    try {
      Object.defineProperty(target, key, { configurable: true, value: false });
    } catch {
      (target as Record<string, unknown>)[key] = false;
    }
  }

  function recordPatch(key: keyof OpenPathObserverState['patched']): void {
    state.patched[key] = true;
  }

  function recordError(error: unknown): void {
    state.lastError = error instanceof Error ? error.message : String(error);
  }

  function notify(url: string, kind: OpenPathMainResourceKind): void {
    if (!url) {
      return;
    }

    try {
      const payload = { source, url, kind };
      state.notifications[kind] = (state.notifications[kind] ?? 0) + 1;
      state.lastNotification = { kind, url: payload.url };
      window.postMessage(payload, '*');
      window.dispatchEvent(new CustomEvent(source, { detail: payload }));
    } catch (error) {
      recordError(error);
    }
  }

  function unwrapUrl(input: unknown): string {
    if (!input) {
      return '';
    }
    if (typeof input === 'string') {
      return input;
    }
    if (input instanceof URL) {
      return input.href;
    }
    if (typeof Request !== 'undefined' && input instanceof Request) {
      return input.url;
    }
    return '';
  }

  function parseSrcset(value: unknown): string {
    if (typeof value !== 'string') {
      return '';
    }
    const firstCandidate = value.split(',')[0];
    return firstCandidate?.trim().split(/\s+/u)[0] ?? '';
  }

  function resolveImageUrl(element: unknown, value: unknown): string {
    const currentSrc = (element as { currentSrc?: unknown } | null)?.currentSrc;
    if (typeof currentSrc === 'string' && currentSrc.length > 0) {
      return currentSrc;
    }
    return unwrapUrl(value) || parseSrcset(value);
  }

  const originalFetch = window.fetch;
  if (
    typeof originalFetch === 'function' &&
    markPatched(window, '__openpathPageResourceObserverFetchPatched')
  ) {
    window.fetch = function (input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
      notify(unwrapUrl(input), 'fetch');
      return originalFetch.call(this, input, init);
    };
    recordPatch('fetch');
  }

  const originalOpen = typeof XMLHttpRequest !== 'undefined' ? XMLHttpRequest.prototype.open : null;
  if (
    typeof originalOpen === 'function' &&
    markPatched(XMLHttpRequest.prototype, '__openpathPageResourceObserverXhrOpenPatched')
  ) {
    XMLHttpRequest.prototype.open = function (
      method: string,
      url: string | URL,
      async?: boolean,
      username?: string | null,
      password?: string | null
    ): void {
      notify(unwrapUrl(url), 'xmlhttprequest');
      originalOpen.call(this, method, url, async ?? true, username ?? null, password ?? null);
    };
    recordPatch('xhrOpen');
  }

  function patchUrlProperty(
    prototype: object | undefined,
    property: string,
    kind: OpenPathMainResourceKind
  ): void {
    const patchKey = `__openpathPageResourceObserverPatched_${property}_${kind}`;
    if (!prototype || !markPatched(prototype, patchKey)) {
      return;
    }

    const descriptor = Object.getOwnPropertyDescriptor(prototype, property);
    if (!descriptor || typeof descriptor.set !== 'function') {
      clearPatched(prototype, patchKey);
      return;
    }
    const descriptorSetter = descriptor.set;
    const descriptorGetter = descriptor.get;

    const nextDescriptor: PropertyDescriptor = {
      configurable: true,
      enumerable: descriptor.enumerable === true,
      set(value: unknown) {
        notify(unwrapUrl(value), kind);
        return descriptorSetter.call(this, value);
      },
    };
    if (descriptorGetter) {
      nextDescriptor.get = function () {
        return descriptorGetter.call(this);
      };
    }
    Object.defineProperty(prototype, property, nextDescriptor);
    recordPatch(kind === 'image' || kind === 'script' ? kind : 'linkHref');
  }

  function getLinkResourceKind(link: unknown): OpenPathMainResourceKind {
    const rel = (link as { rel?: unknown } | null)?.rel;
    const as = (link as { as?: unknown } | null)?.as;
    const relTokens = (typeof rel === 'string' ? rel : '').toLowerCase().split(/\s+/u);
    const asValue = (typeof as === 'string' ? as : '').toLowerCase();
    if (relTokens.includes('preload') && asValue === 'font') {
      return 'font';
    }
    if (relTokens.includes('stylesheet')) {
      return 'stylesheet';
    }
    return 'other';
  }

  if (typeof HTMLImageElement !== 'undefined') {
    patchUrlProperty(HTMLImageElement.prototype, 'src', 'image');
    const imageSrcsetDescriptor = Object.getOwnPropertyDescriptor(
      HTMLImageElement.prototype,
      'srcset'
    );
    if (
      imageSrcsetDescriptor &&
      typeof imageSrcsetDescriptor.set === 'function' &&
      markPatched(HTMLImageElement.prototype, '__openpathPageResourceObserverPatched_srcset_image')
    ) {
      const srcsetSetter = imageSrcsetDescriptor.set;
      const srcsetGetter = imageSrcsetDescriptor.get;
      const srcsetDescriptor: PropertyDescriptor = {
        configurable: true,
        enumerable: imageSrcsetDescriptor.enumerable === true,
        set(value: unknown) {
          notify(resolveImageUrl(this, value), 'image');
          return srcsetSetter.call(this, value);
        },
      };
      if (srcsetGetter) {
        srcsetDescriptor.get = function () {
          return srcsetGetter.call(this);
        };
      }
      Object.defineProperty(HTMLImageElement.prototype, 'srcset', srcsetDescriptor);
      recordPatch('imageSrcset');
    }
  }

  if (typeof HTMLScriptElement !== 'undefined') {
    patchUrlProperty(HTMLScriptElement.prototype, 'src', 'script');
  }

  if (typeof HTMLLinkElement !== 'undefined') {
    const descriptor = Object.getOwnPropertyDescriptor(HTMLLinkElement.prototype, 'href');
    if (
      descriptor &&
      typeof descriptor.set === 'function' &&
      markPatched(HTMLLinkElement.prototype, '__openpathPageResourceObserverPatched_href_link')
    ) {
      const hrefSetter = descriptor.set;
      const hrefGetter = descriptor.get;
      const hrefDescriptor: PropertyDescriptor = {
        configurable: true,
        enumerable: descriptor.enumerable === true,
        set(value: unknown) {
          notify(unwrapUrl(value), getLinkResourceKind(this));
          return hrefSetter.call(this, value);
        },
      };
      if (hrefGetter) {
        hrefDescriptor.get = function () {
          return hrefGetter.call(this);
        };
      }
      Object.defineProperty(HTMLLinkElement.prototype, 'href', hrefDescriptor);
      recordPatch('linkHref');
      recordPatch('stylesheet');
      recordPatch('font');
    }
  }

  const originalSetAttribute =
    typeof Element !== 'undefined' ? Element.prototype.setAttribute : null;
  if (
    typeof originalSetAttribute === 'function' &&
    markPatched(Element.prototype, '__openpathPageResourceObserverSetAttributePatched')
  ) {
    Element.prototype.setAttribute = function (name: string, value: string): void {
      const tag = (this.tagName || '').toLowerCase();
      const attr = (name || '').toLowerCase();
      if (tag === 'img' && attr === 'src') {
        notify(value, 'image');
      }
      if (tag === 'img' && attr === 'srcset') {
        notify(resolveImageUrl(this, value), 'image');
      }
      if (tag === 'source' && attr === 'srcset') {
        notify(parseSrcset(value), 'image');
      }
      if (tag === 'script' && attr === 'src') {
        notify(value, 'script');
      }
      if (tag === 'link' && attr === 'href') {
        notify(value, getLinkResourceKind(this));
      }
      originalSetAttribute.call(this, name, value);
    };
    recordPatch('setAttribute');
  }
})();
