// drivers/_shared/ui/i18n.js

// ==============================================================================
// MODULE: HTML i18n loader
// DESCRIPTION:
// Minimal browser-side i18n system for all Ergopti webviews. Reads the active
// locale from window._i18n_locale (injected by ui_builder before this script
// runs, or "fr" as fallback), fetches the matching JSON file from the shared
// static/locales/ directory, then applies translations to every DOM element
// that carries a data-i18n="key" attribute. Also handles data-i18n-title and
// data-i18n-placeholder for non-text-content attributes.
//
// FEATURES & RATIONALE:
// 1. Zero dependencies — plain fetch + DOM traversal, no library needed.
// 2. Dual path — ui_builder injects window.__i18n_base (file:// URL to
//    static/locales/) and window._i18n_locale into every webview as a
//    <script> prefix, so fetch() resolves correctly even when the HTML is
//    loaded inline with no base URL.
// 3. Graceful fallback — if the fetch fails or a key is missing, elements
//    remain empty (textContent was cleared when data-i18n was added).
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
	"use strict";

	// Capture currentScript.src immediately — currentScript is only set while
	// the <script> tag is being synchronously parsed; it is null by the time
	// DOMContentLoaded fires and resolve_locale_url() is called from load().
	var _script_src = document.currentScript ? document.currentScript.src : null;

	// Resolve the path to static/locales/<code>.json relative to this script's
	// own URL. Works regardless of how many levels deep the calling page sits.
	function resolve_locale_url(code) {
		if (window.__i18n_base) return window.__i18n_base + code + ".json";
		// i18n.js lives at static/ergopti_plus/shared/ui/i18n.js
		// static/locales/ is three dirs above: ui/ → shared/ → drivers/ → static/locales/
		if (_script_src) {
			var base = _script_src.replace(/[^/]+$/, "../../../locales/");
			return base + code + ".json";
		}
		// Fallback: page is at metrics_<x>/index.html — go up 4 levels to reach static/
		// file:///…/static/ergopti_plus/shared/ui/metrics_x/index.html → static/locales/
		var parts = location.href.split("/");
		var base_parts = parts.slice(0, parts.length - 5);
		return base_parts.join("/") + "/locales/" + code + ".json";
	}

	function apply(strings) {
		// Store globally so page scripts can call _t(key) for dynamic content
		window._i18n_strings = strings;

		// data-i18n → textContent
		document.querySelectorAll("[data-i18n]").forEach(function (el) {
			var key = el.getAttribute("data-i18n");
			if (strings[key] !== undefined) {
				if (el.tagName === "TITLE") document.title = strings[key];
				else el.textContent = strings[key];
			}
		});
		// data-i18n-title → title attribute
		document.querySelectorAll("[data-i18n-title]").forEach(function (el) {
			var key = el.getAttribute("data-i18n-title");
			if (strings[key] !== undefined) el.title = strings[key];
		});
		// data-i18n-placeholder → placeholder attribute
		document.querySelectorAll("[data-i18n-placeholder]").forEach(function (el) {
			var key = el.getAttribute("data-i18n-placeholder");
			if (strings[key] !== undefined) el.placeholder = strings[key];
		});
		// data-i18n-option-prefix → each <option> value mapped to key_prefix.value
		document.querySelectorAll("select[data-i18n-option-prefix]").forEach(function (sel) {
			var prefix = sel.getAttribute("data-i18n-option-prefix");
			sel.querySelectorAll("option").forEach(function (opt) {
				var key = prefix + "." + opt.value;
				if (strings[key] !== undefined) opt.textContent = strings[key];
			});
		});
	}

	// Expose apply() globally so Lua backends can inject strings directly via
	// evaluateJavaScript without relying on the fetch() path.
	window.i18n_apply = apply;

	function load() {
		var code = window._i18n_locale || "fr";
		var url = resolve_locale_url(code);

		fetch(url)
			.then(function (r) { return r.ok ? r.json() : null; })
			.then(function (strings) {
				if (strings) apply(strings);
			})
			.catch(function (err) {
				console.warn("[i18n] Could not load locale '" + code + "':", err);
			});
	}

	// Run after DOM is ready
	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", load);
	} else {
		load();
	}
})();
