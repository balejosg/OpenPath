import { describe, it } from 'node:test';
import assert from 'node:assert';
import {
  ApprovalScope,
  DomainRequest,
  DomainSchema,
  RequestBlockCause,
} from '../src/schemas/index.js';

describe('DomainSchema', () => {
  it('accepts valid domains', () => {
    const valid = [
      'google.com',
      'sub.domain.co.uk',
      '*.example.com',
      'a-b.test.org',
      'test.io',
      'www.example.com',
      'api.v2.example.org',
    ];
    valid.forEach((domain) => {
      assert.doesNotThrow(() => DomainSchema.parse(domain), `Should accept: ${domain}`);
    });
  });

  it('rejects invalid domains', () => {
    const invalid = ['', 'a', 'ab', 'abc', '-invalid.com', 'double..dots.com', '.startdot.com'];
    invalid.forEach((domain) => {
      assert.throws(() => DomainSchema.parse(domain), `Should reject: ${domain}`);
    });
  });

  it('accepts wildcard domains', () => {
    assert.doesNotThrow(() => DomainSchema.parse('*.example.com'));
    assert.doesNotThrow(() => DomainSchema.parse('*.sub.domain.org'));
  });

  it('enforces max length (253 chars)', () => {
    const longDomain = `${'a'.repeat(250)}.com`;
    assert.throws(() => DomainSchema.parse(longDomain));
  });

  it('enforces label max length (63 chars)', () => {
    const longLabel = `${'a'.repeat(64)}.com`;
    assert.throws(() => DomainSchema.parse(longLabel));
  });

  it('accepts labels up to 63 chars', () => {
    const maxLabel = `${'a'.repeat(63)}.com`;
    assert.doesNotThrow(() => DomainSchema.parse(maxLabel));
  });
});

const domainRequestBase = {
  id: 'req-1',
  domain: 'gemini.google.com',
  reason: 'Needed for class',
  requesterEmail: 'student@example.com',
  groupId: 'group-1',
  status: 'pending',
  createdAt: '2026-11-26T10:00:00.000Z',
  updatedAt: '2026-11-26T10:00:00.000Z',
  resolvedAt: null,
  resolvedBy: null,
} as const;

describe('DomainRequest blockCause', () => {
  it('accepts a request without blockCause', () => {
    assert.doesNotThrow(() => DomainRequest.parse(domainRequestBase));
  });

  it('accepts a blocked_by_rule cause with matchedRule', () => {
    const parsed = DomainRequest.parse({
      ...domainRequestBase,
      blockCause: { kind: 'blocked_by_rule', matchedRule: '*.google.com' },
    });
    assert.deepStrictEqual(parsed.blockCause, {
      kind: 'blocked_by_rule',
      matchedRule: '*.google.com',
    });
  });

  it('accepts already_allowed and not_allowed causes', () => {
    assert.doesNotThrow(() =>
      DomainRequest.parse({
        ...domainRequestBase,
        blockCause: { kind: 'already_allowed', matchedRule: 'google.com' },
      })
    );
    assert.doesNotThrow(() =>
      DomainRequest.parse({
        ...domainRequestBase,
        blockCause: { kind: 'not_allowed' },
      })
    );
  });

  it('rejects blocked_by_rule without matchedRule', () => {
    assert.throws(() =>
      DomainRequest.parse({
        ...domainRequestBase,
        blockCause: { kind: 'blocked_by_rule' },
      })
    );
  });
});

describe('ApprovalScope', () => {
  it('accepts host and family only', () => {
    assert.strictEqual(ApprovalScope.parse('host'), 'host');
    assert.strictEqual(ApprovalScope.parse('family'), 'family');
    assert.throws(() => ApprovalScope.parse('root'));
  });
});

describe('RequestBlockCause', () => {
  it('rejects unknown kinds', () => {
    assert.throws(() => RequestBlockCause.parse({ kind: 'other' }));
  });
});
