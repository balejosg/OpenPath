/**
 * Rule Detection - Automatically detect rule type based on input pattern
 *
 * Validation (`validateRuleValue`/`cleanRuleValue`) is re-exported from the
 * canonical implementation in @openpath/shared/rules-validation
 * (OpenPath/shared/src/rules-validation.ts) — this file does not keep a
 * parallel copy; it only adds detection heuristics and SPA-local i18n
 * message wiring on top (see the "Validation" section comment below).
 */

import { getRootDomain } from '@openpath/shared/domain';
import {
  cleanRuleValue as cleanRuleValueShared,
  validateRuleValue as validateRuleValueShared,
} from '@openpath/shared/rules-validation';
import type {
  RuleType,
  RuleValidationCode,
  RuleValidationResult as SharedRuleValidationResult,
} from '@openpath/shared/rules-validation';
import { categorizeRuleType } from './rules';
import {
  translateProductText,
  type ProductI18nKey,
  type ProductLocale,
} from '../i18n/product-i18n';

export { getRuleTypeBadge, getRuleTypeLabel } from './rules';

export interface DetectionResult {
  type: RuleType;
  cleanedValue: string;
  confidence: 'high' | 'medium';
  reason: string;
}

export interface ValidationResult {
  valid: boolean;
  error?: string;
}

/**
 * Clean and normalize a rule value.
 * Strips protocol, trailing slashes (for domains), and lowercases.
 */
export function cleanRuleValue(value: string, preservePath = false): string {
  return cleanRuleValueShared(value, preservePath);
}

/**
 * Extract the root domain from a domain string.
 * e.g., "ads.google.com" -> "google.com"
 *       "*.tracking.example.com" -> "example.com"
 */
export function extractRootDomain(domain: string): string {
  return getRootDomain(domain);
}

/**
 * Detect the rule type based on the input pattern and existing whitelist domains.
 *
 * @param value - The raw input value
 * @param existingWhitelistDomains - Array of domains already in the whitelist
 * @returns Detection result with type, cleaned value, confidence, and reason
 */
export function detectRuleType(
  value: string,
  existingWhitelistDomains: string[] = [],
  locale: ProductLocale = 'en'
): DetectionResult {
  const cleaned = cleanRuleValue(value, true);

  // Rule 1: Contains "/" -> it's a path rule
  if (cleaned.includes('/')) {
    return {
      type: 'blocked_path',
      cleanedValue: cleaned,
      confidence: 'high',
      reason: translateProductText(locale, 'rules.detect.pathReason'),
    };
  }

  // Now we know it's a domain-only value
  const domainCleaned = cleanRuleValue(value, false);
  const rootDomain = extractRootDomain(domainCleaned);

  // Rule 2: If the root domain is already in whitelist AND this is a subdomain -> blocked_subdomain
  const normalizedExisting = existingWhitelistDomains.map((d) => d.toLowerCase());

  if (normalizedExisting.includes(rootDomain) && domainCleaned !== rootDomain) {
    return {
      type: 'blocked_subdomain',
      cleanedValue: domainCleaned,
      confidence: 'high',
      reason: translateProductText(locale, 'rules.detect.subdomainExistingReason', { rootDomain }),
    };
  }

  // Rule 3: Starts with "*." -> likely a subdomain block pattern
  if (domainCleaned.startsWith('*.')) {
    const baseDomain = domainCleaned.slice(2);
    const baseRoot = extractRootDomain(baseDomain);

    if (normalizedExisting.includes(baseRoot)) {
      return {
        type: 'blocked_subdomain',
        cleanedValue: domainCleaned,
        confidence: 'high',
        reason: translateProductText(locale, 'rules.detect.wildcardExistingReason', { baseRoot }),
      };
    }

    // Wildcard without matching whitelist - still suggest as subdomain block
    return {
      type: 'blocked_subdomain',
      cleanedValue: domainCleaned,
      confidence: 'medium',
      reason: translateProductText(locale, 'rules.detect.wildcardReason'),
    };
  }

  // Rule 4: Looks like a subdomain (3+ parts) and root is whitelisted
  const parts = domainCleaned.split('.');
  if (parts.length >= 3 && normalizedExisting.includes(rootDomain)) {
    return {
      type: 'blocked_subdomain',
      cleanedValue: domainCleaned,
      confidence: 'high',
      reason: translateProductText(locale, 'rules.detect.subdomainExistingReason', { rootDomain }),
    };
  }

  // Default: treat as whitelist domain
  return {
    type: 'whitelist',
    cleanedValue: domainCleaned,
    confidence: 'high',
    reason: translateProductText(locale, 'rules.detect.whitelistReason'),
  };
}

// =============================================================================
// Validation (canonical logic in @openpath/shared, UI messages in product catalogs)
// =============================================================================

const RULE_VALIDATION_MESSAGE_KEYS: Partial<Record<RuleValidationCode, ProductI18nKey>> = {
  EMPTY: 'rules.validation.empty',
  DOMAIN_TOO_SHORT: 'rules.validation.domainTooShort',
  DOMAIN_TOO_LONG: 'rules.validation.domainTooLong',
  DOMAIN_CONSECUTIVE_DOTS: 'rules.validation.domainConsecutiveDots',
  DOMAIN_INVALID_FORMAT: 'rules.validation.domainInvalidFormat',
  DOMAIN_LABEL_TOO_LONG: 'rules.validation.domainLabelTooLong',
  SUBDOMAIN_TOO_SHORT: 'rules.validation.subdomainTooShort',
  SUBDOMAIN_TOO_LONG: 'rules.validation.subdomainTooLong',
  SUBDOMAIN_CONSECUTIVE_DOTS: 'rules.validation.subdomainConsecutiveDots',
  SUBDOMAIN_INVALID_FORMAT: 'rules.validation.subdomainInvalidFormat',
  SUBDOMAIN_LABEL_TOO_LONG: 'rules.validation.subdomainLabelTooLong',
  PATH_MISSING_SLASH: 'rules.validation.pathMissingSlash',
  PATH_EMPTY: 'rules.validation.pathEmpty',
  PATH_INVALID_CHARS: 'rules.validation.pathInvalidChars',
};

function toRuleValidationError(
  result: SharedRuleValidationResult,
  locale: ProductLocale = 'en'
): string {
  if (result.code === 'PATH_INVALID_DOMAIN') {
    const domainCode = result.details?.domainCode;
    const domainKey =
      domainCode !== undefined ? RULE_VALIDATION_MESSAGE_KEYS[domainCode] : undefined;
    const domainError =
      (domainKey !== undefined ? translateProductText(locale, domainKey) : undefined) ??
      result.details?.domainError ??
      '';
    return translateProductText(locale, 'rules.validation.pathInvalidDomain', { domainError });
  }

  if (result.code !== undefined) {
    const key = RULE_VALIDATION_MESSAGE_KEYS[result.code];
    if (key) {
      return translateProductText(locale, key);
    }
  }

  return result.error ?? translateProductText(locale, 'rules.validation.invalidFormat');
}

/**
 * Validate a rule value based on its detected type.
 * Applies format validation for domains, subdomains, and paths.
 */
export function validateRuleValue(
  value: string,
  type: RuleType,
  locale: ProductLocale = 'en'
): ValidationResult {
  const result = validateRuleValueShared(value, type);
  if (result.valid) {
    return { valid: true };
  }
  return { valid: false, error: toRuleValidationError(result, locale) };
}

/**
 * Categorize a rule as 'allowed' or 'blocked' for filtering.
 */
export function categorizeRule(type: RuleType): 'allowed' | 'blocked' {
  return categorizeRuleType(type);
}
