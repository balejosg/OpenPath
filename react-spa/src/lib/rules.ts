import type { RuleType } from '@openpath/shared/rules-validation';
import {
  translateProductText,
  type ProductLocale,
  type ProductI18nKey,
} from '../i18n/product-i18n';

export type { RuleType };

export type RuleCategory = 'allowed' | 'blocked';

export interface Rule {
  id: string;
  groupId: string;
  type: RuleType;
  value: string;
  source?: 'manual' | 'auto_extension';
  enabled?: boolean;
  comment: string | null;
  createdAt: string;
}

const RULE_TYPE_META: Record<
  RuleType,
  {
    labelKey: ProductI18nKey;
    badgeKey: ProductI18nKey;
    exportKey: ProductI18nKey;
    category: RuleCategory;
  }
> = {
  whitelist: {
    labelKey: 'rules.type.whitelist.label',
    badgeKey: 'rules.type.whitelist.badge',
    exportKey: 'rules.type.whitelist.export',
    category: 'allowed',
  },
  blocked_subdomain: {
    labelKey: 'rules.type.blockedSubdomain.label',
    badgeKey: 'rules.type.blockedSubdomain.badge',
    exportKey: 'rules.type.blockedSubdomain.export',
    category: 'blocked',
  },
  blocked_path: {
    labelKey: 'rules.type.blockedPath.label',
    badgeKey: 'rules.type.blockedPath.badge',
    exportKey: 'rules.type.blockedPath.export',
    category: 'blocked',
  },
};

export function getRuleTypeLabel(type: RuleType, locale: ProductLocale = 'en'): string {
  return translateProductText(locale, RULE_TYPE_META[type].labelKey);
}

export function getRuleTypeBadge(type: RuleType, locale: ProductLocale = 'en'): string {
  return translateProductText(locale, RULE_TYPE_META[type].badgeKey);
}

export function getRuleTypeExportLabel(type: RuleType, locale: ProductLocale = 'en'): string {
  return translateProductText(locale, RULE_TYPE_META[type].exportKey);
}

export function categorizeRuleType(type: RuleType): RuleCategory {
  return RULE_TYPE_META[type].category;
}
