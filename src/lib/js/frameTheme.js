// src/lib/js/frameTheme.js

/**
 * ==============================================================================
 * MODULE: Frame Theme
 * DESCRIPTION:
 * The light or dark theme the visitor chooses for Ergopti Studio's framed
 * pages (the editor, the Comparer, the optimizer). Those pages follow the
 * system's appearance unless told otherwise; the site tells them through
 * the message of _shared/ui/theme_choice.js, and keeps the choice for the
 * visitor's next pages.
 * ==============================================================================
 */

/** The message the framed pages listen for (theme_choice.js MESSAGE). */
export const THEME_MESSAGE = 'ergopti-theme';

/** Where the visitor's choice is kept in this browser. */
export const THEME_STORAGE_KEY = 'ergopti.studio.theme';

/** The choices, the system's appearance first (the default). */
export const THEME_CHOICES = Object.freeze(['system', 'light', 'dark']);

/**
 * A saved choice, or the system's appearance when none is saved or the value
 * is not a choice (an older or damaged entry).
 * @param {string|null} saved - The stored value.
 * @returns {string} One of THEME_CHOICES.
 */
export function readThemeChoice(saved) {
	return THEME_CHOICES.includes(saved) ? saved : THEME_CHOICES[0];
}

/**
 * Tells one framed page the theme.
 * @param {HTMLIFrameElement} frame - A frame of the site's own origin.
 * @param {string} theme - One of THEME_CHOICES.
 * @throws {Error} On a value that is not a choice.
 */
export function sendTheme(frame, theme) {
	if (!THEME_CHOICES.includes(theme)) throw new Error(`frame theme: unknown theme ${theme}`);
	// A frame not yet loaded has no window; its load sends the theme again.
	if (!frame.contentWindow) return;
	frame.contentWindow.postMessage({ type: THEME_MESSAGE, theme }, location.origin);
}
