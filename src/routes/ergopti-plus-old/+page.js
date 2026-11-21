// src/routes/ergopti-plus-old/+page.js

/**
 * Former address of the legacy Ergopti+ page, retired on 2026-11-21. The site
 * is static on GitHub Pages, so the redirect is prerendered: SvelteKit writes a
 * page that forwards to the current Ergopti+ page, and a client-side
 * navigation follows the same redirect from this load.
 */
import { redirect } from '@sveltejs/kit';
import { resolve } from '$app/paths';

export const prerender = true;

export function load() {
	redirect(308, resolve('/ergopti-plus'));
}
