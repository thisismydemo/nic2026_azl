import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// SITE_BASE is the Pages base path (for a project site: /<repository-name>/). A relative base also works from a folder.
export default defineConfig({ plugins: [react()], base: process.env.SITE_BASE ?? './' });
