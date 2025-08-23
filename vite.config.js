import { sveltekit } from '@sveltejs/kit/vite';
import { enhancedImages } from '@sveltejs/enhanced-img';

const config = {
	plugins: [
		enhancedImages(), // must come before the SvelteKit plugin
		sveltekit()
	],
	assetsInclude: ['**/*.toml', '**/*.keylayout', '**/*.kbe', '**/*.exe', '**/*.ahk']
};

export default config;
