import { act, renderHook } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useClipboard } from '../useClipboard';

describe('useClipboard', () => {
  let writeTextMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();

    writeTextMock = vi.fn().mockResolvedValue(undefined);

    Object.assign(navigator, {
      clipboard: {
        writeText: writeTextMock,
      },
    });
  });

  it('copies text and exposes a copied key for a limited time', async () => {
    const { result } = renderHook(() => useClipboard({ resetDelayMs: 2000 }));

    await act(async () => {
      const ok = await result.current.copy('hello', 'k1');
      expect(ok).toBe(true);
    });

    expect(writeTextMock).toHaveBeenCalledWith('hello');
    expect(result.current.copiedKey).toBe('k1');
    expect(result.current.isCopied('k1')).toBe(true);

    act(() => {
      vi.advanceTimersByTime(1999);
    });
    expect(result.current.isCopied('k1')).toBe(true);

    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(result.current.copiedKey).toBeNull();
    expect(result.current.isCopied('k1')).toBe(false);
  });

  it('returns false when clipboard write fails', async () => {
    writeTextMock.mockRejectedValueOnce(new Error('no permission'));

    const { result } = renderHook(() => useClipboard());

    await act(async () => {
      const ok = await result.current.copy('secret');
      expect(ok).toBe(false);
    });

    expect(result.current.error).toBe('Unable to copy to clipboard');
  });
});
