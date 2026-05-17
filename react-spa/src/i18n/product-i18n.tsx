import React, { createContext, useContext, useMemo } from 'react';

export const SUPPORTED_PRODUCT_LOCALES = ['en', 'es'] as const;
export type ProductLocale = (typeof SUPPORTED_PRODUCT_LOCALES)[number];

export const productI18nCatalogs = {
  en: {
    'app.title.dashboard.admin': 'Overview',
    'app.title.dashboard.user': 'My Dashboard',
    'app.title.classrooms.admin': 'Classroom Management',
    'app.title.classrooms.user': 'Classrooms',
    'app.title.groups.admin': 'Groups and Policies',
    'app.title.groups.user': 'My Policies',
    'app.title.rules.default': 'Rules Management',
    'app.title.rules.group': 'Rules: {groupName}',
    'app.title.users.admin': 'User Administration',
    'app.title.domainRequests.admin': 'Access Requests',
    'app.title.settings': 'Settings',
    'sidebar.nav.dashboard.admin': 'Dashboard',
    'sidebar.nav.dashboard.user': 'My Dashboard',
    'sidebar.nav.classrooms.admin': 'Secure Classrooms',
    'sidebar.nav.classrooms.user': 'Classrooms',
    'sidebar.nav.groups.admin': 'Group Policies',
    'sidebar.nav.groups.user': 'My Policies',
    'sidebar.nav.users': 'Users and Roles',
    'sidebar.nav.domainRequests': 'Domain Control',
    'sidebar.nav.settings': 'Settings',
    'sidebar.nav.logout': 'Sign Out',
    'sidebar.section.mainMenu': 'Main Menu',
  },
  es: {
    'app.title.dashboard.admin': 'Vista General',
    'app.title.dashboard.user': 'Mi Panel',
    'app.title.classrooms.admin': 'Gestión de Aulas',
    'app.title.classrooms.user': 'Aulas',
    'app.title.groups.admin': 'Grupos y Políticas',
    'app.title.groups.user': 'Mis Políticas',
    'app.title.rules.default': 'Gestión de Reglas',
    'app.title.rules.group': 'Reglas: {groupName}',
    'app.title.users.admin': 'Administración de Usuarios',
    'app.title.domainRequests.admin': 'Solicitudes de Acceso',
    'app.title.settings': 'Configuración',
    'sidebar.nav.dashboard.admin': 'Panel de Control',
    'sidebar.nav.dashboard.user': 'Mi Panel',
    'sidebar.nav.classrooms.admin': 'Aulas Seguras',
    'sidebar.nav.classrooms.user': 'Aulas',
    'sidebar.nav.groups.admin': 'Políticas de Grupo',
    'sidebar.nav.groups.user': 'Mis Políticas',
    'sidebar.nav.users': 'Usuarios y Roles',
    'sidebar.nav.domainRequests': 'Control de Dominios',
    'sidebar.nav.settings': 'Configuración',
    'sidebar.nav.logout': 'Cerrar Sesión',
    'sidebar.section.mainMenu': 'Menu Principal',
  },
} as const;

export type ProductI18nKey = keyof (typeof productI18nCatalogs)['en'];
export type ProductI18nParams = Record<string, string | number>;
export type ProductT = (key: ProductI18nKey, params?: ProductI18nParams) => string;

interface ProductI18nContextValue {
  locale: ProductLocale;
  t: ProductT;
}

const ProductI18nContext = createContext<ProductI18nContextValue | null>(null);

function isProductLocale(locale: string): locale is ProductLocale {
  return SUPPORTED_PRODUCT_LOCALES.includes(locale as ProductLocale);
}

function getBrowserLocaleCandidates(): string[] {
  if (typeof globalThis.navigator === 'undefined') {
    return [];
  }

  const languages = Array.from(globalThis.navigator.languages);
  return [globalThis.navigator.language, ...languages].filter((candidate) => candidate.length > 0);
}

export function resolveProductLocale(locale?: string | readonly string[] | null): ProductLocale {
  const candidates =
    typeof locale === 'string' ? [locale] : locale ? [...locale] : getBrowserLocaleCandidates();

  for (const candidate of candidates) {
    const normalized = candidate.trim().toLowerCase();
    const [baseLocale = ''] = normalized.split('-');
    if (isProductLocale(baseLocale)) {
      return baseLocale;
    }
  }

  return 'en';
}

function formatProductMessage(message: string, params: ProductI18nParams = {}): string {
  return message.replace(/\{([a-zA-Z0-9_]+)\}/g, (match, name: string) => {
    if (!Object.prototype.hasOwnProperty.call(params, name)) {
      return match;
    }
    return String(params[name]);
  });
}

export function translateProductText(
  locale: ProductLocale,
  key: string,
  params?: ProductI18nParams
): string {
  const catalog: Record<string, string | undefined> = productI18nCatalogs[locale];
  const message = catalog[key];

  if (message === undefined) {
    throw new Error(`Missing OpenPath i18n key "${key}" for locale "${locale}"`);
  }

  return formatProductMessage(message, params);
}

interface OpenPathI18nProviderProps {
  children: React.ReactNode;
  locale?: string | readonly string[] | null;
}

export function OpenPathI18nProvider({ children, locale }: OpenPathI18nProviderProps) {
  const resolvedLocale = resolveProductLocale(locale);
  const value = useMemo<ProductI18nContextValue>(
    () => ({
      locale: resolvedLocale,
      t: (key, params) => translateProductText(resolvedLocale, key, params),
    }),
    [resolvedLocale]
  );

  return <ProductI18nContext.Provider value={value}>{children}</ProductI18nContext.Provider>;
}

export function useOpenPathI18n(): ProductI18nContextValue {
  const value = useContext(ProductI18nContext);
  if (value) {
    return value;
  }

  const locale = resolveProductLocale();
  return {
    locale,
    t: (key, params) => translateProductText(locale, key, params),
  };
}

export function useT(): ProductT {
  return useOpenPathI18n().t;
}
