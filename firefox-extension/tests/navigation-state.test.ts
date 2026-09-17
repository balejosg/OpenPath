import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createNavigationState } from '../src/lib/navigation-state.js';

void test('gives every top-level navigation a distinct generation, including the same URL', () => {
  const state = createNavigationState();
  const first = state.begin(1, 'https://a.example/');
  state.begin(1, 'https://b.example/');
  const second = state.begin(1, 'https://a.example/');
  assert.notEqual(first.generation, second.generation);
  assert.equal(state.isCurrent(first), false);
  assert.equal(state.isCurrent(second), true);
});

void test('correlates errors only with the current URL and shares one redirect reservation', () => {
  const state = createNavigationState();
  const navigation = state.begin(4, 'https://current.example/');
  assert.equal(state.match(4, 'https://old.example/'), null);
  assert.equal(state.match(4, 'https://current.example/')?.generation, navigation.generation);
  assert.equal(state.reserveRedirect(navigation), true);
  assert.equal(state.reserveRedirect(navigation), false);
  state.releaseRedirect(navigation);
  assert.equal(state.reserveRedirect(navigation), true);
});

void test('shown belongs to one generation and disposal invalidates it', () => {
  const state = createNavigationState();
  const navigation = state.begin(9, 'https://a.example/');
  assert.equal(state.reserveRedirect(navigation), true);
  assert.equal(state.markShown(navigation), true);
  assert.equal(state.reserveRedirect(navigation), false);
  state.dispose(9);
  assert.equal(state.isCurrent(navigation), false);
});
