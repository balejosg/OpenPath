interface GoogleSearchGameGuardRuntimeMessage {
  action: 'openpathGoogleSearchGameBlocked';
  blockedAt: number;
  pageHost: string;
  pagePath: string;
  reason: string;
  signals: string[];
}

interface GoogleSearchGameGuardRuntimeLike {
  sendMessage?: (message: GoogleSearchGameGuardRuntimeMessage) => Promise<unknown>;
}

interface GoogleSearchGameGuardGlobal {
  browser?: {
    i18n?: { getMessage?: (key: string) => string };
    runtime?: GoogleSearchGameGuardRuntimeLike;
  };
  chrome?: {
    i18n?: { getMessage?: (key: string) => string };
    runtime?: GoogleSearchGameGuardRuntimeLike;
  };
}

((): void => {
  const guardGlobal = globalThis as typeof globalThis & GoogleSearchGameGuardGlobal;
  const runtime = guardGlobal.browser?.runtime ?? guardGlobal.chrome?.runtime;
  const blockAttribute = 'data-openpath-google-game-guard';
  const blockedValue = 'blocked';
  const scanSelector = [
    'canvas',
    'iframe',
    'object',
    'embed',
    'button',
    'a[href]',
    '[role="button"]',
    '[aria-label]',
    '[title]',
    '[class*="game" i]',
    '[id*="game" i]',
    '[class*="doodle" i]',
    '[id*="doodle" i]',
    '[data-game]',
    '[data-attrid]',
  ].join(',');
  const unsafeContainerSelector =
    'html, body, main, form, [role="main"], [role="search"], #search, #rso';
  // Patterns intentionally exclude generic navigation/account verbs such as
  // "iniciar" (as in "Iniciar sesion"/Sign in), "start", "empezar", "comenzar"
  // and "reanudar". Those appear in ordinary Google chrome on every search page
  // and previously made the sign-in control look like a game play-control.
  const gameTextPattern =
    /\b(play|new game|tap to play|game|games|juego|juegos|jugar|juega|solitaire|solitario|tic tac toe|tres en raya|snake|pac[\s-]?man|buscaminas|minesweeper|memory)\b/i;
  const playTextPattern = /\b(play|new game|tap to play|jugar|juega)\b/i;
  const gameResourcePattern = /(?:doodles\.google|google\.[^/]+\/logos\/|\/logos\/doodles?\/)/i;
  const googleGamePolicyReason = 'GOOGLE_GAME_POLICY';

  function getI18nMessage(key: string, fallback: string): string {
    const i18n = guardGlobal.browser?.i18n ?? guardGlobal.chrome?.i18n;
    if (typeof i18n?.getMessage !== 'function') {
      return fallback;
    }
    return i18n.getMessage(key) || fallback;
  }

  function getLocationParts(): { host: string; path: string; search: string } {
    return {
      host: window.location.hostname.toLowerCase(),
      path: window.location.pathname || '/',
      search: window.location.search || '',
    };
  }

  function isGoogleSearchHost(host: string): boolean {
    return /^(.+\.)?google\.[a-z.]+$/i.test(host);
  }

  function isDoodlesHost(host: string): boolean {
    return host === 'doodles.google' || host.endsWith('.doodles.google');
  }

  function isSearchPath(path: string, search: string): boolean {
    return path === '/search' || path === '/webhp' || (path === '/' && search.includes('q='));
  }

  function isGuardEligible(): boolean {
    const { host, path, search } = getLocationParts();
    return isDoodlesHost(host) || (isGoogleSearchHost(host) && isSearchPath(path, search));
  }

  function readAttribute(element: Element, attributeName: string): string {
    return element.getAttribute(attributeName) ?? '';
  }

  function getElementText(element: Element): string {
    const text = (element as { textContent?: string | null }).textContent;
    return typeof text === 'string' ? text.slice(0, 5000) : '';
  }

  function matchesSafely(element: Element, selector: string): boolean {
    try {
      return element.matches(selector);
    } catch {
      return false;
    }
  }

  function isUnsafeContainer(element: Element): boolean {
    return matchesSafely(element, unsafeContainerSelector);
  }

  function querySelectorSafely(root: ParentNode, selector: string): Element | null {
    try {
      return root.querySelector(selector);
    } catch {
      return null;
    }
  }

  // A genuine game widget is a localized element. Anything that encloses the
  // search-results region (or another structural root) is a page-level
  // container and must never be replaced, otherwise a single stray signal would
  // blank out the entire results page.
  function enclosesProtectedRegion(element: Element): boolean {
    return querySelectorSafely(element, unsafeContainerSelector) !== null;
  }

  function hasBlockedAncestor(element: Element): boolean {
    return element.closest(`[${blockAttribute}]`) !== null;
  }

  function querySelectorAllSafely(root: ParentNode, selector: string): Element[] {
    try {
      return Array.from(root.querySelectorAll(selector));
    } catch {
      return [];
    }
  }

  function hasInteractiveSurface(element: Element): boolean {
    const tag = element.tagName.toLowerCase();
    return (
      tag === 'canvas' ||
      tag === 'iframe' ||
      tag === 'object' ||
      tag === 'embed' ||
      element.querySelector('canvas, iframe, object, embed') !== null
    );
  }

  function isControlElement(element: Element): boolean {
    const tag = element.tagName.toLowerCase();
    return (
      tag === 'button' ||
      (tag === 'a' && readAttribute(element, 'href').length > 0) ||
      readAttribute(element, 'role').toLowerCase() === 'button' ||
      (tag === 'input' &&
        ['button', 'submit'].includes(readAttribute(element, 'type').toLowerCase()))
    );
  }

  function getControlLabel(element: Element): string {
    return [
      getElementText(element),
      readAttribute(element, 'aria-label'),
      readAttribute(element, 'title'),
      readAttribute(element, 'value'),
    ].join(' ');
  }

  function hasPlayControl(element: Element): boolean {
    const controls = [
      ...(isControlElement(element) ? [element] : []),
      ...querySelectorAllSafely(
        element,
        'button, a[href], [role="button"], input[type="button"], input[type="submit"]'
      ),
    ];
    return controls.some((control) => playTextPattern.test(getControlLabel(control)));
  }

  function hasGameText(element: Element): boolean {
    return gameTextPattern.test(
      [
        getElementText(element),
        readAttribute(element, 'aria-label'),
        readAttribute(element, 'title'),
        readAttribute(element, 'class'),
        readAttribute(element, 'id'),
      ].join(' ')
    );
  }

  function hasGoogleGameResource(element: Element): boolean {
    const candidates = [
      readAttribute(element, 'href'),
      readAttribute(element, 'src'),
      readAttribute(element, 'data-url'),
      ...querySelectorAllSafely(element, 'a[href], iframe[src], img[src], script[src], [data-url]')
        .flatMap((node) => [
          readAttribute(node, 'href'),
          readAttribute(node, 'src'),
          readAttribute(node, 'data-url'),
        ])
        .filter((value) => value.length > 0),
    ];
    return candidates.some((value) => gameResourcePattern.test(value));
  }

  function collectSignals(element: Element): string[] {
    const signals: string[] = [];
    if (hasInteractiveSurface(element)) {
      signals.push('interactive-surface');
    }
    if (hasPlayControl(element)) {
      signals.push('play-control');
    }
    if (hasGameText(element)) {
      signals.push('game-text');
    }
    if (hasGoogleGameResource(element)) {
      signals.push('google-game-resource');
    }
    return signals;
  }

  function shouldBlockSignals(signals: string[]): boolean {
    const hasInteractive = signals.includes('interactive-surface');
    const hasPlay = signals.includes('play-control');
    const hasText = signals.includes('game-text');
    const hasResource = signals.includes('google-game-resource');
    return (
      (hasInteractive && hasPlay && hasText) ||
      (hasInteractive && hasResource) ||
      (hasPlay && hasText && hasResource)
    );
  }

  function findBlockTarget(candidate: Element): { element: Element; signals: string[] } | null {
    let current = candidate;
    while (current.parentElement) {
      if (hasBlockedAncestor(current)) {
        return null;
      }
      if (isUnsafeContainer(current) || enclosesProtectedRegion(current)) {
        return null;
      }

      const signals = collectSignals(current);
      if (shouldBlockSignals(signals)) {
        return { element: current, signals };
      }
      current = current.parentElement;
    }
    return null;
  }

  function sendBlockedMessage(reason: string, signals: string[]): void {
    if (typeof runtime?.sendMessage !== 'function') {
      return;
    }

    const { host, path } = getLocationParts();
    try {
      void Promise.resolve(
        runtime.sendMessage({
          action: 'openpathGoogleSearchGameBlocked',
          blockedAt: Date.now(),
          pageHost: host,
          pagePath: path,
          reason,
          signals,
        })
      ).catch(() => {
        // Best effort only. Guard enforcement must not depend on background wake-up.
      });
    } catch {
      // Best effort only. The page must not observe extension diagnostics failures.
    }
  }

  function buildBlockedNotice(): HTMLElement {
    const notice = document.createElement('div');
    notice.setAttribute(blockAttribute, blockedValue);
    notice.setAttribute('role', 'note');
    notice.textContent = getI18nMessage('googleGameBlockedNotice', 'Game blocked by OpenPath');
    notice.setAttribute(
      'style',
      'box-sizing:border-box;margin:8px 0;padding:12px;border:1px solid #b3261e;background:#fff5f5;color:#5f1b16;font:14px/1.4 system-ui,sans-serif;'
    );
    return notice;
  }

  function blockElement(element: Element, signals: string[], reason: string): boolean {
    if (element.getAttribute(blockAttribute) !== null || isUnsafeContainer(element)) {
      return false;
    }

    const notice = buildBlockedNotice();
    element.setAttribute(blockAttribute, blockedValue);
    element.replaceWith(notice);
    sendBlockedMessage(reason, signals);
    return true;
  }

  function blockDoodlesPage(): void {
    const { host } = getLocationParts();
    const body = document.body as HTMLElement | null;
    if (!isDoodlesHost(host) || !body || body.getAttribute(blockAttribute)) {
      return;
    }
    const notice = buildBlockedNotice();
    body.setAttribute(blockAttribute, blockedValue);
    body.textContent = '';
    body.appendChild(notice);
    sendBlockedMessage(`${googleGamePolicyReason}:doodles`, ['google-game-resource', 'game-text']);
  }

  function scanForGameWidgets(): void {
    if (!isGuardEligible()) {
      return;
    }

    blockDoodlesPage();
    const candidates = querySelectorAllSafely(document, scanSelector);
    for (const candidate of candidates) {
      const target = findBlockTarget(candidate);
      if (target) {
        blockElement(target.element, target.signals, `${googleGamePolicyReason}:search-widget`);
      }
    }
  }

  if (!isGuardEligible()) {
    return;
  }

  scanForGameWidgets();

  if (typeof MutationObserver === 'function') {
    const observer = new MutationObserver(() => {
      scanForGameWidgets();
    });
    observer.observe(document, { childList: true, subtree: true });
  }

  for (const delay of [100, 500, 1500]) {
    window.setTimeout(scanForGameWidgets, delay);
  }
})();
