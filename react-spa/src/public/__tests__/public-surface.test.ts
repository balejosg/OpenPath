import { describe, expect, it } from 'vitest';

import * as publicAuth from '../auth';
import * as publicGoogle from '../google';
import * as publicI18n from '../i18n';
import * as publicShell from '../shell';
import * as publicUi from '../ui';

describe('public OpenPath SPA surface', () => {
  it('exports stable shell components and auth helpers', () => {
    expect(typeof publicShell.Sidebar).toBe('function');
    expect(typeof publicShell.Header).toBe('function');
    expect(typeof publicShell.Dashboard).toBe('function');
    expect(typeof publicShell.TeacherDashboard).toBe('function');
    expect(typeof publicShell.Classrooms).toBe('function');
    expect(typeof publicShell.Groups).toBe('function');
    expect(typeof publicShell.RulesManager).toBe('function');
    expect(typeof publicShell.DomainRequests).toBe('function');
    expect(typeof publicShell.Settings).toBe('function');

    expect(typeof publicAuth.isAdmin).toBe('function');
    expect(typeof publicAuth.isAuthenticated).toBe('function');
    expect(typeof publicAuth.isStudent).toBe('function');
    expect(typeof publicAuth.isTeacher).toBe('function');
    expect(typeof publicAuth.logout).toBe('function');
  });

  it('exports stable UI components and initializes Google public types module', () => {
    expect(typeof publicUi.Button).toBe('object');
    expect(typeof publicUi.Input).toBe('object');
    expect(typeof publicUi.Card).toBe('object');
    expect(typeof publicUi.Modal).toBe('function');
    expect(typeof publicUi.ConfirmDialog).toBe('function');
    expect(typeof publicUi.DangerConfirmDialog).toBe('function');

    expect(typeof publicGoogle).toBe('object');
  });

  it('exports stable i18n helpers and provider hooks', () => {
    expect(publicI18n.SUPPORTED_PRODUCT_LOCALES).toEqual(['en', 'es']);
    expect(typeof publicI18n.OpenPathI18nProvider).toBe('function');
    expect(typeof publicI18n.resolveProductLocale).toBe('function');
    expect(typeof publicI18n.translateProductText).toBe('function');
    expect(typeof publicI18n.useOpenPathI18n).toBe('function');
    expect(typeof publicI18n.useT).toBe('function');
  });
});
