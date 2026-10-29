/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

// base: './' يجعل الموقع يعمل على GitHub Pages داخل أي مسار (username.github.io/repo)
export default defineConfig({
  base: './',
  plugins: [react(), tailwindcss()],
  // exceljs كبير لكنه يُحمَّل فقط عند التصدير
  build: { target: 'es2022', sourcemap: false, chunkSizeWarningLimit: 1000 },
  test: { environment: 'node', include: ['src/**/*.test.ts'] },
});
