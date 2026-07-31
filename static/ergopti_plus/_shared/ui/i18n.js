// _shared/ui/i18n.js

// ==============================================================================
// MODULE: HTML i18n loader
// DESCRIPTION:
// Minimal browser-side i18n system for all Ergopti webviews. Reads the active
// locale from window._i18n_locale (injected by ui_builder before this script
// runs, or "fr" as fallback), fetches the matching JSON file from the shared
// _shared/data/locales/ directory, then applies translations to every DOM
// element that carries a data-i18n="key" attribute. Also handles
// data-i18n-title and data-i18n-placeholder for non-text-content attributes.
//
// FEATURES & RATIONALE:
// 1. Zero dependencies — plain fetch + DOM traversal, no library needed.
// 2. Dual path — ui_builder injects window.__i18n_base (file:// URL to
//    _shared/data/locales/) and window._i18n_locale into every webview as a
//    <script> prefix, so fetch() resolves correctly even when the HTML is
//    loaded inline with no base URL.
// 3. Fallback cascade — active → en → fr, consulted lazily. A locale file that
//    fails to load, or that resolves only part of the page, no longer leaves
//    labels blank: the next locale in the chain fills exactly the gaps.
//    This is not hypothetical. The 368 data-i18n elements across the eleven
//    shared webviews all ship with an EMPTY body — the text exists only in the
//    locale JSON — so a single failed fetch rendered the entire window blank
//    with nothing but a console.warn nobody sees. The native menus degrade to
//    the raw key name, which is ugly but legible; the webviews degraded to
//    nothing at all.
//    Cost when the active locale is complete (the normal case, and today the
//    case for all 21): exactly one fetch, as before. A fallback is requested
//    only once the page has measured which keys it still needs.
// 4. Global store — strings are saved in window._i18n_strings so page scripts
//    can call _t(key) for dynamic content not reachable via DOM attributes.
// 5. Direct injection — Lua backends can skip the fetch entirely by calling
//    window.i18n_apply(strings) with a pre-loaded flat key→value map.
// 6. Attribute variants:
//    - data-i18n="key"             → element.textContent
//    - data-i18n-title="key"       → element.title
//    - data-i18n-placeholder="key" → element.placeholder (inputs)
//    - data-i18n-option-prefix     → marks a <select> whose <option> values
//                                    follow the pattern "key_prefix.<value>"
// ==============================================================================

(function () {
	'use strict';

	// Capture currentScript.src immediately — currentScript is only set while
	// the <script> tag is being synchronously parsed; it is null by the time
	// DOMContentLoaded fires and resolve_locale_url() is called from load().
	var _script_src = document.currentScript ? document.currentScript.src : null;

	// Resolve the path to _shared/data/locales/<code>.json relative to this
	// script's own URL. Works regardless of how many levels deep the calling
	// page sits — and therefore also when the webview is opened bridge-less in
	// a plain browser (Edge --app mode, or embedded on the website).
	function resolve_locale_url(code) {
		if (window.__i18n_base) return window.__i18n_base + code + '.json';
		// i18n.js lives at _shared/ui/i18n.js; the locale JSONs live at
		// _shared/data/locales/ — one dir up from ui/, then into data/locales/
		if (_script_src) {
			var base = _script_src.replace(/[^/]+$/, '../data/locales/');
			return base + code + '.json';
		}
		// Fallback: page is at _shared/ui/<app>/index.html — go up 2 levels to
		// reach _shared/, then into data/locales/
		var parts = location.href.split('/');
		var base_parts = parts.slice(0, parts.length - 3);
		return base_parts.join('/') + '/data/locales/' + code + '.json';
	}

	// Locales consulted, in order, for keys the active locale did not resolve.
	// English first because it is the canonical key set every other locale is
	// diffed against; French second because it is the project's UI language and
	// therefore the most complete human translation.
	var FALLBACK_CHAIN = ['en', 'fr'];

	// Every locale key this page needs, gathered from the same attributes apply()
	// consumes. Collected from the DOM rather than from a manifest so the two can
	// never disagree about what "complete" means for this page.
	function required_keys() {
		var keys = [];
		document.querySelectorAll('[data-i18n]').forEach(function (el) {
			keys.push(el.getAttribute('data-i18n'));
		});
		document.querySelectorAll('[data-i18n-title]').forEach(function (el) {
			keys.push(el.getAttribute('data-i18n-title'));
		});
		document.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) {
			keys.push(el.getAttribute('data-i18n-placeholder'));
		});
		document.querySelectorAll('select[data-i18n-option-prefix]').forEach(function (sel) {
			var prefix = sel.getAttribute('data-i18n-option-prefix');
			sel.querySelectorAll('option').forEach(function (opt) {
				keys.push(prefix + '.' + opt.value);
			});
		});
		return keys;
	}

	/** Keys the page needs that this string map does not resolve. */
	function unresolved_keys(strings) {
		return required_keys().filter(function (k) {
			return strings[k] === undefined;
		});
	}

	function apply(strings) {
		// Store globally so page scripts can call _t(key) for dynamic content
		window._i18n_strings = strings;

		// data-i18n → textContent
		document.querySelectorAll('[data-i18n]').forEach(function (el) {
			var key = el.getAttribute('data-i18n');
			if (strings[key] !== undefined) {
				if (el.tagName === 'TITLE') document.title = strings[key];
				else el.textContent = strings[key];
			}
		});
		// data-i18n-title → title attribute
		document.querySelectorAll('[data-i18n-title]').forEach(function (el) {
			var key = el.getAttribute('data-i18n-title');
			if (strings[key] !== undefined) el.title = strings[key];
		});
		// data-i18n-placeholder → placeholder attribute
		document.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) {
			var key = el.getAttribute('data-i18n-placeholder');
			if (strings[key] !== undefined) el.placeholder = strings[key];
		});
		// data-i18n-option-prefix → each <option> value mapped to key_prefix.value
		document.querySelectorAll('select[data-i18n-option-prefix]').forEach(function (sel) {
			var prefix = sel.getAttribute('data-i18n-option-prefix');
			sel.querySelectorAll('option').forEach(function (opt) {
				var key = prefix + '.' + opt.value;
				if (strings[key] !== undefined) opt.textContent = strings[key];
			});
		});
	}

	// Expose apply() globally so Lua backends can inject strings directly via
	// evaluateJavaScript without relying on the fetch() path.
	window.i18n_apply = apply;

	// Fetches one locale file. Resolves to its string map, or to null on any
	// failure — a 404, a parse error, a file:// restriction. The caller decides
	// what a null means; here it is simply "this link of the chain is absent",
	// which is the same thing as an empty map for cascade purposes.
	function fetch_locale(code) {
		return fetch(resolve_locale_url(code))
			.then(function (r) {
				return r.ok ? r.json() : null;
			})
			.then(function (strings) {
				return strings && typeof strings === 'object' ? strings : null;
			})
			.catch(function (err) {
				console.warn("[i18n] Could not load locale '" + code + "':", err);
				return null;
			});
	}

	function load() {
		var code = window._i18n_locale || 'fr';

		// The chain always starts with the active locale, and never repeats it:
		// with _i18n_locale === "en" the chain is en → fr, not en → en → fr.
		var chain = [code];
		FALLBACK_CHAIN.forEach(function (c) {
			if (chain.indexOf(c) === -1) chain.push(c);
		});

		// Walk the chain, stopping as soon as the page is fully resolved. Earlier
		// locales win: each step fills only the keys still missing, so a complete
		// active locale means one fetch and no fallback request at all.
		function step(index, merged) {
			if (index >= chain.length) return finish(merged);
			return fetch_locale(chain[index]).then(function (strings) {
				var combined = merged;
				if (strings) {
					combined = {};
					Object.keys(strings).forEach(function (k) {
						combined[k] = strings[k];
					});
					// The already-merged map came from an earlier, more specific
					// locale, so it overwrites what this fallback proposes.
					Object.keys(merged).forEach(function (k) {
						combined[k] = merged[k];
					});
				}
				if (unresolved_keys(combined).length === 0) return finish(combined);
				return step(index + 1, combined);
			});
		}

		function finish(strings) {
			apply(strings);
			var missing = unresolved_keys(strings);
			if (missing.length > 0) {
				// Named, not counted: a key no locale in the chain resolves is a
				// packaging bug, and the name is what makes it fixable.
				console.warn(
					'[i18n] ' +
						missing.length +
						' key(s) unresolved after ' +
						chain.join(' → ') +
						': ' +
						missing.slice(0, 10).join(', ') +
						(missing.length > 10 ? ', …' : '')
				);
			}
		}

		step(0, {});
	}

	// Run after DOM is ready
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', load);
	} else {
		load();
	}
})();
