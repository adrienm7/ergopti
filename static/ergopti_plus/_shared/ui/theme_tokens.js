// _shared/ui/theme_tokens.js
// =============================================================================
// Reads the colours of _shared/ui/theme.css for the scripts that draw them (SVG
// text, canvas charts), which cannot use var(). The tokens are read from the
// document element once per name. A missing token is a defect of the page (the
// theme is not linked, or the name is wrong): it raises instead of drawing with
// a made-up colour.
//
// Classic script: load it after the theme stylesheet and before the page scripts.
// =============================================================================

var ThemeTokens = (function () {
	'use strict';

	var cache = {};

	/**
	 * The value of one theme token.
	 * @param {string} name Token name without the --theme- prefix, e.g. 'grey-888'.
	 * @return {string} The colour exactly as theme.css writes it.
	 * @throws {Error} When the theme does not define the token.
	 */
	function color(name) {
		if (Object.prototype.hasOwnProperty.call(cache, name)) return cache[name];
		var value = getComputedStyle(document.documentElement)
			.getPropertyValue('--theme-' + name)
			.trim();
		if (value === '') throw new Error('theme token missing: --theme-' + name);
		cache[name] = value;
		return value;
	}

	return { color: color };
})();
