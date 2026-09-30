import type { Tabs } from 'webextension-polyfill';

import { getErrorMessage, logger } from './logger.js';
import {
  RUNTIME_DEPENDENCY_AUTO_RELOAD_COALESCE_MS,
  RUNTIME_DEPENDENCY_AUTO_RELOAD_MAX_NAVIGATION_AGE_MS,
  RUNTIME_DEPENDENCY_AUTO_RELOAD_TAB_COOLDOWN_MS,
  type LocalRuntimeDependencyInput,
} from './runtime-dependency-protocol.js';

export interface AutoReloadCancellationContext {
  dependencyHost: string;
  frameId: number;
  requestType: string;
  tabId: number;
}

export interface AutoReloadNavigationContext {
  tabId: number;
  url: string;
  method?: string;
}

export interface AutoReloadDiagnosticEvent {
  dependencyHost?: string;
  kind: 'auto-reload';
  navigationId?: number;
  reason: string;
  requestType?: string;
  tabId: number;
}

export interface RuntimeDependencyAutoReloadOptions {
  browserTabs: Pick<Tabs.Static, 'get' | 'reload'>;
  /** True when the host announced the auto-reload capability and the port is ready. */
  isCapable: () => boolean;
  /** URLs that must never be auto-reloaded (extension pages, blocked screen, portal flows). */
  isExcludedUrl?: (url: string) => boolean;
  now?: () => number;
  coalesceMs?: number;
  maxNavigationAgeMs?: number;
  tabCooldownMs?: number;
  recordEvent?: (event: AutoReloadDiagnosticEvent) => void;
}

export interface RuntimeDependencyAutoReloadController {
  noteDependencyCancelled: (context: AutoReloadCancellationContext) => void;
  noteDependencyReady: (input: LocalRuntimeDependencyInput) => void;
  noteMainFrameRequest: (context: AutoReloadNavigationContext) => void;
  noteNavigationCommitted: (context: AutoReloadNavigationContext) => void;
  noteNavigationStarted: (context: AutoReloadNavigationContext) => void;
  disposeTab: (tabId: number) => void;
}

interface NavigationRecord {
  committed: boolean;
  id: number;
  method: string;
  startedAt: number;
  url: string;
}

interface CancelledRecord {
  dependencyHost: string;
  navigationId: number;
  recordedAt: number;
  requestType: string;
  tabId: number;
}

/**
 * Render-critical request types are the only ones whose cancellation makes the
 * first paint wrong: repairing them is worth one automatic reload.
 */
const AUTO_RELOAD_RENDER_CRITICAL_TYPES = new Set(['script', 'stylesheet', 'font']);
const CANCELLED_RECORD_MAX_AGE_MS = 5 * 60 * 1000;
const CANCELLED_RECORD_MAX_ENTRIES = 200;

function normalizeUrlWithoutFragment(rawUrl: string): string {
  try {
    const parsed = new URL(rawUrl);
    parsed.hash = '';
    return parsed.toString();
  } catch {
    return rawUrl;
  }
}

export function createRuntimeDependencyAutoReloadController(
  options: RuntimeDependencyAutoReloadOptions
): RuntimeDependencyAutoReloadController {
  const now = options.now ?? ((): number => Date.now());
  const coalesceMs = options.coalesceMs ?? RUNTIME_DEPENDENCY_AUTO_RELOAD_COALESCE_MS;
  const maxNavigationAgeMs =
    options.maxNavigationAgeMs ?? RUNTIME_DEPENDENCY_AUTO_RELOAD_MAX_NAVIGATION_AGE_MS;
  const tabCooldownMs = options.tabCooldownMs ?? RUNTIME_DEPENDENCY_AUTO_RELOAD_TAB_COOLDOWN_MS;

  const navigations = new Map<number, NavigationRecord>();
  const cancelledRecords: CancelledRecord[] = [];
  const pendingReloadTimers = new Map<number, ReturnType<typeof setTimeout>>();
  const lastReloadAtByTab = new Map<number, number>();
  const reloadedNavigationIds = new Set<number>();
  let nextNavigationId = 1;

  function record(event: AutoReloadDiagnosticEvent): void {
    try {
      options.recordEvent?.(event);
    } catch (error) {
      logger.warn('[Monitor] Falló el registro de diagnóstico de recarga', {
        error: getErrorMessage(error),
      });
    }
  }

  function pruneCancelledRecords(): void {
    const cutoff = now() - CANCELLED_RECORD_MAX_AGE_MS;
    while (cancelledRecords.length > 0 && cancelledRecords[0] !== undefined) {
      if (cancelledRecords[0].recordedAt >= cutoff) {
        break;
      }
      cancelledRecords.shift();
    }
    while (cancelledRecords.length > CANCELLED_RECORD_MAX_ENTRIES) {
      cancelledRecords.shift();
    }
  }

  function scheduleReload(tabId: number): void {
    if (pendingReloadTimers.has(tabId)) {
      return;
    }
    const timer = setTimeout(() => {
      pendingReloadTimers.delete(tabId);
      void performReload(tabId);
    }, coalesceMs);
    pendingReloadTimers.set(tabId, timer);
  }

  async function performReload(tabId: number): Promise<void> {
    const fail = (reason: string): void => {
      record({ kind: 'auto-reload', reason, tabId });
    };

    if (!options.isCapable()) {
      fail('capability-absent');
      return;
    }

    const navigation = navigations.get(tabId);
    if (!navigation) {
      fail('navigation-unknown');
      return;
    }
    if (navigation.method !== 'GET') {
      fail('navigation-not-get');
      return;
    }
    if (now() - navigation.startedAt > maxNavigationAgeMs) {
      fail('navigation-too-old');
      return;
    }
    if (reloadedNavigationIds.has(navigation.id)) {
      fail('already-reloaded');
      return;
    }
    const lastReloadAt = lastReloadAtByTab.get(tabId);
    if (lastReloadAt !== undefined && now() - lastReloadAt < tabCooldownMs) {
      fail('tab-cooldown');
      return;
    }

    let currentUrl: string | undefined;
    try {
      const tab = await options.browserTabs.get(tabId);
      currentUrl = tab.url;
    } catch (error) {
      record({
        kind: 'auto-reload',
        reason: `tab-unavailable:${getErrorMessage(error)}`,
        tabId,
      });
      return;
    }

    if (
      !currentUrl ||
      normalizeUrlWithoutFragment(currentUrl) !== normalizeUrlWithoutFragment(navigation.url)
    ) {
      fail('url-mismatch');
      return;
    }
    if (options.isExcludedUrl?.(currentUrl) === true) {
      fail('excluded-url');
      return;
    }

    try {
      await options.browserTabs.reload(tabId);
      reloadedNavigationIds.add(navigation.id);
      lastReloadAtByTab.set(tabId, now());
      record({
        kind: 'auto-reload',
        reason: 'reloaded',
        tabId,
        navigationId: navigation.id,
      });
    } catch (error) {
      record({
        kind: 'auto-reload',
        reason: `reload-failed:${getErrorMessage(error)}`,
        tabId,
        navigationId: navigation.id,
      });
    }
  }

  return {
    noteNavigationStarted: (context): void => {
      navigations.set(context.tabId, {
        committed: false,
        id: nextNavigationId,
        method: context.method ?? '',
        startedAt: now(),
        url: context.url,
      });
      nextNavigationId += 1;
      const pending = pendingReloadTimers.get(context.tabId);
      if (pending !== undefined) {
        clearTimeout(pending);
        pendingReloadTimers.delete(context.tabId);
      }
    },
    noteMainFrameRequest: (context): void => {
      const existing = navigations.get(context.tabId);
      if (!existing) {
        navigations.set(context.tabId, {
          committed: false,
          id: nextNavigationId,
          method: context.method ?? '',
          startedAt: now(),
          url: context.url,
        });
        nextNavigationId += 1;
        return;
      }
      if (context.method) {
        existing.method = context.method;
      }
      if (!existing.committed) {
        // A redirect chain reports the final document URL on the request.
        existing.url = context.url;
      }
    },
    noteNavigationCommitted: (context): void => {
      const existing = navigations.get(context.tabId);
      if (
        !existing ||
        normalizeUrlWithoutFragment(existing.url) !== normalizeUrlWithoutFragment(context.url)
      ) {
        navigations.set(context.tabId, {
          committed: true,
          id: nextNavigationId,
          method: existing?.method ?? '',
          startedAt: existing?.startedAt ?? now(),
          url: context.url,
        });
        nextNavigationId += 1;
        return;
      }
      existing.committed = true;
      existing.url = context.url;
    },
    noteDependencyCancelled: (context): void => {
      if (
        context.frameId !== 0 ||
        !AUTO_RELOAD_RENDER_CRITICAL_TYPES.has(context.requestType.toLowerCase())
      ) {
        return;
      }
      pruneCancelledRecords();
      cancelledRecords.push({
        dependencyHost: context.dependencyHost.toLowerCase(),
        navigationId: navigations.get(context.tabId)?.id ?? -1,
        recordedAt: now(),
        requestType: context.requestType.toLowerCase(),
        tabId: context.tabId,
      });
    },
    noteDependencyReady: (input): void => {
      pruneCancelledRecords();
      const dependencyHost = input.dependencyHost.toLowerCase();
      // Consume the matching cancellations: each one is repaired by at most one
      // reload, and the navigation check below decides if it still applies.
      for (let index = cancelledRecords.length - 1; index >= 0; index -= 1) {
        const record = cancelledRecords[index];
        if (record?.dependencyHost !== dependencyHost) {
          continue;
        }
        cancelledRecords.splice(index, 1);
        const navigation = navigations.get(record.tabId);
        if (navigation?.id !== record.navigationId) {
          continue;
        }
        scheduleReload(record.tabId);
      }
    },
    disposeTab: (tabId): void => {
      navigations.delete(tabId);
      const pending = pendingReloadTimers.get(tabId);
      if (pending !== undefined) {
        clearTimeout(pending);
        pendingReloadTimers.delete(tabId);
      }
    },
  };
}
