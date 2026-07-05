/**
 * Rule value validation for domains, subdomains, and paths.
 *
 * This is the canonical (single source of truth) implementation. The React
 * SPA client (react-spa/src/lib/ruleDetection.ts) does not keep a parallel
 * copy — it imports `validateRuleValue`/`cleanRuleValue` directly from this
 * module via the `@openpath/shared/rules-validation` subpath, and only adds
 * detection heuristics and SPA-local i18n message wiring on top.
 */

// =============================================================================
// Types
// =============================================================================

/** The rule types supported by whitelist groups. */
export type RuleType = 'whitelist' | 'blocked_subdomain' | 'blocked_path' | 'allowed_path';

export type RuleValidationCode =
  | 'EMPTY'
  | 'DOMAIN_TOO_SHORT'
  | 'DOMAIN_TOO_LONG'
  | 'DOMAIN_CONSECUTIVE_DOTS'
  | 'DOMAIN_INVALID_FORMAT'
  | 'DOMAIN_LABEL_TOO_LONG'
  | 'SUBDOMAIN_TOO_SHORT'
  | 'SUBDOMAIN_TOO_LONG'
  | 'SUBDOMAIN_CONSECUTIVE_DOTS'
  | 'SUBDOMAIN_INVALID_FORMAT'
  | 'SUBDOMAIN_LABEL_TOO_LONG'
  | 'PATH_MISSING_SLASH'
  | 'PATH_INVALID_DOMAIN'
  | 'PATH_EMPTY'
  | 'PATH_INVALID_CHARS';

/** Result of validating a rule value. */
export interface RuleValidationResult {
  valid: boolean;
  code?: RuleValidationCode;
  error?: string;
  details?: {
    domainCode?: RuleValidationCode;
    domainError?: string;
  };
}

// =============================================================================
// Regex patterns (must match react-spa/src/lib/ruleDetection.ts)
// =============================================================================

// Domain validation: each label 1-63 chars (alphanumeric + hyphens, not at start/end),
// TLD 2-63 chars letters only. Does NOT allow wildcard prefix.
const DOMAIN_REGEX = /^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$/;

// Same as DOMAIN_REGEX but optionally allows a "*." prefix for wildcard patterns
const SUBDOMAIN_REGEX =
  /^(?:\*\.)?(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$/;

// Path characters: anything allowed after domain/ except whitespace and control chars
const PATH_SEGMENT_REGEX = /^[^\s]+$/;

// =============================================================================
// Cleaning / normalization
// =============================================================================

/**
 * Clean and normalize a rule value.
 * Strips protocol, trailing slashes (for domains), and lowercases.
 */
export function cleanRuleValue(value: string, preservePath = false): string {
  let cleaned = value.trim().toLowerCase();

  // Remove protocol
  cleaned = cleaned.replace(/^https?:\/\//, '');
  cleaned = cleaned.replace(/^\*:\/\//, '');

  // Remove trailing slash if it's just a domain (no path content after /)
  if (!preservePath) {
    cleaned = cleaned.replace(/\/$/, '');
  }

  return cleaned;
}

// =============================================================================
// Individual validators
// =============================================================================

/**
 * Validate that a domain string is well-formed.
 * Checks: length 4-253, no consecutive dots, each label <= 63 chars, matches DOMAIN_REGEX.
 */
function validateDomain(domain: string): RuleValidationResult {
  if (domain.length < 4) {
    return {
      valid: false,
      code: 'DOMAIN_TOO_SHORT',
      error: 'Domain too short (minimum 4 characters)',
    };
  }
  if (domain.length > 253) {
    return {
      valid: false,
      code: 'DOMAIN_TOO_LONG',
      error: 'Domain exceeds maximum length of 253 characters',
    };
  }
  if (domain.includes('..')) {
    return {
      valid: false,
      code: 'DOMAIN_CONSECUTIVE_DOTS',
      error: 'Domain cannot contain consecutive dots (..)',
    };
  }
  if (!DOMAIN_REGEX.test(domain)) {
    return {
      valid: false,
      code: 'DOMAIN_INVALID_FORMAT',
      error: 'Invalid domain format. Example: example.com',
    };
  }
  // Validate each label length
  const labels = domain.split('.');
  for (const label of labels) {
    if (label.length > 63) {
      return {
        valid: false,
        code: 'DOMAIN_LABEL_TOO_LONG',
        error: 'Each domain label must be 63 characters or less',
      };
    }
  }
  return { valid: true };
}

/**
 * Validate that a subdomain pattern is well-formed.
 * Accepts: domain.tld, sub.domain.tld, *.domain.tld
 */
function validateSubdomain(value: string): RuleValidationResult {
  if (value.length < 4) {
    return {
      valid: false,
      code: 'SUBDOMAIN_TOO_SHORT',
      error: 'Subdomain too short (minimum 4 characters)',
    };
  }
  if (value.length > 253) {
    return {
      valid: false,
      code: 'SUBDOMAIN_TOO_LONG',
      error: 'Subdomain exceeds maximum length of 253 characters',
    };
  }
  if (value.includes('..')) {
    return {
      valid: false,
      code: 'SUBDOMAIN_CONSECUTIVE_DOTS',
      error: 'Subdomain cannot contain consecutive dots (..)',
    };
  }
  if (!SUBDOMAIN_REGEX.test(value)) {
    return {
      valid: false,
      code: 'SUBDOMAIN_INVALID_FORMAT',
      error: 'Invalid subdomain format. Example: sub.example.com or *.example.com',
    };
  }
  // Validate each label length (skip wildcard)
  const labels = value.replace(/^\*\./, '').split('.');
  for (const label of labels) {
    if (label.length > 63) {
      return {
        valid: false,
        code: 'SUBDOMAIN_LABEL_TOO_LONG',
        error: 'Each subdomain label must be 63 characters or less',
      };
    }
  }
  return { valid: true };
}

/**
 * Validate that a blocked path is well-formed.
 * Must be domain/path where domain is valid and path is non-empty.
 */
function validatePath(value: string): RuleValidationResult {
  const slashIndex = value.indexOf('/');
  if (slashIndex === -1) {
    return {
      valid: false,
      code: 'PATH_MISSING_SLASH',
      error: 'Path must contain a slash (/). Example: example.com/path',
    };
  }

  const domainPart = value.substring(0, slashIndex);
  const pathPart = value.substring(slashIndex + 1);

  // Allow global wildcard paths like */ads/*
  if (domainPart !== '*') {
    // Validate domain part
    const domainResult = validateDomain(domainPart);
    if (!domainResult.valid) {
      const details: RuleValidationResult['details'] = {};
      if (domainResult.code !== undefined) {
        details.domainCode = domainResult.code;
      }
      if (domainResult.error !== undefined) {
        details.domainError = domainResult.error;
      }
      return {
        valid: false,
        code: 'PATH_INVALID_DOMAIN',
        error: `Invalid domain in path: ${domainResult.error ?? ''}`,
        details,
      };
    }
  }

  if (!pathPart) {
    return { valid: false, code: 'PATH_EMPTY', error: 'Path after domain cannot be empty' };
  }

  if (!PATH_SEGMENT_REGEX.test(pathPart)) {
    return {
      valid: false,
      code: 'PATH_INVALID_CHARS',
      error: 'Path contains invalid characters (whitespace)',
    };
  }

  return { valid: true };
}

/**
 * Validate an allowed-path (allow-by-URL) rule. Like validatePath, but the domain
 * part is always validated as a concrete domain — a global "*" wildcard is rejected,
 * because an allow rule must target a specific host.
 */
function validateAllowedPath(value: string): RuleValidationResult {
  const slashIndex = value.indexOf('/');
  if (slashIndex === -1) {
    return {
      valid: false,
      code: 'PATH_MISSING_SLASH',
      error: 'Path must contain a slash (/). Example: example.com/path',
    };
  }

  const domainPart = value.substring(0, slashIndex);
  const pathPart = value.substring(slashIndex + 1);

  const domainResult = validateDomain(domainPart);
  if (!domainResult.valid) {
    const details: RuleValidationResult['details'] = {};
    if (domainResult.code !== undefined) {
      details.domainCode = domainResult.code;
    }
    if (domainResult.error !== undefined) {
      details.domainError = domainResult.error;
    }
    return {
      valid: false,
      code: 'PATH_INVALID_DOMAIN',
      error: `Invalid domain in path: ${domainResult.error ?? ''}`,
      details,
    };
  }

  if (!pathPart) {
    return { valid: false, code: 'PATH_EMPTY', error: 'Path after domain cannot be empty' };
  }

  if (!PATH_SEGMENT_REGEX.test(pathPart)) {
    return {
      valid: false,
      code: 'PATH_INVALID_CHARS',
      error: 'Path contains invalid characters (whitespace)',
    };
  }

  return { valid: true };
}

// =============================================================================
// Main validation dispatcher
// =============================================================================

/**
 * Validate a rule value based on its type.
 * Cleans the value first, then applies type-specific format validation.
 *
 * @param value - The raw input value
 * @param type - The rule type (whitelist, blocked_subdomain, blocked_path)
 * @returns Validation result with optional error message
 */
export function validateRuleValue(value: string, type: RuleType): RuleValidationResult {
  const cleaned =
    type === 'blocked_path' || type === 'allowed_path'
      ? cleanRuleValue(value, true)
      : cleanRuleValue(value, false);

  if (!cleaned) {
    return { valid: false, code: 'EMPTY', error: 'Value cannot be empty' };
  }

  switch (type) {
    case 'whitelist':
      return validateDomain(cleaned);
    case 'blocked_subdomain':
      return validateSubdomain(cleaned);
    case 'blocked_path':
      return validatePath(cleaned);
    case 'allowed_path':
      return validateAllowedPath(cleaned);
  }
}
