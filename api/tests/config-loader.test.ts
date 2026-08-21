import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { loadConfig } from '../src/config-loader.js';

void describe('config loader', () => {
  void test('normalizes the legacy GitHub Pages APT repository override to the raw gh-pages origin', () => {
    const config = loadConfig({
      NODE_ENV: 'test',
      APT_REPO_URL: 'https://balejosg.github.io/openpath/apt',
    });

    assert.equal(
      config.aptRepoUrl,
      'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt'
    );
  });

  void test('defaults the enrollment token max TTL to 24 hours', () => {
    const config = loadConfig({ NODE_ENV: 'test' });
    assert.equal(config.enrollmentTokenMaxTtlHours, 24);
  });

  void test('accepts a positive integer enrollment token max TTL override', () => {
    const config = loadConfig({ NODE_ENV: 'test', ENROLLMENT_TOKEN_MAX_TTL_HOURS: '48' });
    assert.equal(config.enrollmentTokenMaxTtlHours, 48);
  });

  void test('rejects non-positive or non-integer enrollment token max TTL overrides', () => {
    assert.throws(
      () => loadConfig({ NODE_ENV: 'test', ENROLLMENT_TOKEN_MAX_TTL_HOURS: '0' }),
      /positive integer/
    );
    assert.throws(
      () => loadConfig({ NODE_ENV: 'test', ENROLLMENT_TOKEN_MAX_TTL_HOURS: '-4' }),
      /positive integer/
    );
    assert.throws(
      () => loadConfig({ NODE_ENV: 'test', ENROLLMENT_TOKEN_MAX_TTL_HOURS: '2.5' }),
      /positive integer/
    );
    assert.throws(
      () => loadConfig({ NODE_ENV: 'test', ENROLLMENT_TOKEN_MAX_TTL_HOURS: 'soon' }),
      /positive integer/
    );
  });
});
