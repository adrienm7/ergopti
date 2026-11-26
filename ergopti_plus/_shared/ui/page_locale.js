// _shared/ui/page_locale.js

/**
 * ==============================================================================
 * MODULE: Page Locale
 * DESCRIPTION:
 * The one owner of an app window's root language and writing direction. Every
 * shared page loads it in its head, before its other scripts: with the host's
 * seeded window._i18n_locale it sets <html lang> (WCAG 3.1.1) and <html dir>,
 * so an Arabic or Hebrew window lays out right to left (PCK-22) before the body
 * draws. A page that changes language live (onboarding) or learns it later
 * (i18n.js, physical shortcuts) calls window.setPageLocale(code).
 * ==============================================================================
 */

(function () {
	'use strict';

	// The shipped locales written right to left. tools/test/test-page-direction.cjs
	// derives the same set from the native names in locale_names.json.
	var RIGHT_TO_LEFT = ['ar', 'he'];

	/**
	 * Sets the root language and writing direction of the page.
	 * @param {string} code A locale code ("ar", "fr", "pt-BR").
	 */
	function setPageLocale(code) {
		if (typeof code !== 'string' || code === '') {
			throw new TypeError('page_locale: a locale code is required');
		}
		var root = document.documentElement;
		root.lang = code;
		root.dir = RIGHT_TO_LEFT.indexOf(code.toLowerCase().split('-')[0]) === -1 ? 'ltr' : 'rtl';
	}

	window.setPageLocale = setPageLocale;
	if (typeof window._i18n_locale === 'string' && window._i18n_locale !== '') {
		setPageLocale(window._i18n_locale);
	}
})();
