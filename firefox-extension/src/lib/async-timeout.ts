/** Resolves to `fallback` if `promise` has not settled within `timeoutMs`.
 *  A rejected input promise also resolves to `fallback`. Never rejects.
 *  When `timeoutMs <= 0` the timer is skipped and the promise is raced
 *  immediately (fast-path: resolves to value or, on rejection, to fallback). */
export function withTimeoutOrFallback<T>(
  promise: Promise<T>,
  timeoutMs: number,
  fallback: T
): Promise<T> {
  if (timeoutMs <= 0) {
    return promise.catch(() => fallback);
  }

  return new Promise((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(fallback);
    }, timeoutMs);

    void promise.then(
      (value) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(value);
      },
      () => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(fallback);
      }
    );
  });
}

/** Rejects with `new Error(message)` if `promise` has not settled within
 *  `timeoutMs`. Lets the input promise's own rejection propagate unchanged. */
export function withTimeoutOrThrow<T>(
  promise: Promise<T>,
  timeoutMs: number,
  message: string
): Promise<T> {
  let timeoutId: ReturnType<typeof setTimeout> | null = null;
  const timeoutPromise = new Promise<never>((_resolve, reject) => {
    timeoutId = setTimeout(() => {
      reject(new Error(message));
    }, timeoutMs);
  });

  return Promise.race([promise, timeoutPromise]).finally(() => {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
    }
  });
}
