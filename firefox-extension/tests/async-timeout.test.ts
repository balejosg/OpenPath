import assert from 'node:assert/strict';
import { test } from 'node:test';

import { withTimeoutOrFallback, withTimeoutOrThrow } from '../src/lib/async-timeout.js';

// --- withTimeoutOrFallback ---

void test('withTimeoutOrFallback: resolves to the value when the promise settles before the timeout', async () => {
  const result = await withTimeoutOrFallback(Promise.resolve(42), 50, 0);
  assert.equal(result, 42);
});

void test('withTimeoutOrFallback: resolves to the fallback when the promise never settles within timeoutMs', async () => {
  const never = new Promise<number>(() => undefined);
  const result = await withTimeoutOrFallback(never, 5, -1);
  assert.equal(result, -1);
});

void test('withTimeoutOrFallback: resolves to the fallback when the input promise rejects before timeout', async () => {
  const rejected = Promise.reject<number>(new Error('boom'));
  const result = await withTimeoutOrFallback(rejected, 50, 99);
  assert.equal(result, 99);
});

void test('withTimeoutOrFallback: timeoutMs <= 0 fast-path: returns fallback on rejected input', async () => {
  const rejected = Promise.reject<string>(new Error('fast-reject'));
  const result = await withTimeoutOrFallback(rejected, 0, 'default');
  assert.equal(result, 'default');
});

void test('withTimeoutOrFallback: timeoutMs <= 0 fast-path: returns the resolved value on fulfilled input', async () => {
  const result = await withTimeoutOrFallback(Promise.resolve('ok'), 0, 'default');
  assert.equal(result, 'ok');
});

// --- withTimeoutOrThrow ---

void test('withTimeoutOrThrow: resolves to the value when the promise settles before the timeout', async () => {
  const result = await withTimeoutOrThrow(Promise.resolve('hello'), 50, 'timed out');
  assert.equal(result, 'hello');
});

void test('withTimeoutOrThrow: rejects with an Error whose message matches the passed message when the promise never settles', async () => {
  const never = new Promise<string>(() => undefined);
  await assert.rejects(withTimeoutOrThrow(never, 5, 'request timed out'), (err: unknown) => {
    assert.ok(err instanceof Error);
    assert.equal(err.message, 'request timed out');
    return true;
  });
});

void test('withTimeoutOrThrow: propagates the original rejection unchanged when the input promise rejects before the timeout', async () => {
  const originalError = new Error('original failure');
  const rejected = Promise.reject<string>(originalError);
  await assert.rejects(withTimeoutOrThrow(rejected, 50, 'should not see this'), (err: unknown) => {
    // The original error must surface, not the timeout message.
    assert.strictEqual(err, originalError);
    return true;
  });
});
