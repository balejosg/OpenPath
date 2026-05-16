import { test, describe } from 'node:test';
import assert from 'node:assert';

import {
  DEFAULT_REQUEST_CONFIG,
  getRequestApiEndpoints,
  hasValidRequestConfig,
  loadRequestConfig,
  loadRequestConfigWithNativeFallback,
  saveRequestConfig,
} from '../src/lib/config-storage.js';
import { loadNativeRequestConfigWithSender } from '../src/lib/config-storage-native.js';

function setMockBrowser(mock: unknown): void {
  Object.defineProperty(globalThis, 'browser', {
    value: mock,
    configurable: true,
  });
}

function clearMockBrowser(): void {
  const globalRec = globalThis as unknown as Record<string, unknown>;
  delete globalRec.browser;
}

function createMockBrowser(params: {
  storedLocalConfig?: unknown;
  storedSyncConfig?: unknown;
  localStorageError?: Error;
  syncStorageError?: Error;
  nativeResponse?: unknown;
  nativeError?: Error;
  onLocalSave?: (value: unknown) => void;
  onSyncSave?: (value: unknown) => void;
}): unknown {
  return {
    storage: {
      local: {
        get: (): Promise<unknown> => {
          if (params.localStorageError) {
            return Promise.reject(params.localStorageError);
          }
          return Promise.resolve(params.storedLocalConfig ?? {});
        },
        set: (value: unknown): Promise<void> => {
          params.onLocalSave?.(value);
          return Promise.resolve();
        },
      },
      sync: {
        get: (): Promise<unknown> => {
          if (params.syncStorageError) {
            return Promise.reject(params.syncStorageError);
          }
          return Promise.resolve(params.storedSyncConfig ?? {});
        },
        set: (value: unknown): Promise<void> => {
          params.onSyncSave?.(value);
          return Promise.resolve();
        },
      },
    },
    runtime: {
      sendNativeMessage: (): Promise<unknown> => {
        if (params.nativeError) {
          return Promise.reject(params.nativeError);
        }
        return Promise.resolve(
          params.nativeResponse ?? { success: false, error: 'native unavailable' }
        );
      },
    },
  };
}

void describe('config-storage', () => {
  void test('getRequestApiEndpoints returns primary + fallbacks', () => {
    const endpoints = getRequestApiEndpoints({
      ...DEFAULT_REQUEST_CONFIG,
      requestApiUrl: 'https://api.example',
      fallbackApiUrls: ['https://api-2.example', ''],
    });

    assert.deepStrictEqual(endpoints, ['https://api.example', 'https://api-2.example']);
  });

  void test('hasValidRequestConfig requires enableRequests and endpoints', () => {
    assert.strictEqual(hasValidRequestConfig(DEFAULT_REQUEST_CONFIG), false);
    assert.strictEqual(
      hasValidRequestConfig({
        ...DEFAULT_REQUEST_CONFIG,
        requestApiUrl: 'https://api.example',
      }),
      true
    );
  });

  void test('loadRequestConfig merges stored config with defaults', async () => {
    setMockBrowser(
      createMockBrowser({
        storedLocalConfig: {
          config: {
            requestApiUrl: 'https://api.example',
            sharedSecret: 'secret',
            requestTimeout: 1234,
          },
        },
      })
    );

    try {
      const loaded = await loadRequestConfig();
      assert.strictEqual(loaded.requestApiUrl, 'https://api.example');
      assert.strictEqual(loaded.sharedSecret, 'secret');
      assert.strictEqual(loaded.requestTimeout, 1234);
      assert.deepStrictEqual(loaded.fallbackApiUrls, []);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadRequestConfig keeps native endpoints when persisted storage only contains empty legacy overrides', async () => {
    setMockBrowser(
      createMockBrowser({
        storedLocalConfig: {
          config: {
            requestApiUrl: '',
            fallbackApiUrls: [],
          },
        },
        nativeResponse: {
          success: true,
          requestApiUrl: 'https://native.example/',
          fallbackApiUrls: ['https://backup.example/'],
        },
      })
    );

    try {
      const loaded = await loadRequestConfig();
      assert.strictEqual(loaded.requestApiUrl, 'https://native.example');
      assert.deepStrictEqual(loaded.fallbackApiUrls, ['https://backup.example']);
      assert.strictEqual(loaded.enableRequests, true);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadNativeRequestConfigWithSender normalizes config from the supplied native channel', async () => {
    const sentMessages: unknown[] = [];

    const nativeFallback = await loadNativeRequestConfigWithSender((message) => {
      sentMessages.push(message);
      return Promise.resolve({
        success: true,
        apiUrl: 'https://native-channel.example/',
        fallbackApiUrls: ['https://native-channel-backup.example/'],
      });
    });

    assert.deepStrictEqual(sentMessages, [{ action: 'get-config' }]);
    assert.deepStrictEqual(nativeFallback, {
      requestApiUrl: 'https://native-channel.example',
      fallbackApiUrls: ['https://native-channel-backup.example'],
      enableRequests: true,
    });
  });

  void test('loadRequestConfigWithNativeFallback keeps supplied native config ahead of stale storage', async () => {
    setMockBrowser(
      createMockBrowser({
        storedLocalConfig: {
          config: {
            requestApiUrl: '',
            fallbackApiUrls: [],
            enableRequests: false,
          },
        },
      })
    );

    try {
      const loaded = await loadRequestConfigWithNativeFallback({
        requestApiUrl: 'https://native-channel.example',
        fallbackApiUrls: [],
        enableRequests: true,
      });

      assert.strictEqual(loaded.requestApiUrl, 'https://native-channel.example');
      assert.strictEqual(loaded.enableRequests, true);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadRequestConfig treats native classroom endpoints as request-enabled despite stale legacy disable flags', async () => {
    setMockBrowser(
      createMockBrowser({
        storedLocalConfig: {
          config: {
            requestApiUrl: '',
            fallbackApiUrls: [],
            enableRequests: false,
          },
        },
        nativeResponse: {
          success: true,
          requestApiUrl: 'https://native.example/',
        },
      })
    );

    try {
      const loaded = await loadRequestConfig();
      assert.strictEqual(loaded.requestApiUrl, 'https://native.example');
      assert.strictEqual(loaded.enableRequests, true);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadRequestConfigWithNativeFallback lets native endpoints override malformed legacy request flags', async () => {
    setMockBrowser(
      createMockBrowser({
        storedLocalConfig: {
          config: {
            requestApiUrl: '',
            fallbackApiUrls: [],
            enableRequests: null,
          },
        },
      })
    );

    try {
      const loaded = await loadRequestConfigWithNativeFallback({
        requestApiUrl: 'https://native.example',
        fallbackApiUrls: ['https://native-backup.example'],
        enableRequests: true,
      });

      assert.strictEqual(loaded.requestApiUrl, 'https://native.example');
      assert.deepStrictEqual(loaded.fallbackApiUrls, ['https://native-backup.example']);
      assert.strictEqual(loaded.enableRequests, true);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadRequestConfig falls back to native host config when storage is empty', async () => {
    setMockBrowser(
      createMockBrowser({
        nativeResponse: {
          success: true,
          requestApiUrl: 'https://native.example/',
          fallbackApiUrls: ['https://backup.example/'],
        },
      })
    );

    try {
      const loaded = await loadRequestConfig();
      assert.strictEqual(loaded.requestApiUrl, 'https://native.example');
      assert.deepStrictEqual(loaded.fallbackApiUrls, ['https://backup.example']);
      assert.strictEqual(loaded.enableRequests, true);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadRequestConfig keeps native endpoints ahead of stale stored endpoints while preserving native request enablement', async () => {
    setMockBrowser(
      createMockBrowser({
        storedLocalConfig: {
          config: {
            requestApiUrl: 'https://stored.example/cp',
            fallbackApiUrls: ['https://stored-backup.example'],
            enableRequests: false,
          },
        },
        nativeResponse: {
          success: true,
          requestApiUrl: 'https://native.example',
          fallbackApiUrls: ['https://native-backup.example'],
        },
      })
    );

    try {
      const loaded = await loadRequestConfig();
      assert.strictEqual(loaded.requestApiUrl, 'https://native.example');
      assert.deepStrictEqual(loaded.fallbackApiUrls, ['https://native-backup.example']);
      assert.strictEqual(loaded.enableRequests, true);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadRequestConfig preserves a legacy disable flag when no native request endpoint is available', async () => {
    setMockBrowser(
      createMockBrowser({
        storedLocalConfig: {
          config: {
            requestApiUrl: 'https://stored.example',
            fallbackApiUrls: [],
            enableRequests: false,
          },
        },
      })
    );

    try {
      const loaded = await loadRequestConfig();
      assert.strictEqual(loaded.requestApiUrl, 'https://stored.example');
      assert.strictEqual(loaded.enableRequests, false);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadRequestConfig uses native fallback when storage read fails', async () => {
    setMockBrowser(
      createMockBrowser({
        localStorageError: new Error('local storage unavailable'),
        syncStorageError: new Error('sync storage unavailable'),
        nativeResponse: {
          success: true,
          apiUrl: 'https://native-only.example',
        },
      })
    );

    try {
      const loaded = await loadRequestConfig();
      assert.strictEqual(loaded.requestApiUrl, 'https://native-only.example');
      assert.deepStrictEqual(loaded.fallbackApiUrls, []);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadRequestConfig falls back to defaults when native config fails', async () => {
    setMockBrowser(
      createMockBrowser({
        nativeError: new Error('native unavailable'),
      })
    );

    try {
      const loaded = await loadRequestConfig();
      assert.deepStrictEqual(loaded, DEFAULT_REQUEST_CONFIG);
    } finally {
      clearMockBrowser();
    }
  });

  void test('loadRequestConfig falls back to legacy sync config when local storage is empty', async () => {
    setMockBrowser(
      createMockBrowser({
        storedSyncConfig: {
          config: {
            requestApiUrl: 'https://legacy.example',
            fallbackApiUrls: ['https://legacy-backup.example'],
          },
        },
      })
    );

    try {
      const loaded = await loadRequestConfig();
      assert.strictEqual(loaded.requestApiUrl, 'https://legacy.example');
      assert.deepStrictEqual(loaded.fallbackApiUrls, ['https://legacy-backup.example']);
    } finally {
      clearMockBrowser();
    }
  });

  void test('saveRequestConfig persists merged config to local storage', async () => {
    let savedLocal: unknown;
    let savedSync: unknown;
    setMockBrowser(
      createMockBrowser({
        onLocalSave: (value) => {
          savedLocal = value;
        },
        onSyncSave: (value) => {
          savedSync = value;
        },
      })
    );

    try {
      await saveRequestConfig({ requestApiUrl: 'https://api.example', sharedSecret: 'secret' });
      assert.deepStrictEqual(savedLocal, {
        config: {
          ...DEFAULT_REQUEST_CONFIG,
          requestApiUrl: 'https://api.example',
          sharedSecret: 'secret',
        },
      });
      assert.strictEqual(savedSync, undefined);
    } finally {
      clearMockBrowser();
    }
  });
});
