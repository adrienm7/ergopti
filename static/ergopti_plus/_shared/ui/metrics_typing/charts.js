// ui/metrics_typing/charts.js

/**
 * ==============================================================================
 * MODULE: Chart Rendering
 * DESCRIPTION:
 * Builds and updates all Chart.js instances for the typing metrics dashboard:
 * delegation stacked area, WPM line, precision line, and HS/LLM sparklines.
 *
 * FEATURES & RATIONALE:
 * 1. Destroy-Recreate: Charts are fully destroyed before re-creation to avoid
 *    memory leaks and stale dataset references across filter changes.
 * 2. CSS Variable Colors: All chart colors reference CSS variables resolved at
 *    render time, ensuring correct light/dark mode support.
 * 3. Pinch-to-Zoom: WPM and delegation charts support trackpad pinch zoom via
 *    chartjs-plugin-zoom for fine-grained time range exploration.
 * ==============================================================================
 */

// ============================================================
// ============================================================
// ======= 1/ i18n Helper & Main Chart Render Helpers  =======
// ============================================================
// ============================================================

/**
 * Returns the translated string for a given i18n key, or the key itself as fallback.
 * Reads from window._i18n_strings populated by the shared i18n loader.
 * @param {string} key - The dotted i18n key (e.g. "ui_typing.day_0").
 * @returns {string} The translated string, or the key if not found.
 */
function _t(key) {
	return (window._i18n_strings && window._i18n_strings[key]) || key;
}


// ====================================
// ====================================
// ======= 2/ Main Chart Render =======
// ====================================
// ====================================

/**
 * Renders (or re-renders) the delegation, WPM, and precision chart canvases
 * using the current time_series data in app_state. When the selected range spans
 * exactly one day, precision and speed charts switch to hourly granularity using
 * app_state.hourly_series — far more informative than a single daily data point.
 */
function render_charts() {
	if (typeof Chart === 'undefined') return;

	const root = getComputedStyle(document.documentElement);
	const rgb_ia = root.getPropertyValue('--kpi-llm-rgb').trim() || '122, 54, 163';
	const rgb_hs = root.getPropertyValue('--kpi-hs-rgb').trim() || '204, 41, 34';
	const rgb_man = root.getPropertyValue('--kpi-delegation-rgb').trim() || '0, 86, 179';
	const rgb_wpm = root.getPropertyValue('--chart-wpm-rgb').trim() || '230, 140, 0';
	const rgb_prc = root.getPropertyValue('--kpi-precision-rgb').trim() || '33, 136, 56';

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

		const wpm = d.wpm_chars >= 10 && d.time_ms > 0 ? d.wpm_chars / 5 / (d.time_ms / 60000) : 0;
		if (!isNaN(wpm) && wpm > 0) wpm_pts.push({ x: date_obj, y: wpm });
	});

	// Shared x-axis range so precision and speed charts always have identical bounds
	const x_min = sorted_keys.length > 0 ? new Date(sorted_keys[0] + 'T12:00:00') : null;
	const x_max = sorted_keys.length > 0 ? new Date(sorted_keys.at(-1) + 'T12:00:00') : null;

	// Delegation chart always uses daily points — no per-hour HS/LLM breakdown available
	_render_delegation_chart(manual_pts, hs_pts, llm_pts, rgb_ia, rgb_hs, rgb_man);
	_render_sparklines(hs_sp_pts, llm_sp_pts, rgb_hs, rgb_ia);
	_render_activity_calendar();
	_render_hour_weekday_heatmap();

	// Single-day view: use hourly_series for precision and activity charts so the
	// user sees an intra-day curve instead of a single meaningless dot.
	if (sorted_keys.length === 1) {
		_render_hourly_charts(sorted_keys[0], rgb_wpm, rgb_prc);
	} else {
		// Restore daily titles in case they were previously changed by an hourly view
		const wpm_title_el = document.getElementById('wpm_chart_title');
		if (wpm_title_el) wpm_title_el.textContent = _t('ui_typing.h3_speed');
		const prc_title_el = document.getElementById('precision_chart_title');
		if (prc_title_el) prc_title_el.textContent = _t('ui_typing.h3_precision');

		_render_wpm_chart(wpm_pts, rgb_wpm, x_min, x_max);
		_render_precision_chart(sorted_keys, rgb_prc, x_min, x_max);
	}
}

/**
 * Resets the zoom on a named chart instance back to the default view.
 * @param {string} chart_id - "delegation", "wpm", or "precision".
 */
function reset_chart_zoom(chart_id) {
	if (chart_id === 'delegation' && delegation_chart_instance) delegation_chart_instance.resetZoom();
	if (chart_id === 'wpm' && wpm_chart_instance) wpm_chart_instance.resetZoom();
	if (chart_id === 'precision' && precision_chart_instance) precision_chart_instance.resetZoom();
}

// =====================================================
// =====================================================
// ======= 3/ Individual Chart Builder Helpers =======
// =====================================================
// =====================================================

const ZOOM_OPTIONS = {
	pan: { enabled: false },
	zoom: {
		wheel: { enabled: true, modifierKey: 'ctrl' },
		pinch: { enabled: true },
		mode: 'x'
	}
};

const GRID_COLOR = 'rgba(128,128,128,0.2)';

// Day/month name arrays resolved at call time so i18n strings injected
// after script parse are always reflected in axis labels.
function days_fr() {
	return [0,1,2,3,4,5,6].map(i => _t('ui_typing.day_' + i));
}
function months_fr() {
	return [0,1,2,3,4,5,6,7,8,9,10,11].map(i => _t('ui_typing.month_' + i));
}

/**
 * Returns a two-line French day tick label for a daily x-axis value.
 * Used with ticks.color: "transparent" so Chart.js reserves the correct two-line
 * height while the DAY_TICK_RENDERER plugin redraws the text with bold dates.
 * @param {number} value - Timestamp in milliseconds.
 * @returns {string[]} [dayName, "d month"] — e.g. ["lundi", "12 avr."]
 */
function _format_day_tick(value) {
	const d = new Date(value);
	return [days_fr()[d.getDay()], `${d.getDate()} ${months_fr()[d.getMonth()]}`];
}

// Canvas IDs of daily charts that use the two-line day+date tick renderer.
// Identified by canvas ID to avoid adding unknown properties to Chart.js options objects,
// which can interfere with Chart.js 4's internal option resolution pipeline.
const DAY_TICK_CANVAS_IDS = new Set([
	'delegation_chart',
	'wpm_chart',
	'precision_chart',
	'hs_sparkline',
	'llm_sparkline'
]);

// Plugin: redraws daily x-axis tick labels as two lines — day name (normal) + date (bold).
// Charts in DAY_TICK_CANVAS_IDS must also set ticks.color: "transparent" so Chart.js
// reserves two-line height without drawing its own unstyled labels.
if (typeof Chart !== 'undefined') {
	Chart.register({
		id: 'day_tick_renderer',
		afterDraw(chart) {
			const xScale = chart.scales.x;
			if (!xScale || !DAY_TICK_CANVAS_IDS.has(chart.canvas?.id)) return;

			const ctx = chart.ctx;
			const ticks = xScale.ticks;
			if (!ticks?.length) return;

			const tick_opts = xScale.options.ticks || {};
			const font_cfg = tick_opts.font || {};
			// Read font size from the scale config (sparklines use 10, main charts default to 12)
			const size = (typeof font_cfg === 'object' ? font_cfg.size : null) || 12;
			const pad = typeof tick_opts.padding === 'number' ? tick_opts.padding : 3;
			const lh = Math.round(size * 1.2);
			const color = Chart.defaults.color || 'rgba(0,0,0,0.6)';

			// xScale.top = bottom of the plot area (axis line level); tick labels start just below it
			const y1 = xScale.top + pad + 1;
			const y2 = y1 + lh;

			ctx.save();
			ctx.textAlign = 'center';
			ctx.textBaseline = 'top';
			ctx.fillStyle = color;

			ticks.forEach((tick, i) => {
				const x = xScale.getPixelForTick(i);
				const d = new Date(tick.value);

				// Line 1 — day name, normal weight
				ctx.font = `${size}px sans-serif`;
				ctx.fillText(days_fr()[d.getDay()], x, y1);

				// Line 2 — "d month" in bold (e.g. "12 avr.")
				ctx.font = `bold ${size}px sans-serif`;
				ctx.fillText(`${d.getDate()} ${months_fr()[d.getMonth()]}`, x, y2);
			});

			ctx.restore();
		}
	});
}

/**
 * @param {Object[]} manual_pts - Data points for manually typed chars.
 * @param {Object[]} hs_pts     - Data points for hotstring chars.
 * @param {Object[]} llm_pts    - Data points for LLM chars.
 * @param {string}   rgb_ia     - CSS RGB string for LLM color.
 * @param {string}   rgb_hs     - CSS RGB string for HS color.
 * @param {string}   rgb_man    - CSS RGB string for manual color.
 */
function _render_delegation_chart(manual_pts, hs_pts, llm_pts, rgb_ia, rgb_hs, rgb_man) {
	if (delegation_chart_instance) delegation_chart_instance.destroy();
	const elem = document.getElementById('delegation_chart');
	if (!elem) return;

	delegation_chart_instance = new Chart(elem.getContext('2d'), {
		type: 'line',
		data: {
			datasets: [
				{
					label: _t('ui_typing.dataset_ai'),
					data: llm_pts,
					backgroundColor: `rgba(${rgb_ia}, 0.6)`,
					fill: true,
					tension: 0.2,
					pointRadius: 0,
					pointHitRadius: 10
				},
				{
					label: _t('ui_typing.dataset_hs'),
					data: hs_pts,
					backgroundColor: `rgba(${rgb_hs}, 0.6)`,
					fill: true,
					tension: 0.2,
					pointRadius: 0,
					pointHitRadius: 10
				},
				{
					label: _t('ui_typing.dataset_manual'),
					data: manual_pts,
					backgroundColor: `rgba(${rgb_man}, 0.3)`,
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
				zoom: ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallback,
						// format_number_plain avoids raw HTML in the tooltip (Chart.js renders labels as plain text)
						label: (ctx) =>
							`${ctx.dataset.label} : ${format_number_plain(Math.round(ctx.parsed.y))} ${_t('ui_typing.unit_keystrokes')}`
					}
				}
			},
			scales: {
				x: {
					type: 'time',
					time: { unit: 'day' },
					stacked: true,
					grid: { color: GRID_COLOR },
					// color: transparent hides Chart.js auto-labels; the plugin redraws them with bold dates
					ticks: { color: 'transparent', callback: (v) => _format_day_tick(v) }
				},
				y: { stacked: true, grid: { color: GRID_COLOR } }
			}
		}
	});
}

/**
 * @param {Object[]} wpm_pts - Data points for daily WPM values.
 * @param {string}   rgb_wpm - CSS RGB string for WPM color.
 * @param {Date|null} x_min  - Shared x-axis lower bound (aligns with precision chart).
 * @param {Date|null} x_max  - Shared x-axis upper bound.
 */
function _render_wpm_chart(wpm_pts, rgb_wpm, x_min = null, x_max = null) {
	if (wpm_chart_instance) wpm_chart_instance.destroy();
	const elem = document.getElementById('wpm_chart');
	if (!elem) return;

	const x_opts = {
		type: 'time',
		time: { unit: 'day' },
		grid: { color: GRID_COLOR },
		ticks: { color: 'transparent', callback: (v) => _format_day_tick(v) }
	};
	if (x_min) x_opts.min = x_min;
	if (x_max) x_opts.max = x_max;

	wpm_chart_instance = new Chart(elem.getContext('2d'), {
		type: 'line',
		data: {
			datasets: [
				{
					label: _t('ui_typing.dataset_speed'),
					data: wpm_pts,
					borderColor: `rgb(${rgb_wpm})`,
					backgroundColor: `rgba(${rgb_wpm}, 0.2)`,
					fill: true,
					tension: 0.3,
					pointRadius: 3
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			layout: { padding: { bottom: 0 } },
			plugins: {
				legend: { display: false },
				zoom: ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallback,
						label: (ctx) => `${_t('ui_typing.dataset_speed')} : ${format_number_plain(Math.round(ctx.parsed.y))} ${_t('ui_typing.unit_mpm')}`
					}
				}
			},
			scales: {
				x: x_opts,
				y: { beginAtZero: true, grid: { color: GRID_COLOR } }
			}
		}
	});
}

/**
 * @param {string[]} sorted_keys - Sorted date keys from time_series.
 * @param {string}   rgb_prc     - CSS RGB string for precision color.
 * @param {Date|null} x_min      - Shared x-axis lower bound (aligns with speed chart).
 * @param {Date|null} x_max      - Shared x-axis upper bound.
 */
function _render_precision_chart(sorted_keys, rgb_prc, x_min = null, x_max = null) {
	if (precision_chart_instance) precision_chart_instance.destroy();
	const elem = document.getElementById('precision_chart');
	if (!elem) return;

	// Populate the (i) tooltip next to the chart title with the formula details.
	const info_el = document.getElementById('precision_info');
	if (info_el && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const ui_thresh_ms =
			parseInt(document.getElementById('pause_threshold')?.value ?? '5000', 10) || 5000;
		const thresh_label =
			ui_thresh_ms >= 99999000
				? _t('ui_typing.precision_no_filter')
				: ui_thresh_ms >= 60000
					? `${ui_thresh_ms / 60000}${NBSP}min`
					: `${ui_thresh_ms / 1000}${NBSP}s`;
		const tip = _t('ui_typing.tooltip_precision_formula').replace('{thresh}', thresh_label);
		info_el.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}

	// Precision formula
	// ─────────────────
	//   - Manual errors are read from the per-day cumulative bucket cache
	//     (daily_e_buckets) at the bucket matching the user's pause-threshold
	//     slider. A backspace only counts if its delay since the previous
	//     keystroke is ≤ pause_thresh — backspaces after long pauses are
	//     typically deletions of selected text / whole lines, not typo
	//     corrections, so they mustn't deflate precision.
	//   - Synthetic chars from HS / IA are added when their toggle is active
	//     (− their trigger chars, which are already in daily_chars). They
	//     count as 100 % correct, so toggling a source on can only raise
	//     precision.
	// precision = (manual − errors + synth) / (manual + synth)
	const { show_hs, show_llm } = get_source_mode_flags();
	const pause_thresh =
		parseInt(document.getElementById('pause_threshold')?.value ?? '5000', 10) || 5000;
	const bucket_key = pause_thresh_to_bucket_key(pause_thresh);
	const precision_pts = sorted_keys
		.filter((k) => app_state.time_series[k].daily_chars > 0)
		.map((k) => {
			const d = app_state.time_series[k];
			const filtered_errs = d.daily_e_buckets?.[bucket_key] || 0;
			const synth_hs = show_hs ? Math.max(0, (d.hs_chars || 0) - (d.hs_input_chars || 0)) : 0;
			const synth_llm = show_llm ? Math.max(0, (d.llm_chars || 0) - (d.llm_input_chars || 0)) : 0;
			const total_chars = d.daily_chars + synth_hs + synth_llm;
			const correct = d.daily_chars - filtered_errs + synth_hs + synth_llm;
			const accuracy = total_chars > 0 ? (correct / total_chars) * 100 : 0;
			return { x: new Date(k + 'T12:00:00'), y: Math.max(0, Math.min(100, accuracy)) };
		})
		.filter((pt) => pt.y >= 20);

	precision_chart_instance = new Chart(elem.getContext('2d'), {
		type: 'line',
		data: {
			datasets: [
				{
					label: _t('ui_typing.dataset_precision'),
					data: precision_pts,
					borderColor: `rgb(${rgb_prc})`,
					backgroundColor: `rgba(${rgb_prc}, 0.2)`,
					fill: true,
					tension: 0.3,
					pointRadius: 3
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			layout: { padding: { bottom: 0 } },
			plugins: {
				legend: { display: false },
				zoom: ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallback,
						label: (ctx) =>
							`Pr\u00E9cision\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0%`
					}
				}
			},
			scales: {
				x: Object.assign(
					{
						type: 'time',
						time: { unit: 'day' },
						grid: { color: GRID_COLOR },
						ticks: { color: 'transparent', callback: (v) => _format_day_tick(v) }
					},
					x_min ? { min: x_min } : {},
					x_max ? { max: x_max } : {}
				),
				y: {
					beginAtZero: true,
					min: 0,
					max: 100,
					ticks: { callback: (v) => v + '%' },
					grid: { color: 'rgba(128, 128, 128, 0.1)' }
				}
			}
		}
	});
}

/**
 * @param {Object[]} hs_sp_pts  - HS acceptance rate sparkline points.
 * @param {Object[]} llm_sp_pts - LLM acceptance rate sparkline points.
 * @param {string}   rgb_hs     - CSS RGB string for HS color.
 * @param {string}   rgb_ia     - CSS RGB string for LLM color.
 */
function _render_sparklines(hs_sp_pts, llm_sp_pts, rgb_hs, rgb_ia) {
	hs_sparkline_instance = _render_sparkline(
		'hs_sparkline',
		hs_sparkline_instance,
		hs_sp_pts,
		`rgb(${rgb_hs})`
	);
	llm_sparkline_instance = _render_sparkline(
		'llm_sparkline',
		llm_sparkline_instance,
		llm_sp_pts,
		`rgb(${rgb_ia})`
	);
}

/**
 * Creates or replaces a mini sparkline chart inside the given canvas element.
 * @param {string}      ctx_id    - The canvas DOM ID.
 * @param {Chart|null}  chart_ref - The existing chart instance to destroy.
 * @param {Object[]}    data_pts  - The data points { x, y }.
 * @param {string}      color     - The CSS color string.
 * @returns {Chart} The newly created chart instance.
 */
function _render_sparkline(ctx_id, chart_ref, data_pts, color) {
	if (chart_ref) chart_ref.destroy();
	const elem = document.getElementById(ctx_id);
	if (!elem) return null;

	return new Chart(elem.getContext('2d'), {
		type: 'line',
		data: {
			datasets: [
				{
					data: data_pts,
					borderColor: color,
					borderWidth: 2,
					tension: 0.3,
					pointRadius: 0
				}
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
						label: (ctx) =>
							`Accept\u00E9es\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0%`
					}
				}
			},
			scales: {
				x: {
					type: 'time',
					display: true,
					time: { unit: 'day' },
					ticks: {
						font: { size: 10 },
						maxTicksLimit: 4,
						color: 'transparent',
						callback: (v) => _format_day_tick(v)
					},
					grid: { display: false }
				},
				y: {
					display: true,
					beginAtZero: true,
					ticks: {
						font: { size: 10 },
						maxTicksLimit: 3,
						callback: (v) => format_number_plain(v) + '%'
					},
					grid: { color: 'rgba(128, 128, 128, 0.1)' }
				}
			},
			layout: { padding: 0 }
		}
	});
}

// ====================================================
// ====================================================
// ======= 4/ Hourly Chart Helpers (single day) =======
// ====================================================
// ====================================================

/**
 * Tooltip title callback for hourly charts: shows "lundi 14/04 à 15h" instead
 * of a full date, since the day is already known when in single-day mode.
 * @param {Array} context - Chart.js tooltip context array.
 * @returns {string} Hour-aware French-formatted label.
 */
const tooltipTitleCallbackHourly = (context) => {
	const days = [
		_t('ui_typing.day_0'), _t('ui_typing.day_1'), _t('ui_typing.day_2'),
		_t('ui_typing.day_3'), _t('ui_typing.day_4'), _t('ui_typing.day_5'),
		_t('ui_typing.day_6')
	];
	const d = new Date(context[0].parsed.x);
	const dayName = days[d.getDay()];
	const dd = String(d.getDate()).padStart(2, '0');
	const mm = String(d.getMonth() + 1).padStart(2, '0');
	const h = d.getHours();
	return `${dayName} ${dd}/${mm} \u00E0 ${h}\u202Fh`;
};

/**
 * Builds the hourly data points from app_state.hourly_series and renders both
 * the activity (touches/h) and precision charts for the given single-day date.
 * Called from render_charts() when sorted_keys.length === 1.
 * @param {string} date_str - The ISO date string for the single selected day.
 * @param {string} rgb_wpm  - CSS RGB string for the activity chart color.
 * @param {string} rgb_prc  - CSS RGB string for the precision chart color.
 */
function _render_hourly_charts(date_str, rgb_wpm, rgb_prc) {
	// hour_cutoff: null or 0 → show all hours (hourly); N > 0 → last-hour view (5-min)
	const cutoff = typeof app_state.hour_cutoff === 'number' ? app_state.hour_cutoff : 0;

	if (cutoff > 0) {
		// Last-hour preset: switch to 5-minute resolution for a detailed intra-hour view
		_render_minute5_charts(date_str, rgb_wpm, rgb_prc, cutoff);
		return;
	}

	const act_pts = []; // { x: Date, y: chars_count } — typing activity per hour
	const prec_pts = []; // { x: Date, y: accuracy_pct }

	for (let h = 0; h < 24; h++) {
		const h_str = h.toString().padStart(2, '0');
		const hd = app_state.hourly_series[h_str];
		if (!hd || hd.c === 0) continue;

		// Midpoint of the hour so the chart point sits in the centre of the slot
		const date_obj = new Date(`${date_str}T${h_str}:30:00`);
		act_pts.push({ x: date_obj, y: hd.c });

		// Precision: bucketed error count at the user's pause threshold.
		const _key = pause_thresh_to_bucket_key(
			parseInt(document.getElementById('pause_threshold')?.value ?? '5000', 10) || 5000
		);
		const filtered_e = hd.e_buckets?.[_key] || 0;
		const acc = ((hd.c - filtered_e) / hd.c) * 100;
		prec_pts.push({ x: date_obj, y: Math.max(0, Math.min(100, acc)) });
	}

	// Update chart titles to reflect hourly context
	const wpm_title_el = document.getElementById('wpm_chart_title');
	if (wpm_title_el) wpm_title_el.textContent = _t('ui_typing.h3_activity_hourly');
	const prc_title_el = document.getElementById('precision_chart_title');
	if (prc_title_el) prc_title_el.textContent = _t('ui_typing.h3_precision_hourly');

	_render_hourly_activity_chart(act_pts, rgb_wpm, date_str, cutoff);
	_render_hourly_precision_chart(prec_pts, rgb_prc, date_str, cutoff);
}

/**
 * Renders the hourly activity chart (chars typed per hour) reusing the wpm canvas.
 * WPM cannot be computed without per-hour typing-time data, so character count per
 * hour is used as a faithful proxy for typing intensity throughout the day.
 * The x-axis always spans from the cutoff hour to end-of-day so a single data point
 * (e.g. "last_hour" preset with activity in only one slot) still reads as a chart.
 * @param {Object[]} pts      - Data points { x: Date, y: count }.
 * @param {string}   color    - CSS RGB string for the line color.
 * @param {string}   date_str - ISO date string for the selected day (x-axis bounds).
 * @param {number}   cutoff   - First hour shown (0 = full day).
 */
function _render_hourly_activity_chart(pts, color, date_str, cutoff) {
	if (wpm_chart_instance) wpm_chart_instance.destroy();
	const elem = document.getElementById('wpm_chart');
	if (!elem) return;

	// For today, cap the right edge at the current hour + 1 so the user sees
	// a tight window around actual data rather than an empty stretch to midnight.
	const today_str = get_local_date_string();
	const end_hour = date_str === today_str ? Math.min(new Date().getHours() + 1, 23) : 23;
	const x_min = new Date(`${date_str}T${String(cutoff).padStart(2, '0')}:00:00`);
	const x_max = new Date(`${date_str}T${String(end_hour).padStart(2, '0')}:59:59`);

	wpm_chart_instance = new Chart(elem.getContext('2d'), {
		type: 'line',
		data: {
			datasets: [
				{
					label: _t('ui_typing.dataset_touches_h'),
					data: pts,
					borderColor: `rgb(${color})`,
					backgroundColor: `rgba(${color}, 0.2)`,
					fill: true,
					tension: 0.3,
					pointRadius: 4
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom: ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallbackHourly,
						label: (ctx) =>
							`${_t('ui_typing.lbl_activity')}\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0${_t('ui_typing.unit_keystrokes')}`
					}
				}
			},
			scales: {
				x: {
					type: 'time',
					min: x_min,
					max: x_max,
					time: { unit: 'hour', displayFormats: { hour: "H'h'" } },
					grid: { color: GRID_COLOR }
				},
				y: { beginAtZero: true, grid: { color: GRID_COLOR } }
			}
		}
	});
}

/**
 * Renders the hourly precision chart reusing the precision canvas.
 * The x-axis always spans from the cutoff hour to end-of-day — same reason as above.
 * @param {Object[]} pts      - Data points { x: Date, y: accuracy_pct }.
 * @param {string}   color    - CSS RGB string for the line color.
 * @param {string}   date_str - ISO date string for the selected day (x-axis bounds).
 * @param {number}   cutoff   - First hour shown (0 = full day).
 */
function _render_hourly_precision_chart(pts, color, date_str, cutoff) {
	if (precision_chart_instance) precision_chart_instance.destroy();
	const elem = document.getElementById('precision_chart');
	if (!elem) return;

	// Same rationale as the activity chart: cap x_max at the current hour + 1 for today.
	const today_str_p = get_local_date_string();
	const end_hour_p = date_str === today_str_p ? Math.min(new Date().getHours() + 1, 23) : 23;
	const x_min = new Date(`${date_str}T${String(cutoff).padStart(2, '0')}:00:00`);
	const x_max = new Date(`${date_str}T${String(end_hour_p).padStart(2, '0')}:59:59`);

	precision_chart_instance = new Chart(elem.getContext('2d'), {
		type: 'line',
		data: {
			datasets: [
				{
					label: 'Pr\u00E9cision (%)',
					data: pts,
					borderColor: `rgb(${color})`,
					backgroundColor: `rgba(${color}, 0.2)`,
					fill: true,
					tension: 0.3,
					pointRadius: 4
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom: ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallbackHourly,
						label: (ctx) =>
							`Pr\u00E9cision\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0%`
					}
				}
			},
			scales: {
				x: {
					type: 'time',
					min: x_min,
					max: x_max,
					time: { unit: 'hour', displayFormats: { hour: "H'h'" } },
					grid: { color: GRID_COLOR }
				},
				y: {
					beginAtZero: false,
					min: 50,
					max: 100,
					ticks: { callback: (v) => v + '%' },
					grid: { color: 'rgba(128, 128, 128, 0.1)' }
				}
			}
		}
	});
}

// ==================================================================
// ==================================================================
// ======= 4/ 5-Minute Chart Helpers (last-hour single-day) =======
// ==================================================================
// ==================================================================

/**
 * Tooltip title callback for 5-minute charts: shows "lundi 14/04 à 15h05"
 * so the user can read the exact time slot without any ambiguity.
 * @param {Array} context - Chart.js tooltip context array.
 * @returns {string} Minute-aware French-formatted label.
 */
const tooltipTitleCallbackMinute5 = (context) => {
	const days = [
		_t('ui_typing.day_0'), _t('ui_typing.day_1'), _t('ui_typing.day_2'),
		_t('ui_typing.day_3'), _t('ui_typing.day_4'), _t('ui_typing.day_5'),
		_t('ui_typing.day_6')
	];
	const d = new Date(context[0].parsed.x);
	const dayName = days[d.getDay()];
	const dd = String(d.getDate()).padStart(2, '0');
	const mm = String(d.getMonth() + 1).padStart(2, '0');
	const h = d.getHours();
	const min = String(d.getMinutes()).padStart(2, '0');
	return `${dayName} ${dd}/${mm} \u00E0 ${h}h${min}`;
};

/**
 * Builds the 5-minute data points and renders both the activity and precision
 * charts using app_state.minute5_series. Called by _render_hourly_charts when
 * hour_cutoff > 0 (last-hour preset).
 * @param {string} date_str - The ISO date string for the selected day.
 * @param {string} rgb_wpm  - CSS RGB string for the activity chart color.
 * @param {string} rgb_prc  - CSS RGB string for the precision chart color.
 * @param {number} cutoff   - First hour shown; the window spans cutoff to cutoff+2.
 */
function _render_minute5_charts(date_str, rgb_wpm, rgb_prc, cutoff) {
	const act_pts = []; // { x: Date, y: chars_count } per 5-min bucket
	const prec_pts = []; // { x: Date, y: accuracy_pct }
	const bucket_key = pause_thresh_to_bucket_key(
		parseInt(document.getElementById('pause_threshold')?.value ?? '5000', 10) || 5000
	);

	// Iterate the 5-minute buckets sorted so the chart line is always left-to-right
	const sorted_buckets = Object.keys(app_state.minute5_series).sort();
	sorted_buckets.forEach((bucket) => {
		const bh = parseInt(bucket.split(':')[0], 10);
		// Only show buckets at or after the cutoff hour
		if (bh < cutoff) return;

		const md = app_state.minute5_series[bucket];
		if (!md || md.c === 0) return;

		// Use the bucket start time as the data point x coordinate
		const date_obj = new Date(`${date_str}T${bucket}:00`);
		act_pts.push({ x: date_obj, y: md.c });

		const filtered_e = md.e_buckets?.[bucket_key] || 0;
		const acc = ((md.c - filtered_e) / md.c) * 100;
		prec_pts.push({ x: date_obj, y: Math.max(0, Math.min(100, acc)) });
	});

	// Update chart titles for 5-minute context
	const wpm_title_el = document.getElementById('wpm_chart_title');
	if (wpm_title_el) wpm_title_el.textContent = _t('ui_typing.chart_title_activity_5min');
	const prc_title_el = document.getElementById('precision_chart_title');
	if (prc_title_el) prc_title_el.textContent = _t('ui_typing.chart_title_precision_5min');

	_render_minute5_activity_chart(act_pts, rgb_wpm, date_str, cutoff);
	_render_minute5_precision_chart(prec_pts, rgb_prc, date_str, cutoff);
}

/**
 * Renders the 5-minute activity chart (chars typed per 5-min bucket), reusing
 * the wpm canvas. x-axis spans the cutoff hour to end of the following hour.
 * @param {Object[]} pts      - Data points { x: Date, y: count }.
 * @param {string}   color    - CSS RGB string for the line color.
 * @param {string}   date_str - ISO date string for the selected day.
 * @param {number}   cutoff   - First hour shown (> 0 in this path).
 */
function _render_minute5_activity_chart(pts, color, date_str, cutoff) {
	if (wpm_chart_instance) wpm_chart_instance.destroy();
	const elem = document.getElementById('wpm_chart');
	if (!elem) return;

	const today_str = get_local_date_string();
	const end_hour = date_str === today_str ? Math.min(new Date().getHours() + 1, 23) : cutoff + 1;
	const x_min = new Date(`${date_str}T${String(cutoff).padStart(2, '0')}:00:00`);
	const x_max = new Date(`${date_str}T${String(end_hour).padStart(2, '0')}:59:59`);

	wpm_chart_instance = new Chart(elem.getContext('2d'), {
		type: 'line',
		data: {
			datasets: [
				{
					label: _t('ui_typing.dataset_touches_5min'),
					data: pts,
					borderColor: `rgb(${color})`,
					backgroundColor: `rgba(${color}, 0.2)`,
					fill: true,
					tension: 0.2,
					pointRadius: 4
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom: ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallbackMinute5,
						label: (ctx) =>
							`${_t('ui_typing.lbl_activity')}\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0${_t('ui_typing.unit_keystrokes')}`
					}
				}
			},
			scales: {
				x: {
					type: 'time',
					min: x_min,
					max: x_max,
					time: { unit: 'minute', stepSize: 5, displayFormats: { minute: "H'h'mm" } },
					grid: { color: GRID_COLOR }
				},
				y: { beginAtZero: true, grid: { color: GRID_COLOR } }
			}
		}
	});
}

/**
 * Renders the 5-minute precision chart, reusing the precision canvas.
 * @param {Object[]} pts      - Data points { x: Date, y: accuracy_pct }.
 * @param {string}   color    - CSS RGB string for the line color.
 * @param {string}   date_str - ISO date string for the selected day.
 * @param {number}   cutoff   - First hour shown (> 0 in this path).
 */
function _render_minute5_precision_chart(pts, color, date_str, cutoff) {
	if (precision_chart_instance) precision_chart_instance.destroy();
	const elem = document.getElementById('precision_chart');
	if (!elem) return;

	const today_str = get_local_date_string();
	const end_hour = date_str === today_str ? Math.min(new Date().getHours() + 1, 23) : cutoff + 1;
	const x_min = new Date(`${date_str}T${String(cutoff).padStart(2, '0')}:00:00`);
	const x_max = new Date(`${date_str}T${String(end_hour).padStart(2, '0')}:59:59`);

	precision_chart_instance = new Chart(elem.getContext('2d'), {
		type: 'line',
		data: {
			datasets: [
				{
					label: 'Pr\u00E9cision (%)',
					data: pts,
					borderColor: `rgb(${color})`,
					backgroundColor: `rgba(${color}, 0.2)`,
					fill: true,
					tension: 0.2,
					pointRadius: 4
				}
			]
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom: ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallbackMinute5,
						label: (ctx) =>
							`Pr\u00E9cision\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0%`
					}
				}
			},
			scales: {
				x: {
					type: 'time',
					min: x_min,
					max: x_max,
					time: { unit: 'minute', stepSize: 5, displayFormats: { minute: "H'h'mm" } },
					grid: { color: GRID_COLOR }
				},
				y: {
					beginAtZero: false,
					min: 50,
					max: 100,
					ticks: { callback: (v) => v + '%' },
					grid: { color: 'rgba(128, 128, 128, 0.1)' }
				}
			}
		}
	});
}

// =================================================
// =================================================
// ======= 7/ Activity Calendar (year view) =======
// =================================================
// =================================================

/**
 * Renders a GitHub-style daily activity calendar : 7 rows (weekdays) × ~53
 * columns (weeks), one cell per day in the rolling last 12 months. Cell
 * intensity is a function of the day's manual character count, so the user
 * gets a glance-level view of which days were active and which were not.
 *
 * The calendar window is fixed to "today minus 364 days → today" regardless
 * of the date filter — a calendar IS a navigational view of all data, not a
 * slice of the currently-filtered data.
 */
function _render_activity_calendar() {
	const container = document.getElementById('activity_calendar_container');
	if (!container) return;

	const CELL = 12; // cell side in px
	const GAP = 3; // gap between cells
	const PAD_TOP = 18; // space for month labels
	const PAD_LEFT = 28; // space for weekday labels
	const ROWS = 7; // Mon..Sun
	const DAYS = 365; // 52*7 + 1 — covers a full year

	// Build the full date map from the manifest so the calendar shows historical
	// days even when they're not currently in the filter selection.
	const date_chars = {};
	if (window.metrics_manifest) {
		Object.keys(window.metrics_manifest).forEach((date_str) => {
			let total = 0;
			Object.values(window.metrics_manifest[date_str] || {}).forEach((app) => {
				total += app.chars || 0;
			});
			date_chars[date_str] = total;
		});
	}
	if (app_state.today_live_data) {
		const today = get_local_date_string();
		let total = 0;
		Object.values(app_state.today_live_data).forEach((app) => {
			total += app.chars || 0;
		});
		date_chars[today] = (date_chars[today] || 0) + total;
	}

	const today = new Date();
	today.setHours(12, 0, 0, 0);
	const start = new Date(today.getTime() - (DAYS - 1) * 86400_000);
	// Start the grid on the Monday of `start`'s week so columns align to weeks.
	const start_dow = (start.getDay() + 6) % 7; // 0 = Mon, 6 = Sun
	start.setDate(start.getDate() - start_dow);

	// Find the day max for color scale (gamma-compressed so big outliers don't
	// flatten everything else).
	let max_chars = 0;
	Object.values(date_chars).forEach((n) => {
		if (n > max_chars) max_chars = n;
	});
	const heat_color = (n) => {
		if (n <= 0) return 'rgba(255, 255, 255, 0.04)';
		const t = Math.pow(n / Math.max(1, max_chars), 0.5);
		const r = Math.round(34 + t * (74 - 34));
		const g = Math.round(70 + t * (222 - 70));
		const b = Math.round(54 + t * (128 - 54));
		return `rgb(${r}, ${g}, ${b})`;
	};

	const fr_date = (d) =>
		d.toLocaleDateString('fr-FR', {
			weekday: 'long',
			day: 'numeric',
			month: 'long',
			year: 'numeric'
		});
	const iso_date = (d) =>
		`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

	let cells = '';
	let month_labels = '';
	let last_month = -1;
	const cursor = new Date(start);
	let col = 0;
	while (cursor <= today) {
		const dow = (cursor.getDay() + 6) % 7; // 0 = Mon
		if (dow === 0 && col > 0) col++; // new column at start of each week
		// Actually the simplest: increment column when we hit Monday OR the very first iteration
		const x = PAD_LEFT + col * (CELL + GAP);
		const y = PAD_TOP + dow * (CELL + GAP);
		const date_str = iso_date(cursor);
		const n = date_chars[date_str] || 0;
		const fill = heat_color(n);
		const tip = `${fr_date(cursor)} — ${n === 0 ? _t('ui_typing.calendar_no_keystrokes') : format_number(n) + ' ' + _t('ui_typing.calendar_chars')}`;
		cells += `<rect x="${x}" y="${y}" width="${CELL}" height="${CELL}" rx="2" fill="${fill}"><title>${tip}</title></rect>`;

		// Month label appears once at the start of each new month
		if (cursor.getMonth() !== last_month && dow === 0) {
			const month_short = [
				_t('ui_typing.calendar_month_0'),
				_t('ui_typing.calendar_month_1'),
				_t('ui_typing.calendar_month_2'),
				_t('ui_typing.calendar_month_3'),
				_t('ui_typing.calendar_month_4'),
				_t('ui_typing.calendar_month_5'),
				_t('ui_typing.calendar_month_6'),
				_t('ui_typing.calendar_month_7'),
				_t('ui_typing.calendar_month_8'),
				_t('ui_typing.calendar_month_9'),
				_t('ui_typing.calendar_month_10'),
				_t('ui_typing.calendar_month_11')
			][cursor.getMonth()];
			month_labels += `<text x="${x}" y="${PAD_TOP - 6}" font-size="10" fill="var(--text-muted, #888)">${month_short}</text>`;
			last_month = cursor.getMonth();
		}

		cursor.setDate(cursor.getDate() + 1);
		if ((cursor.getDay() + 6) % 7 === 0) col++;
	}

	const weekday_labels = [_t('ui_typing.calendar_day_mon'), _t('ui_typing.calendar_day_wed'), _t('ui_typing.calendar_day_fri')]
		.map(
			(lbl, i) =>
				`<text x="0" y="${PAD_TOP + i * 2 * (CELL + GAP) + CELL - 2}" font-size="9" fill="var(--text-muted, #888)">${lbl}</text>`
		)
		.join('');

	const total_cols = col + 1;
	const svg_w = PAD_LEFT + total_cols * (CELL + GAP);
	const svg_h = PAD_TOP + ROWS * (CELL + GAP);

	let total_chars = 0,
		active_days = 0;
	Object.values(date_chars).forEach((n) => {
		if (n > 0) {
			total_chars += n;
			active_days++;
		}
	});

	container.innerHTML =
		`<div style="background:var(--panel-bg);border:1px solid var(--border);border-radius:10px;padding:12px 14px;">` +
		`<div style="display:flex;align-items:baseline;justify-content:space-between;margin-bottom:8px;">` +
		`<h3 style="margin:0;font-size:14px;color:var(--text-color);">${_t('ui_typing.calendar_title')} <span style="color:var(--text-muted);font-weight:normal;font-size:12px;">— ${_t('ui_typing.calendar_subtitle')}</span></h3>` +
		`<span style="font-size:11px;color:var(--text-muted);">${active_days} ${_t('ui_typing.calendar_active_days')} · ${format_number(total_chars)} ${_t('ui_typing.calendar_chars')}</span>` +
		`</div>` +
		`<svg width="${svg_w}" height="${svg_h}" xmlns="http://www.w3.org/2000/svg" style="display:block;max-width:100%;">` +
		weekday_labels +
		month_labels +
		cells +
		`</svg></div>`;
}

// ===================================================
// ===================================================
// ======= 8/ Hour × Weekday Heatmap =======
// ===================================================
// ===================================================

/**
 * Renders a 7×24 heatmap of typing volume by weekday and hour, aggregated
 * over the user-selected date range. The cell intensity is the total number
 * of manual characters typed in that (weekday, hour) slot — so a cell at
 * "Wednesday 21:00" reflects every Wednesday in the range, not a single one.
 *
 * Useful to spot productivity rhythms (e.g. "I type the most on Tuesday
 * afternoons but rarely after 22:00") that the time series doesn't show.
 */
function _render_hour_weekday_heatmap() {
	const container = document.getElementById('hour_weekday_heatmap_container');
	if (!container) return;

	const start_val = document.getElementById('date_start')?.value;
	const end_val = document.getElementById('date_end')?.value;

	// matrix[weekday][hour] = total chars
	const matrix = Array.from({ length: 7 }, () => Array.from({ length: 24 }, () => 0));
	let max_cell = 0;

	const accumulate_day = (date_str, app_data_map) => {
		const d = new Date(date_str + 'T12:00:00');
		const dow = (d.getDay() + 6) % 7; // 0 = Mon, 6 = Sun
		Object.values(app_data_map || {}).forEach((app) => {
			if (!app || !app.hourly) return;
			Object.entries(app.hourly).forEach(([h_str, hd]) => {
				const h = parseInt(h_str, 10);
				if (isNaN(h)) return;
				const c = hd.c || 0;
				matrix[dow][h] += c;
				if (matrix[dow][h] > max_cell) max_cell = matrix[dow][h];
			});
		});
	};

	if (window.metrics_manifest) {
		Object.keys(window.metrics_manifest).forEach((date_str) => {
			if (start_val && date_str < start_val) return;
			if (end_val && date_str > end_val) return;
			accumulate_day(date_str, window.metrics_manifest[date_str]);
		});
	}
	if (app_state.today_live_data) {
		const today = get_local_date_string();
		const today_in_range = (!start_val || today >= start_val) && (!end_val || today <= end_val);
		if (today_in_range) accumulate_day(today, app_state.today_live_data);
	}

	const CELL_W = 22,
		CELL_H = 18,
		GAP = 2;
	const PAD_LEFT = 36,
		PAD_TOP = 18;
	const SVG_W = PAD_LEFT + 24 * (CELL_W + GAP) + 4;
	const SVG_H = PAD_TOP + 7 * (CELL_H + GAP) + 4;

	const heat_color = (n) => {
		if (n <= 0) return 'rgba(255, 255, 255, 0.04)';
		const t = Math.pow(n / max_cell, 0.45);
		const r = Math.round(30 + t * (245 - 30));
		const g = Math.round(64 + t * (158 - 64));
		const b = Math.round(175 + t * (11 - 175));
		return `rgb(${r}, ${g}, ${b})`;
	};

	const days_fr = [
		_t('ui_typing.heatmap_day_mon'),
		_t('ui_typing.heatmap_day_tue'),
		_t('ui_typing.heatmap_day_wed'),
		_t('ui_typing.heatmap_day_thu'),
		_t('ui_typing.heatmap_day_fri'),
		_t('ui_typing.heatmap_day_sat'),
		_t('ui_typing.heatmap_day_sun')
	];

	let cells = '';
	for (let dow = 0; dow < 7; dow++) {
		for (let h = 0; h < 24; h++) {
			const x = PAD_LEFT + h * (CELL_W + GAP);
			const y = PAD_TOP + dow * (CELL_H + GAP);
			const n = matrix[dow][h];
			const tip = `${days_fr[dow]} ${String(h).padStart(2, '0')}h — ${n === 0 ? _t('ui_typing.heatmap_hour_no_keystrokes') : format_number(n) + ' ' + _t('ui_typing.heatmap_hour_chars_abbrev')}`;
			cells += `<rect x="${x}" y="${y}" width="${CELL_W}" height="${CELL_H}" rx="2" fill="${heat_color(n)}"><title>${tip}</title></rect>`;
		}
	}
	const day_labels = days_fr
		.map(
			(lbl, i) =>
				`<text x="0" y="${PAD_TOP + i * (CELL_H + GAP) + CELL_H - 4}" font-size="10" fill="var(--text-muted, #888)">${lbl}</text>`
		)
		.join('');
	const hour_labels = [];
	for (let h = 0; h < 24; h += 3) {
		const x = PAD_LEFT + h * (CELL_W + GAP) + CELL_W / 2;
		hour_labels.push(
			`<text x="${x}" y="${PAD_TOP - 6}" font-size="9" fill="var(--text-muted, #888)" text-anchor="middle">${String(h).padStart(2, '0')}h</text>`
		);
	}

	let total_chars = 0;
	for (let i = 0; i < 7; i++) for (let j = 0; j < 24; j++) total_chars += matrix[i][j];

	container.innerHTML =
		`<div style="background:var(--panel-bg);border:1px solid var(--border);border-radius:10px;padding:12px 14px;">` +
		`<div style="display:flex;align-items:baseline;justify-content:space-between;margin-bottom:8px;">` +
		`<h3 style="margin:0;font-size:14px;color:var(--text-color);">${_t('ui_typing.heatmap_hour_title')} <span style="color:var(--text-muted);font-weight:normal;font-size:12px;">— ${_t('ui_typing.heatmap_hour_subtitle')}</span></h3>` +
		`<span style="font-size:11px;color:var(--text-muted);">${format_number(total_chars)} ${_t('ui_typing.heatmap_hour_total')}</span>` +
		`</div>` +
		`<svg width="${SVG_W}" height="${SVG_H}" xmlns="http://www.w3.org/2000/svg" style="display:block;max-width:100%;">` +
		day_labels +
		hour_labels.join('') +
		cells +
		`</svg></div>`;
}
