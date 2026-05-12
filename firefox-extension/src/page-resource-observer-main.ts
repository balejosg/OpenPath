interface OpenPathPageResourceObserverWindow {
  __openpathPageResourceObserverInstalled?: boolean;
  __openpathPageResourceObserverState?: {
    candidateCount: number;
    installedAt: string;
    lastCandidateAt: string | null;
    version: number;
  };
}

((): void => {
  const pageWindow = window as typeof window & OpenPathPageResourceObserverWindow;

  if (pageWindow.__openpathPageResourceObserverInstalled === true) {
    return;
  }

  const state = {
    candidateCount: 0,
    installedAt: new Date().toISOString(),
    lastCandidateAt: null as string | null,
    version: 1,
  };
  pageWindow.__openpathPageResourceObserverInstalled = true;
  pageWindow.__openpathPageResourceObserverState = state;

  const normalizeUrl = (value: unknown): string | null => {
    if (typeof value !== 'string' || value.length === 0) {
      return null;
    }
    try {
      const parsed = new URL(value, window.location.href);
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
        return null;
      }
      return parsed.href;
    } catch {
      return null;
    }
  };

  const emitCandidate = (kind: string, urlValue: unknown): void => {
    const url = normalizeUrl(urlValue);
    if (!url) {
      return;
    }

    state.candidateCount += 1;
    state.lastCandidateAt = new Date().toISOString();
    const payload = {
      source: 'openpath-page-resource-candidate',
      kind,
      url,
      pageUrl: window.location.href,
    };

    window.postMessage(payload, '*');
    window.dispatchEvent(new CustomEvent('openpath-page-resource-candidate', { detail: payload }));
  };

  const originalFetch = window.fetch;
  if (typeof originalFetch === 'function') {
    window.fetch = function openPathObservedFetch(
      input: RequestInfo | URL,
      init?: RequestInit
    ): Promise<Response> {
      const requestUrl =
        typeof input === 'string'
          ? input
          : input instanceof URL
            ? input.href
            : input instanceof Request
              ? input.url
              : null;
      emitCandidate('fetch', requestUrl);
      return originalFetch.call(this, input, init);
    };
  }

  const originalOpen = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'open')
    ?.value as XMLHttpRequest['open'];
  const originalSend = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'send')
    ?.value as XMLHttpRequest['send'];
  XMLHttpRequest.prototype.open = function openPathObservedXhrOpen(
    method: string,
    url: string | URL,
    async?: boolean,
    username?: string | null,
    password?: string | null
  ): void {
    Object.defineProperty(this, '__openpathObservedUrl', {
      configurable: true,
      value: typeof url === 'string' ? url : url.href,
    });
    originalOpen.call(this, method, url, async ?? true, username ?? null, password ?? null);
  };
  XMLHttpRequest.prototype.send = function openPathObservedXhrSend(
    body?: Document | XMLHttpRequestBodyInit | null
  ): void {
    emitCandidate(
      'xmlhttprequest',
      (this as XMLHttpRequest & { __openpathObservedUrl?: string }).__openpathObservedUrl
    );
    originalSend.call(this, body);
  };

  const classifyLink = (element: HTMLLinkElement): string | null => {
    const rel = element.rel.toLowerCase();
    if (rel.includes('stylesheet')) {
      return 'stylesheet';
    }
    if (rel.includes('preload') && element.as.toLowerCase() === 'font') {
      return 'font';
    }
    return null;
  };

  const observeElement = (element: Element): void => {
    if (element instanceof HTMLImageElement) {
      emitCandidate('image', element.currentSrc || element.src);
    } else if (element instanceof HTMLScriptElement) {
      emitCandidate('script', element.src);
    } else if (element instanceof HTMLLinkElement) {
      const kind = classifyLink(element);
      if (kind) {
        emitCandidate(kind, element.href);
      }
    } else if (element instanceof HTMLStyleElement) {
      const css = element.textContent;
      const urlPattern = /url\((['"]?)(.*?)\1\)/gi;
      let match: RegExpExecArray | null;
      while ((match = urlPattern.exec(css))) {
        emitCandidate('font', match[2]);
      }
    }
  };

  const observeTree = (node: Node): void => {
    if (!(node instanceof Element)) {
      return;
    }
    observeElement(node);
    for (const element of Array.from(
      node.querySelectorAll('img[src],script[src],link[href],style')
    )) {
      observeElement(element);
    }
  };

  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      for (const node of Array.from(mutation.addedNodes)) {
        observeTree(node);
      }
    }
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });

  const patchUrlProperty = <TElement extends Element>(
    prototype: TElement,
    propertyName: 'href' | 'src',
    kindForElement: (element: TElement) => string | null
  ): void => {
    const descriptor = Object.getOwnPropertyDescriptor(prototype, propertyName);
    if (!descriptor?.set || !descriptor.get) {
      return;
    }
    const readProperty = (element: TElement): string => descriptor.get?.call(element) as string;
    const writeProperty = (element: TElement, value: string): void => {
      descriptor.set?.call(element, value);
    };

    Object.defineProperty(prototype, propertyName, {
      configurable: true,
      enumerable: descriptor.enumerable ?? false,
      get(this: TElement): string {
        return readProperty(this);
      },
      set(this: TElement, value: string) {
        const kind = kindForElement(this);
        if (kind) {
          emitCandidate(kind, value);
        }
        writeProperty(this, value);
      },
    });
  };

  patchUrlProperty(HTMLImageElement.prototype, 'src', () => 'image');
  patchUrlProperty(HTMLScriptElement.prototype, 'src', () => 'script');
  patchUrlProperty(HTMLLinkElement.prototype, 'href', (element) => classifyLink(element));
})();
