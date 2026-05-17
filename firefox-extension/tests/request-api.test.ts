import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { fetchWithFallback, submitBlockedDomainRequest } from '../src/lib/request-api.js';

await describe('request api helpers', async () => {
  await test('fetchWithFallback tries later endpoints after a failure', async () => {
    const calls: string[] = [];
    const response = await fetchWithFallback(
      ['https://primary.invalid', 'https://secondary.example'],
      '/api/requests/submit',
      { method: 'POST' },
      1000,
      (url) => {
        const requestUrl = typeof url === 'string' ? url : url instanceof URL ? url.href : url.url;
        calls.push(requestUrl);
        if (requestUrl.includes('primary')) {
          return Promise.reject(new Error('primary down'));
        }

        return Promise.resolve(
          new Response(JSON.stringify({ success: true }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          })
        );
      }
    );

    assert.equal(response.status, 200);
    assert.deepEqual(calls, [
      'https://primary.invalid/api/requests/submit',
      'https://secondary.example/api/requests/submit',
    ]);
  });

  await test('submitBlockedDomainRequest builds and posts the unblock request', async () => {
    const result = await submitBlockedDomainRequest(
      {
        domain: 'example.com',
        reason: 'needed for class',
        origin: 'https://portal.school',
      },
      {
        buildBlockedDomainSubmitBody: (input) => input,
        fetchImpl: () =>
          Promise.resolve(
            new Response(JSON.stringify({ success: true, status: 'pending', id: 'req-1' }), {
              status: 200,
              headers: { 'Content-Type': 'application/json' },
            })
          ),
        getClientVersion: () => '1.2.3',
        getRequestApiEndpoints: () => ['https://api.example'],
        loadRequestConfig: () =>
          Promise.resolve({
            fallbackApiUrls: [],
            enableRequests: true,
            requestApiUrl: 'https://api.example',
            requestTimeout: 1000,
          }),
        sendNativeMessage: (message) => {
          if ((message as { action?: string }).action === 'get-hostname') {
            return Promise.resolve({ success: true, hostname: 'lab-pc-01' });
          }
          return Promise.resolve({ success: true, token: 'machine-token' });
        },
      }
    );

    assert.deepEqual(result, {
      success: true,
      status: 'pending',
      id: 'req-1',
    });
  });

  await test('submitBlockedDomainRequest treats existing pending requests as submitted', async () => {
    const result = await submitBlockedDomainRequest(
      {
        domain: 'example.com',
        reason: 'needed for class',
      },
      {
        buildBlockedDomainSubmitBody: (input) => input,
        fetchImpl: () =>
          Promise.resolve(
            new Response(JSON.stringify({ error: 'Pending request exists for this domain' }), {
              status: 409,
              headers: { 'Content-Type': 'application/json' },
            })
          ),
        getClientVersion: () => '1.2.3',
        getRequestApiEndpoints: () => ['https://api.example'],
        loadRequestConfig: () =>
          Promise.resolve({
            fallbackApiUrls: [],
            enableRequests: true,
            requestApiUrl: 'https://api.example',
            requestTimeout: 1000,
          }),
        sendNativeMessage: (message) => {
          if ((message as { action?: string }).action === 'get-hostname') {
            return Promise.resolve({ success: true, hostname: 'lab-pc-01' });
          }
          return Promise.resolve({ success: true, token: 'machine-token' });
        },
      }
    );

    assert.deepEqual(result, {
      success: true,
      status: 'pending',
      domain: 'example.com',
    });
  });

  await test('submitBlockedDomainRequest reports missing native request configuration clearly', async () => {
    const result = await submitBlockedDomainRequest(
      {
        domain: 'example.com',
        reason: 'needed for class',
      },
      {
        buildBlockedDomainSubmitBody: (input) => input,
        getClientVersion: () => '1.2.3',
        getRequestApiEndpoints: () => [],
        loadRequestConfig: () =>
          Promise.resolve({
            fallbackApiUrls: [],
            enableRequests: true,
            requestApiUrl: '',
            requestTimeout: 1000,
          }),
        sendNativeMessage: () => {
          throw new Error('Native host should not be called without request endpoints');
        },
      }
    );

    assert.deepEqual(result, {
      success: false,
      error: 'Incomplete configuration for domain requests',
    });
  });
});
