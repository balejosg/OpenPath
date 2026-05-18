import { describe, it, expect } from 'vitest';
import {
  cleanRuleValue,
  extractRootDomain,
  detectRuleType,
  getRuleTypeLabel,
  getRuleTypeBadge,
  categorizeRule,
  validateRuleValue,
} from '../ruleDetection';

describe('ruleDetection', () => {
  describe('cleanRuleValue', () => {
    it('removes https protocol', () => {
      expect(cleanRuleValue('https://google.com')).toBe('google.com');
    });

    it('removes http protocol', () => {
      expect(cleanRuleValue('http://google.com')).toBe('google.com');
    });

    it('removes wildcard protocol', () => {
      expect(cleanRuleValue('*://google.com')).toBe('google.com');
    });

    it('lowercases the value', () => {
      expect(cleanRuleValue('Google.COM')).toBe('google.com');
    });

    it('trims whitespace', () => {
      expect(cleanRuleValue('  google.com  ')).toBe('google.com');
    });

    it('removes trailing slash for domains', () => {
      expect(cleanRuleValue('google.com/')).toBe('google.com');
    });

    it('preserves path when preservePath is true', () => {
      expect(cleanRuleValue('https://google.com/path', true)).toBe('google.com/path');
    });

    it('preserves trailing slash in paths', () => {
      expect(cleanRuleValue('google.com/path/', true)).toBe('google.com/path/');
    });
  });

  describe('extractRootDomain', () => {
    it('returns same domain for 2-part domain', () => {
      expect(extractRootDomain('google.com')).toBe('google.com');
    });

    it('extracts root from subdomain', () => {
      expect(extractRootDomain('ads.google.com')).toBe('google.com');
    });

    it('extracts root from deep subdomain', () => {
      expect(extractRootDomain('a.b.c.google.com')).toBe('google.com');
    });

    it('handles wildcard prefix', () => {
      expect(extractRootDomain('*.google.com')).toBe('google.com');
    });

    it('handles wildcard with subdomain', () => {
      expect(extractRootDomain('*.tracking.google.com')).toBe('google.com');
    });
  });

  describe('detectRuleType', () => {
    describe('path detection', () => {
      it('detects path rule when value contains /', () => {
        const result = detectRuleType('facebook.com/gaming');
        expect(result.type).toBe('blocked_path');
        expect(result.cleanedValue).toBe('facebook.com/gaming');
        expect(result.confidence).toBe('high');
      });

      it('detects global path rule', () => {
        const result = detectRuleType('*/ads/*');
        expect(result.type).toBe('blocked_path');
        expect(result.cleanedValue).toBe('*/ads/*');
      });

      it('strips protocol from path rules', () => {
        const result = detectRuleType('https://facebook.com/gaming');
        expect(result.type).toBe('blocked_path');
        expect(result.cleanedValue).toBe('facebook.com/gaming');
      });
    });

    describe('subdomain detection with existing whitelist', () => {
      const existingWhitelist = ['google.com', 'facebook.com'];

      it('detects subdomain block when root is whitelisted', () => {
        const result = detectRuleType('ads.google.com', existingWhitelist);
        expect(result.type).toBe('blocked_subdomain');
        expect(result.confidence).toBe('high');
        expect(result.reason).toContain('google.com');
      });

      it('detects deep subdomain block', () => {
        const result = detectRuleType('tracking.ads.google.com', existingWhitelist);
        expect(result.type).toBe('blocked_subdomain');
      });

      it('detects wildcard subdomain block', () => {
        const result = detectRuleType('*.tracking.google.com', existingWhitelist);
        expect(result.type).toBe('blocked_subdomain');
        expect(result.confidence).toBe('high');
      });
    });

    describe('wildcard without existing whitelist', () => {
      it('suggests subdomain block for wildcard pattern', () => {
        const result = detectRuleType('*.example.com', []);
        expect(result.type).toBe('blocked_subdomain');
        expect(result.confidence).toBe('medium');
      });
    });

    describe('whitelist domain detection', () => {
      it('detects new domain as whitelist', () => {
        const result = detectRuleType('wikipedia.org', []);
        expect(result.type).toBe('whitelist');
        expect(result.confidence).toBe('high');
      });

      it('detects domain as whitelist even with existing domains', () => {
        const result = detectRuleType('wikipedia.org', ['google.com']);
        expect(result.type).toBe('whitelist');
      });

      it('strips protocol for whitelist domains', () => {
        const result = detectRuleType('https://wikipedia.org', []);
        expect(result.type).toBe('whitelist');
        expect(result.cleanedValue).toBe('wikipedia.org');
      });

      it('handles root domain that matches existing', () => {
        // If google.com is already whitelisted and user types google.com again
        const result = detectRuleType('google.com', ['google.com']);
        expect(result.type).toBe('whitelist'); // Still whitelist, duplicate check is elsewhere
      });
    });

    describe('edge cases', () => {
      it('handles empty existing whitelist', () => {
        const result = detectRuleType('example.com', []);
        expect(result.type).toBe('whitelist');
      });

      it('handles case-insensitive matching', () => {
        const result = detectRuleType('ADS.GOOGLE.COM', ['google.com']);
        expect(result.type).toBe('blocked_subdomain');
      });

      it('handles mixed case in existing whitelist', () => {
        const result = detectRuleType('ads.google.com', ['GOOGLE.COM']);
        expect(result.type).toBe('blocked_subdomain');
      });
    });
  });

  describe('getRuleTypeLabel', () => {
    it('returns correct label for whitelist', () => {
      expect(getRuleTypeLabel('whitelist')).toBe('Allowed domain');
      expect(getRuleTypeLabel('whitelist', 'es')).toBe('Dominio permitido');
    });

    it('returns correct label for blocked_subdomain', () => {
      expect(getRuleTypeLabel('blocked_subdomain')).toBe('Blocked subdomain');
    });

    it('returns correct label for blocked_path', () => {
      expect(getRuleTypeLabel('blocked_path')).toBe('Blocked path');
    });
  });

  describe('getRuleTypeBadge', () => {
    it('returns short badge for whitelist', () => {
      expect(getRuleTypeBadge('whitelist')).toBe('Allowed');
      expect(getRuleTypeBadge('whitelist', 'es')).toBe('Permitido');
    });

    it('returns short badge for blocked_subdomain', () => {
      expect(getRuleTypeBadge('blocked_subdomain')).toBe('Sub. blocked');
    });

    it('returns short badge for blocked_path', () => {
      expect(getRuleTypeBadge('blocked_path')).toBe('Path blocked');
    });
  });

  describe('categorizeRule', () => {
    it('categorizes whitelist as allowed', () => {
      expect(categorizeRule('whitelist')).toBe('allowed');
    });

    it('categorizes blocked_subdomain as blocked', () => {
      expect(categorizeRule('blocked_subdomain')).toBe('blocked');
    });

    it('categorizes blocked_path as blocked', () => {
      expect(categorizeRule('blocked_path')).toBe('blocked');
    });
  });

  describe('validateRuleValue', () => {
    describe('whitelist (domain) validation', () => {
      it('accepts valid simple domain', () => {
        expect(validateRuleValue('google.com', 'whitelist').valid).toBe(true);
      });

      it('accepts valid domain with subdomain-like parts', () => {
        expect(validateRuleValue('www.google.com', 'whitelist').valid).toBe(true);
      });

      it('accepts domain with hyphens', () => {
        expect(validateRuleValue('my-site.example.com', 'whitelist').valid).toBe(true);
      });

      it('accepts domain with protocol (gets stripped)', () => {
        expect(validateRuleValue('https://google.com', 'whitelist').valid).toBe(true);
      });

      it('accepts domain with trailing slash (gets stripped)', () => {
        expect(validateRuleValue('google.com/', 'whitelist').valid).toBe(true);
      });

      it('accepts domain with long TLD', () => {
        expect(validateRuleValue('example.museum', 'whitelist').valid).toBe(true);
      });

      it('accepts ccTLD domains', () => {
        expect(validateRuleValue('example.co.uk', 'whitelist').valid).toBe(true);
      });

      it('rejects empty string', () => {
        const result = validateRuleValue('', 'whitelist');
        expect(result.valid).toBe(false);
        expect(result.error).toBeDefined();
      });

      it('rejects whitespace only', () => {
        const result = validateRuleValue('   ', 'whitelist');
        expect(result.valid).toBe(false);
      });

      it('rejects domain too short', () => {
        const result = validateRuleValue('a.b', 'whitelist');
        expect(result.valid).toBe(false);
        expect(result.error).toContain('too short');
      });

      it('rejects domain with consecutive dots', () => {
        const result = validateRuleValue('google..com', 'whitelist');
        expect(result.valid).toBe(false);
        expect(result.error).toContain('consecutive');
      });

      it('rejects domain starting with hyphen', () => {
        const result = validateRuleValue('-google.com', 'whitelist');
        expect(result.valid).toBe(false);
      });

      it('rejects domain ending with hyphen', () => {
        const result = validateRuleValue('google-.com', 'whitelist');
        expect(result.valid).toBe(false);
      });

      it('rejects domain with spaces', () => {
        const result = validateRuleValue('goo gle.com', 'whitelist');
        expect(result.valid).toBe(false);
      });

      it('rejects random string without dots', () => {
        const result = validateRuleValue('notadomain', 'whitelist');
        expect(result.valid).toBe(false);
      });

      it('rejects domain with invalid characters', () => {
        const result = validateRuleValue('goo!gle.com', 'whitelist');
        expect(result.valid).toBe(false);
      });

      it('rejects domain with underscores', () => {
        const result = validateRuleValue('my_site.com', 'whitelist');
        expect(result.valid).toBe(false);
      });

      it('rejects single-char TLD', () => {
        const result = validateRuleValue('example.a', 'whitelist');
        expect(result.valid).toBe(false);
      });

      it('rejects numeric TLD', () => {
        const result = validateRuleValue('example.123', 'whitelist');
        expect(result.valid).toBe(false);
      });
    });

    describe('blocked_subdomain validation', () => {
      it('accepts valid subdomain', () => {
        expect(validateRuleValue('ads.google.com', 'blocked_subdomain').valid).toBe(true);
      });

      it('accepts wildcard subdomain', () => {
        expect(validateRuleValue('*.google.com', 'blocked_subdomain').valid).toBe(true);
      });

      it('accepts deep wildcard subdomain', () => {
        expect(validateRuleValue('*.tracking.google.com', 'blocked_subdomain').valid).toBe(true);
      });

      it('accepts normal domain as subdomain type', () => {
        expect(validateRuleValue('google.com', 'blocked_subdomain').valid).toBe(true);
      });

      it('rejects invalid wildcard format', () => {
        const result = validateRuleValue('**.google.com', 'blocked_subdomain');
        expect(result.valid).toBe(false);
      });

      it('rejects wildcard in middle', () => {
        const result = validateRuleValue('ads.*.google.com', 'blocked_subdomain');
        expect(result.valid).toBe(false);
      });

      it('rejects empty subdomain', () => {
        const result = validateRuleValue('', 'blocked_subdomain');
        expect(result.valid).toBe(false);
      });

      it('rejects subdomain with consecutive dots', () => {
        const result = validateRuleValue('ads..google.com', 'blocked_subdomain');
        expect(result.valid).toBe(false);
      });
    });

    describe('blocked_path validation', () => {
      it('accepts valid domain/path', () => {
        expect(validateRuleValue('facebook.com/gaming', 'blocked_path').valid).toBe(true);
      });

      it('accepts domain/path with nested segments', () => {
        expect(validateRuleValue('example.com/path/to/page', 'blocked_path').valid).toBe(true);
      });

      it('accepts wildcard domain path', () => {
        expect(validateRuleValue('*/ads/*', 'blocked_path').valid).toBe(true);
      });

      it('accepts path with query string', () => {
        expect(validateRuleValue('example.com/path?q=test', 'blocked_path').valid).toBe(true);
      });

      it('accepts path with protocol (gets stripped)', () => {
        expect(validateRuleValue('https://facebook.com/gaming', 'blocked_path').valid).toBe(true);
      });

      it('rejects path without slash', () => {
        const result = validateRuleValue('facebook.com', 'blocked_path');
        expect(result.valid).toBe(false);
        expect(result.error).toContain('/');
      });

      it('rejects path with invalid domain', () => {
        const result = validateRuleValue('not valid!/path', 'blocked_path');
        expect(result.valid).toBe(false);
      });

      it('rejects path with empty path part', () => {
        const result = validateRuleValue('example.com/', 'blocked_path');
        expect(result.valid).toBe(false);
        expect(result.error).toContain('empty');
      });

      it('rejects empty value', () => {
        const result = validateRuleValue('', 'blocked_path');
        expect(result.valid).toBe(false);
      });
    });

    describe('protocol and normalization handling', () => {
      it('strips https:// and validates domain', () => {
        expect(validateRuleValue('https://example.com', 'whitelist').valid).toBe(true);
      });

      it('strips http:// and validates domain', () => {
        expect(validateRuleValue('http://example.com', 'whitelist').valid).toBe(true);
      });

      it('strips protocol from path rules', () => {
        expect(validateRuleValue('https://example.com/page', 'blocked_path').valid).toBe(true);
      });

      it('handles case insensitive input', () => {
        expect(validateRuleValue('GOOGLE.COM', 'whitelist').valid).toBe(true);
      });

      it('trims whitespace', () => {
        expect(validateRuleValue('  google.com  ', 'whitelist').valid).toBe(true);
      });
    });
  });
});
