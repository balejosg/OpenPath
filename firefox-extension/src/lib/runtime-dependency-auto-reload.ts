import type { Tabs } from 'webextension-polyfill';

import { getErrorMessage, logger } from './logger.js';
import { recordExtensionDiagnostic } from './extension-diagnostics.js';
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
  /**
   * Phase 2E E3: fallback navigation identity for a cancellation observed
   * before any navigation event reached the background (late background start).
   */
  documentUrl?: string;
}

export interface AutoReloadNavigationContext {
  tabId: number;
  url: string;
  method?: string;
  /** webNavigation.onCommitted transition type (e.g. 'form_submit'). */
  transitionType?: string;
}

export interface AutoReloadDiagnosticEvent {
  dependencyHost?: string;
  kind: 'auto-reload';
  navigationId?: number;
  reason: string;
  /** Phase 2E: the repaired request was released (not cancelled) at its budget. */
  released?: boolean;
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
  /**
   * Phase 2E: a render-critical frame-0 request was released by its soft timeout
   * while the dependency was still unproven (the port was connecting and the
   * capability was unknown). It is repaired by the same single auto-reload when
   * the dependency later becomes ready.
   */
  noteDependencyReleased: (context: AutoReloadCancellationContext) => void;
  noteDependencyReady: (input: LocalRuntimeDependencyInput) => void;
  noteMainFrameRequest: (context: AutoReloadNavigationContext) => void;
  noteNavigationCommitted: (context: AutoReloadNavigationContext) => void;
  noteNavigationStarted: (context: AutoReloadNavigationContext) => void;
  noteHistoryStateUpdated: (context: AutoReloadNavigationContext) => void;
  disposeTab: (tabId: number) => void;
}

interface NavigationRecord {
  committed: boolean;
  committedAt: number;
  id: number;
  method: string;
  /** Phase 2E E3: false when only onBeforeNavigate/onCommitted were observed. */
  methodKnown: boolean;
  startedAt: number;
  url: string;
  /** Per-tab document identity: increments on every main-frame commit. */
  documentToken: number;
  /** webNavigation.onCommitted reported a form submission. */
  formSubmit: boolean;
  /** Last same-document history update after the commit. */
  historyUpdatedAt: number;
  host: string;
}

interface CancelledRecord {
  dependencyHost: string;
  navigationId: number;
  recordedAt: number;
  requestType: string;
  tabId: number;
  documentUrl?: string;
  documentHost?: string;
  documentToken?: number;
  /** Phase 2E: true when the request was released by its soft budget. */
  released: boolean;
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

function parseUrl(rawUrl: string): URL | null {
  try {
    return new URL(rawUrl);
  } catch {
    return null;
  }
}

function hostOf(rawUrl: string): string {
  return parseUrl(rawUrl)?.host.toLowerCase() ?? '';
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
  const documentTokenByTab = new Map<number, number>();
  let nextNavigationId = 1;

  function record(event: AutoReloadDiagnosticEvent): void {
    try {
      options.recordEvent?.(event);
    } catch (error) {
      logger.warn('[Monitor] Falló el registro de diagnóstico de recarga', {
        error: getErrorMessage(error),
      });
    }
    // Phase 2E E1: every decision (including the previously silent ones) is
    // visible in the lab through the host log.
    recordExtensionDiagnostic({
      kind: 'reload-decision',
      reason: event.reason,
      tabId: event.tabId,
      ...(event.navigationId !== undefined ? { navigationId: event.navigationId } : {}),
      ...(event.dependencyHost ? { dependencyHost: event.dependencyHost } : {}),
      ...(event.requestType ? { type: event.requestType } : {}),
    });
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

  function scheduleReload(tabId: number, record: CancelledRecord): void {
    if (pendingReloadTimers.has(tabId)) {
      return;
    }
    const timer = setTimeout(() => {
      pendingReloadTimers.delete(tabId);
      void performReload(tabId, record);
    }, coalesceMs);
    pendingReloadTimers.set(tabId, timer);
  }

  function isSameDocument(
    tabId: number,
    navigation: NavigationRecord,
    currentUrl: string,
    cancelled: CancelledRecord
  ): boolean {
    if (
      normalizeUrlWithoutFragment(currentUrl) === normalizeUrlWithoutFragment(navigation.url) ||
      (cancelled.documentUrl !== undefined &&
        normalizeUrlWithoutFragment(currentUrl) ===
          normalizeUrlWithoutFragment(cancelled.documentUrl))
    ) {
      return true;
    }
    const current = parseUrl(currentUrl);
    const navigated = parseUrl(navigation.url);
    if (!current || !navigated) {
      return false;
    }
    if (current.origin !== navigated.origin) {
      // Another site: the tab is in another document, never reload it.
      return false;
    }
    // Same origin: a same-path change (query/hash) is the same document. A
    // path change is only accepted when a same-document history update
    // (replaceState/pushState) was observed after the commit; otherwise the tab
    // may be in another same-origin document and must not be reloaded.
    if (current.pathname === navigated.pathname) {
      return true;
    }
    const currentToken = documentTokenByTab.get(tabId);
    if (
      cancelled.documentToken !== undefined &&
      currentToken !== undefined &&
      currentToken !== cancelled.documentToken
    ) {
      return false;
    }
    return navigation.historyUpdatedAt > navigation.committedAt;
  }

  async function performReload(tabId: number, cancelled: CancelledRecord): Promise<void> {
    const fail = (reason: string): void => {
      record({
        kind: 'auto-reload',
        reason,
        tabId,
        dependencyHost: cancelled.dependencyHost,
        ...(cancelled.released ? { released: true } : {}),
        ...(cancelled.navigationId >= 0 ? { navigationId: cancelled.navigationId } : {}),
      });
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
    if (navigation.formSubmit) {
      fail('navigation-form-submit');
      return;
    }
    // Phase 2E E3: an unknown method allows the reload (a late background never
    // sees the main-frame request); a known non-GET never does.
    if (navigation.methodKnown && navigation.method !== 'GET') {
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
        dependencyHost: cancelled.dependencyHost,
      });
      return;
    }

    if (!currentUrl) {
      fail('tab-no-url');
      return;
    }
    if (!isSameDocument(tabId, navigation, currentUrl, cancelled)) {
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
        dependencyHost: cancelled.dependencyHost,
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

  function createNavigationRecord(
    context: AutoReloadNavigationContext,
    committed: boolean
  ): NavigationRecord {
    return {
      committed,
      committedAt: committed ? now() : 0,
      id: nextNavigationId++,
      method: context.method ?? '',
      methodKnown: typeof context.method === 'string' && context.method.length > 0,
      startedAt: now(),
      url: context.url,
      documentToken: documentTokenByTab.get(context.tabId) ?? 0,
      formSubmit: context.transitionType === 'form_submit',
      historyUpdatedAt: 0,
      host: hostOf(context.url),
    };
  }

  function rememberRepairRecord(context: AutoReloadCancellationContext, released: boolean): void {
    if (
      context.frameId !== 0 ||
      !AUTO_RELOAD_RENDER_CRITICAL_TYPES.has(context.requestType.toLowerCase())
    ) {
      return;
    }
    pruneCancelledRecords();
    let navigation = navigations.get(context.tabId);
    if (!navigation && context.documentUrl) {
      // Phase 2E E3: the background may have started after the navigation
      // events. Rebuild the identity from the frame-0 request's document URL
      // instead of recording navigationId -1 and losing the repair.
      navigation = {
        committed: false,
        committedAt: 0,
        id: nextNavigationId++,
        method: '',
        methodKnown: false,
        startedAt: now(),
        url: context.documentUrl,
        documentToken: documentTokenByTab.get(context.tabId) ?? 0,
        formSubmit: false,
        historyUpdatedAt: 0,
        host: hostOf(context.documentUrl),
      };
      navigations.set(context.tabId, navigation);
      recordExtensionDiagnostic({
        kind: 'navigation',
        source: 'document-url-fallback',
        tabId: context.tabId,
        navigationId: navigation.id,
        host: navigation.host,
        methodKnown: false,
        committed: false,
      });
    }
    cancelledRecords.push({
      dependencyHost: context.dependencyHost.toLowerCase(),
      navigationId: navigation?.id ?? -1,
      recordedAt: now(),
      requestType: context.requestType.toLowerCase(),
      tabId: context.tabId,
      ...(context.documentUrl ? { documentUrl: context.documentUrl } : {}),
      ...(context.documentUrl ? { documentHost: hostOf(context.documentUrl) } : {}),
      ...(navigation ? { documentToken: navigation.documentToken } : {}),
      released,
    });
    recordExtensionDiagnostic({
      kind: 'hold-outcome',
      tabId: context.tabId,
      frameId: context.frameId,
      type: context.requestType.toLowerCase(),
      dependencyHost: context.dependencyHost.toLowerCase(),
      outcome: released ? 'released-budget' : 'cancelled-budget',
    });
  }

  return {
    noteNavigationStarted: (context): void => {
      const navigation = createNavigationRecord(context, false);
      navigations.set(context.tabId, navigation);
      recordExtensionDiagnostic({
        kind: 'navigation',
        source: 'onBeforeNavigate',
        tabId: context.tabId,
        navigationId: navigation.id,
        host: navigation.host,
        methodKnown: navigation.methodKnown,
        committed: false,
      });
      const pending = pendingReloadTimers.get(context.tabId);
      if (pending !== undefined) {
        clearTimeout(pending);
        pendingReloadTimers.delete(context.tabId);
      }
    },
    noteMainFrameRequest: (context): void => {
      const existing = navigations.get(context.tabId);
      if (!existing) {
        const navigation = createNavigationRecord(context, false);
        navigations.set(context.tabId, navigation);
        recordExtensionDiagnostic({
          kind: 'navigation',
          source: 'webRequest.onBeforeRequest',
          tabId: context.tabId,
          navigationId: navigation.id,
          host: navigation.host,
          methodKnown: navigation.methodKnown,
          committed: false,
        });
        return;
      }
      if (context.method && context.method.length > 0) {
        existing.method = context.method;
        existing.methodKnown = true;
      }
      if (!existing.committed) {
        // A redirect chain reports the final document URL on the request.
        existing.url = context.url;
        existing.host = hostOf(context.url);
      }
      recordExtensionDiagnostic({
        kind: 'navigation',
        source: 'webRequest.onBeforeRequest',
        tabId: context.tabId,
        navigationId: existing.id,
        host: existing.host,
        methodKnown: existing.methodKnown,
        committed: existing.committed,
      });
    },
    noteNavigationCommitted: (context): void => {
      const token = (documentTokenByTab.get(context.tabId) ?? 0) + 1;
      documentTokenByTab.set(context.tabId, token);
      const existing = navigations.get(context.tabId);
      if (
        !existing ||
        normalizeUrlWithoutFragment(existing.url) !== normalizeUrlWithoutFragment(context.url)
      ) {
        const navigation = createNavigationRecord(context, true);
        navigation.documentToken = token;
        navigations.set(context.tabId, navigation);
        recordExtensionDiagnostic({
          kind: 'navigation',
          source: 'onCommitted',
          tabId: context.tabId,
          navigationId: navigation.id,
          host: navigation.host,
          methodKnown: navigation.methodKnown,
          committed: true,
        });
        return;
      }
      existing.committed = true;
      existing.committedAt = now();
      existing.url = context.url;
      existing.host = hostOf(context.url);
      existing.documentToken = token;
      existing.formSubmit = existing.formSubmit || context.transitionType === 'form_submit';
      recordExtensionDiagnostic({
        kind: 'navigation',
        source: 'onCommitted',
        tabId: context.tabId,
        navigationId: existing.id,
        host: existing.host,
        methodKnown: existing.methodKnown,
        committed: true,
      });
    },
    noteHistoryStateUpdated: (context): void => {
      const existing = navigations.get(context.tabId);
      if (existing) {
        existing.historyUpdatedAt = now();
      }
      recordExtensionDiagnostic({
        kind: 'navigation',
        source: 'onHistoryStateUpdated',
        tabId: context.tabId,
        ...(existing ? { navigationId: existing.id } : {}),
        host: hostOf(context.url),
      });
    },
    noteDependencyCancelled: (context): void => {
      rememberRepairRecord(context, false);
    },
    noteDependencyReleased: (context): void => {
      // Phase 2E: the request was released by its soft timeout while the port
      // was still connecting, so neither the capability nor the readiness could
      // be proven. Repair it with the same single auto-reload when the
      // dependency becomes ready in the same document.
      rememberRepairRecord(context, true);
    },
    noteDependencyReady: (input): void => {
      pruneCancelledRecords();
      const dependencyHost = input.dependencyHost.toLowerCase();
      // Consume the matching cancellations: each one is repaired by at most one
      // reload, and the navigation check below decides if it still applies.
      for (let index = cancelledRecords.length - 1; index >= 0; index -= 1) {
        const cancelled = cancelledRecords[index];
        if (cancelled?.dependencyHost !== dependencyHost) {
          continue;
        }
        cancelledRecords.splice(index, 1);
        const navigation = navigations.get(cancelled.tabId);
        if (navigation?.id === cancelled.navigationId) {
          scheduleReload(cancelled.tabId, cancelled);
          continue;
        }
        // Phase 2E E3: previously a silent `continue`. The navigation record may
        // be missing (background started late) or superseded by a newer record
        // for the same document; adopt it by document identity when the tab is
        // still on the cancelled document.
        if (cancelled.navigationId === -1 || !navigation) {
          const cancelledHost = cancelled.documentHost ?? '';
          const currentToken = documentTokenByTab.get(cancelled.tabId);
          const sameDocument =
            cancelledHost.length > 0 &&
            (navigation === undefined
              ? true
              : navigation.host === cancelledHost &&
                (cancelled.documentToken === undefined ||
                  currentToken === undefined ||
                  currentToken === cancelled.documentToken));
          if (sameDocument) {
            if (!navigation && cancelled.documentUrl) {
              navigations.set(cancelled.tabId, {
                committed: false,
                committedAt: 0,
                id: nextNavigationId++,
                method: '',
                methodKnown: false,
                startedAt: cancelled.recordedAt,
                url: cancelled.documentUrl,
                documentToken: currentToken ?? cancelled.documentToken ?? 0,
                formSubmit: false,
                historyUpdatedAt: 0,
                host: cancelledHost,
              });
            }
            record({
              kind: 'auto-reload',
              reason: 'ready-adopted-document',
              tabId: cancelled.tabId,
              dependencyHost,
            });
            scheduleReload(cancelled.tabId, cancelled);
            continue;
          }
        }
        record({
          kind: 'auto-reload',
          reason: navigation ? 'navigation-mismatch' : 'navigation-unknown',
          tabId: cancelled.tabId,
          ...(cancelled.navigationId >= 0 ? { navigationId: cancelled.navigationId } : {}),
          dependencyHost,
        });
      }
    },
    disposeTab: (tabId): void => {
      navigations.delete(tabId);
      documentTokenByTab.delete(tabId);
      const pending = pendingReloadTimers.get(tabId);
      if (pending !== undefined) {
        clearTimeout(pending);
        pendingReloadTimers.delete(tabId);
      }
    },
  };
}
