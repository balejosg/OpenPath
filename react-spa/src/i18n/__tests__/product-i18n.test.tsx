import React from 'react';
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import {
  OpenPathI18nProvider,
  productI18nCatalogs,
  resolveProductLocale,
  translateProductText,
  useT,
} from '../product-i18n';

function Probe() {
  const t = useT();
  return <div>{t('sidebar.nav.settings')}</div>;
}

describe('product i18n', () => {
  it('defaults unsupported browser locales to English and accepts language regions', () => {
    expect(resolveProductLocale('fr-FR')).toBe('en');
    expect(resolveProductLocale('es-ES')).toBe('es');
    expect(resolveProductLocale(['de-DE', 'en-US'])).toBe('en');
  });

  it('keeps English and Spanish catalogs in key parity', () => {
    expect(Object.keys(productI18nCatalogs.es).sort()).toEqual(
      Object.keys(productI18nCatalogs.en).sort()
    );
  });

  it('fails loudly when a catalog key is missing', () => {
    expect(() => translateProductText('en', 'missing.key')).toThrow(/Missing OpenPath i18n key/);
  });

  it('provides translated labels from context', () => {
    render(
      <OpenPathI18nProvider locale="es">
        <Probe />
      </OpenPathI18nProvider>
    );

    expect(screen.getByText('Configuración')).toBeInTheDocument();
  });
});
