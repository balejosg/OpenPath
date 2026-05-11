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

  if (typeof runtime?.sendMessage !== 'function') {
    return;
  }

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
