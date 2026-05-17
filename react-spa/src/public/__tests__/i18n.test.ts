import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

import * as publicI18n from '../i18n';
import * as packagePublicI18n from '../../../public-i18n';

describe('public i18n surface', () => {
  it('exports product locale helpers and provider hooks', () => {
    expect(publicI18n.SUPPORTED_PRODUCT_LOCALES).toEqual(['en', 'es']);
    expect(typeof publicI18n.resolveProductLocale).toBe('function');
    expect(typeof publicI18n.translateProductText).toBe('function');
    expect(typeof publicI18n.OpenPathI18nProvider).toBe('function');
    expect(typeof publicI18n.useOpenPathI18n).toBe('function');
    expect(typeof publicI18n.useT).toBe('function');
  });

  it('is exposed through the react-spa package exports map', () => {
    const packageJson = JSON.parse(readFileSync(join(process.cwd(), 'package.json'), 'utf8')) as {
      exports: Record<string, string>;
    };

    expect(packageJson.exports['./public-i18n']).toBe('./public-i18n.ts');
    expect(packagePublicI18n.SUPPORTED_PRODUCT_LOCALES).toEqual(['en', 'es']);
  });
});
