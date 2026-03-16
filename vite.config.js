import { sveltekit } from '@sveltejs/kit/vite';
import { enhancedImages } from '@sveltejs/enhanced-img';

// Allow overriding the base path at build time via the BASE_PATH environment variable.
// Useful when deploying the site under a subpath like /dev/ on GitHub Pages.
const config = {
	base: process.env.BASE_PATH || '',
	plugins: [
		enhancedImages(), // must come before the SvelteKit plugin
		sveltekit()
	],
	assetsInclude: ['**/*.toml', '**/*.keylayout', '**/*.kbe', '**/*.exe', '**/*.ahk']
};

export default config;
