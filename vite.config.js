import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Cloudflare Pages serves this app at the domain root; GitHub Pages serves it under the repository path.
const base = process.env.CF_PAGES ? '/' : '/miniature-lamp/';

export default defineConfig({ plugins: [react()], base });
