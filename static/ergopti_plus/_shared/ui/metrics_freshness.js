// _shared/ui/metrics_freshness.js

// ==============================================================================
// MODULE: Metrics freshness banner
// DESCRIPTION:
// Tells the reader how current the numbers on a metrics dashboard are. A
// snapshot painted from the host's cache names the moment it was computed and
// says that an update is running; a first open without a snapshot shows a
// loading notice; a failed update keeps the snapshot's date on screen. Fresh
// data hides the banner.
//
// FEATURES & RATIONALE:
// 1. Host-driven only. The state comes from the host with each publication;
//    the page never guesses whether its data is current.
// 2. Ordered. Each state carries the host's publication revision and an older
//    one never replaces a newer one, so a delayed "stale" notice cannot cover
//    fresh data.
// 3. Pure core. describe_freshness turns a state into display text without
//    touching the DOM, so it is unit-tested in Node.
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

	/**
	 * Formats the moment a snapshot was computed in the active locale.
	 * @param {number} ms Epoch milliseconds.
	 * @param {string} locale Active locale code.
	 * @returns {string} Date and time, e.g. "September 29, 2026 at 14:05".
	 */
	function format_moment(ms, locale) {
		const date = new Date(ms);
		try {
			return date.toLocaleString(locale || undefined, {
				day: 'numeric',
				month: 'long',
				year: 'numeric',
				hour: '2-digit',
				minute: '2-digit'
			});
		} catch (_) {
			return date.toISOString();
		}
	}

	/**
	 * Turns a host freshness state into banner state.
	 * @param {Object} freshness {state, generated_at} from the host.
	 * @param {Object} strings Active locale strings.
	 * @param {string} locale Active locale code.
	 * @returns {{visible: boolean, failed: boolean, text: string}}
	 */
	function describe_freshness(freshness, strings, locale) {
		const state = freshness && freshness.state;
		const at = Number(freshness && freshness.generated_at);
		const dated = Number.isFinite(at) && at > 0;
		if (state === 'stale' && dated) {
			return {
				visible: true,
				failed: false,
				text: fill(lookup(strings, 'ui_metrics_freshness.stale'), {
					date: format_moment(at, locale)
				})
			};
		}
		if (state === 'loading') {
			return {
				visible: true,
				failed: false,
				text: lookup(strings, 'ui_metrics_freshness.loading')
			};
		}
		if (state === 'failed') {
			return {
				visible: true,
				failed: true,
				text: dated
					? fill(lookup(strings, 'ui_metrics_freshness.failed'), {
							date: format_moment(at, locale)
						})
					: lookup(strings, 'ui_metrics_freshness.failed_empty')
			};
		}
		return { visible: false, failed: false, text: '' };
	}

	const api = {
		describe_freshness: describe_freshness,
		format_moment: format_moment
	};

	if (typeof document === 'undefined' || !document.createElement) {
		window.metrics_freshness = api;
		return;
	}

	let root = null;
	let applied_revision = -1;

	function ensure_root() {
		if (root) return;
		const style = document.createElement('style');
		style.textContent =
			'#metrics_freshness_banner{position:sticky;top:0;z-index:49;padding:8px 14px;font-size:13px;' +
			'background:rgba(59,130,246,0.12);border-bottom:1px solid rgba(59,130,246,0.35);display:none}' +
			'#metrics_freshness_banner.failed{background:rgba(220,53,69,0.16);border-color:rgba(220,53,69,0.5)}';
		document.head.appendChild(style);
		root = document.createElement('div');
		root.id = 'metrics_freshness_banner';
		root.setAttribute('role', 'status');
		root.setAttribute('aria-live', 'polite');
		document.body.insertBefore(root, document.body.firstChild);
	}

	/**
	 * Applies a host freshness state unless a newer one is already shown.
	 * @param {Object} freshness {state, generated_at}.
	 * @param {number} revision Host publication revision.
	 * @returns {boolean} Whether the state was applied.
	 */
	api.show = function (freshness, revision) {
		if (!Number.isSafeInteger(revision) || revision < applied_revision) return false;
		applied_revision = revision;
		const view = describe_freshness(freshness, window._i18n_strings, window._i18n_locale);
		ensure_root();
		root.style.display = view.visible ? 'block' : 'none';
		root.classList.toggle('failed', view.failed);
		root.textContent = view.text;
		return true;
	};
	window.metrics_freshness = api;
})();
