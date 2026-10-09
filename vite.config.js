import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The app is served from the domain root on Cloudflare Workers/Pages.
// GitHub Actions currently validates builds only, so use root-relative assets.
export default defineConfig({ plugins: [react()], base: '/' });
