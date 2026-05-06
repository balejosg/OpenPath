import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';
import noOnlyTests from 'eslint-plugin-no-only-tests';

export default tseslint.config(
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
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-misused-promises': 'error',
      '@typescript-eslint/consistent-type-definitions': ['error', 'interface'],
      '@typescript-eslint/explicit-function-return-type': 'error',
      '@typescript-eslint/dot-notation': 'off',
      'no-console': 'off',
    },
  },
  // Test anti-pattern rules
  {
    files: ['tests/**/*.ts'],
    plugins: {
      'no-only-tests': noOnlyTests,
    },
    rules: {
      'no-only-tests/no-only-tests': 'error',
    },
  },
  {
    ignores: [
      'coverage/',
      'dist/',
      'build/',
      'node_modules/',
      'blocked/*.js',
      'build-chromium-managed.mjs',
      'build-firefox-release.mjs',
      'build-firefox-source-submission.mjs',
      'eslint.config.js',
      'firefox-release-amo-version.mjs',
      'firefox-release-payload-hash.mjs',
      'sign-firefox-release.mjs',
      'sync-firefox-amo-policy.mjs',
      'upload-firefox-amo-source.mjs',
      'verify-firefox-amo-version.mjs',
      'verify-firefox-amo-submission.mjs',
      'verify-firefox-release-artifacts.mjs',
    ],
  }
);
