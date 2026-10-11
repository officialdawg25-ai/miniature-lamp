import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { execSync } from 'node:child_process';

// The app is served from the domain root on Cloudflare Workers/Pages.
// GitHub Actions currently validates builds only, so use root-relative assets.
// Public build metadata (commit + time only) lets the deployed bundle be matched to a commit.
const sha = (() => {
  const env = process.env.WORKERS_CI_COMMIT_SHA || process.env.CF_PAGES_COMMIT_SHA || process.env.GITHUB_SHA;
  if (env) return env;
  try { return execSync('git rev-parse HEAD', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim(); } catch { return 'unknown'; }
})();

export default defineConfig({
  plugins: [react()],
  base: '/',
  define: {
    __BUILD_SHA__: JSON.stringify(sha.slice(0, 7)),
    __BUILD_TIME__: JSON.stringify(new Date().toISOString()),
  },
});
