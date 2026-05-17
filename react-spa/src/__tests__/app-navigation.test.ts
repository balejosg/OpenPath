import { describe, expect, it } from 'vitest';
import {
  getAuthViewFromPathname,
  getPathForAuthView,
  getPathForTab,
  getTabFromPathname,
  isAuthPath,
  normalizePathname,
} from '../app-navigation';

describe('app-navigation', () => {
  it('normalizes trailing slashes without collapsing root', () => {
    expect(normalizePathname('/classrooms///')).toBe('/classrooms');
    expect(normalizePathname('/')).toBe('/');
    expect(normalizePathname('')).toBe('/');
  });

  it('maps pathnames to tabs', () => {
    expect(getTabFromPathname('/')).toBe('dashboard');
    expect(getTabFromPathname('/dashboard/')).toBe('dashboard');
    expect(getTabFromPathname('/classrooms/1')).toBe('classrooms');
    expect(getTabFromPathname('/policies')).toBe('groups');
    expect(getTabFromPathname('/groups')).toBe('groups');
    expect(getTabFromPathname('/rules')).toBe('rules');
    expect(getTabFromPathname('/users')).toBe('users');
    expect(getTabFromPathname('/domain-requests')).toBe('domains');
    expect(getTabFromPathname('/domains')).toBe('domains');
    expect(getTabFromPathname('/settings')).toBe('settings');
    expect(getTabFromPathname('/aulas')).toBe('dashboard');
    expect(getTabFromPathname('/configuracion')).toBe('dashboard');
    expect(getTabFromPathname('/desconocido')).toBe('dashboard');
  });

  it('maps auth pathnames and explicit auth routes', () => {
    expect(getAuthViewFromPathname('/')).toBe('login');
    expect(getAuthViewFromPathname('/login')).toBe('login');
    expect(getAuthViewFromPathname('/register')).toBe('register');
    expect(getAuthViewFromPathname('/forgot-password')).toBe('forgot-password');
    expect(getAuthViewFromPathname('/reset-password')).toBe('reset-password');

    expect(isAuthPath('/')).toBe(true);
    expect(isAuthPath('/login')).toBe(true);
    expect(isAuthPath('/register')).toBe(true);
    expect(isAuthPath('/forgot-password')).toBe(true);
    expect(isAuthPath('/reset-password')).toBe(true);
    expect(isAuthPath('/classrooms')).toBe(false);
  });

  it('maps tabs and auth views back to route paths', () => {
    expect(getPathForTab('dashboard')).toBe('/');
    expect(getPathForTab('classrooms')).toBe('/classrooms');
    expect(getPathForTab('groups')).toBe('/policies');
    expect(getPathForTab('rules')).toBe('/rules');
    expect(getPathForTab('users')).toBe('/users');
    expect(getPathForTab('domains')).toBe('/domain-requests');
    expect(getPathForTab('settings')).toBe('/settings');
    expect(getPathForTab('unknown')).toBe('/');

    expect(getPathForAuthView('login')).toBe('/login');
    expect(getPathForAuthView('register')).toBe('/register');
    expect(getPathForAuthView('forgot-password')).toBe('/forgot-password');
    expect(getPathForAuthView('reset-password')).toBe('/reset-password');
  });
});
