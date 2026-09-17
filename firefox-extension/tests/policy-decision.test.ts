import assert from 'node:assert/strict';
import { test } from 'node:test';

import { normalizePolicyDecision, permitsPolicyRedirect } from '../src/lib/policy-decision.js';

void test('accepts a complete explicit blocked verdict', () => {
  const verdict = normalizePolicyDecision({
    domain: 'blocked.example',
    inWhitelist: false,
    policyActive: true,
    policyDecision: 'blocked',
    policyReason: 'default-deny',
    policyVersion: 'v1',
  });
  assert.equal(verdict.decision, 'blocked');
  assert.equal(permitsPolicyRedirect(verdict, 'v1'), true);
});

void test('does not infer a block from legacy inWhitelist false', () => {
  const verdict = normalizePolicyDecision({
    domain: 'blocked.example',
    inWhitelist: false,
    policyActive: true,
  });
  assert.equal(verdict.decision, 'unknown');
  assert.equal(permitsPolicyRedirect(verdict), false);
});

void test('inactive, errored, unknown, and stale verdicts cannot redirect', () => {
  const base = {
    domain: 'blocked.example',
    inWhitelist: false,
    policyDecision: 'blocked' as const,
    policyReason: 'default-deny',
    policyVersion: 'v1',
  };
  assert.equal(
    permitsPolicyRedirect(normalizePolicyDecision({ ...base, policyActive: false })),
    false
  );
  assert.equal(
    permitsPolicyRedirect(
      normalizePolicyDecision({ ...base, policyActive: true, error: 'policy-read-failed' })
    ),
    false
  );
  assert.equal(
    permitsPolicyRedirect(
      normalizePolicyDecision({ ...base, policyActive: true, policyDecision: 'unknown' })
    ),
    false
  );
  assert.equal(
    permitsPolicyRedirect(normalizePolicyDecision({ ...base, policyActive: true }), 'v2'),
    false
  );
});

void test('rejects malformed protocol fields instead of inventing values', () => {
  const verdict = normalizePolicyDecision({
    domain: 'blocked.example',
    inWhitelist: false,
    policyActive: true,
    policyDecision: 'denied',
    policyReason: '',
    policyVersion: 7,
  });
  assert.equal(verdict.decision, 'unknown');
  assert.equal(verdict.version, null);
  assert.equal(permitsPolicyRedirect(verdict), false);
});
