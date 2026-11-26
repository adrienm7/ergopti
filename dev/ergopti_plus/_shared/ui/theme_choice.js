// _shared/ui/theme_choice.js

/**
 * ==============================================================================
 * MODULE: Chosen Theme
 * DESCRIPTION:
 * Lets a shared page framed by the site (the Studio's editor, Comparer and
 * optimizer) follow the light or dark theme the visitor chose there, instead
 * of only the system's appearance. theme.css reads the choice from
 * <html data-theme>; without one (the app's windows) the page follows the
 * system as before.
 *
 * FEATURES & RATIONALE:
 * 1. A link may name the theme (?theme=light|dark), so the first paint is
 *    already right.
 * 2. The framing page sends {type: 'ergopti-theme', theme} when the visitor
 *    changes it; 'system' removes the choice. Only a parent of this page's
 *    own origin is heard.
 * 3. An unknown value is named in the console and changes nothing.
 * ==============================================================================
 */

(function () {
	'use strict';

	const MESSAGE = 'ergopti-theme';
	const SYSTEM = 'system';
	const CHOICES = ['light', 'dark'];

	/** Applies a theme choice; 'system' gives the page back to the system's appearance. */
	function apply(theme) {
		if (theme === SYSTEM) {
			delete document.documentElement.dataset.theme;
			return;
		}
		if (!CHOICES.includes(theme)) {
			console.warn(`theme choice: unknown theme ${theme}`);
			return;
		}
		document.documentElement.dataset.theme = theme;
	}

	const linked = new URLSearchParams(location.search).get('theme');
	if (linked !== null) apply(linked);

	window.addEventListener('message', (event) => {
		if (event.origin !== location.origin || event.source !== window.parent) return;
		if (!event.data || event.data.type !== MESSAGE) return;
		apply(event.data.theme);
	});
})();
