interface OpenPathRuntimeLike {
  sendMessage?: (message: unknown) => Promise<unknown>;
}

interface OpenPathContentGlobal {
  browser?: { runtime?: OpenPathRuntimeLike };
  chrome?: { runtime?: OpenPathRuntimeLike };
}

interface OpenPathPageResourceCandidate {
  kind?: unknown;
  pageUrl?: unknown;
  source?: unknown;
  url?: unknown;
}

function isPageResourceCandidate(value: unknown): value is OpenPathPageResourceCandidate {
  if (!value || typeof value !== 'object') {
    return false;
  }
  const candidate = value as OpenPathPageResourceCandidate;
  return (
    candidate.source === 'openpath-page-resource-candidate' &&
    typeof candidate.url === 'string' &&
    candidate.url.length > 0
  );
}

function installPageResourceObserverBridge(runtime: OpenPathRuntimeLike): void {
  if (typeof window === 'undefined') {
    return;
  }

  window.addEventListener('message', (event: MessageEvent<unknown>) => {
    if (event.source !== window || !isPageResourceCandidate(event.data)) {
      return;
    }

    const candidate = event.data;
    try {
      void Promise.resolve(
        runtime.sendMessage?.({
          action: 'openpathPageResourceCandidate',
          kind: typeof candidate.kind === 'string' ? candidate.kind : 'other',
          pageUrl: typeof candidate.pageUrl === 'string' ? candidate.pageUrl : undefined,
          resourceUrl: candidate.url,
        })
      ).catch(() => {
        // Best effort only. Candidate diagnostics must not affect page execution.
      });
    } catch {
      // Best effort only. Candidate diagnostics must not affect page execution.
    }
  });
}

((): void => {
  const contentGlobal = globalThis as typeof globalThis & OpenPathContentGlobal;
  const runtime = contentGlobal.browser?.runtime ?? contentGlobal.chrome?.runtime;

  if (typeof runtime?.sendMessage !== 'function') {
    return;
  }

  installPageResourceObserverBridge(runtime);

  try {
    void Promise.resolve(
      runtime.sendMessage({
        action: 'openpathPageActivity',
      })
    ).catch(() => {
      // Best effort only. Page scripts must never be affected by extension wake-up.
    });
  } catch {
    // Best effort only. Page scripts must never be affected by extension wake-up.
  }
})();
