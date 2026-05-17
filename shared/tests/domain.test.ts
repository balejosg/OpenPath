import { describe, it } from 'node:test';
import assert from 'node:assert';
import {
  getRootDomain,
  groupByRootDomain,
  CC_SLDS,
  normalizeManualRequestDomain,
} from '../src/domain.js';

describe('getRootDomain', () => {
  describe('standard TLDs', () => {
    it('should extract root domain from simple domain', () => {
      assert.strictEqual(getRootDomain('google.com'), 'google.com');
    });

    it('should extract root domain from subdomain', () => {
      assert.strictEqual(getRootDomain('mail.google.com'), 'google.com');
    });

    it('should extract root domain from deep subdomain', () => {
      assert.strictEqual(getRootDomain('a.b.c.d.google.com'), 'google.com');
    });

    it('should handle www prefix', () => {
      assert.strictEqual(getRootDomain('www.google.com'), 'google.com');
    });

    it('should handle https protocol', () => {
      assert.strictEqual(getRootDomain('https://www.google.com'), 'google.com');
    });

    it('should handle http protocol', () => {
      assert.strictEqual(getRootDomain('http://mail.google.com'), 'google.com');
    });

    it('should remove path', () => {
      assert.strictEqual(getRootDomain('facebook.com/gaming'), 'facebook.com');
    });

    it('should remove query string', () => {
      assert.strictEqual(getRootDomain('example.com?foo=bar'), 'example.com');
    });

    it('should remove hash', () => {
      assert.strictEqual(getRootDomain('example.com#section'), 'example.com');
    });

    it('should remove port', () => {
      assert.strictEqual(getRootDomain('example.com:8080'), 'example.com');
    });

    it('should handle wildcard prefix', () => {
      assert.strictEqual(getRootDomain('*.google.com'), 'google.com');
    });

    it('should handle wildcard with dot prefix', () => {
      assert.strictEqual(getRootDomain('*.cdn.example.com'), 'example.com');
    });
  });

  describe('ccTLDs (country-code second-level domains)', () => {
    it('should handle .co.uk', () => {
      assert.strictEqual(getRootDomain('www.bbc.co.uk'), 'bbc.co.uk');
    });

    it('should handle .com.au', () => {
      assert.strictEqual(getRootDomain('news.abc.com.au'), 'abc.com.au');
    });

    it('should handle .com.br', () => {
      assert.strictEqual(getRootDomain('www.globo.com.br'), 'globo.com.br');
    });

    it('should handle .com.ar', () => {
      assert.strictEqual(getRootDomain('mail.clarin.com.ar'), 'clarin.com.ar');
    });

    it('should handle .co.jp', () => {
      assert.strictEqual(getRootDomain('www.sony.co.jp'), 'sony.co.jp');
    });

    it('should handle .co.nz', () => {
      assert.strictEqual(getRootDomain('shop.stuff.co.nz'), 'stuff.co.nz');
    });

    it('should handle .gov.uk', () => {
      assert.strictEqual(getRootDomain('www.gov.uk'), 'gov.uk');
    });

    it('should handle .edu.au', () => {
      assert.strictEqual(getRootDomain('library.unimelb.edu.au'), 'unimelb.edu.au');
    });

    it('should handle bare ccSLD', () => {
      // When domain is just the ccSLD itself
      assert.strictEqual(getRootDomain('co.uk'), 'co.uk');
    });

    it('should handle ccSLD with full URL', () => {
      assert.strictEqual(getRootDomain('https://www.example.co.uk/path?query=1'), 'example.co.uk');
    });
  });

  describe('edge cases', () => {
    it('should return single-part domain as-is', () => {
      assert.strictEqual(getRootDomain('localhost'), 'localhost');
    });

    it('should handle empty string', () => {
      assert.strictEqual(getRootDomain(''), '');
    });

    it('should handle IP addresses (returns last 2 octets as if TLD)', () => {
      // IP addresses don't have a "root domain" - function treats octets like domain parts
      assert.strictEqual(getRootDomain('192.168.1.1'), '1.1');
    });

    it('should preserve case (normalization happens elsewhere)', () => {
      // getRootDomain extracts the root, case normalization is done by normalize.domain()
      assert.strictEqual(getRootDomain('WWW.GOOGLE.COM'), 'GOOGLE.COM');
    });

    it('should handle trailing dots', () => {
      // Trailing dots are technically valid in DNS
      assert.strictEqual(getRootDomain('google.com.'), 'com.');
    });
  });
});

describe('normalizeManualRequestDomain', () => {
  it('normalizes manual request subdomains to their root domain', () => {
    assert.strictEqual(normalizeManualRequestDomain('es.wikipedia.org'), 'wikipedia.org');
    assert.strictEqual(normalizeManualRequestDomain('mail.google.com'), 'google.com');
  });
});

describe('groupByRootDomain', () => {
  it('should group rules by root domain', () => {
    const rules = [
      { value: 'mail.google.com', id: '1' },
      { value: 'drive.google.com', id: '2' },
      { value: 'facebook.com', id: '3' },
      { value: 'www.facebook.com', id: '4' },
    ];

    const groups = groupByRootDomain(rules);

    assert.strictEqual(groups.size, 2);
    assert.strictEqual(groups.get('google.com')?.length, 2);
    assert.strictEqual(groups.get('facebook.com')?.length, 2);
  });

  it('should handle empty array', () => {
    const groups = groupByRootDomain([]);
    assert.strictEqual(groups.size, 0);
  });

  it('should handle ccTLDs correctly', () => {
    const rules = [
      { value: 'www.bbc.co.uk', id: '1' },
      { value: 'news.bbc.co.uk', id: '2' },
      { value: 'example.co.uk', id: '3' },
    ];

    const groups = groupByRootDomain(rules);

    assert.strictEqual(groups.size, 2);
    assert.strictEqual(groups.get('bbc.co.uk')?.length, 2);
    assert.strictEqual(groups.get('example.co.uk')?.length, 1);
  });

  it('should preserve original rule objects', () => {
    const rule = { value: 'test.google.com', id: '1', extra: 'data' };
    const groups = groupByRootDomain([rule]);

    const googleRules = groups.get('google.com');
    assert.strictEqual(googleRules?.[0], rule);
  });
});

describe('CC_SLDS set', () => {
  it('should contain common UK ccSLDs', () => {
    assert.ok(CC_SLDS.has('co.uk'));
    assert.ok(CC_SLDS.has('org.uk'));
    assert.ok(CC_SLDS.has('gov.uk'));
  });

  it('should contain common Australian ccSLDs', () => {
    assert.ok(CC_SLDS.has('com.au'));
    assert.ok(CC_SLDS.has('edu.au'));
    assert.ok(CC_SLDS.has('gov.au'));
  });

  it('should contain common Latin American ccSLDs', () => {
    assert.ok(CC_SLDS.has('com.ar'));
    assert.ok(CC_SLDS.has('com.br'));
    assert.ok(CC_SLDS.has('com.mx'));
  });

  it('should contain common Asian ccSLDs', () => {
    assert.ok(CC_SLDS.has('co.jp'));
    assert.ok(CC_SLDS.has('com.cn'));
    assert.ok(CC_SLDS.has('co.kr'));
  });

  it('should not contain standard TLDs', () => {
    assert.ok(!CC_SLDS.has('com'));
    assert.ok(!CC_SLDS.has('org'));
    assert.ok(!CC_SLDS.has('net'));
  });
});
