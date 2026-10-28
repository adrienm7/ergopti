import { sveltekit } from '@sveltejs/kit/vite';
import { enhancedImages } from '@sveltejs/enhanced-img';
import adapter from '@sveltejs/adapter-static';

// Allow overriding the base path at build time via the BASE_PATH environment variable.
// Useful when deploying the site under a subpath like /dev/ on GitHub Pages.
const base = process.env.BASE_PATH || '';

const config = {
	plugins: [
		enhancedImages(), // must come before the SvelteKit plugin
		sveltekit({
			adapter: adapter({
				precompress: true
			}),
			paths: {
				base
			},
			// Nothing on the site reads updated.current, so keep the SvelteKit 2
			// behaviour of never polling _app/version.json.
			version: {
				pollInterval: 0
			}
		})
	],
	assetsInclude: ['**/*.toml', '**/*.keylayout', '**/*.kbe', '**/*.exe', '**/*.ahk']
};

export default config;
