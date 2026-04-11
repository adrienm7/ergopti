// ui/metrics_typing/script.js

/**
 * ==============================================================================
 * MODULE: Metrics Dashboard Logic
 * DESCRIPTION:
 * Manages data processing, filtering, and rendering for the typing metrics UI.
 *
 * FEATURES & RATIONALE:
 * 1. Zero Lag Architecture: Deep in-memory caching for instant UI updates.
 * 2. Visual Modules: Dynamic Y-axis precision and trackpad pinch-to-zoom.
 * 3. Dynamic Coloring: CSS Variable inheritance directly into Chart.js elements.
 * 4. Real-Time Sync: Merges unencrypted live buffer with historical db streams.
 * ==============================================================================
 */

window.metrics_manifest = window.metrics_manifest || {};
window.app_icons = window.app_icons || {};
window._lua_request = null;

const app_state = {
	historical_cache: null,
	today_live_data: null,
	data: { c: {}, bg: {}, tg: {}, qg: {}, pg: {}, hx: {}, hp: {}, w: {}, sc: {} },
	time_series: {},
	hourly_series: {},
	available_apps: [],
	selected_apps: new Set(),
	did_apply_initial_reset: false,
	current_tab: 'c',
	sort_col: 'count',
	sort_asc: false,
	search_query: '',
	rendered_list: [],
	loading_data: false,
	manifest_dates_sorted: []
};

let delegation_chart_instance = null;
let wpm_chart_instance = null;
let precision_chart_instance = null;
let hs_sparkline_instance = null;
let llm_sparkline_instance = null;
let auto_refresh_bound = false;

const info_svg =
	'<svg class="info-icon" xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg>';

// =====================================
// =====================================
// ======= 1/ Formatting Helpers =======
// =====================================
// =====================================

/**
 * Escapes characters to prevent HTML injections.
 * @param {string} str - The raw string.
 * @returns {string} The escaped safe string.
 */
function escape_html(str) {
	if (!str) return '';
	return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * Formats a number with standard non-breaking spaces.
 * Also abbreviates millions (M) and billions (Md).
 * @param {number} num - The number to format.
 * @returns {string} The localized string representation.
 */
function format_number(num) {
	if (num === null || num === undefined || isNaN(num)) return '0';

	let isNegative = num < 0;
	let absNum = Math.abs(num);

	if (absNum >= 1000000000) {
		return (
			(isNegative ? '-' : '') +
			(absNum / 1000000000).toFixed(1).replace('.0', '').replace('.', ',') +
			'\u00A0Md'
		);
	}
	if (absNum >= 1000000) {
		return (
			(isNegative ? '-' : '') +
			(absNum / 1000000).toFixed(1).replace('.0', '').replace('.', ',') +
			'\u00A0M'
		);
	}

	let str = Number(num).toString();
	let parts = str.split('.');
	parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, '\u00A0');
	return parts.join(',');
}

/**
 * Formats French dates for Chart.js tooltips.
 * @param {object} context - Chart context containing the date.
 * @returns {string} The formatted date string.
 */
const tooltipTitleCallback = (context) => {
	const days = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];
	const d = new Date(context[0].parsed.x);
	const dayName = days[d.getDay()];
	const dd = String(d.getDate()).padStart(2, '0');
	const mm = String(d.getMonth() + 1).padStart(2, '0');
	const yyyy = d.getFullYear();
	return `${dayName} ${dd}/${mm}/${yyyy}`;
};

/**
 * Formats special characters safely for UI display.
 * @param {string} str - The raw keystroke sequence.
 * @returns {string} HTML string with visual chips.
 */
function format_display_key(str) {
	let escaped = escape_html(str);
	escaped = escaped.replace(/ /g, '[[SPACE]]');
	escaped = escaped.replace(/\u00A0/g, '[[NBSP]]');
	escaped = escaped.replace(/\u202F/g, '[[NNBSP]]');
	escaped = escaped.replace(/\n/g, '[[NEWLINE]]');
	escaped = escaped.replace(/\[BS\]/gi, '[[BACKSPACE]]');
	escaped = escaped.replace(/\[\[SPACE\]\]/g, '<span class="space-reg">␣</span>');
	escaped = escaped.replace(/\[\[NBSP\]\]/g, '<span class="space-nbsp">NBSP</span>');
	escaped = escaped.replace(/\[\[NNBSP\]\]/g, '<span class="space-nnbsp">NNBSP</span>');
	escaped = escaped.replace(/\[\[NEWLINE\]\]/g, '<span style="color:var(--text-muted);">↵</span>');
	escaped = escaped.replace(
		/\[\[BACKSPACE\]\]/g,
		'<span style="color:#ff3b30; font-weight:bold;">⌫</span>'
	);
	return escaped;
}

/**
 * Formats shortcuts with visual chips for modifiers and primary key.
 * @param {string} str - The raw shortcut string.
 * @returns {string} The styled HTML string.
 */
function format_shortcut_key(str) {
	if (!str) return '';

	const modifierSet = new Set(['cmd', 'ctrl', 'alt', 'shift', 'fn']);
	const prettyMap = {
		cmd: '⌘',
		ctrl: '⌃',
		alt: '⌥',
		shift: '⇧',
		fn: 'fn',
		left: '←',
		right: '→',
		up: '↑',
		down: '↓',
		enter: '⏎',
		tab: '⇥',
		backspace: '⌫',
		escape: '⎋',
		space: '␣',
		delete: '⌦',
		home: '⇱',
		end: '⇲',
		pageup: '⇞',
		pagedown: '⇟'
	};
	const parts = String(str)
		.split('+')
		.map((part) => part.trim())
		.filter((part) => part.length > 0);

	if (parts.length === 0) return '';

	return parts
		.map((part, index) => {
			const lowerPart = part.toLowerCase();
			const cls = modifierSet.has(lowerPart)
				? 'shortcut-chip shortcut-mod'
				: 'shortcut-chip shortcut-key';
			let label = prettyMap[lowerPart] || part;
			if (!prettyMap[lowerPart] && part.length === 1) label = part.toUpperCase();
			const plus = index < parts.length - 1 ? '<span class="shortcut-plus">+</span>' : '';
			return `<span class="${cls}">${escape_html(label)}</span>${plus}`;
		})
		.join('');
}

/**
 * Keeps the dashboard in sync without aggressive polling.
 * Refreshes only when the window or tab becomes active again.
 */
function ensure_live_refresh() {
	if (auto_refresh_bound) return;
	auto_refresh_bound = true;

	const refreshIfIdle = () => {
		if (app_state.loading_data) return;
		request_range_data(false);
	};

	document.addEventListener('visibilitychange', () => {
		if (!document.hidden) refreshIfIdle();
	});

	window.addEventListener('focus', refreshIfIdle);
}

/**
 * Procedurally generates an app color using string hashing.
 * @param {string} appName - The target app name.
 * @returns {string} A CSS hsl color string.
 */
function get_app_color(appName) {
	let hash = 0;
	for (let i = 0; i < appName.length; i++) hash = appName.charCodeAt(i) + ((hash << 5) - hash);
	return `hsl(${Math.abs(hash) % 360}, 65%, 55%)`;
}

/**
 * Generates an SVG trend arrow based on linear regression.
 * @param {Array} valid_points - An array of numerical Y values.
 * @returns {string} HTML string containing the SVG element.
 */
function get_trend_svg(valid_points) {
	if (!valid_points || valid_points.length < 2) {
		return '<svg class="trend-svg stable" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="5" y1="12" x2="19" y2="12"></line><polyline points="12 5 19 12 12 19"></polyline></svg>';
	}

	const n = valid_points.length;
	let sum_x = 0,
		sum_y = 0,
		sum_xy = 0,
		sum_xx = 0;

	for (let i = 0; i < n; i++) {
		sum_x += i;
		sum_y += valid_points[i];
		sum_xy += i * valid_points[i];
		sum_xx += i * i;
	}

	const slope = (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x);
	const threshold = Math.max(...valid_points) * 0.01;

	if (slope > threshold) {
		return '<svg class="trend-svg up" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="7" y1="17" x2="17" y2="7"></line><polyline points="7 7 17 7 17 17"></polyline></svg>';
	}

	if (slope < -threshold) {
		return '<svg class="trend-svg down" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="7" y1="7" x2="17" y2="17"></line><polyline points="17 7 17 17 7 17"></polyline></svg>';
	}

	return '<svg class="trend-svg stable" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="5" y1="12" x2="19" y2="12"></line><polyline points="12 5 19 12 12 19"></polyline></svg>';
}

/**
 * Returns the default range from the first logged day to today.
 * @returns {object} Object with start and end date strings.
 */
function get_default_date_range() {
	const sorted_dates =
		app_state.manifest_dates_sorted.length > 0
			? app_state.manifest_dates_sorted
			: Object.keys(window.metrics_manifest).sort();
	const today = new Date().toISOString().split('T')[0];
	const first_logged_date = sorted_dates.length > 0 ? sorted_dates[0] : today;
	return { start: first_logged_date, end: today };
}

/**
 * Applies default date inputs safely to the DOM.
 */
function apply_default_date_range() {
	const start_input = document.getElementById('date_start');
	const end_input = document.getElementById('date_end');
	if (!start_input || !end_input) return;
	const range = get_default_date_range();
	start_input.value = range.start;
	end_input.value = range.end;
}

// =====================================
// =====================================
// ======= 2/ Data Pipeline =======
// =====================================
// =====================================

/**
 * Merges raw dictionary entries applying current UI filters.
 * @param {object} target - The destination dictionary.
 * @param {object} source - The raw source data.
 * @param {boolean} case_sensitive - Whether to match case.
 * @param {boolean} show_spaces - Whether to include space characters.
 * @param {boolean} show_hs - Include hotstrings.
 * @param {boolean} show_llm - Include LLM completions.
 * @param {boolean} show_manual - Include human manual typing.
 * @param {string} tabName - Identifier of the active tab.
 */
function merge_dict(
	target,
	source,
	case_sensitive,
	show_spaces,
	show_hs,
	show_llm,
	show_manual,
	tabName
) {
	if (!source || typeof source !== 'object') return;
	const isShortcutsTab = tabName === 'sc';

	Object.keys(source).forEach((k) => {
		let display_k = case_sensitive ? k : k.toLowerCase();

		if (
			!show_spaces &&
			(display_k.includes(' ') || display_k.includes('\u00A0') || display_k.includes('\u202F'))
		) {
			return;
		}

		let item = source[k];
		let total_count = item.c || 0;
		let hs_count = item.hs || 0;
		let llm_count = item.llm || 0;
		let other_synth_count = item.o || 0;

		let manual_count = Math.max(0, total_count - hs_count - llm_count - other_synth_count);
		let filtered_hs_count = hs_count;
		let filtered_llm_count = llm_count;
		let real_count = total_count;

		if (!isShortcutsTab) {
			filtered_hs_count = show_hs ? hs_count : 0;
			filtered_llm_count = show_llm ? llm_count : 0;
			real_count =
				(show_manual ? manual_count : 0) +
				filtered_hs_count +
				filtered_llm_count +
				other_synth_count;
		}
		if (real_count <= 0) return;

		if (!target[display_k]) {
			target[display_k] = {
				count: 0,
				time: 0,
				errors: 0,
				synth_hs: 0,
				synth_llm: 0,
				synth_other: 0
			};
		}

		target[display_k].count += real_count;
		target[display_k].time += item.t || 0;
		target[display_k].errors += item.e || 0;
		target[display_k].synth_hs += filtered_hs_count;
		target[display_k].synth_llm += filtered_llm_count;
		target[display_k].synth_other += item.o || 0;
	});
}

/**
 * Main boot function processing the fast manifest and bridging to Lua.
 */
function process_manifest() {
	if (Object.keys(window.metrics_manifest).length > 0) {
		app_state.manifest_dates_sorted = Object.keys(window.metrics_manifest).sort();
		const appSet = new Set();
		app_state.manifest_dates_sorted.forEach((date) => {
			Object.keys(window.metrics_manifest[date]).forEach((appName) => {
				if (appName !== 'Unknown') appSet.add(appName);
			});
		});

		const previousApps = new Set(app_state.available_apps);
		const hadAllSelected =
			app_state.available_apps.length > 0 &&
			app_state.selected_apps.size === app_state.available_apps.length;

		app_state.available_apps = Array.from(appSet).sort((a, b) => a.localeCompare(b));

		if (app_state.selected_apps.size === 0 || hadAllSelected) {
			app_state.selected_apps.clear();
			app_state.available_apps.forEach((app) => app_state.selected_apps.add(app));
		} else {
			// Keep existing custom selection, and prune apps that disappeared
			const nextSelection = new Set();
			app_state.available_apps.forEach((app) => {
				if (app_state.selected_apps.has(app) || !previousApps.has(app)) {
					nextSelection.add(app);
				}
			});
			app_state.selected_apps = nextSelection;
		}

		const start_input = document.getElementById('date_start');
		const end_input = document.getElementById('date_end');
		if (start_input && end_input && (!start_input.value || !end_input.value)) {
			apply_default_date_range();
		}
	}

	if (!app_state.did_apply_initial_reset) {
		app_state.did_apply_initial_reset = true;
		ensure_live_refresh();
		reset_filters();
		request_range_data();
		return;
	}

	update_app_btn_text();
	compute_manifest_metrics();
	request_range_data();
	ensure_live_refresh();
}

/**
 * Computes high-level global metrics for the top cards.
 */
function compute_manifest_metrics() {
	app_state.time_series = {};
	app_state.hourly_series = {};

	for (let i = 0; i < 24; i++) {
		app_state.hourly_series[i.toString().padStart(2, '0')] = { c: 0, e: 0, es: 0 };
	}

	let global_hs_triggers = 0;
	let global_llm_triggers = 0;
	let global_hs_suggested = 0;
	let global_llm_suggested = 0;

	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	const show_hs = document.getElementById('btn_show_hs').classList.contains('active');
	const show_llm = document.getElementById('btn_show_llm').classList.contains('active');
	const show_manual = document.getElementById('btn_show_manual').classList.contains('active');

	const manifest_dates =
		app_state.manifest_dates_sorted.length > 0
			? app_state.manifest_dates_sorted
			: Object.keys(window.metrics_manifest).sort();

	manifest_dates.forEach((dateStr) => {
		if (start_val && dateStr < start_val) return;
		if (end_val && dateStr > end_val) return;

		Object.keys(window.metrics_manifest[dateStr]).forEach((appName) => {
			if (appName !== 'Unknown' && !app_state.selected_apps.has(appName)) return;

			const app = window.metrics_manifest[dateStr][appName];
			if (!app_state.time_series[dateStr]) {
				app_state.time_series[dateStr] = {
					chars: 0,
					time_ms: 0,
					hs_chars: 0,
					llm_chars: 0,
					daily_chars: 0,
					daily_manual_errors: 0
				};
			}

			const total_chars = app.chars || 0;
			const hs_chars_raw = app.hs_chars || 0;
			const llm_chars_raw = app.llm_chars || 0;
			const manual_chars_raw = Math.max(0, total_chars - hs_chars_raw - llm_chars_raw);

			const filtered_hs_chars = show_hs ? hs_chars_raw : 0;
			const filtered_llm_chars = show_llm ? llm_chars_raw : 0;
			const filtered_manual_chars = show_manual ? manual_chars_raw : 0;
			const effective_chars = Math.max(
				0,
				filtered_manual_chars + filtered_hs_chars + filtered_llm_chars
			);

			if (show_hs) {
				global_hs_triggers += app.hs_triggers || 0;
				global_hs_suggested += Math.max(app.hs_suggested || 0, app.hs_triggers || 0);
			}
			if (show_llm) {
				global_llm_triggers += app.llm_triggers || 0;
				global_llm_suggested += Math.max(app.llm_suggested || 0, app.llm_triggers || 0);
			}

			app_state.time_series[dateStr].chars += effective_chars;
			app_state.time_series[dateStr].time_ms += app.time || 0;
			app_state.time_series[dateStr].hs_chars += filtered_hs_chars;
			app_state.time_series[dateStr].llm_chars += filtered_llm_chars;

			if (app.hourly) {
				Object.keys(app.hourly).forEach((hour) => {
					if (app_state.hourly_series[hour]) {
						const hourData = app.hourly[hour] || {};
						const manualErrors = typeof hourData.em === 'number' ? hourData.em : hourData.e || 0;
						app_state.hourly_series[hour].c += hourData.c || 0;
						app_state.hourly_series[hour].e += manualErrors;
						app_state.hourly_series[hour].es += hourData.es || 0;
					}
					// Accumulate daily accuracy stats
					const hourData = app.hourly[hour] || {};
					const manualErrors = typeof hourData.em === 'number' ? hourData.em : hourData.e || 0;
					app_state.time_series[dateStr].daily_chars += hourData.c || 0;
					app_state.time_series[dateStr].daily_manual_errors += manualErrors;
				});
			}
		});
	});

	const grid = document.getElementById('main_stats_grid');
	const hsCard = document.getElementById('hs_card');
	const llmCard = document.getElementById('llm_card');

	// Keep cards visible to preserve stable layout; filters affect values, not visibility
	hsCard.style.display = 'flex';
	llmCard.style.display = 'flex';
	grid.style.gridTemplateColumns = '2fr 2fr 1fr';

	const sorted_keys = Object.keys(app_state.time_series).sort();
	const hs_points = [],
		llm_points = [],
		wpm_points = [];
	let hs_chars_total = 0,
		llm_chars_total = 0;
	let global_chars_total = 0,
		global_time_total = 0;

	sorted_keys.forEach((k) => {
		const d = app_state.time_series[k];
		hs_chars_total += d.hs_chars;
		llm_chars_total += d.llm_chars;
		global_chars_total += d.chars || 0;
		global_time_total += d.time_ms || 0;

		if (d.chars > 0) {
			hs_points.push({ x: new Date(k + 'T12:00:00'), y: (d.hs_chars / d.chars) * 100 });
			llm_points.push({ x: new Date(k + 'T12:00:00'), y: (d.llm_chars / d.chars) * 100 });
		}

		let day_wpm = d.chars >= 10 && d.time_ms > 0 ? d.chars / 5 / (d.time_ms / 60000) : 0;
		if (!isNaN(day_wpm)) {
			wpm_points.push({ x: new Date(k + 'T12:00:00'), y: day_wpm });
		}
	});

	document.getElementById('hs_loading').style.display = 'none';
	document.getElementById('hs_details').style.display = 'flex';
	document.getElementById('hs_val').innerHTML =
		`${format_number(global_hs_triggers)} <span class="stat-unit">activations</span>`;
	document.getElementById('hs_net_val').innerText = format_number(hs_chars_total);

	let hs_accepted_pct =
		global_hs_suggested > 0 ? (global_hs_triggers / global_hs_suggested) * 100 : 0;
	if (hs_accepted_pct > 100) hs_accepted_pct = 100;
	document.getElementById('hs_acc_pct').innerText = `${format_number(hs_accepted_pct.toFixed(1))}%`;
	document.getElementById('hs_acc_raw').innerText =
		`(${format_number(global_hs_triggers)}/${format_number(global_hs_suggested)})`;
	document.getElementById('hs_trend').innerHTML = get_trend_svg(
		hs_points.map((p) => p.y).filter((y) => y > 0)
	);

	document.getElementById('llm_loading').style.display = 'none';
	document.getElementById('llm_details').style.display = 'flex';
	document.getElementById('llm_val').innerHTML =
		`${format_number(global_llm_triggers)} <span class="stat-unit">activations</span>`;
	document.getElementById('llm_net_val').innerText = format_number(llm_chars_total);

	let llm_accepted_pct =
		global_llm_suggested > 0 ? (global_llm_triggers / global_llm_suggested) * 100 : 0;
	if (llm_accepted_pct > 100) llm_accepted_pct = 100;
	document.getElementById('llm_acc_pct').innerText =
		`${format_number(llm_accepted_pct.toFixed(1))}%`;
	document.getElementById('llm_acc_raw').innerText =
		`(${format_number(global_llm_triggers)}/${format_number(global_llm_suggested)})`;
	document.getElementById('llm_trend').innerHTML = get_trend_svg(
		llm_points.map((p) => p.y).filter((y) => y > 0)
	);

	document.getElementById('wpm_trend').innerHTML = get_trend_svg(
		wpm_points.map((p) => p.y).filter((y) => y > 0)
	);

	const manifest_cpm = global_time_total > 0 ? global_chars_total / (global_time_total / 60000) : 0;
	const manifest_wpm = manifest_cpm / 5;
	const wpm_val_elem = document.getElementById('wpm_val');
	if (wpm_val_elem) {
		wpm_val_elem.innerHTML = `
			<div style="display:flex; flex-direction:column; justify-content:center;">
				<div style="display:flex; align-items:center; gap:6px;">
					<span>${format_number(manifest_wpm.toFixed(1))} <span class="stat-unit">MPM</span></span>
					<span class="tooltip stat-inline-tooltip">${info_svg}<span class="tooltiptext">MPM : Mots par minute, avec la convention standard 1 mot = 5 touches</span></span>
				</div>
				<div style="display:flex; align-items:center; gap:6px; font-size: 0.65em; margin-top: 5px;">
					<span>${format_number(manifest_cpm.toFixed(0))} <span class="stat-unit">CPM</span></span>
					<span class="tooltip stat-inline-tooltip">${info_svg}<span class="tooltiptext">CPM : Caractères par minute, total de touches tapées par minute</span></span>
				</div>
			</div>
		`;
	}

	const global_details_elem = document.getElementById('global_details');
	if (global_details_elem) {
		global_details_elem.innerHTML = `<div style="margin-top:5px;"><strong style="color:var(--kpi-wpm-color); font-size: 1.1em;">${format_number(global_chars_total)}</strong> <span class="stat-unit" style="font-size: 0.9em;">touches tapées</span></div>`;
	}

	render_charts();
}

/**
 * Deep merge of historical and live unencrypted dictionaries without disk IO.
 */
function apply_local_filters() {
	if (!app_state.historical_cache && !app_state.today_live_data) return;

	app_state.data = { c: {}, bg: {}, tg: {}, qg: {}, pg: {}, hx: {}, hp: {}, w: {}, sc: {} };

	const show_hs = document.getElementById('btn_show_hs').classList.contains('active');
	const show_llm = document.getElementById('btn_show_llm').classList.contains('active');
	const show_spaces = document.getElementById('btn_show_spaces').classList.contains('active');
	const show_manual = document.getElementById('btn_show_manual').classList.contains('active');
	const case_sensitive = document.getElementById('btn_case_sensitive').classList.contains('active');

	const merge_source = (source_cache) => {
		if (!source_cache) return;
		Object.keys(app_state.data).forEach((tab) => {
			merge_dict(
				app_state.data[tab],
				source_cache[tab],
				case_sensitive,
				show_spaces,
				show_hs,
				show_llm,
				show_manual,
				tab
			);
		});
	};

	merge_source(app_state.historical_cache);

	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	const today_str = new Date().toISOString().split('T')[0];

	let include_today = true;
	if (start_val && today_str < start_val) include_today = false;
	if (end_val && today_str > end_val) include_today = false;

	if (include_today && app_state.today_live_data) {
		Object.keys(app_state.today_live_data).forEach((appName) => {
			if (appName !== 'Unknown' && !app_state.selected_apps.has(appName)) return;
			const appData = app_state.today_live_data[appName];
			Object.keys(app_state.data).forEach((tab) => {
				merge_dict(
					app_state.data[tab],
					appData[tab],
					case_sensitive,
					show_spaces,
					show_hs,
					show_llm,
					show_manual,
					tab
				);
			});
		});
	}

	render_current_tab();
}

/**
 * Queries Hammerspoon Lua thread for range data.
 * @param {boolean} show_loader - Display the loading spinner in UI.
 */
function request_range_data(show_loader = true) {
	if (app_state.loading_data) return;
	app_state.loading_data = true;

	const req = {
		start_date: document.getElementById('date_start').value,
		end_date: document.getElementById('date_end').value,
		apps: Array.from(app_state.selected_apps)
	};

	if (show_loader) {
		document.getElementById('metrics_table_body').innerHTML =
			'<tr><td colspan="6" style="text-align:center; padding: 30px;"><div class="loader-spinner"></div> Récupération et déchiffrement depuis la DB...</td></tr>';
	}

	setTimeout(() => {
		window._lua_request = JSON.stringify(req);
	}, 50);
}

/**
 * Native callback invoked by the Lua thread bridging the raw sqlite cache.
 * @param {object} payload - Combined object containing historical and today.
 */
function receive_range_data(payload) {
	app_state.loading_data = false;
	if (!payload) return;

	app_state.historical_cache = payload.historical;
	app_state.today_live_data = payload.today;
	apply_local_filters();
}

/**
 * Native callback invoked immediately when you type for instant rendering.
 * @param {object} today_idx - The updated today dictionary from memory.
 */
function receive_live_update(today_idx) {
	app_state.today_live_data = today_idx;
	apply_local_filters();
}

/**
 * Filter Toggles logic.
 * @param {string} btn_id - The ID of the clicked button.
 */
function toggle_filter(btn_id) {
	document.getElementById(btn_id).classList.toggle('active');
	compute_manifest_metrics();
	apply_local_filters();
}

function apply_date_app_filters() {
	compute_manifest_metrics();
	request_range_data();
}

function reset_filters() {
	apply_default_date_range();

	['btn_show_manual', 'btn_show_hs', 'btn_show_llm', 'btn_show_spaces'].forEach((id) => {
		document.getElementById(id).classList.add('active');
	});

	document.getElementById('btn_case_sensitive').classList.remove('active');

	app_state.available_apps.forEach((app) => app_state.selected_apps.add(app));
	update_app_btn_text();
	apply_date_app_filters();
}

// =====================================
// =====================================
// ======= 3/ Modal Management =======
// =====================================
// =====================================

function update_app_btn_text() {
	const btn = document.getElementById('app_filter_btn');
	if (!btn) return;

	const sel = app_state.selected_apps.size;
	const tot = app_state.available_apps.length;

	if (sel === tot) {
		btn.innerText = 'Apps (Toutes)';
		btn.classList.add('active');
	} else {
		btn.innerText = sel === 0 ? 'Apps (Aucune)' : `Apps (${sel}/${tot})`;
		btn.classList.remove('active');
	}
}

function open_app_modal() {
	document.getElementById('app_search').value = '';
	render_app_list();
	document.getElementById('app_modal').style.display = 'flex';
	document.getElementById('app_search').focus();
}

function close_app_modal() {
	document.getElementById('app_modal').style.display = 'none';
	update_app_btn_text();
	apply_date_app_filters();
}

function select_all_apps() {
	app_state.available_apps.forEach((app) => app_state.selected_apps.add(app));
	render_app_list();
}

function deselect_all_apps() {
	app_state.selected_apps.clear();
	render_app_list();
}

function toggle_app_selection(checkbox) {
	if (checkbox.checked) {
		app_state.selected_apps.add(checkbox.value);
	} else {
		app_state.selected_apps.delete(checkbox.value);
	}
}

function render_app_list() {
	const query = document.getElementById('app_search').value.toLowerCase();
	const container = document.getElementById('app_list');
	let html = '';

	app_state.available_apps.forEach((app) => {
		if (app.toLowerCase().includes(query)) {
			const checked = app_state.selected_apps.has(app) ? 'checked' : '';
			const icon =
				window.app_icons && window.app_icons[app]
					? `<img src="${window.app_icons[app]}" class="app-icon-img" alt="${escape_html(app)}" />`
					: `<div class="app-icon-div" style="background-color: ${get_app_color(app)}">${app.charAt(0).toUpperCase()}</div>`;

			html += `<label class="app-item"><input type="checkbox" value="${escape_html(app)}" ${checked} onchange="toggle_app_selection(this)"><div class="app-icon-wrapper">${icon}</div><span class="app-name">${escape_html(app)}</span></label>`;
		}
	});

	container.innerHTML =
		html ||
		'<div style="padding: 15px; color: var(--text-muted); text-align: center;">Aucune application trouvée</div>';
}

// =====================================
// =====================================
// ======= 4/ Chart Rendering =======
// =====================================
// =====================================

function reset_chart_zoom(chart_id) {
	if (chart_id === 'delegation' && delegation_chart_instance) {
		delegation_chart_instance.resetZoom();
	}
	if (chart_id === 'wpm' && wpm_chart_instance) {
		wpm_chart_instance.resetZoom();
	}
}
window.reset_chart_zoom = reset_chart_zoom;

function render_charts() {
	if (typeof Chart === 'undefined') return;

	const rootStyle = getComputedStyle(document.documentElement);

	const rgbIA = rootStyle.getPropertyValue('--kpi-llm-rgb').trim() || '122, 54, 163';
	const rgbHS = rootStyle.getPropertyValue('--kpi-hs-rgb').trim() || '204, 41, 34';
	const rgbMan = rootStyle.getPropertyValue('--kpi-delegation-rgb').trim() || '0, 86, 179';
	const rgbWPM = rootStyle.getPropertyValue('--kpi-wpm-rgb').trim() || '170, 122, 10';
	const rgbPrec = rootStyle.getPropertyValue('--kpi-precision-rgb').trim() || '33, 136, 56';

	const sorted_keys = Object.keys(app_state.time_series).sort();
	const manual_pts = [],
		hs_pts = [],
		llm_pts = [],
		wpm_pts = [];
	const hs_sp_pts = [],
		llm_sp_pts = [];

	sorted_keys.forEach((k) => {
		const d = app_state.time_series[k];
		const date_obj = new Date(k + 'T12:00:00');

		manual_pts.push({ x: date_obj, y: Math.max(0, d.chars - d.hs_chars - d.llm_chars) });
		hs_pts.push({ x: date_obj, y: d.hs_chars });
		llm_pts.push({ x: date_obj, y: d.llm_chars });

		if (d.chars > 0) {
			hs_sp_pts.push({ x: date_obj, y: (d.hs_chars / d.chars) * 100 });
			llm_sp_pts.push({ x: date_obj, y: (d.llm_chars / d.chars) * 100 });
		}

		let wpm = d.chars >= 10 && d.time_ms > 0 ? d.chars / 5 / (d.time_ms / 60000) : 0;
		if (!isNaN(wpm) && wpm > 0) wpm_pts.push({ x: date_obj, y: wpm });
	});

	if (delegation_chart_instance) delegation_chart_instance.destroy();
	const delegation_elem = document.getElementById('delegation_chart');
	if (delegation_elem) {
		delegation_chart_instance = new Chart(delegation_elem.getContext('2d'), {
			type: 'line',
			data: {
				datasets: [
					{
						label: 'IA',
						data: llm_pts,
						backgroundColor: `rgba(${rgbIA}, 0.6)`,
						fill: true,
						tension: 0.2,
						pointRadius: 0,
						pointHitRadius: 10
					},
					{
						label: 'Hotstrings',
						data: hs_pts,
						backgroundColor: `rgba(${rgbHS}, 0.6)`,
						fill: true,
						tension: 0.2,
						pointRadius: 0,
						pointHitRadius: 10
					},
					{
						label: 'Manuelles',
						data: manual_pts,
						backgroundColor: `rgba(${rgbMan}, 0.3)`,
						fill: true,
						tension: 0.2,
						pointRadius: 0,
						pointHitRadius: 10
					}
				]
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				interaction: { mode: 'index', intersect: false },
				plugins: {
					legend: { display: true },
					zoom: {
						pan: { enabled: false },
						zoom: {
							wheel: { enabled: true, modifierKey: 'ctrl' },
							pinch: { enabled: true },
							mode: 'x'
						}
					},
					tooltip: {
						callbacks: {
							title: tooltipTitleCallback,
							label: (ctx) =>
								`${ctx.dataset.label} : ${format_number(Math.round(ctx.parsed.y))} touches`
						}
					}
				},
				scales: {
					x: {
						type: 'time',
						time: { unit: 'day', displayFormats: { day: 'd MMM' } },
						stacked: true,
						grid: { color: 'rgba(128,128,128,0.2)' }
					},
					y: { stacked: true, grid: { color: 'rgba(128,128,128,0.2)' } }
				}
			}
		});
	}

	if (wpm_chart_instance) wpm_chart_instance.destroy();
	const wpm_elem = document.getElementById('wpm_chart');
	if (wpm_elem) {
		wpm_chart_instance = new Chart(wpm_elem.getContext('2d'), {
			type: 'line',
			data: {
				datasets: [
					{
						label: 'Vitesse',
						data: wpm_pts,
						borderColor: `rgb(${rgbWPM})`,
						backgroundColor: `rgba(${rgbWPM}, 0.2)`,
						fill: true,
						tension: 0.3,
						pointRadius: 3
					}
				]
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				plugins: {
					legend: { display: false },
					zoom: {
						pan: { enabled: false },
						zoom: {
							wheel: { enabled: true, modifierKey: 'ctrl' },
							pinch: { enabled: true },
							mode: 'x'
						}
					},
					tooltip: {
						callbacks: {
							title: tooltipTitleCallback,
							label: (ctx) => `Vitesse : ${format_number(Math.round(ctx.parsed.y))} MPM`
						}
					}
				},
				scales: {
					x: {
						type: 'time',
						time: { unit: 'day', displayFormats: { day: 'd MMM' } },
						grid: { color: 'rgba(128,128,128,0.2)' }
					},
					y: { beginAtZero: true, grid: { color: 'rgba(128,128,128,0.2)' } }
				}
			}
		});
	}

	if (precision_chart_instance) precision_chart_instance.destroy();
	const precision_pts = [];
	sorted_keys.forEach((k) => {
		const d = app_state.time_series[k];
		const accuracy =
			d.daily_chars > 0 ? ((d.daily_chars - d.daily_manual_errors) / d.daily_chars) * 100 : 0;
		const date_obj = new Date(k + 'T12:00:00');
		precision_pts.push({ x: date_obj, y: accuracy });
	});

	const precision_elem = document.getElementById('precision_chart');
	if (precision_elem) {
		precision_chart_instance = new Chart(precision_elem.getContext('2d'), {
			type: 'line',
			data: {
				datasets: [
					{
						label: 'Précision (%)',
						data: precision_pts,
						borderColor: `rgb(${rgbPrec})`,
						backgroundColor: `rgba(${rgbPrec}, 0.2)`,
						fill: true,
						tension: 0.3,
						pointRadius: 3
					}
				]
			},
			options: {
				responsive: true,
				maintainAspectRatio: false,
				plugins: {
					legend: { display: false },
					zoom: {
						pan: { enabled: false },
						zoom: {
							wheel: { enabled: true, modifierKey: 'ctrl' },
							pinch: { enabled: true },
							mode: 'x'
						}
					},
					tooltip: {
						callbacks: {
							title: tooltipTitleCallback,
							label: (ctx) => `Précision : ${format_number(Math.round(ctx.parsed.y))} %`
						}
					}
				},
				scales: {
					x: {
						type: 'time',
						time: { unit: 'day', displayFormats: { day: 'd MMM' } },
						grid: { color: 'rgba(128,128,128,0.2)' }
					},
					y: {
						beginAtZero: false,
						min: 0,
						max: 100,
						ticks: { callback: (v) => v + '%' },
						grid: { color: 'rgba(128, 128, 128, 0.1)' }
					}
				}
			}
		});
	}

	if (precision_elem) {
		const precisionChartContainer = precision_elem.closest('.chart-container');
		if (precisionChartContainer) {
			precisionChartContainer.style.display = 'flex';
			precisionChartContainer.style.visibility = 'visible';
			precisionChartContainer.style.flex = '1';
		}
		const parentWrapper = precisionChartContainer?.parentElement;
		if (parentWrapper) {
			parentWrapper.style.display = 'flex';
			parentWrapper.style.visibility = 'visible';
		}
	}

	render_sparkline(
		'hs_sparkline',
		hs_sparkline_instance,
		hs_sp_pts,
		`rgb(${rgbHS})`,
		(i) => (hs_sparkline_instance = i)
	);
	render_sparkline(
		'llm_sparkline',
		llm_sparkline_instance,
		llm_sp_pts,
		`rgb(${rgbIA})`,
		(i) => (llm_sparkline_instance = i)
	);
}

/**
 * Re-renders small sparkline visual elements.
 */
function render_sparkline(ctxId, chartRef, dataPoints, colorHex, updateRefFn) {
	if (chartRef) chartRef.destroy();

	const elem = document.getElementById(ctxId);
	if (!elem) return;

	const newChart = new Chart(elem.getContext('2d'), {
		type: 'line',
		data: {
			datasets: [
				{ data: dataPoints, borderColor: colorHex, borderWidth: 2, tension: 0.3, pointRadius: 0 }
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				tooltip: {
					enabled: true,
					callbacks: {
						title: tooltipTitleCallback,
						label: (ctx) => `Acceptés : ${format_number(Math.round(ctx.parsed.y))} %`
					}
				}
			},
			scales: {
				x: {
					type: 'time',
					display: true,
					time: { unit: 'day', displayFormats: { day: 'd MMM' } },
					ticks: { font: { size: 10 }, maxTicksLimit: 4 },
					grid: { display: false }
				},
				y: {
					display: true,
					beginAtZero: true,
					ticks: {
						font: { size: 10 },
						maxTicksLimit: 3,
						callback: function (val) {
							return format_number(val) + '%';
						}
					},
					grid: { color: 'rgba(128, 128, 128, 0.1)' }
				}
			},
			layout: { padding: 0 }
		}
	});

	updateRefFn(newChart);
}

// =====================================
// =====================================
// ======= 5/ Table Rendering =======
// =====================================
// =====================================

function switch_tab(tab_name) {
	app_state.current_tab = tab_name;
	document.querySelectorAll('.tabs .tab-btn').forEach((btn) => btn.classList.remove('active'));
	const tabBtn = document.querySelector(`[onclick="switch_tab('${tab_name}')"]`);
	if (tabBtn) tabBtn.classList.add('active');
	app_state.sort_col = 'count';
	app_state.sort_asc = false;
	document.getElementById('search_input').value = '';
	app_state.search_query = '';
	render_current_tab();
}

function handle_search() {
	app_state.search_query = document.getElementById('search_input').value.toLowerCase();
	render_table();
}

function handle_sort(col_name) {
	if (app_state.sort_col === col_name) {
		app_state.sort_asc = !app_state.sort_asc;
	} else {
		app_state.sort_col = col_name;
		app_state.sort_asc = col_name === 'key';
	}
	render_table();
}

function render_current_tab() {
	const source_dict = app_state.data[app_state.current_tab] || {};
	let data_arr = [];

	Object.keys(source_dict).forEach((k) => {
		let norm_k = k.replace(/\[BS\]/gi, 'B');
		let seq_len =
			app_state.current_tab === 'w'
				? Array.from(norm_k).length
				: { hp: 7, hx: 6, pg: 5, qg: 4, tg: 3, bg: 2 }[app_state.current_tab] || 1;

		if (
			app_state.current_tab !== 'w' &&
			app_state.current_tab !== 'sc' &&
			Array.from(norm_k).length !== seq_len
		)
			return;

		const item = source_dict[k];
		const manual_count = Math.max(
			0,
			item.count - item.synth_hs - item.synth_llm - item.synth_other
		);
		const avg = manual_count > 0 ? item.time / manual_count : 0;

		data_arr.push({
			key: k,
			count: item.count,
			synth_hs: item.synth_hs,
			synth_llm: item.synth_llm,
			synth_other: item.synth_other,
			avg: isNaN(avg) ? 0 : avg,
			wpm:
				app_state.current_tab !== 'sc' && !isNaN(avg) && avg > 0 ? seq_len / 5 / (avg / 60000) : 0,
			acc: item.count > 0 ? ((item.count - item.errors) / item.count) * 100 : 0
		});
	});

	app_state.rendered_list = data_arr.filter((i) => i.count >= 2);

	let total_occ = 0;
	let total_time = 0;

	app_state.rendered_list.forEach((i) => {
		total_occ += i.count;
		total_time += i.count * i.avg;
		i.freq = 0;
	});

	app_state.rendered_list.forEach((i) => {
		i.freq = total_occ > 0 ? (i.count / total_occ) * 100 : 0;
	});

	let cpm_filtered = 0;
	let wpm_filtered = 0;
	if (total_time > 0) {
		cpm_filtered = total_occ / (total_time / 60000);
		wpm_filtered = cpm_filtered / 5;
	}

	const wpm_val_elem = document.getElementById('wpm_val');
	if (wpm_val_elem) {
		wpm_val_elem.innerHTML = `
			<div style="display:flex; flex-direction:column; justify-content:center;">
				<div style="display:flex; align-items:center; gap:6px;">
					<span>${format_number(wpm_filtered.toFixed(1))} <span class="stat-unit">MPM</span></span>
					<span class="tooltip stat-inline-tooltip">${info_svg}<span class="tooltiptext">MPM : Mots par minute, avec la convention standard 1 mot = 5 touches</span></span>
				</div>
				<div style="display:flex; align-items:center; gap:6px; font-size: 0.65em; margin-top: 5px;">
					<span>${format_number(cpm_filtered.toFixed(0))} <span class="stat-unit">CPM</span></span>
					<span class="tooltip stat-inline-tooltip">${info_svg}<span class="tooltiptext">CPM : Caractères par minute, total de touches tapées par minute</span></span>
				</div>
			</div>
		`;
	}

	const global_details_elem = document.getElementById('global_details');
	if (global_details_elem) {
		global_details_elem.innerHTML = `<div style="margin-top:5px;"><strong style="color:var(--kpi-wpm-color); font-size: 1.1em;">${format_number(total_occ)}</strong> <span class="stat-unit" style="font-size: 0.9em;">touches tapées</span></div>`;
	}

	const total_occ_elem = document.getElementById('total_occurrences');
	if (total_occ_elem) {
		total_occ_elem.innerText = `(${format_number(total_occ)})`;
	}

	render_table();
}

function render_table() {
	let arr = [...app_state.rendered_list];

	if (app_state.search_query) {
		arr = arr.filter((i) => i.key.toLowerCase().includes(app_state.search_query));
	}

	arr.sort((a, b) => {
		let v_a = a[app_state.sort_col] || 0;
		let v_b = b[app_state.sort_col] || 0;

		if (typeof v_a === 'string') {
			return app_state.sort_asc ? v_a.localeCompare(v_b) : v_b.localeCompare(v_a);
		}
		return app_state.sort_asc ? v_a - v_b : v_b - v_a;
	});

	const tbody = document.getElementById('metrics_table_body');
	if (!tbody) return;

	let html = arr
		.slice(0, 1000)
		.map((item) => {
			const keyHtml =
				app_state.current_tab === 'sc'
					? `<span class="shortcut-seq">${format_shortcut_key(item.key)}</span>`
					: `<span class="mono-space">${format_display_key(item.key)}</span>`;

			let synth = [];
			if (item.synth_hs > 0) synth.push(`${format_number(item.synth_hs)} HS`);
			if (item.synth_llm > 0) synth.push(`${format_number(item.synth_llm)} IA`);

			let synth_str = synth.length
				? `<br><span style="font-size:10px; color:var(--text-muted);">(dont ${synth.join(', ')})</span>`
				: '';
			let avg_str = item.avg > 0 ? format_number(item.avg.toFixed(1)) + ' ms' : '-';

			let wpm_color =
				item.wpm > 60 ? '#34c759' : item.wpm > 0 && item.wpm < 30 ? '#ff3b30' : 'inherit';
			let wpm_str = item.wpm > 0 ? format_number(item.wpm.toFixed(1)) + ' MPM' : '-';

			let acc_color = item.acc >= 95 ? '#34c759' : item.acc < 80 ? '#ff3b30' : '#ffcc00';

			return `<tr>
			<td>${keyHtml}</td>
			<td>${format_number(item.count)}${synth_str}</td>
			<td>${format_number(item.freq.toFixed(2))} %</td>
			<td>${avg_str}</td>
			<td><strong style="color: ${wpm_color}">${wpm_str}</strong></td>
			<td><strong style="color: ${acc_color}">${format_number(item.acc.toFixed(1))} %</strong></td>
		</tr>`;
		})
		.join('');

	tbody.innerHTML =
		html || '<tr><td colspan="6" style="text-align:center;">Aucune donnée</td></tr>';
}

window.process_manifest = process_manifest;
window.apply_date_app_filters = apply_date_app_filters;
window.reset_filters = reset_filters;
window.switch_tab = switch_tab;
window.handle_search = handle_search;
window.handle_sort = handle_sort;
window.open_app_modal = open_app_modal;
window.close_app_modal = close_app_modal;
window.select_all_apps = select_all_apps;
window.deselect_all_apps = deselect_all_apps;
window.toggle_app_selection = toggle_app_selection;
window.render_app_list = render_app_list;
window.receive_range_data = receive_range_data;
window.receive_live_update = receive_live_update;
window.toggle_filter = toggle_filter;
