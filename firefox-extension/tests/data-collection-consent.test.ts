import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  ensureBrowsingActivityConsent,
  startBrowsingActivityConsentRequest,
} from '../src/lib/data-collection-consent.js';

await describe('data collection consent', async () => {
  await test('checks the required permission without requesting runtime consent', async () => {
    let requestCalled = false;

    const result = await ensureBrowsingActivityConsent({
      contains: () => Promise.resolve(true),
      request: () => {
        requestCalled = true;
        return Promise.resolve(true);
      },
    });

    assert.deepEqual(result, { granted: true });
    assert.equal(requestCalled, false);
  });

  await test('does not request runtime consent when required permission is already granted', async () => {
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
    assert.equal(requested, false);
  });

  await test('returns a recovery message when the required browsing activity permission is missing', async () => {
    const requestedPayloads: unknown[] = [];

    const result = await ensureBrowsingActivityConsent({
      contains: () => Promise.resolve(false),
      request: (payload) => {
        requestedPayloads.push(payload);
        return Promise.resolve(true);
      },
    });

    assert.equal(result.granted, false);
    assert.match(result.error, /permiso de actividad de navegacion requerido/);
    assert.deepEqual(requestedPayloads, []);
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

  await test('checks the required consent without opening a runtime prompt', async () => {
    const events: string[] = [];

    const consentPromise = startBrowsingActivityConsentRequest({
      contains: () => {
        events.push('contains');
        return Promise.resolve(true);
      },
      request: () => Promise.reject(new Error('request should not run')),
    });

    events.push('after-start');
    assert.deepEqual(events, ['contains', 'after-start']);

    const result = await consentPromise;

    assert.deepEqual(result, { granted: true });
    assert.deepEqual(events, ['contains', 'after-start']);
  });

  await test('returns the compatibility message with contains failure detail when permission checks fail', async () => {
    const result = await ensureBrowsingActivityConsent({
      contains: () => Promise.reject(new Error('contains unavailable')),
      request: () => Promise.reject(new Error('user activation expired')),
    });

    assert.equal(result.granted, false);
    assert.match(result.error, /no permite comprobar/);
    assert.match(result.error, /contains unavailable/);
  });

  await test('returns a compatibility message when Firefox lacks the data collection API', async () => {
    const result = await ensureBrowsingActivityConsent(null);

    assert.equal(result.granted, false);
    assert.match(result.error, /no permite comprobar/);
  });
});
