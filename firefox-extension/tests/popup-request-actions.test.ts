import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  buildRequestDomainOptions,
  retryPopupDomainLocalUpdate,
  shouldEnableSubmitRequest,
  submitPopupDomainRequest,
} from '../src/lib/popup-request-actions.js';

await describe('popup request actions', async () => {
  await test('builds request domain options with fallback origins', () => {
    const options = buildRequestDomainOptions({
      'b.example.com': {
        count: 1,
        origin: null,
        timestamp: 2,
      },
      'a.example.com': {
        count: 2,
        origin: 'portal.school',
        timestamp: 1,
      },
    });

    assert.deepEqual(options, [
      { hostname: 'a.example.com', origin: 'portal.school' },
      { hostname: 'b.example.com', origin: 'unknown' },
    ]);
  });

  await test('enables submit only when selection, reason, config and native host are ready', () => {
    assert.equal(
      shouldEnableSubmitRequest({
        hasSelectedDomain: true,
        hasValidReason: true,
        isNativeAvailable: true,
        isRequestConfigured: true,
      }),
      true
    );
    assert.equal(
      shouldEnableSubmitRequest({
        hasSelectedDomain: true,
        hasValidReason: false,
        isNativeAvailable: true,
        isRequestConfigured: true,
      }),
      false
    );
  });

  await test('submits popup requests through the background message builder', async () => {
    let capturedMessage: unknown;
    const consentPayloads: unknown[] = [];

    const result = await submitPopupDomainRequest({
      blockedDomainsData: {
        'cdn.example.com': {
          errors: ['NS_ERROR_UNKNOWN_HOST'],
          origin: 'portal.school',
          timestamp: 1,
        },
      },
      buildSubmitMessage: (payload) => payload,
      domain: 'cdn.example.com',
      isNativeAvailable: true,
      isRequestConfigured: true,
      requestBrowsingActivityConsent: (payload) => {
        consentPayloads.push(payload);
        return Promise.resolve({ granted: true });
      },
      reason: 'needed for class',
      sendMessage: (message) => {
        capturedMessage = message;
        return Promise.resolve({ success: true, id: 'req-1' });
      },
    });

    assert.deepEqual(consentPayloads, [{ data_collection: ['browsingActivity'] }]);
    assert.deepEqual(capturedMessage, {
      domain: 'cdn.example.com',
      error: 'NS_ERROR_UNKNOWN_HOST',
      origin: 'portal.school',
      reason: 'needed for class',
    });
    assert.deepEqual(result, {
      success: true,
      shouldReloadDomainStatuses: true,
      shouldResetForm: true,
      userMessage: '✅ Request sent for cdn.example.com. It remains pending approval.',
    });
  });

  await test('does not contact the background script when browsing activity consent is denied', async () => {
    let called = false;

    const result = await submitPopupDomainRequest({
      blockedDomainsData: {
        'cdn.example.com': {
          errors: ['NS_ERROR_UNKNOWN_HOST'],
          origin: 'portal.school',
          timestamp: 1,
        },
      },
      buildSubmitMessage: (payload) => payload,
      domain: 'cdn.example.com',
      isNativeAvailable: true,
      isRequestConfigured: true,
      requestBrowsingActivityConsent: () =>
        Promise.resolve({
          granted: false,
          error: 'Se necesita el permiso de actividad de navegación para enviar la solicitud.',
        }),
      reason: 'needed for class',
      sendMessage: () => {
        called = true;
        return Promise.resolve({});
      },
    });

    assert.equal(called, false);
    assert.equal(result.success, false);
    assert.match(result.userMessage, /actividad de navegación/);
  });

  await test('returns validation failures without contacting the background script', async () => {
    let called = false;

    const result = await submitPopupDomainRequest({
      blockedDomainsData: {},
      buildSubmitMessage: (payload) => payload,
      domain: '',
      isNativeAvailable: true,
      isRequestConfigured: true,
      reason: 'ok',
      sendMessage: () => {
        called = true;
        return Promise.resolve({});
      },
    });

    assert.equal(called, false);
    assert.equal(result.success, false);
    assert.equal(result.userMessage, '❌ Select a domain and enter a reason');
  });

  await test('maps retry requests to the background message contract', async () => {
    let capturedMessage: unknown;

    const result = await retryPopupDomainLocalUpdate({
      hostname: 'cdn.example.com',
      sendMessage: (message) => {
        capturedMessage = message;
        return Promise.resolve({ success: true });
      },
      tabId: 8,
    });

    assert.deepEqual(capturedMessage, {
      action: 'retryLocalUpdate',
      tabId: 8,
      hostname: 'cdn.example.com',
    });
    assert.deepEqual(result, { success: true });
  });
});
