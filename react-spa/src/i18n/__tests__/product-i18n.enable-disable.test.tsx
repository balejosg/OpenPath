import { describe, expect, it } from 'vitest';
import { translateProductText } from '../product-i18n';

describe('product-i18n enable/disable keys', () => {
  it('rulesActions.disabled resolves without throwing and substitutes {value} in English', () => {
    const result = translateProductText('en', 'rulesActions.disabled', { value: 'x.com' });
    expect(result).not.toBe('rulesActions.disabled');
    expect(result).toContain('x.com');
  });

  it('rulesActions.disabled resolves without throwing and substitutes {value} in Spanish', () => {
    const result = translateProductText('es', 'rulesActions.disabled', { value: 'x.com' });
    expect(result).not.toBe('rulesActions.disabled');
    expect(result).toContain('x.com');
  });

  it('rulesActions.enabled resolves without throwing and substitutes {value} in English', () => {
    const result = translateProductText('en', 'rulesActions.enabled', { value: 'x.com' });
    expect(result).not.toBe('rulesActions.enabled');
    expect(result).toContain('x.com');
  });

  it('rulesActions.enabled resolves without throwing and substitutes {value} in Spanish', () => {
    const result = translateProductText('es', 'rulesActions.enabled', { value: 'x.com' });
    expect(result).not.toBe('rulesActions.enabled');
    expect(result).toContain('x.com');
  });

  it('rulesActions.bulkDisabled resolves without throwing and substitutes {count} in English', () => {
    const result = translateProductText('en', 'rulesActions.bulkDisabled', { count: 2 });
    expect(result).not.toBe('rulesActions.bulkDisabled');
    expect(result).toContain('2');
  });

  it('rulesActions.bulkDisabled resolves without throwing and substitutes {count} in Spanish', () => {
    const result = translateProductText('es', 'rulesActions.bulkDisabled', { count: 2 });
    expect(result).not.toBe('rulesActions.bulkDisabled');
    expect(result).toContain('2');
  });

  it('rulesActions.bulkEnabled resolves without throwing and substitutes {count} in English', () => {
    const result = translateProductText('en', 'rulesActions.bulkEnabled', { count: 2 });
    expect(result).not.toBe('rulesActions.bulkEnabled');
    expect(result).toContain('2');
  });

  it('rulesActions.bulkEnabled resolves without throwing and substitutes {count} in Spanish', () => {
    const result = translateProductText('es', 'rulesActions.bulkEnabled', { count: 2 });
    expect(result).not.toBe('rulesActions.bulkEnabled');
    expect(result).toContain('2');
  });

  it('rules.row.disable resolves to a non-key string in English', () => {
    const result = translateProductText('en', 'rules.row.disable');
    expect(result).not.toBe('rules.row.disable');
    expect(result.length).toBeGreaterThan(0);
  });

  it('rules.row.disable resolves to a non-key string in Spanish', () => {
    const result = translateProductText('es', 'rules.row.disable');
    expect(result).not.toBe('rules.row.disable');
    expect(result.length).toBeGreaterThan(0);
  });

  it('rules.row.enable resolves to a non-key string in English', () => {
    const result = translateProductText('en', 'rules.row.enable');
    expect(result).not.toBe('rules.row.enable');
    expect(result.length).toBeGreaterThan(0);
  });

  it('rules.row.enable resolves to a non-key string in Spanish', () => {
    const result = translateProductText('es', 'rules.row.enable');
    expect(result).not.toBe('rules.row.enable');
    expect(result.length).toBeGreaterThan(0);
  });

  it('rules.row.disabled resolves to a non-key string in English', () => {
    const result = translateProductText('en', 'rules.row.disabled');
    expect(result).not.toBe('rules.row.disabled');
    expect(result.length).toBeGreaterThan(0);
  });

  it('rules.row.disabled resolves to a non-key string in Spanish', () => {
    const result = translateProductText('es', 'rules.row.disabled');
    expect(result).not.toBe('rules.row.disabled');
    expect(result.length).toBeGreaterThan(0);
  });
});
