import assert from 'node:assert';
import { describe, test } from 'node:test';

import {
  SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
  buildBlockedScreenContextFromSearch,
  buildSubmitBlockedDomainRequestMessage,
  isSubmitBlockedDomainRequestMessage,
  shouldClearBlockedMonitorStateOnNavigate,
} from '../src/lib/blocked-screen-contract.js';

void describe('blocked screen contract', () => {
  void test('separates blocked screen display fallbacks from request payload data', () => {
    const context = buildBlockedScreenContextFromSearch(
      '?blockedUrl=https%3A%2F%2Flearning.example%2Flesson&error=NS_ERROR_UNKNOWN_HOST'
    );

    assert.deepStrictEqual(context, {
      blockedDomain: 'learning.example',
      displayOrigin: 'unknown',
      error: 'NS_ERROR_UNKNOWN_HOST',
      origin: null,
    });
  });

  void test('builds the background request message without empty optional fields', () => {
    assert.deepStrictEqual(
      buildSubmitBlockedDomainRequestMessage({
        domain: 'learning.example',
        reason: 'Lo necesito para una actividad de clase',
        origin: null,
        error: 'NS_ERROR_UNKNOWN_HOST',
      }),
      {
        action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
        domain: 'learning.example',
        reason: 'Lo necesito para una actividad de clase',
        error: 'NS_ERROR_UNKNOWN_HOST',
      }
    );
  });

  void test('rejects malformed optional background request fields', () => {
    assert.equal(
      isSubmitBlockedDomainRequestMessage({
        action: SUBMIT_BLOCKED_DOMAIN_REQUEST_ACTION,
        domain: 'learning.example',
        reason: 'Lo necesito para una actividad de clase',
        origin: 42,
      }),
      false
    );
  });

  void test('preserves monitor state while navigating to the extension blocked screen', () => {
    const blockedScreenUrl = 'moz-extension://unit-test-id/blocked/blocked.html';

    assert.equal(
      shouldClearBlockedMonitorStateOnNavigate(
        {
          frameId: 0,
          url: 'moz-extension://unit-test-id/blocked/blocked.html?domain=learning.example',
        },
        blockedScreenUrl
      ),
      false
    );
    assert.equal(
      shouldClearBlockedMonitorStateOnNavigate(
        { frameId: 0, url: 'https://learning.example/activity' },
        blockedScreenUrl
      ),
      true
    );
    assert.equal(
      shouldClearBlockedMonitorStateOnNavigate(
        { frameId: 1, url: 'https://learning.example/frame' },
        blockedScreenUrl
      ),
      false
    );
  });
});
