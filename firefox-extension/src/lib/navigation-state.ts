export interface NavigationIdentity {
  generation: number;
  source: 'error' | 'preflight' | 'reconciliation';
  tabId: number;
  url: string;
}

export interface NavigationState {
  begin: (tabId: number, url: string, source?: NavigationIdentity['source']) => NavigationIdentity;
  dispose: (tabId: number) => void;
  get: (tabId: number) => NavigationIdentity | null;
  isCurrent: (identity: NavigationIdentity) => boolean;
  markShown: (identity: NavigationIdentity) => boolean;
  match: (tabId: number, url: string) => NavigationIdentity | null;
  releaseRedirect: (identity: NavigationIdentity) => void;
  reserveRedirect: (identity: NavigationIdentity) => boolean;
}

export function createNavigationState(): NavigationState {
  type Entry = NavigationIdentity & { redirect: 'idle' | 'pending' | 'shown' };
  const entries = new Map<number, Entry>();
  let nextGeneration = 0;

  function current(identity: NavigationIdentity): Entry | null {
    const entry = entries.get(identity.tabId);
    return entry?.generation === identity.generation && entry.url === identity.url ? entry : null;
  }

  return {
    begin(
      tabId: number,
      url: string,
      source: NavigationIdentity['source'] = 'preflight'
    ): NavigationIdentity {
      const entry: Entry = {
        generation: ++nextGeneration,
        redirect: 'idle',
        source,
        tabId,
        url,
      };
      entries.set(tabId, entry);
      return entry;
    },
    dispose(tabId: number): void {
      entries.delete(tabId);
    },
    get(tabId: number): NavigationIdentity | null {
      return entries.get(tabId) ?? null;
    },
    isCurrent(identity: NavigationIdentity): boolean {
      return current(identity) !== null;
    },
    markShown(identity: NavigationIdentity): boolean {
      const entry = current(identity);
      if (!entry || entry.redirect !== 'pending') return false;
      entry.redirect = 'shown';
      return true;
    },
    match(tabId: number, url: string): NavigationIdentity | null {
      const entry = entries.get(tabId);
      return entry?.url === url ? entry : null;
    },
    releaseRedirect(identity: NavigationIdentity): void {
      const entry = current(identity);
      if (entry?.redirect === 'pending') entry.redirect = 'idle';
    },
    reserveRedirect(identity: NavigationIdentity): boolean {
      const entry = current(identity);
      if (!entry || entry.redirect !== 'idle') return false;
      entry.redirect = 'pending';
      return true;
    },
  };
}
