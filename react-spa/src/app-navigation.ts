export type AuthView = 'login' | 'register' | 'forgot-password' | 'reset-password';

export function normalizePathname(pathname: string): string {
  const trimmed = pathname.replace(/\/+$/, '');
  return trimmed.length === 0 ? '/' : trimmed;
}

export function getTabFromPathname(pathname: string): string {
  const normalized = normalizePathname(pathname);

  if (normalized === '/' || normalized.startsWith('/dashboard')) return 'dashboard';
  if (normalized.startsWith('/classrooms')) return 'classrooms';
  if (normalized.startsWith('/policies') || normalized.startsWith('/groups')) return 'groups';
  if (normalized.startsWith('/rules')) return 'rules';
  if (normalized.startsWith('/users')) return 'users';
  if (normalized.startsWith('/domain-requests') || normalized.startsWith('/domains'))
    return 'domains';
  if (normalized.startsWith('/settings')) return 'settings';

  return 'dashboard';
}

export function getAuthViewFromPathname(pathname: string): AuthView {
  const normalized = normalizePathname(pathname);

  if (normalized.startsWith('/register')) return 'register';
  if (normalized.startsWith('/forgot-password')) return 'forgot-password';
  if (normalized.startsWith('/reset-password')) return 'reset-password';
  if (normalized.startsWith('/login') || normalized === '/') return 'login';

  return 'login';
}

export function isAuthPath(pathname: string): boolean {
  const normalized = normalizePathname(pathname);
  return (
    normalized === '/' ||
    normalized.startsWith('/login') ||
    normalized.startsWith('/register') ||
    normalized.startsWith('/forgot-password') ||
    normalized.startsWith('/reset-password')
  );
}

export function getPathForTab(tab: string): string {
  switch (tab) {
    case 'dashboard':
      return '/';
    case 'classrooms':
      return '/classrooms';
    case 'groups':
      return '/policies';
    case 'rules':
      return '/rules';
    case 'users':
      return '/users';
    case 'domains':
      return '/domain-requests';
    case 'settings':
      return '/settings';
    default:
      return '/';
  }
}

export function getPathForAuthView(view: AuthView): string {
  switch (view) {
    case 'register':
      return '/register';
    case 'forgot-password':
      return '/forgot-password';
    case 'reset-password':
      return '/reset-password';
    case 'login':
    default:
      return '/login';
  }
}
