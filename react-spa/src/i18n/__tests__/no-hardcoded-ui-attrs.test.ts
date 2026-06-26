import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Regression guard for UI-language mixing.
 *
 * User-facing text in OpenPath's SPA must come from the i18n catalog (`useT()` / `t('key')`),
 * never from hardcoded string literals. The attributes below are the class that historically
 * kept slipping through into English while the rest of the UI was Spanish, because they hold
 * plain strings instead of rendered children. This test scans the component and view trees and
 * fails if any of them is assigned an English-looking string LITERAL.
 *
 * Fix a failure by moving the text into `src/i18n/product-i18n.tsx` (both `en` and `es`) and
 * referencing it: `placeholder={t('your.key')}`. Dynamic values (`title={someVar}`,
 * `aria-label={cond ? t('a') : t('b')}`) are not literals and are not flagged.
 */

const SRC = resolve(__dirname, '../..');
const ROOTS = [join(SRC, 'components'), join(SRC, 'views')];
const ATTRS = ['placeholder', 'title', 'aria-label', 'alt'];

// Exact `attr="value"` strings that are legitimately not translatable (example values, brand
// tokens, etc.). Keep this list small and justify each entry — prefer migrating to the catalog.
const ALLOW = new Set<string>([]);

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) {
      if (name === '__tests__') continue;
      out.push(...walk(p));
    } else if (name.endsWith('.tsx') && !name.endsWith('.test.tsx')) {
      out.push(p);
    }
  }
  return out;
}

// attr="literal" | attr={'literal'} | attr={"literal"}
const PATTERNS = [
  new RegExp(`\\b(${ATTRS.join('|')})="([^"]*)"`, 'g'),
  new RegExp(`\\b(${ATTRS.join('|')})=\\{'([^']*)'\\}`, 'g'),
  new RegExp(`\\b(${ATTRS.join('|')})=\\{"([^"]*)"\\}`, 'g'),
];

function looksEnglish(value: string): boolean {
  if (value.includes('@')) return false; // example emails like user@example.com
  if (/[•]/.test(value)) return false; // password bullet masks
  return /[A-Za-z]{3,}/.test(value); // contains a 3+ letter word
}

describe('no hardcoded user-facing UI-text attributes', () => {
  it('keeps placeholder/title/aria-label/alt catalog-backed across components and views', () => {
    const violations: string[] = [];

    for (const root of ROOTS) {
      for (const file of walk(root)) {
        const src = readFileSync(file, 'utf8');
        for (const pattern of PATTERNS) {
          pattern.lastIndex = 0;
          let match: RegExpExecArray | null;
          while ((match = pattern.exec(src))) {
            const [, attr, value] = match;
            if (!looksEnglish(value)) continue;
            if (ALLOW.has(`${attr}="${value}"`)) continue;
            const line = src.slice(0, match.index).split('\n').length;
            violations.push(`${file.replace(`${SRC}/`, '')}:${line}  ${attr}="${value}"`);
          }
        }
      }
    }

    expect(
      violations,
      'Hardcoded UI-text attribute(s) found — move them into product-i18n.tsx and use t():\n' +
        violations.join('\n')
    ).toEqual([]);
  });
});
