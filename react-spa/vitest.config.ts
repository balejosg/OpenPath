import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config';

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      globals: true,
      environment: 'jsdom',
      setupFiles: './src/test/setup.ts',
      include: ['src/**/*.{test,spec}.{ts,tsx}'],
      coverage: {
        provider: 'v8',
        reporter: ['text', 'json', 'html', 'lcov'],
        exclude: [
          'node_modules/**',
          'e2e/**',
          'src/test/**',
          '**/*.d.ts',
          '**/*.config.*',
          '**/types/**',
        ],
        thresholds: {
          lines: 80,
          functions: 75,
          branches: 70,
          statements: 80,
        },
      },
    },
  })
);
