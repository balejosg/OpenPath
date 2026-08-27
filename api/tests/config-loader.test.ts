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

  void test('requires a credential-free HTTPS PUBLIC_URL in production when configured', () => {
    assert.throws(
      () =>
        loadConfig({
          NODE_ENV: 'production',
          JWT_SECRET: 'config-loader-production-secret',
          PUBLIC_URL: 'http://internal-container:3000',
        }),
      /PUBLIC_URL must use HTTPS/u
    );
    assert.throws(
      () =>
        loadConfig({
          NODE_ENV: 'production',
          JWT_SECRET: 'config-loader-production-secret',
          PUBLIC_URL: 'https://user:password@openpath.example.test',
        }),
      /PUBLIC_URL must contain a hostname and no URL credentials/u
    );

    const config = loadConfig({
      NODE_ENV: 'production',
      JWT_SECRET: 'config-loader-production-secret',
      PUBLIC_URL: 'https://openpath.example.test/',
    });
    assert.equal(config.publicUrl, 'https://openpath.example.test/');
  });

  void test('rejects PUBLIC_URL query strings and fragments', () => {
    assert.throws(
      () =>
        loadConfig({
          NODE_ENV: 'test',
          PUBLIC_URL: 'https://openpath.example.test/base?tenant=one',
        }),
      /query string or fragment/i
    );
    assert.throws(
      () =>
        loadConfig({
          NODE_ENV: 'test',
          PUBLIC_URL: 'https://openpath.example.test/base#installer',
        }),
      /query string or fragment/i
    );
  });

  void test('requires PUBLIC_URL during production startup when offline installer is configured', () => {
    assert.throws(
      () =>
        loadConfig({
          NODE_ENV: 'production',
          JWT_SECRET: 'config-loader-production-secret',
          OPENPATH_WINDOWS_OFFLINE_TEMPLATE_DIR: '/srv/templates',
          OPENPATH_WINDOWS_OFFLINE_ARTIFACTS_DIR: '/srv/artifacts',
          OPENPATH_WINDOWS_OFFLINE_TEMPLATE_VERSION: '4.1.0',
          OPENPATH_WINDOWS_OFFLINE_TEMPLATE_COMMIT: 'a'.repeat(40),
          OPENPATH_WINDOWS_OFFLINE_TEMPLATE_SHA256: 'b'.repeat(64),
          OPENPATH_WINDOWS_OFFLINE_TEMPLATE_RELEASE_TAG: 'scripts-v4.1.0-aaaaaaa',
        }),
      /PUBLIC_URL.*required.*offline installer/i
    );
  });
});
