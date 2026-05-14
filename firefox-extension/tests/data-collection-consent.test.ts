import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { ensureBrowsingActivityConsent } from '../src/lib/data-collection-consent.js';

await describe('data collection consent', async () => {
  await test('does not preflight contains before requesting consent from a user gesture', async () => {
    let containsCalled = false;

    const result = await ensureBrowsingActivityConsent({
      contains: () => {
        containsCalled = true;
        throw new Error('contains should not run before request');
      },
      request: () => {
        return Promise.resolve(true);
      },
    });

    assert.deepEqual(result, { granted: true });
    assert.equal(containsCalled, false);
  });

  await test('falls back to contains when consent is already granted but request returns false', async () => {
    let requested = false;

    const result = await ensureBrowsingActivityConsent({
      contains: () => {
        return Promise.resolve(true);
      },
      request: () => {
        requested = true;
        return Promise.resolve(false);
      },
    });

    assert.deepEqual(result, { granted: true });
    assert.equal(requested, true);
  });

  await test('requests optional browsing activity consent when it is missing', async () => {
    const requestedPayloads: unknown[] = [];

    const result = await ensureBrowsingActivityConsent({
      contains: () => Promise.resolve(false),
      request: (payload) => {
        requestedPayloads.push(payload);
        return Promise.resolve(true);
      },
    });

    assert.deepEqual(result, { granted: true });
    assert.deepEqual(requestedPayloads, [{ data_collection: ['browsingActivity'] }]);
  });

  await test('returns a denial message when the user does not grant consent', async () => {
    const result = await ensureBrowsingActivityConsent({
      contains: () => Promise.resolve(false),
      request: () => Promise.resolve(false),
    });

    assert.equal(result.granted, false);
    assert.match(result.error, /permiso de actividad de navegacion/);
  });

  await test('keeps working when Firefox throws during request but consent is already granted', async () => {
    const result = await ensureBrowsingActivityConsent({
      contains: () => Promise.resolve(true),
      request: () => Promise.reject(new Error('user activation expired')),
    });

    assert.deepEqual(result, { granted: true });
  });

  await test('returns the compatibility message with request failure detail when request and contains both fail', async () => {
    const result = await ensureBrowsingActivityConsent({
      contains: () => Promise.reject(new Error('contains unavailable')),
      request: () => Promise.reject(new Error('user activation expired')),
    });

    assert.equal(result.granted, false);
    assert.match(result.error, /no es compatible/);
    assert.match(result.error, /user activation expired/);
  });

  await test('returns a compatibility message when Firefox lacks the data collection API', async () => {
    const result = await ensureBrowsingActivityConsent(null);

    assert.equal(result.granted, false);
    assert.match(result.error, /no es compatible/);
  });
});
