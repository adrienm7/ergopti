import adapter from '@sveltejs/adapter-static';

// Allow overriding the base path at build time via BASE_PATH environment variable.
const base = process.env.BASE_PATH || '';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	kit: {
		adapter: adapter({
			precompress: true
		}),
		paths: {
			base
		}
	}
};

export default config;
