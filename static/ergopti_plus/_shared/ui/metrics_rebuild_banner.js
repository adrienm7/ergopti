// _shared/ui/metrics_rebuild_banner.js

// ==============================================================================
// MODULE: Metrics rebuild banner
// DESCRIPTION:
// Shows a notice on top of the metrics dashboards while the numbers on screen
// cover only the most recent days of a statistics rebuild.
//
// FEATURES & RATIONALE:
// 1. Partial data is labelled. A snapshot carrying `_partial` covers the days
//    rebuilt so far, newest first; the notice names how far back it reaches and
//    disappears with the first complete snapshot.
// 2. Pure core. describe_partial turns host payloads into
//    display state without touching the DOM, so they are unit-tested in Node.
// 3. Hosts without rebuild messages (macOS, Linux) never show the banner.
// ==============================================================================

(function () {
	'use strict';

	function lookup(strings, key) {
		return (strings && strings[key]) || key;
	}

	function fill(template, values) {
		return Object.keys(values).reduce(function (text, name) {
			return text.split('{' + name + '}').join(String(values[name]));
		}, template);
	}

	function format_day(day, locale) {
		const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(day || ''));
		if (!match) return String(day || '');
		const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
		try {
			return date.toLocaleDateString(locale || undefined, { day: 'numeric', month: 'long', year: 'numeric' });
		} catch (_) {
			return String(day);
		}
	}

	/**
	 * Label a snapshot that covers only the most recent days.
	 * @param {Object} partial `_partial` of a snapshot, or undefined.
	 * @param {Object} strings Active locale strings.
	 * @param {string} locale Active locale code.
	 * @returns {string} Notice text, empty for a complete snapshot.
	 */
	function describe_partial(partial, strings, locale) {
		if (!partial || !partial.oldest) return '';
		return fill(lookup(strings, 'ui_metrics_rebuild.partial'), { date: format_day(partial.oldest, locale) });
	}

	const api = {
		describe_partial: describe_partial
	};

	if (typeof document === 'undefined' || !document.createElement) {
		window.metrics_rebuild = api;
		return;
	}

	let root = null;
	let notice = null;
	let partial_text = '';

	function ensure_root() {
		if (root) return;
		const style = document.createElement('style');
		style.textContent =
			'#metrics_rebuild_banner{position:sticky;top:0;z-index:50;padding:8px 14px;font-size:13px;' +
			'background:rgba(127,127,127,0.14);border-bottom:1px solid rgba(127,127,127,0.3);display:none}' +
			'#metrics_rebuild_banner .notice{opacity:.8}';
		document.head.appendChild(style);
		root = document.createElement('div');
		root.id = 'metrics_rebuild_banner';
		root.setAttribute('role', 'status');
		root.setAttribute('aria-live', 'polite');
		notice = document.createElement('div');
		notice.className = 'notice';
		root.appendChild(notice);
		document.body.insertBefore(root, document.body.firstChild);
	}

	function render() {
		ensure_root();
		root.style.display = partial_text ? 'block' : 'none';
		notice.textContent = partial_text;
	}

	api.mark_snapshot = function (blob) {
		partial_text = describe_partial(blob && blob._partial, window._i18n_strings, window._i18n_locale);
		render();
	};
	window.metrics_rebuild = api;
})();
