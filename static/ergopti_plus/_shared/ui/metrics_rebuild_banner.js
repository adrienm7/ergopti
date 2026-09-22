// _shared/ui/metrics_rebuild_banner.js

// ==============================================================================
// MODULE: Metrics rebuild banner
// DESCRIPTION:
// Shows the progress of a statistics rebuild on top of the metrics dashboards:
// a bar with the percentage and the estimated remaining time reported by the
// host, a notice while the numbers on screen cover only the most recent days,
// and an error state when the rebuild worker dies.
//
// FEATURES & RATIONALE:
// 1. Host-driven only. Every value comes from a real progress message: the
//    page never animates a fake timer, so a stalled worker shows a stalled bar.
// 2. Partial data is labelled. A snapshot carrying `_partial` covers the days
//    rebuilt so far, newest first; the notice names how far back it reaches and
//    disappears with the first complete snapshot.
// 3. Pure core. describe_progress / describe_partial turn host payloads into
//    display state without touching the DOM, so they are unit-tested in Node.
// 4. Hosts without rebuild messages (macOS, Linux) never show the banner.
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

	// Remaining time as h:mm:ss or m:ss, which reads the same in every locale.
	function format_eta(seconds) {
		const total = Math.max(0, Math.round(seconds));
		const hours = Math.floor(total / 3600);
		const minutes = Math.floor((total % 3600) / 60);
		const secs = String(total % 60).padStart(2, '0');
		return hours > 0
			? hours + ':' + String(minutes).padStart(2, '0') + ':' + secs
			: minutes + ':' + secs;
	}

	function format_day(day, locale) {
		const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(day || ''));
		if (!match) return String(day || '');
		const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
		try {
			return date.toLocaleDateString(locale || undefined, {
				day: 'numeric',
				month: 'long',
				year: 'numeric'
			});
		} catch (_) {
			return String(day);
		}
	}

	/**
	 * Turn a host progress payload into banner state.
	 * @param {Object} progress {state, percent, eta_s} from the host.
	 * @param {Object} strings Active locale strings.
	 * @returns {{visible: boolean, failed: boolean, percent: number|null, text: string}}
	 */
	function describe_progress(progress, strings) {
		const state = progress && progress.state;
		if (state === 'running') {
			const percent = Math.max(0, Math.min(100, Math.floor(Number(progress.percent) || 0)));
			const eta = Number(progress.eta_s);
			const remaining =
				Number.isFinite(eta) && eta >= 0
					? fill(lookup(strings, 'ui_metrics_rebuild.eta'), { eta: format_eta(eta) })
					: lookup(strings, 'ui_metrics_rebuild.eta_unknown');
			return {
				visible: true,
				failed: false,
				percent: percent,
				text: fill(lookup(strings, 'ui_metrics_rebuild.progress'), {
					percent: percent,
					remaining: remaining
				})
			};
		}
		if (state === 'finalizing')
			return {
				visible: true,
				failed: false,
				percent: 100,
				text: lookup(strings, 'ui_metrics_rebuild.finalizing')
			};
		if (state === 'failed')
			return {
				visible: true,
				failed: true,
				percent: null,
				text: lookup(strings, 'ui_metrics_rebuild.failed')
			};
		return { visible: false, failed: false, percent: null, text: '' };
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
		return fill(lookup(strings, 'ui_metrics_rebuild.partial'), {
			date: format_day(partial.oldest, locale)
		});
	}

	const api = {
		describe_progress: describe_progress,
		describe_partial: describe_partial,
		format_eta: format_eta
	};

	if (typeof document === 'undefined' || !document.createElement) {
		window.metrics_rebuild = api;
		return;
	}

	let root = null;
	let bar = null;
	let label = null;
	let notice = null;
	let progress_state = { visible: false };
	let partial_text = '';

	function ensure_root() {
		if (root) return;
		const style = document.createElement('style');
		style.textContent =
			'#metrics_rebuild_banner{position:sticky;top:0;z-index:50;padding:8px 14px;font-size:13px;' +
			'background:rgba(127,127,127,0.14);border-bottom:1px solid rgba(127,127,127,0.3);display:none}' +
			'#metrics_rebuild_banner.failed{background:rgba(220,53,69,0.16);border-color:rgba(220,53,69,0.5)}' +
			'#metrics_rebuild_banner .track{height:6px;border-radius:3px;background:rgba(127,127,127,0.25);' +
			'margin-top:6px;overflow:hidden}' +
			'#metrics_rebuild_banner .fill{height:100%;width:0;background:#3b82f6;transition:width .4s ease}' +
			'#metrics_rebuild_banner .notice{margin-top:4px;opacity:.8}';
		document.head.appendChild(style);
		root = document.createElement('div');
		root.id = 'metrics_rebuild_banner';
		root.setAttribute('role', 'status');
		root.setAttribute('aria-live', 'polite');
		label = document.createElement('div');
		const track = document.createElement('div');
		track.className = 'track';
		bar = document.createElement('div');
		bar.className = 'fill';
		track.appendChild(bar);
		notice = document.createElement('div');
		notice.className = 'notice';
		root.appendChild(label);
		root.appendChild(track);
		root.appendChild(notice);
		document.body.insertBefore(root, document.body.firstChild);
	}

	function render() {
		ensure_root();
		const visible = progress_state.visible || partial_text !== '';
		root.style.display = visible ? 'block' : 'none';
		root.classList.toggle('failed', !!progress_state.failed);
		label.textContent = progress_state.visible ? progress_state.text : '';
		label.style.display = progress_state.visible ? 'block' : 'none';
		bar.parentNode.style.display =
			progress_state.percent === null || !progress_state.visible ? 'none' : 'block';
		bar.style.width = (progress_state.percent || 0) + '%';
		notice.textContent = partial_text;
		notice.style.display = partial_text ? 'block' : 'none';
	}

	api.show_progress = function (progress) {
		progress_state = describe_progress(progress, window._i18n_strings);
		render();
	};
	api.mark_snapshot = function (blob) {
		partial_text = describe_partial(
			blob && blob._partial,
			window._i18n_strings,
			window._i18n_locale
		);
		render();
	};
	window.metrics_rebuild = api;
})();
