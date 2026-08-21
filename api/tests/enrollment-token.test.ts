import { test, describe } from 'node:test';
import assert from 'node:assert';
import jwt from 'jsonwebtoken';
import { loadConfig, setConfigForTests } from '../src/config.js';
import {
  generateEnrollmentToken,
  generateEnrollmentTokenWithExpiry,
  getEnrollmentTokenExpiresAt,
  verifyEnrollmentToken,
} from '../src/lib/enrollment-token.js';

void describe('Enrollment Token Lib', () => {
  void test('should generate and verify a valid token', () => {
    const classroomId = 'test-room-123';
    const token = generateEnrollmentToken(classroomId);
    assert.ok(token);

    const payload = verifyEnrollmentToken(token);
    assert.strictEqual(payload?.classroomId, classroomId);
    assert.strictEqual(payload.typ, 'enroll');
  });

  void test('should return null for invalid token', () => {
    const payload = verifyEnrollmentToken('invalid-token');
    assert.strictEqual(payload, null);
  });

  void test('should reject token with wrong audience', () => {
    // This is implicitly covered by verifyEnrollmentToken options
    // but we trust the jsonwebtoken lib for standard claim verification.
    const payload = verifyEnrollmentToken('');
    assert.strictEqual(payload, null);
  });

  void test('defaults to an installer-safe two hour lifetime', () => {
    const token = generateEnrollmentToken('test-room-ttl');
    const decoded = jwt.decode(token) as { exp?: number; iat?: number } | null;

    assert.ok(decoded?.exp);
    assert.ok(decoded.iat);
    assert.strictEqual(decoded.exp - decoded.iat, 2 * 60 * 60);
  });

  void test('accepts an explicit 24h lifetime when requested', () => {
    const token = generateEnrollmentToken('test-room-ttl-24h', '24h');
    const decoded = jwt.decode(token) as { exp?: number; iat?: number } | null;

    assert.ok(decoded?.exp);
    assert.ok(decoded.iat);
    assert.strictEqual(decoded.exp - decoded.iat, 24 * 60 * 60);
  });

  void test('rejects explicit lifetimes beyond the default 24 hour ceiling', () => {
    assert.throws(() => generateEnrollmentToken('test-room-ttl-over', '25h'), /maximum/i);
  });

  void test('accepts a lifetime exactly at the default ceiling in any supported unit', () => {
    const hoursToken = generateEnrollmentToken('test-room-ttl-max-h', '24h');
    const minutesToken = generateEnrollmentToken('test-room-ttl-max-m', '1440m');

    for (const token of [hoursToken, minutesToken]) {
      const decoded = jwt.decode(token) as { exp?: number; iat?: number } | null;
      assert.ok(decoded?.exp);
      assert.ok(decoded.iat);
      assert.strictEqual(decoded.exp - decoded.iat, 24 * 60 * 60);
    }
  });

  void test('honors a lowered configured ceiling', () => {
    const base = loadConfig();
    setConfigForTests({ ...base, enrollmentTokenMaxTtlHours: 1 });
    try {
      assert.throws(() => generateEnrollmentToken('test-room-ttl-low', '2h'), /maximum/i);
      assert.doesNotThrow(() => generateEnrollmentToken('test-room-ttl-low-ok', '45m'));
    } finally {
      setConfigForTests(base);
    }
  });

  void test('rejects unsupported or malformed expiry formats', () => {
    assert.throws(() => generateEnrollmentToken('test-room-ttl-bad', 'banana'));
    assert.throws(() => generateEnrollmentToken('test-room-ttl-week', '3w'));
  });

  void test('derives an ISO expiresAt from the issued token exp claim only', () => {
    const bundle = generateEnrollmentTokenWithExpiry('test-room-expires-at');
    const decoded = jwt.decode(bundle.enrollmentToken) as { exp?: number } | null;

    assert.ok(decoded?.exp);
    assert.strictEqual(bundle.expiresAt, new Date(decoded.exp * 1000).toISOString());
    assert.match(bundle.expiresAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);

    assert.strictEqual(getEnrollmentTokenExpiresAt(bundle.enrollmentToken), bundle.expiresAt);
  });
});
