type OpenPathPageResourceKind =
  | 'fetch'
  | 'xmlhttprequest'
  | 'image'
  | 'script'
  | 'stylesheet'
  | 'font'
  | 'other';

interface OpenPathRuntimeLike {
  sendMessage?: (message: unknown) => Promise<unknown>;
}

interface OpenPathContentGlobal {
  browser?: { runtime?: OpenPathRuntimeLike };
  chrome?: { runtime?: OpenPathRuntimeLike };
}

((): void => {
  const contentGlobal = globalThis as typeof globalThis & OpenPathContentGlobal;
  const runtime = contentGlobal.browser?.runtime ?? contentGlobal.chrome?.runtime;
  const source = 'openpath-page-resource-candidate';

  function getCurrentUrl(): string {
    return window.location.href;
  }

  function sendRuntimeMessage(message: unknown): void {
    if (typeof runtime?.sendMessage !== 'function') {
      return;
    }

    try {
      void Promise.resolve(runtime.sendMessage(message)).catch(() => {
        // Best effort only. Page scripts must never be affected by extension wake-up.
      });
    } catch {
      // Best effort only. Page scripts must never be affected by extension wake-up.
    }
  }

  function notifyPageActivity(url = getCurrentUrl()): void {
    if (!url) {
      return;
    }

    sendRuntimeMessage({
      action: 'openpathPageActivity',
      url,
    });
  }

  function notifyPageResourceCandidate(
    resourceUrl: string,
    kind: OpenPathPageResourceKind,
    pageUrl = getCurrentUrl()
  ): void {
    if (!pageUrl || !resourceUrl) {
      return;
    }

    sendRuntimeMessage({
      action: 'openpathPageResourceCandidate',
      kind,
      pageUrl,
      resourceUrl,
    });
  }

  function getCurrentOrigin(): string {
    try {
      return new URL(getCurrentUrl()).origin;
    } catch {
      return '';
    }
  }

  function isPageResourceMessageOriginAllowed(
    eventOrigin: unknown,
    currentOrigin: string
  ): boolean {
    if (typeof eventOrigin !== 'string') {
      return true;
    }

    if (!eventOrigin || eventOrigin === 'null') {
      return true;
    }

    return !currentOrigin || eventOrigin === currentOrigin;
  }

  function getDomResourceCandidate(
    node: unknown
  ): { kind: OpenPathPageResourceKind; url: string } | null {
    const element = node as Partial<
      HTMLImageElement & HTMLScriptElement & HTMLLinkElement & HTMLSourceElement
    >;
    const tagName = typeof element.tagName === 'string' ? element.tagName.toLowerCase() : '';
    if (tagName === 'img') {
      const imageUrl =
        (typeof element.currentSrc === 'string' && element.currentSrc.length > 0
          ? element.currentSrc
          : undefined) ??
        (typeof element.src === 'string' && element.src.length > 0 ? element.src : undefined) ??
        (typeof element.srcset === 'string'
          ? (element.srcset.split(',')[0]?.trim().split(/\s+/u)[0] ?? '')
          : '');
      if (imageUrl.length > 0) {
        return { kind: 'image', url: imageUrl };
      }
    }
    if (tagName === 'source' && typeof element.srcset === 'string' && element.srcset.length > 0) {
      const imageUrl = element.srcset.split(',')[0]?.trim().split(/\s+/u)[0] ?? '';
      if (imageUrl.length > 0) {
        return { kind: 'image', url: imageUrl };
      }
    }
    if (tagName === 'script' && typeof element.src === 'string' && element.src.length > 0) {
      return { kind: 'script', url: element.src };
    }
    if (tagName === 'link' && typeof element.href === 'string' && element.href.length > 0) {
      const relTokens =
        typeof element.rel === 'string' ? element.rel.toLowerCase().split(/\s+/) : [];
      const asValue = typeof element.as === 'string' ? element.as.toLowerCase() : '';
      if (relTokens.includes('preload') && asValue === 'font') {
        return { kind: 'font', url: element.href };
      }
      if (relTokens.includes('stylesheet')) {
        return { kind: 'stylesheet', url: element.href };
      }
    }

    return null;
  }

  function reportDomResourceCandidate(node: unknown): void {
    const candidate = getDomResourceCandidate(node);
    if (!candidate) {
      return;
    }

    notifyPageResourceCandidate(candidate.url, candidate.kind);
  }

  function relayCandidateData(candidateData: unknown): void {
    const data = (candidateData ?? {}) as { kind?: unknown; source?: unknown; url?: unknown };
    if (data.source !== source || typeof data.url !== 'string') {
      return;
    }

    const kind =
      data.kind === 'fetch' ||
      data.kind === 'xmlhttprequest' ||
      data.kind === 'image' ||
      data.kind === 'script' ||
      data.kind === 'stylesheet' ||
      data.kind === 'font'
        ? data.kind
        : 'other';

    notifyPageResourceCandidate(data.url, kind);
  }

  window.addEventListener('message', (event) => {
    const currentOrigin = getCurrentOrigin();
    if (!isPageResourceMessageOriginAllowed(event.origin, currentOrigin)) {
      return;
    }

    relayCandidateData(event.data);
  });

  window.addEventListener('openpath-page-resource-candidate', (event) => {
    relayCandidateData((event as CustomEvent).detail);
  });

  if (typeof MutationObserver === 'function') {
    const observer = new MutationObserver((records) => {
      for (const record of records) {
        for (const node of Array.from(record.addedNodes)) {
          reportDomResourceCandidate(node);
        }
        if (
          record.attributeName === 'src' ||
          record.attributeName === 'srcset' ||
          record.attributeName === 'href' ||
          record.attributeName === 'rel' ||
          record.attributeName === 'as'
        ) {
          reportDomResourceCandidate(record.target);
        }
      }
    });
    observer.observe(document, {
      attributeFilter: ['src', 'srcset', 'href', 'rel', 'as'],
      attributes: true,
      childList: true,
      subtree: true,
    });
  }

  notifyPageActivity();
})();
