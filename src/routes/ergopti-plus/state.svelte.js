// src/routes/ergopti-plus/state.svelte.js

/**
 * ==============================================================================
 * MODULE: Ergopti+ Page — Shared Reactive State
 * DESCRIPTION:
 * Cross-component reactive state for the Ergopti+ marketing page, shared by
 * the hero, the demo windows, the platform section and the final CTA.
 *
 * FEATURES & RATIONALE:
 * 1. Single OS Choice: the Windows/macOS chrome toggle must drive every mock
 *    window on the page at once — one shared $state beats prop-drilling
 *    through a dozen section components.
 * 2. Single Release Fetch: the GitHub release is fetched once on mount and
 *    every download button derives its URL from here.
 * ==============================================================================
 */

/** Storage key for the persisted OS style choice. */
const OS_STORAGE_KEY = 'ergoptiplus.osStyle';

export const ui = $state({
	/** @type {'windows'|'macos'|'linux'} Chrome style applied to every mock window. */
	osStyle: 'windows',
	/** @type {{tag: string, url: (name: string) => string | null} | null} */
	release: null
});

/**
 * Detect the visitor's OS from the user agent (SSR-safe, defaults to
 * Windows which matches the majority audience).
 * @returns {'windows'|'macos'|'linux'}
 */
export function detectOS() {
	if (typeof navigator === 'undefined') return 'windows';
	const ua = navigator.userAgent || '';
	if (/mac/i.test(ua) && !/windows/i.test(ua)) return 'macos';
	// Android UAs contain "Linux" — only desktop Linux gets the GNOME chrome.
	if (/linux/i.test(ua) && !/android/i.test(ua)) return 'linux';
	return 'windows';
}

/**
 * Set the OS chrome style and persist the explicit choice so it sticks
 * across visits.
 * @param {'windows'|'macos'|'linux'} next
 */
export function setOS(next) {
	ui.osStyle = next;
	try {
		localStorage.setItem(OS_STORAGE_KEY, next);
	} catch (_) {
		/* localStorage might be unavailable — silently fall back. */
	}
}

/**
 * Restore the persisted OS choice if any, otherwise sniff the user agent.
 * Called once from the page's onMount.
 */
export function restoreOS() {
	let stored = null;
	try {
		stored = localStorage.getItem(OS_STORAGE_KEY);
	} catch (_) {
		/* ignore */
	}
	ui.osStyle =
		stored === 'macos' || stored === 'windows' || stored === 'linux' ? stored : detectOS();
}
