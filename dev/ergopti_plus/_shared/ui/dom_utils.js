// _shared/ui/dom_utils.js

// ===========================================================================
// MODULE: DOM Utilities
// DESCRIPTION:
// Shared DOM helpers used by all webview apps. Provides a single, canonical
// escapeHtml() implementation (replaces three divergent copies) and a
// domReady() helper that avoids duplicating the readyState guard pattern.
// Load before any app script that uses these functions.
// ===========================================================================

/**
 * Escapes a value for safe insertion into HTML content or attribute values.
 * Converts the five characters &, <, >, ", ' into their named entities.
 * @param {any} s - The value to escape (coerced to string).
 * @returns {string} HTML-safe string.
 */
function escapeHtml(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#039;');
}

/**
 * Runs fn after the DOM is ready. Safe to call when the document may already
 * be fully parsed (avoids the DOMContentLoaded event firing too early).
 * @param {function} fn - The callback to execute.
 */
function domReady(fn) {
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', fn);
	} else {
		fn();
	}
}
