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

  it('clearCopied cancels the pending timer and resets copiedKey', async () => {
    const { result } = renderHook(() => useClipboard({ resetDelayMs: 2000 }));

    await act(async () => {
      await result.current.copy('hello', 'k1');
    });

    expect(result.current.copiedKey).toBe('k1');

    act(() => {
      result.current.clearCopied();
    });

    expect(result.current.copiedKey).toBeNull();

    // Advance past the original timeout — copiedKey must remain null (timer was cleared)
    act(() => {
      vi.advanceTimersByTime(2000);
    });
    expect(result.current.copiedKey).toBeNull();
  });

  it('returns false with error when clipboard API is unavailable', async () => {
    // Remove clipboard from navigator entirely
    Object.assign(navigator, { clipboard: undefined });

    const { result } = renderHook(() => useClipboard());

    await act(async () => {
      const ok = await result.current.copy('text');
      expect(ok).toBe(false);
    });

    expect(result.current.error).toBe('Clipboard API no disponible');
  });

  it('cancels the existing timer when copy is called a second time before reset', async () => {
    const { result } = renderHook(() => useClipboard({ resetDelayMs: 2000 }));

    // First copy
    await act(async () => {
      await result.current.copy('first', 'k1');
    });
    expect(result.current.copiedKey).toBe('k1');

    // Advance partway through the first timer
    act(() => {
      vi.advanceTimersByTime(1000);
    });

    // Second copy — must cancel the first timer
    await act(async () => {
      await result.current.copy('second', 'k2');
    });
    expect(result.current.copiedKey).toBe('k2');

    // First timer's deadline passes — copiedKey must still be k2 (first timer was cancelled)
    act(() => {
      vi.advanceTimersByTime(1000);
    });
    expect(result.current.copiedKey).toBe('k2');

    // Second timer fires — now resets
    act(() => {
      vi.advanceTimersByTime(1000);
    });
    expect(result.current.copiedKey).toBeNull();
  });
});
