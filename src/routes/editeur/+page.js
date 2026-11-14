// src/routes/editeur/+page.js

/**
 * Former address of Ergopti Studio. The site is static on GitHub Pages, so the
 * redirect is prerendered: SvelteKit writes a page that forwards to /studio,
 * and a client-side navigation follows the same redirect from this load.
 */
import { redirect } from '@sveltejs/kit';
import { resolve } from '$app/paths';

export const prerender = true;

export function load() {
	redirect(308, resolve('/studio'));
}
