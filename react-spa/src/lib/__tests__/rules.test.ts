import { describe, expect, it } from 'vitest';

import {
  categorizeRuleType,
  getRuleTypeBadge,
  getRuleTypeExportLabel,
  getRuleTypeLabel,
} from '../rules';

describe('rules helpers', () => {
  it('provides English labels by default and Spanish labels when requested', () => {
    expect(getRuleTypeLabel('whitelist')).toBe('Allowed domain');
    expect(getRuleTypeLabel('blocked_subdomain')).toBe('Blocked subdomain');
    expect(getRuleTypeLabel('blocked_path')).toBe('Blocked path');
    expect(getRuleTypeLabel('whitelist', 'es')).toBe('Dominio permitido');
  });

  it('provides short badges for each rule type', () => {
    expect(getRuleTypeBadge('whitelist')).toBe('Allowed');
    expect(getRuleTypeBadge('blocked_subdomain')).toBe('Sub. blocked');
    expect(getRuleTypeBadge('blocked_path')).toBe('Path blocked');
    expect(getRuleTypeBadge('whitelist', 'es')).toBe('Permitido');
  });

  it('provides export labels for each rule type', () => {
    expect(getRuleTypeExportLabel('whitelist')).toBe('Allowed');
    expect(getRuleTypeExportLabel('blocked_subdomain')).toBe('Blocked subdomain');
    expect(getRuleTypeExportLabel('blocked_path')).toBe('Blocked path');
    expect(getRuleTypeExportLabel('whitelist', 'es')).toBe('Permitido');
  });

  it('categorizes rule types as allowed/blocked', () => {
    expect(categorizeRuleType('whitelist')).toBe('allowed');
    expect(categorizeRuleType('blocked_subdomain')).toBe('blocked');
    expect(categorizeRuleType('blocked_path')).toBe('blocked');
  });
});
