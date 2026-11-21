// src/lib/js/tryLink.js

/**
 * ==============================================================================
 * MODULE: Try Link
 * DESCRIPTION:
 * The site frames the Studio's « Essayer » page (static/ergopti_plus/_shared/
 * ui/layout_try). Its address names the layout typed (?layout=ergopti); this
 * module hands that parameter, and an anchor of the former « Essayer » page,
 * on to the frame. The page is prerendered: the address is read in the
 * browser.
 * ==============================================================================
 */

/** The message the framed page posts when the visitor picks a layout (try_page.js). */
export const TRY_LAYOUT_MESSAGE = 'ergopti-studio:try-layout';

/** The layout the « Essayer » tab types when the address names none (try_page.js DEFAULT_LAYOUT). */
export const TRY_DEFAULT_LAYOUT = 'ergopti';

/** The anchors of the former « Essayer » page, which name parts of the framed page. */
export const TRY_ANCHORS = Object.freeze(['input-text', 'keyboard_emulation']);

/**
 * The frame's address: French, the visited address's layout and a known anchor.
 * @param {string} page - The framed page's index.html URL.
 * @param {string} search - The visited address's query (location.search), '' when prerendering.
 * @param {string} hash - The visited address's anchor (location.hash), '' when prerendering.
 * @returns {string} The frame's src.
 */
export function trySrc(page, search, hash) {
	const query = new URLSearchParams({ lang: 'fr' });
	const layout = new URLSearchParams(search).get('layout');
	if (layout !== null && layout !== '') query.set('layout', layout);
	const anchor = String(hash).replace(/^#/, '');
	return page + '?' + query.toString() + (TRY_ANCHORS.includes(anchor) ? '#' + anchor : '');
}
