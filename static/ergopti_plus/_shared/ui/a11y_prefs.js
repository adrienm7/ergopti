// _shared/ui/a11y_prefs.js

/**
 * ==============================================================================
 * MODULE: Accessibility Preferences
 * DESCRIPTION:
 * The one owner of the visitor's display preferences on the website and in the
 * Ergopti Studio pages it frames: reduced motion, a hyperlegible or a
 * dyslexia font, a larger text size, wider text spacing, shorter lines, text
 * aligned to the start, high contrast and colours that colour-blind readers
 * tell apart. Each preference becomes a
 * data attribute on the document's root element, which the site stylesheet
 * (src/lib/css/accessibility.css) and the shared theme (theme.css) style.
 *
 * FEATURES & RATIONALE:
 * 1. Classic script, loaded synchronously in the head, so the preferences
 *    apply before the first paint: no flash of the default look.
 * 2. Stored per visitor in localStorage. Blocked or absent storage (private
 *    windows, sandboxed frames, the native webviews) reads as « no
 *    preference », and a refused write keeps the choice for the current page.
 * 3. A Studio frame loads this script too. The storage event reaches every
 *    same-origin document, so a change made on the site restyles its open
 *    frames at once.
 * 4. Values are closed lists: an unknown stored value is ignored, so an old or
 *    hand-edited entry cannot put the page in an undefined look.
 * ==============================================================================
 */

(function () {
	'use strict';

	var STORAGE_KEY = 'ergopti-a11y-preferences';
	// Each reading font's stylesheet, served by the site next to this file's
	// folder (static/fonts/), never from a CDN. Resolved from this script's own
	// address, so the site under any base path and its frames find the same file.
	var SCRIPT_SRC = document.currentScript ? document.currentScript.src : '';
	var FONT_FOLDERS = { hyperlegible: 'atkinson-hyperlegible', dyslexic: 'opendyslexic' };
	var FONT_LINK_ID = 'ergopti-a11y-font-';
	// Each preference: its root attribute and its allowed values, the first
	// being the default (no attribute written).
	var PREFERENCES = {
		motion: { attribute: 'data-a11y-motion', values: ['system', 'reduce'] },
		font: { attribute: 'data-a11y-font', values: ['default', 'hyperlegible', 'dyslexic'] },
		text: { attribute: 'data-a11y-text', values: ['100', '125', '150', '200'] },
		spacing: { attribute: 'data-a11y-spacing', values: ['default', 'wide'] },
		measure: { attribute: 'data-a11y-measure', values: ['default', 'short'] },
		align: { attribute: 'data-a11y-align', values: ['default', 'start'] },
		contrast: { attribute: 'data-a11y-contrast', values: ['default', 'high'] },
		colors: { attribute: 'data-a11y-colors', values: ['default', 'cvd'] }
	};

	/** Keep only known preferences with allowed values. */
	function sanitize(raw) {
		var clean = {};
		if (!raw || typeof raw !== 'object') return clean;
		Object.keys(PREFERENCES).forEach(function (name) {
			var value = raw[name];
			if (typeof value === 'string' && PREFERENCES[name].values.indexOf(value) > 0)
				clean[name] = value;
		});
		return clean;
	}

	/** The stored preferences, or none when storage is blocked or malformed. */
	function read() {
		try {
			var text = window.localStorage.getItem(STORAGE_KEY);
			return text ? sanitize(JSON.parse(text)) : {};
		} catch (error) {
			return {};
		}
	}

	/** Link a font's stylesheet once, the first time that font is picked. */
	function linkFont(doc, font) {
		if (!SCRIPT_SRC || doc.getElementById(FONT_LINK_ID + font)) return;
		var link = doc.createElement('link');
		link.id = FONT_LINK_ID + font;
		link.rel = 'stylesheet';
		link.href = new URL('../../../fonts/' + FONT_FOLDERS[font] + '/font.css', SCRIPT_SRC).href;
		doc.head.appendChild(link);
	}

	/** Write the root attributes of one document from a preference map. */
	function apply(preferences, root) {
		var target = root || document.documentElement;
		var clean = sanitize(preferences);
		Object.keys(PREFERENCES).forEach(function (name) {
			var attribute = PREFERENCES[name].attribute;
			if (clean[name]) target.setAttribute(attribute, clean[name]);
			else target.removeAttribute(attribute);
		});
		if (clean.font) linkFont(target.ownerDocument, clean.font);
		return clean;
	}

	/**
	 * Apply and remember a preference map. Returns whether it was stored; a
	 * refused write still applies to the current page.
	 */
	function save(preferences) {
		var clean = apply(preferences);
		try {
			if (Object.keys(clean).length)
				window.localStorage.setItem(STORAGE_KEY, JSON.stringify(clean));
			else window.localStorage.removeItem(STORAGE_KEY);
			return true;
		} catch (error) {
			return false;
		}
	}

	/** Whether animations and smooth scrolling must be skipped now. */
	function reducedMotion() {
		if (document.documentElement.getAttribute(PREFERENCES.motion.attribute) === 'reduce')
			return true;
		return Boolean(
			window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
		);
	}

	window.ErgoptiA11yPrefs = {
		STORAGE_KEY: STORAGE_KEY,
		PREFERENCES: PREFERENCES,
		read: read,
		apply: apply,
		save: save,
		reducedMotion: reducedMotion
	};

	apply(read());
	window.addEventListener('storage', function (event) {
		if (event.key === STORAGE_KEY || event.key === null) apply(read());
	});
})();
