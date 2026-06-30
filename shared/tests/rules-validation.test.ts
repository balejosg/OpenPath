import { describe, it } from 'node:test';
import assert from 'node:assert';
import { validateRuleValue, cleanRuleValue } from '../src/rules-validation.js';
import type { RuleType } from '../src/rules-validation.js';

// =============================================================================
// cleanRuleValue
// =============================================================================

describe('cleanRuleValue', () => {
  it('trims and lowercases', () => {
    assert.strictEqual(cleanRuleValue('  Example.COM  '), 'example.com');
  });

  it('strips http protocol', () => {
    assert.strictEqual(cleanRuleValue('http://example.com'), 'example.com');
  });

  it('strips https protocol', () => {
    assert.strictEqual(cleanRuleValue('https://example.com'), 'example.com');
  });

  it('strips wildcard protocol', () => {
    assert.strictEqual(cleanRuleValue('*://example.com'), 'example.com');
  });

  it('removes trailing slash for domains', () => {
    assert.strictEqual(cleanRuleValue('example.com/'), 'example.com');
  });

  it('preserves path when preservePath=true', () => {
    assert.strictEqual(cleanRuleValue('example.com/path/', true), 'example.com/path/');
  });

  it('handles empty input', () => {
    assert.strictEqual(cleanRuleValue('   '), '');
  });
});

// =============================================================================
// validateRuleValue - Domain (whitelist)
// =============================================================================

describe('validateRuleValue - whitelist (domain)', () => {
  const type: RuleType = 'whitelist';

  it('accepts valid domains', () => {
    const valid = ['example.com', 'sub.example.com', 'my-site.co.uk', 'a1b2.org', 'test.museum'];
    for (const domain of valid) {
      const result = validateRuleValue(domain, type);
      assert.strictEqual(result.valid, true, `Expected "${domain}" to be valid`);
    }
  });

  it('rejects too short', () => {
    const result = validateRuleValue('a.b', type);
    assert.strictEqual(result.valid, false);
    assert.strictEqual(result.code, 'DOMAIN_TOO_SHORT');
  });

  it('rejects consecutive dots', () => {
    const result = validateRuleValue('example..com', type);
    assert.strictEqual(result.valid, false);
    assert.strictEqual(result.code, 'DOMAIN_CONSECUTIVE_DOTS');
  });

  it('rejects invalid format - starts with hyphen', () => {
    const result = validateRuleValue('-example.com', type);
    assert.strictEqual(result.valid, false);
  });

  it('rejects invalid format - ends with hyphen', () => {
    const result = validateRuleValue('example-.com', type);
    assert.strictEqual(result.valid, false);
  });

  it('rejects invalid format - numeric TLD', () => {
    const result = validateRuleValue('example.123', type);
    assert.strictEqual(result.valid, false);
  });

  it('rejects domain with spaces', () => {
    const result = validateRuleValue('exa mple.com', type);
    assert.strictEqual(result.valid, false);
  });

  it('rejects wildcard prefix (not allowed for whitelist)', () => {
    const result = validateRuleValue('*.example.com', type);
    assert.strictEqual(result.valid, false);
  });

  it('strips protocol before validating', () => {
    const result = validateRuleValue('https://example.com', type);
    assert.strictEqual(result.valid, true);
  });

  it('rejects empty after cleaning', () => {
    const result = validateRuleValue('   ', type);
    assert.strictEqual(result.valid, false);
    assert.strictEqual(result.code, 'EMPTY');
  });

  it('rejects label longer than 63 chars', () => {
    const longLabel = 'a'.repeat(64);
    const result = validateRuleValue(`${longLabel}.com`, type);
    assert.strictEqual(result.valid, false);
    assert.ok(result.code, 'Expected an error code');
  });

  it('rejects domain exceeding 253 chars', () => {
    // Build a domain just over 253 chars
    const labels = [];
    for (let i = 0; i < 40; i++) {
      labels.push('abcdef');
    }
    const longDomain = labels.join('.') + '.com';
    assert.ok(longDomain.length > 253);
    const result = validateRuleValue(longDomain, type);
    assert.strictEqual(result.valid, false);
    assert.strictEqual(result.code, 'DOMAIN_TOO_LONG');
  });
});

// =============================================================================
// validateRuleValue - Subdomain (blocked_subdomain)
// =============================================================================

describe('validateRuleValue - blocked_subdomain', () => {
  const type: RuleType = 'blocked_subdomain';

  it('accepts valid subdomains', () => {
    const valid = [
      'sub.example.com',
      'deep.sub.example.com',
      '*.example.com',
      '*.tracking.example.com',
      'example.com',
    ];
    for (const value of valid) {
      const result = validateRuleValue(value, type);
      assert.strictEqual(result.valid, true, `Expected "${value}" to be valid`);
    }
  });

  it('accepts wildcard prefix', () => {
    const result = validateRuleValue('*.example.com', type);
    assert.strictEqual(result.valid, true);
  });

  it('rejects too short', () => {
    const result = validateRuleValue('a.b', type);
    assert.strictEqual(result.valid, false);
  });

  it('rejects consecutive dots', () => {
    const result = validateRuleValue('sub..example.com', type);
    assert.strictEqual(result.valid, false);
  });

  it('rejects invalid format', () => {
    const result = validateRuleValue('!!!.invalid', type);
    assert.strictEqual(result.valid, false);
  });

  it('rejects label over 63 chars', () => {
    const longLabel = 'a'.repeat(64);
    const result = validateRuleValue(`${longLabel}.example.com`, type);
    assert.strictEqual(result.valid, false);
  });
});

// =============================================================================
// validateRuleValue - Path (blocked_path)
// =============================================================================

describe('validateRuleValue - blocked_path', () => {
  const type: RuleType = 'blocked_path';

  it('accepts valid paths', () => {
    const valid = [
      'example.com/ads',
      'example.com/path/to/resource',
      '*/ads/banner',
      'example.com/tracking.js',
    ];
    for (const value of valid) {
      const result = validateRuleValue(value, type);
      assert.strictEqual(result.valid, true, `Expected "${value}" to be valid`);
    }
  });

  it('rejects missing slash', () => {
    const result = validateRuleValue('example.com', type);
    assert.strictEqual(result.valid, false);
    assert.strictEqual(result.code, 'PATH_MISSING_SLASH');
  });

  it('rejects empty path after slash', () => {
    // Note: cleanRuleValue with preservePath=true does NOT strip trailing slash
    // But the path "" after the slash is empty
    const result = validateRuleValue('example.com/', type);
    assert.strictEqual(result.valid, false);
    assert.strictEqual(result.code, 'PATH_EMPTY');
  });

  it('rejects invalid domain part', () => {
    const result = validateRuleValue('-bad-.com/path', type);
    assert.strictEqual(result.valid, false);
    assert.strictEqual(result.code, 'PATH_INVALID_DOMAIN');
    assert.ok(result.details?.domainCode, 'Expected domainCode details');
  });

  it('accepts wildcard domain part', () => {
    const result = validateRuleValue('*/ads', type);
    assert.strictEqual(result.valid, true);
  });

  it('rejects path with spaces', () => {
    const result = validateRuleValue('example.com/bad path', type);
    assert.strictEqual(result.valid, false);
    assert.strictEqual(result.code, 'PATH_INVALID_CHARS');
  });

  it('strips protocol before validating', () => {
    const result = validateRuleValue('https://example.com/ads', type);
    assert.strictEqual(result.valid, true);
  });
});

// =============================================================================
// validateRuleValue - edge cases
// =============================================================================

describe('validateRuleValue - edge cases', () => {
  it('validates protocol-prefixed domain correctly', () => {
    const result = validateRuleValue('http://valid.example.com', 'whitelist');
    assert.strictEqual(result.valid, true);
  });

  it('validates protocol-prefixed subdomain correctly', () => {
    const result = validateRuleValue('https://sub.example.com', 'blocked_subdomain');
    assert.strictEqual(result.valid, true);
  });

  it('validates protocol-prefixed path correctly', () => {
    const result = validateRuleValue('https://example.com/ads', 'blocked_path');
    assert.strictEqual(result.valid, true);
  });

  it('rejects garbage input for all types', () => {
    const garbage = ['!!!', 'not valid at all', '...', '@#$%', ''];
    const types: RuleType[] = ['whitelist', 'blocked_subdomain', 'blocked_path'];
    for (const type of types) {
      for (const input of garbage) {
        const result = validateRuleValue(input, type);
        assert.strictEqual(result.valid, false, `Expected "${input}" (${type}) to be invalid`);
      }
    }
  });

  it('handles single-char TLD rejection', () => {
    const result = validateRuleValue('example.x', 'whitelist');
    assert.strictEqual(result.valid, false);
  });

  it('accepts valid international TLDs', () => {
    const result = validateRuleValue('example.museum', 'whitelist');
    assert.strictEqual(result.valid, true);
  });
});

// =============================================================================
// validateRuleValue - allowed_path
// =============================================================================

describe('validateRuleValue allowed_path', () => {
  it('accepts a concrete domain + path', () => {
    assert.equal(validateRuleValue('youtube.com/watch?v=abc', 'allowed_path').valid, true);
  });
  it('accepts a full URL (cleaned, path preserved)', () => {
    assert.equal(
      validateRuleValue('https://www.youtube.com/watch?v=abc', 'allowed_path').valid,
      true
    );
  });
  it('rejects a value with no path', () => {
    assert.equal(validateRuleValue('youtube.com', 'allowed_path').valid, false);
  });
  it('rejects a global wildcard domain (must target a concrete domain)', () => {
    assert.equal(validateRuleValue('*/watch', 'allowed_path').valid, false);
  });
  it('rejects whitespace in the path', () => {
    assert.equal(validateRuleValue('youtube.com/a b', 'allowed_path').valid, false);
  });
});
