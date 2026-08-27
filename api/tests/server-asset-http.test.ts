import { test } from 'node:test';
import assert from 'node:assert/strict';

import { loadConfig, setConfigForTests } from '../src/config.js';
import {
  buildStaticEtag,
  buildWhitelistEtag,
  getPublicBaseUrl,
  matchesIfNoneMatch,
} from '../src/lib/server-asset-http.js';

void test('server-asset-http builds stable etags and matches If-None-Match values', () => {
  const staticEtag = buildStaticEtag('openpath');
  const whitelistEtag = buildWhitelistEtag({
    groupId: 'group-1',
    updatedAt: new Date('2026-01-01T00:00:00.000Z'),
    enabled: true,
  });

  assert.match(staticEtag, /^".+"$/);
  assert.match(whitelistEtag, /^".+"$/);
  assert.equal(
    matchesIfNoneMatch(
      { headers: { 'if-none-match': `W/${whitelistEtag}` } } as never,
      whitelistEtag
    ),
    true
  );
});

void test('uses the configured public URL instead of request host or forwarded headers', () => {
  const configured = loadConfig({
    NODE_ENV: 'test',
    JWT_SECRET: 'server-asset-http-test-secret',
    PUBLIC_URL: 'https://public.openpath.example.test/',
  });
  const previous = loadConfig({
    NODE_ENV: 'test',
    JWT_SECRET: 'server-asset-http-previous-secret',
  });
  setConfigForTests(configured);

  try {
    assert.equal(
      getPublicBaseUrl({
        protocol: 'http',
        headers: {
          host: 'internal-api:3000',
          'x-forwarded-host': 'attacker.example.test',
          'x-forwarded-proto': 'http',
        },
        get: (name: string) =>
          ({ host: 'internal-api:3000', 'x-forwarded-host': 'attacker.example.test' })[
            name.toLowerCase()
          ],
      } as never),
      'https://public.openpath.example.test'
    );
  } finally {
    setConfigForTests(previous);
  }
});

void test('preserves a configured public pathname base without trusting proxy headers', () => {
  const configured = loadConfig({
    NODE_ENV: 'test',
    JWT_SECRET: 'server-asset-http-base-secret',
    PUBLIC_URL: 'https://public.openpath.example.test/base/',
  });
  const previous = loadConfig({
    NODE_ENV: 'test',
    JWT_SECRET: 'server-asset-http-previous-secret',
  });
  setConfigForTests(configured);

  try {
    assert.equal(
      getPublicBaseUrl({
        protocol: 'http',
        headers: { host: 'internal-api:3000' },
        get: () => 'internal-api:3000',
      } as never),
      'https://public.openpath.example.test/base'
    );
  } finally {
    setConfigForTests(previous);
  }
});

void test('fails closed for public URL generation in production without PUBLIC_URL', () => {
  const production = loadConfig({
    NODE_ENV: 'production',
    JWT_SECRET: 'server-asset-http-production-secret',
  });
  const previous = loadConfig({
    NODE_ENV: 'test',
    JWT_SECRET: 'server-asset-http-previous-secret',
  });
  setConfigForTests(production);

  try {
    assert.throws(
      () =>
        getPublicBaseUrl({
          protocol: 'http',
          headers: {
            host: 'internal-api:3000',
            'x-forwarded-host': 'attacker.example.test',
            'x-forwarded-proto': 'http',
          },
          get: (name: string) =>
            ({ host: 'internal-api:3000', 'x-forwarded-host': 'attacker.example.test' })[
              name.toLowerCase()
            ],
        } as never),
      /PUBLIC_URL/i
    );
  } finally {
    setConfigForTests(previous);
  }
});

void test('never downgrades a configured production public URL to an HTTP origin', () => {
  assert.throws(
    () =>
      loadConfig({
        NODE_ENV: 'production',
        JWT_SECRET: 'server-asset-http-production-secret',
        PUBLIC_URL: 'http://internal-container:3000',
      }),
    /PUBLIC_URL must use HTTPS/u
  );
});
