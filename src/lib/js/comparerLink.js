// src/lib/js/comparerLink.js

/**
 * ==============================================================================
 * MODULE: Comparer Link
 * DESCRIPTION:
 * The site frames the Studio's Comparer (static/ergopti_plus/_shared/ui/
 * layout_analysis). A comparison is shared as the framing page's address with
 * the Comparer's link parameters (comparer_page.js LINK_PARAMS); this module
 * hands them on to the frame, so the shared address opens the same
 * comparison. The page is prerendered: the address is read in the browser.
 * ==============================================================================
 */

/** The link parameters the Comparer reads (comparer_page.js LINK_PARAMS). */
export const COMPARER_LINK_PARAMS = Object.freeze([
	'corpus',
	'keyboard',
	'format',
	'layouts',
	'details',
	'versus'
]);

/**
 * The Comparer's frame address: the page's defaults, overridden by the
 * Comparer parameters of the visited address.
 * @param {string} page - The Comparer's index.html URL.
 * @param {Record<string, string>} defaults - The parameters the frame opens on.
 * @param {string} search - The visited address's query (location.search), '' when
 *   prerendering.
 * @returns {string} The frame's src.
 */
export function comparerSrc(page, defaults, search) {
	const query = new URLSearchParams(defaults);
	const visited = new URLSearchParams(search);
	for (const name of COMPARER_LINK_PARAMS) {
		const value = visited.get(name);
		if (value !== null) query.set(name, value);
	}
	return `${page}?${query.toString().replace(/%2C/g, ',')}`;
}
