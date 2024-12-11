import { sveltekit } from '@sveltejs/kit/vite';

const config = {
	plugins: [sveltekit()],
	assetsInclude: ['**/*.toml', '**/*.keylayout', '**/*.kbe', '**/*.exe', '**/*.ahk']
};

export default config;
