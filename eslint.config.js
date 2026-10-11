// Minimal static check: catches undefined identifiers (for example a variable used in a component that does not
// receive it as a prop), which neither the bundler nor unit tests report.
export default [
  {
    files: ['src/**/*.{js,jsx}'],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'module',
      parserOptions: { ecmaFeatures: { jsx: true } },
      globals: {
        window: 'readonly', document: 'readonly', console: 'readonly', fetch: 'readonly', localStorage: 'readonly',
        setInterval: 'readonly', clearInterval: 'readonly', setTimeout: 'readonly', clearTimeout: 'readonly',
        URLSearchParams: 'readonly', Date: 'readonly', __BUILD_SHA__: 'readonly', __BUILD_TIME__: 'readonly',
      },
    },
    rules: { 'no-undef': 'error' },
  },
];
