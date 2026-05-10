import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { ensureBrowsingActivityConsent } from '../src/lib/data-collection-consent.js';

await describe('data collection consent', async () => {
  await test('continues when browsing activity consent is already granted', async () => {
    let requested = false;

    const result = await ensureBrowsingActivityConsent({
      contains: () => Promise.resolve(true),
      request: () => {
        requested = true;
        return Promise.resolve(false);
      },
    });

    assert.deepEqual(result, { granted: true });
    assert.equal(requested, false);
  });

  await test('requests optional browsing activity consent when it is missing', async () => {
    const checkedPayloads: unknown[] = [];
    const requestedPayloads: unknown[] = [];

    const result = await ensureBrowsingActivityConsent({
      contains: (payload) => {
        checkedPayloads.push(payload);
        return Promise.resolve(false);
      },
      request: (payload) => {
        requestedPayloads.push(payload);
        return Promise.resolve(true);
      },
    });

    assert.deepEqual(result, { granted: true });
    assert.deepEqual(checkedPayloads, [{ data_collection: ['browsingActivity'] }]);
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

  await test('returns a compatibility message when Firefox lacks the data collection API', async () => {
    const result = await ensureBrowsingActivityConsent(null);

    assert.equal(result.granted, false);
    assert.match(result.error, /no es compatible/);
  });
});
