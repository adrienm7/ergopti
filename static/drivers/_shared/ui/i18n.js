// drivers/_shared/ui/i18n.js

// ==============================================================================
// MODULE: HTML i18n loader
// DESCRIPTION:
// Minimal browser-side i18n system for the metrics webviews. Reads the active
// locale from window._i18n_locale (injected by the backend before this script
// runs, or "fr" as fallback), fetches the matching JSON file from the shared
// static/locales/ directory, then applies translations to every DOM element
// that carries a data-i18n="key" attribute. Also handles data-i18n-title and
// data-i18n-placeholder for non-text-content attributes.
//
// FEATURES & RATIONALE:
// 1. Zero dependencies — plain fetch + DOM traversal, no library needed.
// 2. Self-contained — the backend does not need to push strings; the page
//    fetches the JSON itself using a relative path resolved at runtime.
// 3. Graceful fallback — if the fetch fails or a key is missing, the existing
//    hardcoded French text is left in place so the UI is never broken.
// 4. Attribute variants:
//    - data-i18n="key"             → element.textContent
//    - data-i18n-title="key"       → element.title
//    - data-i18n-placeholder="key" → element.placeholder (inputs)
//    - data-i18n-option-prefix     → marks a <select> whose <option> values
//                                    follow the pattern "key_prefix.<value>"
// ==============================================================================

(function () {
	"use strict";

	// Resolve the path to static/locales/ relative to this script's own URL.
	// Works whether the page is served from metrics_typing/ or metrics_apps/.
	function resolve_locale_url(code) {
		// __i18n_base is optionally set by the backend before this script loads.
		if (window.__i18n_base) return window.__i18n_base + code + ".json";
		// Walk up from the current page URL to find the shared locales directory.
		// Both metrics pages are two levels deep: ui/<page>/index.html
		const base = new URL("../../locales/", document.currentScript
			? document.currentScript.src.replace(/[^/]+$/, "../../")
			: location.href);
		return new URL(code + ".json", base).href;
	}

	function apply(strings) {
		// data-i18n → textContent
		document.querySelectorAll("[data-i18n]").forEach(function (el) {
			const key = el.getAttribute("data-i18n");
			if (strings[key] !== undefined) el.textContent = strings[key];
		});
		// data-i18n-title → title attribute
		document.querySelectorAll("[data-i18n-title]").forEach(function (el) {
			const key = el.getAttribute("data-i18n-title");
			if (strings[key] !== undefined) el.title = strings[key];
		});
		// data-i18n-placeholder → placeholder attribute
		document.querySelectorAll("[data-i18n-placeholder]").forEach(function (el) {
			const key = el.getAttribute("data-i18n-placeholder");
			if (strings[key] !== undefined) el.placeholder = strings[key];
		});
		// data-i18n-option-prefix → each <option> value mapped to key_prefix.value
		document.querySelectorAll("select[data-i18n-option-prefix]").forEach(function (sel) {
			const prefix = sel.getAttribute("data-i18n-option-prefix");
			sel.querySelectorAll("option").forEach(function (opt) {
				const key = prefix + "." + opt.value;
				if (strings[key] !== undefined) opt.textContent = strings[key];
			});
		});
	}

	function load() {
		const code = window._i18n_locale || "fr";

		// Resolve URL two levels up (ui/<subdir>/index.html → ui/locales/)
		const here = location.href;
		const parts = here.split("/");
		// Remove filename and subdir, append locales/<code>.json
		const base_parts = parts.slice(0, parts.length - 2);
		const url = base_parts.join("/") + "/locales/" + code + ".json";

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
