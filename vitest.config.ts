// packages/hotstrings-web/vitest.config.ts

import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vitest/config';

export default defineConfig({
	plugins: [svelte()],
	resolve: { conditions: ['browser'] },
	test: {
		include: ['tests/**/*.test.ts'],
		coverage: {
			provider: 'v8',
			include: ['src/**/*.ts', 'src/**/*.svelte'],
			exclude: ['src/types.ts'],
			reporter: ['text', 'json-summary'],
			thresholds: { lines: 100, branches: 100, functions: 100, statements: 100 }
		}
	}
});
