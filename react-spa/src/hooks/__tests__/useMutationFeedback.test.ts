import { describe, expect, it } from 'vitest';
import { resolveMutationFeedback } from '../useMutationFeedback';

describe('resolveMutationFeedback', () => {
  const messages = {
    badRequest: 'Revisa los datos enviados.',
    conflict: 'Existe un conflicto con el estado actual.',
    fallback: 'Unable to save configuration. Try again.',
  };

  it('maps tRPC error codes to messages when available', () => {
    expect(resolveMutationFeedback({ data: { code: 'BAD_REQUEST' } }, messages)).toBe(
      messages.badRequest
    );
    expect(resolveMutationFeedback({ data: { code: 'CONFLICT' } }, messages)).toBe(
      messages.conflict
    );
  });

  it('falls back to generic message when no rule matches', () => {
    expect(resolveMutationFeedback(new Error('unknown upstream timeout'), messages)).toBe(
      messages.fallback
    );
  });
});
