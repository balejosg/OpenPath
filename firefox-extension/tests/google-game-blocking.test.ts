import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  GOOGLE_GAME_POLICY_REASON,
  evaluateGoogleGameBlocking,
  isGoogleGameUrl,
} from '../src/lib/google-game-blocking.js';

void describe('Firefox Google game blocking', () => {
  void test('blocks direct Google Snake navigations before page auto-allow can release them', () => {
    const outcome = evaluateGoogleGameBlocking(
      {
        type: 'main_frame',
        url: 'https://www.google.com/fbx?fbx=snake_arcade',
      },
      { extensionOrigin: 'moz-extension://unit-test/' }
    );

    assert.ok(outcome);
    assert.equal(outcome.reason, `${GOOGLE_GAME_POLICY_REASON}:snake`);
    assert.match(outcome.redirectUrl ?? '', /\/blocked\/blocked\.html/);
    assert.equal(outcome.cancel, undefined);
  });

  void test('cancels Google doodle game frames and logo game assets', () => {
    assert.deepEqual(
      evaluateGoogleGameBlocking(
        {
          type: 'sub_frame',
          url: 'https://doodles.google/doodle/pacman/',
        },
        { extensionOrigin: 'moz-extension://unit-test/' }
      ),
      {
        cancel: true,
        reason: `${GOOGLE_GAME_POLICY_REASON}:doodles`,
      }
    );

    assert.deepEqual(
      evaluateGoogleGameBlocking(
        {
          type: 'script',
          url: 'https://www.google.com/logos/2010/pacman10-hp.js',
        },
        { extensionOrigin: 'moz-extension://unit-test/' }
      ),
      {
        cancel: true,
        reason: `${GOOGLE_GAME_POLICY_REASON}:logo-game`,
      }
    );
  });

  void test('does not block ordinary Google search or static logo requests', () => {
    assert.equal(isGoogleGameUrl('https://www.google.com/search?q=algebra'), null);
    assert.equal(
      evaluateGoogleGameBlocking({ type: 'main_frame', url: 'https://www.google.com/' }),
      null
    );
    assert.equal(
      evaluateGoogleGameBlocking({
        type: 'image',
        url: 'https://www.google.com/logos/doodles/2026/holiday-static.png',
      }),
      null
    );
  });
});
