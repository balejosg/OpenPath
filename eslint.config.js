import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';
import noOnlyTests from 'eslint-plugin-no-only-tests';

export default tseslint.config(
  {
    ignores: [
      '**/node_modules/**',
      '**/dist/**',
      '**/build/**',
      '**/coverage/**',
      '.worktrees/**',
      'api/tests/load/**',
      'eslint.config.js',
      '**/*.config.js',
      '**/*.config.ts',
      '**/*.config.mjs',
      '**/shared/tests/**',
      'react-spa/e2e/**',
      'firefox-extension/blocked/**',
      'firefox-extension/xpi-signature-evidence.mjs',
      'tests/repo-config.test.mjs',
      'tests/generate-docker-manifests.test.mjs',
      'tests/selenium/**',
      'scripts/**',
    ],
  },
  eslint.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  ...tseslint.configs.stylisticTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      '@typescript-eslint/no-non-null-assertion': 'error',
      '@typescript-eslint/no-confusing-void-expression': ['error', { ignoreArrowShorthand: true }],
      '@typescript-eslint/restrict-template-expressions': ['error', { allowNumber: true }],
      'no-console': 'off',
      semi: ['error', 'always'],
      quotes: ['error', 'single', { avoidEscape: true }],
    },
  },
  // Enforce centralized error reporting in SPA app code.
  {
    files: ['react-spa/src/**/*.{ts,tsx}'],
    rules: {
      'no-console': 'error',
    },
  },
  {
    files: ['react-spa/src/lib/reportError.ts'],
    rules: {
      'no-console': ['error', { allow: ['error'] }],
    },
  },
  {
    files: ['tests/**/*.mjs'],
    ...tseslint.configs.disableTypeChecked,
  },
  // Test anti-pattern rules for all test files
  {
    files: ['**/*.test.ts', '**/*.test.tsx', '**/*.spec.ts', '**/*.spec.tsx'],
    plugins: {
      'no-only-tests': noOnlyTests,
    },
    rules: {
      // Prevent .only() which would skip other tests
      'no-only-tests/no-only-tests': 'error',
      'no-console': 'off',
    },
  }
);
