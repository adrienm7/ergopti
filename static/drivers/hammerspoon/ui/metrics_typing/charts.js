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


// ====================================
// ====================================
// ======= 1/ Main Chart Render =======
// ====================================
// ====================================

/**
 * Renders (or re-renders) the delegation, WPM, and precision chart canvases
 * using the current time_series data in app_state. When the selected range spans
 * exactly one day, precision and speed charts switch to hourly granularity using
 * app_state.hourly_series — far more informative than a single daily data point.
 */
function render_charts() {
	if (typeof Chart === "undefined") return;

	const root    = getComputedStyle(document.documentElement);
	const rgb_ia  = root.getPropertyValue("--kpi-llm-rgb").trim()        || "122, 54, 163";
	const rgb_hs  = root.getPropertyValue("--kpi-hs-rgb").trim()         || "204, 41, 34";
	const rgb_man = root.getPropertyValue("--kpi-delegation-rgb").trim() || "0, 86, 179";
	const rgb_wpm = root.getPropertyValue("--chart-wpm-rgb").trim()      || "230, 140, 0";
	const rgb_prc = root.getPropertyValue("--kpi-precision-rgb").trim()  || "33, 136, 56";

	const sorted_keys = Object.keys(app_state.time_series).sort();
	const manual_pts  = [], hs_pts = [], llm_pts = [], wpm_pts = [];
	const hs_sp_pts   = [], llm_sp_pts = [];

	sorted_keys.forEach((k) => {
		const d        = app_state.time_series[k];
		const date_obj = new Date(k + "T12:00:00");

		manual_pts.push({ x: date_obj, y: Math.max(0, d.chars - d.hs_chars - d.llm_chars) });
		hs_pts.push(     { x: date_obj, y: d.hs_chars  });
		llm_pts.push(    { x: date_obj, y: d.llm_chars });

		if (d.chars > 0) {
			hs_sp_pts.push(  { x: date_obj, y: (d.hs_chars  / d.chars) * 100 });
			llm_sp_pts.push( { x: date_obj, y: (d.llm_chars / d.chars) * 100 });
		}

		const wpm = d.wpm_chars >= 10 && d.time_ms > 0 ? d.wpm_chars / 5 / (d.time_ms / 60000) : 0;
		if (!isNaN(wpm) && wpm > 0) wpm_pts.push({ x: date_obj, y: wpm });
	});

	// Shared x-axis range so precision and speed charts always have identical bounds
	const x_min = sorted_keys.length > 0 ? new Date(sorted_keys[0]          + "T12:00:00") : null;
	const x_max = sorted_keys.length > 0 ? new Date(sorted_keys.at(-1) + "T12:00:00") : null;

	// Delegation chart always uses daily points — no per-hour HS/LLM breakdown available
	_render_delegation_chart(manual_pts, hs_pts, llm_pts, rgb_ia, rgb_hs, rgb_man);
	_render_sparklines(hs_sp_pts, llm_sp_pts, rgb_hs, rgb_ia);

	// Single-day view: use hourly_series for precision and activity charts so the
	// user sees an intra-day curve instead of a single meaningless dot.
	if (sorted_keys.length === 1) {
		_render_hourly_charts(sorted_keys[0], rgb_wpm, rgb_prc);
	} else {
		// Restore daily titles in case they were previously changed by an hourly view
		const wpm_title_el = document.getElementById("wpm_chart_title");
		if (wpm_title_el) wpm_title_el.textContent = "Vitesse (MPM)";
		const prc_title_el = document.getElementById("precision_chart_title");
		if (prc_title_el) prc_title_el.textContent = "Précision (%)";

		_render_wpm_chart(wpm_pts, rgb_wpm, x_min, x_max);
		_render_precision_chart(sorted_keys, rgb_prc, x_min, x_max);
	}
}

/**
 * Resets the zoom on a named chart instance back to the default view.
 * @param {string} chart_id - "delegation", "wpm", or "precision".
 */
function reset_chart_zoom(chart_id) {
	if (chart_id === "delegation" && delegation_chart_instance) delegation_chart_instance.resetZoom();
	if (chart_id === "wpm"        && wpm_chart_instance)        wpm_chart_instance.resetZoom();
	if (chart_id === "precision"  && precision_chart_instance)  precision_chart_instance.resetZoom();
}


// =====================================================
// =====================================================
// ======= 2/ Individual Chart Builder Helpers =======
// =====================================================
// =====================================================

const ZOOM_OPTIONS = {
	pan:  { enabled: false },
	zoom: {
		wheel: { enabled: true, modifierKey: "ctrl" },
		pinch: { enabled: true },
		mode:  "x",
	},
};

const GRID_COLOR = "rgba(128,128,128,0.2)";

// French day names used by the x-axis tick formatter below
const DAYS_FR = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"];

/**
 * Returns a two-line French day tick label for a daily x-axis value.
 * Used with ticks.color: "transparent" so Chart.js reserves the correct two-line
 * height while the DAY_TICK_RENDERER plugin redraws the text with bold dates.
 * @param {number} value - Timestamp in milliseconds.
 * @returns {string[]} [dayName, "dd/mm/yyyy"]
 */
function _format_day_tick(value) {
	const d    = new Date(value);
	const dd   = String(d.getDate()).padStart(2, "0");
	const mm   = String(d.getMonth() + 1).padStart(2, "0");
	const yyyy = d.getFullYear();
	return [DAYS_FR[d.getDay()], `${dd}/${mm}/${yyyy}`];
}

// Canvas IDs of daily charts that use the two-line day+date tick renderer.
// Identified by canvas ID to avoid adding unknown properties to Chart.js options objects,
// which can interfere with Chart.js 4's internal option resolution pipeline.
const DAY_TICK_CANVAS_IDS = new Set([
	"delegation_chart", "wpm_chart", "precision_chart",
	"hs_sparkline", "llm_sparkline",
]);

// Plugin: redraws daily x-axis tick labels as two lines — day name (normal) + date (bold).
// Charts in DAY_TICK_CANVAS_IDS must also set ticks.color: "transparent" so Chart.js
// reserves two-line height without drawing its own unstyled labels.
if (typeof Chart !== "undefined") {
	Chart.register({
		id: "day_tick_renderer",
		afterDraw(chart) {
			const xScale = chart.scales.x;
			if (!xScale || !DAY_TICK_CANVAS_IDS.has(chart.canvas?.id)) return;

			const ctx   = chart.ctx;
			const ticks = xScale.ticks;
			if (!ticks?.length) return;

			const tick_opts = xScale.options.ticks || {};
			const font_cfg  = tick_opts.font || {};
			// Read font size from the scale config (sparklines use 10, main charts default to 12)
			const size  = (typeof font_cfg === "object" ? font_cfg.size : null) || 12;
			const pad   = typeof tick_opts.padding === "number" ? tick_opts.padding : 3;
			const lh    = Math.round(size * 1.2);
			const color = Chart.defaults.color || "rgba(0,0,0,0.6)";

			// xScale.top = bottom of the plot area (axis line level); tick labels start just below it
			const y1 = xScale.top + pad + 1;
			const y2 = y1 + lh;

			ctx.save();
			ctx.textAlign    = "center";
			ctx.textBaseline = "top";
			ctx.fillStyle    = color;

			ticks.forEach((tick, i) => {
				const x = xScale.getPixelForTick(i);
				const d = new Date(tick.value);
				const dd   = String(d.getDate()).padStart(2, "0");
				const mm   = String(d.getMonth() + 1).padStart(2, "0");
				const yyyy = d.getFullYear();

				// Line 1 — day name, normal weight
				ctx.font = `${size}px sans-serif`;
				ctx.fillText(DAYS_FR[d.getDay()], x, y1);

				// Line 2 — date, bold
				ctx.font = `bold ${size}px sans-serif`;
				ctx.fillText(`${dd}/${mm}/${yyyy}`, x, y2);
			});

			ctx.restore();
		},
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
	const elem = document.getElementById("delegation_chart");
	if (!elem) return;

	delegation_chart_instance = new Chart(elem.getContext("2d"), {
		type: "line",
		data: {
			datasets: [
				{
					label: "IA",
					data:  llm_pts,
					backgroundColor: `rgba(${rgb_ia}, 0.6)`,
					fill: true, tension: 0.2, pointRadius: 0, pointHitRadius: 10,
				},
				{
					label: "Hotstrings",
					data:  hs_pts,
					backgroundColor: `rgba(${rgb_hs}, 0.6)`,
					fill: true, tension: 0.2, pointRadius: 0, pointHitRadius: 10,
				},
				{
					label: "Manuelles",
					data:  manual_pts,
					backgroundColor: `rgba(${rgb_man}, 0.3)`,
					fill: true, tension: 0.2, pointRadius: 0, pointHitRadius: 10,
				},
			],
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			interaction: { mode: "index", intersect: false },
			plugins: {
				legend: { display: true },
				zoom:   ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallback,
						// format_number_plain avoids raw HTML in the tooltip (Chart.js renders labels as plain text)
					label: (ctx) => `${ctx.dataset.label} : ${format_number_plain(Math.round(ctx.parsed.y))} touches`,
					},
				},
			},
			scales: {
				x: {
					type:    "time",
					time:    { unit: "day" },
					stacked: true,
					grid:    { color: GRID_COLOR },
					// color: transparent hides Chart.js auto-labels; the plugin redraws them with bold dates
					ticks:   { color: "transparent", callback: (v) => _format_day_tick(v) },
				},
				y: { stacked: true, grid: { color: GRID_COLOR } },
			},
		},
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
	const elem = document.getElementById("wpm_chart");
	if (!elem) return;

	const x_opts = { type: "time", time: { unit: "day" }, grid: { color: GRID_COLOR },
		ticks: { color: "transparent", callback: (v) => _format_day_tick(v) } };
	if (x_min) x_opts.min = x_min;
	if (x_max) x_opts.max = x_max;

	wpm_chart_instance = new Chart(elem.getContext("2d"), {
		type: "line",
		data: {
			datasets: [{
				label:           "Vitesse",
				data:            wpm_pts,
				borderColor:     `rgb(${rgb_wpm})`,
				backgroundColor: `rgba(${rgb_wpm}, 0.2)`,
				fill: true, tension: 0.3, pointRadius: 3,
			}],
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom:   ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallback,
						label: (ctx) => `Vitesse : ${format_number_plain(Math.round(ctx.parsed.y))} MPM`,
					},
				},
			},
			scales: {
				x: x_opts,
				y: { beginAtZero: true, grid: { color: GRID_COLOR } },
			},
		},
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
	const elem = document.getElementById("precision_chart");
	if (!elem) return;

	// Skip days with no data and days with suspiciously low accuracy (<20%) which
	// indicate data artifacts (e.g., a session logged almost entirely as errors).
	const precision_pts = sorted_keys
		.filter(k => app_state.time_series[k].daily_chars > 0)
		.map((k) => {
			const d = app_state.time_series[k];
			const accuracy = ((d.daily_chars - d.daily_manual_errors) / d.daily_chars) * 100;
			return { x: new Date(k + "T12:00:00"), y: Math.max(0, Math.min(100, accuracy)) };
		})
		.filter(pt => pt.y >= 20);

	precision_chart_instance = new Chart(elem.getContext("2d"), {
		type: "line",
		data: {
			datasets: [{
				label:           "Précision (%)",
				data:            precision_pts,
				borderColor:     `rgb(${rgb_prc})`,
				backgroundColor: `rgba(${rgb_prc}, 0.2)`,
				fill: true, tension: 0.3, pointRadius: 3,
			}],
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom:   ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallback,
						label: (ctx) => `Pr\u00E9cision\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0%`,
					},
				},
			},
			scales: {
				x: Object.assign(
					{ type: "time", time: { unit: "day" }, grid: { color: GRID_COLOR },
					  ticks: { color: "transparent", callback: (v) => _format_day_tick(v) } },
					x_min ? { min: x_min } : {},
					x_max ? { max: x_max } : {}
				),
				y: {
					beginAtZero: true, min: 0, max: 100,
					ticks: { callback: (v) => v + "%" },
					grid:  { color: "rgba(128, 128, 128, 0.1)" },
				},
			},
		},
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
		"hs_sparkline", hs_sparkline_instance, hs_sp_pts, `rgb(${rgb_hs})`
	);
	llm_sparkline_instance = _render_sparkline(
		"llm_sparkline", llm_sparkline_instance, llm_sp_pts, `rgb(${rgb_ia})`
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

	return new Chart(elem.getContext("2d"), {
		type: "line",
		data: {
			datasets: [{
				data:        data_pts,
				borderColor: color,
				borderWidth: 2,
				tension:     0.3,
				pointRadius: 0,
			}],
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
						label: (ctx) => `Accept\u00E9es\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0%`,
					},
				},
			},
			scales: {
				x: {
					type:    "time",
					display: true,
					time:    { unit: "day" },
					ticks:   { font: { size: 10 }, maxTicksLimit: 4, color: "transparent", callback: (v) => _format_day_tick(v) },
					grid:    { display: false },
				},
				y: {
					display:     true,
					beginAtZero: true,
					ticks:       { font: { size: 10 }, maxTicksLimit: 3, callback: (v) => format_number_plain(v) + "%" },
					grid:        { color: "rgba(128, 128, 128, 0.1)" },
				},
			},
			layout: { padding: 0 },
		},
	});
}


// ====================================================
// ====================================================
// ======= 3/ Hourly Chart Helpers (single day) =======
// ====================================================
// ====================================================

/**
 * Tooltip title callback for hourly charts: shows "lundi 14/04 à 15h" instead
 * of a full date, since the day is already known when in single-day mode.
 * @param {Array} context - Chart.js tooltip context array.
 * @returns {string} Hour-aware French-formatted label.
 */
const tooltipTitleCallbackHourly = (context) => {
	const days    = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"];
	const d       = new Date(context[0].parsed.x);
	const dayName = days[d.getDay()];
	const dd      = String(d.getDate()).padStart(2, "0");
	const mm      = String(d.getMonth() + 1).padStart(2, "0");
	const h       = d.getHours();
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
	const cutoff = typeof app_state.hour_cutoff === "number" ? app_state.hour_cutoff : 0;

	if (cutoff > 0) {
		// Last-hour preset: switch to 5-minute resolution for a detailed intra-hour view
		_render_minute5_charts(date_str, rgb_wpm, rgb_prc, cutoff);
		return;
	}

	const act_pts  = [];   // { x: Date, y: chars_count } — typing activity per hour
	const prec_pts = [];   // { x: Date, y: accuracy_pct }

	for (let h = 0; h < 24; h++) {
		const h_str = h.toString().padStart(2, "0");
		const hd    = app_state.hourly_series[h_str];
		if (!hd || hd.c === 0) continue;

		// Midpoint of the hour so the chart point sits in the centre of the slot
		const date_obj = new Date(`${date_str}T${h_str}:30:00`);
		act_pts.push({ x: date_obj, y: hd.c });

		const acc = ((hd.c - hd.e) / hd.c) * 100;
		prec_pts.push({ x: date_obj, y: Math.max(0, Math.min(100, acc)) });
	}

	// Update chart titles to reflect hourly context
	const wpm_title_el = document.getElementById("wpm_chart_title");
	if (wpm_title_el) wpm_title_el.textContent = "Activit\u00E9 (touches/h)";
	const prc_title_el = document.getElementById("precision_chart_title");
	if (prc_title_el) prc_title_el.textContent = "Pr\u00E9cision (%) \u2014 vue horaire";

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
	const elem = document.getElementById("wpm_chart");
	if (!elem) return;

	// For today, cap the right edge at the current hour + 1 so the user sees
	// a tight window around actual data rather than an empty stretch to midnight.
	const today_str  = get_local_date_string();
	const end_hour   = date_str === today_str ? Math.min(new Date().getHours() + 1, 23) : 23;
	const x_min = new Date(`${date_str}T${String(cutoff).padStart(2, "0")}:00:00`);
	const x_max = new Date(`${date_str}T${String(end_hour).padStart(2, "0")}:59:59`);

	wpm_chart_instance = new Chart(elem.getContext("2d"), {
		type: "line",
		data: {
			datasets: [{
				label:           "Touches/h",
				data:            pts,
				borderColor:     `rgb(${color})`,
				backgroundColor: `rgba(${color}, 0.2)`,
				fill: true, tension: 0.3, pointRadius: 4,
			}],
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom:   ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallbackHourly,
						label: (ctx) => `Activit\u00E9\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0touches`,
					},
				},
			},
			scales: {
				x: {
					type: "time",
					min:  x_min,
					max:  x_max,
					time: { unit: "hour", displayFormats: { hour: "H'h'" } },
					grid: { color: GRID_COLOR },
				},
				y: { beginAtZero: true, grid: { color: GRID_COLOR } },
			},
		},
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
	const elem = document.getElementById("precision_chart");
	if (!elem) return;

	// Same rationale as the activity chart: cap x_max at the current hour + 1 for today.
	const today_str_p  = get_local_date_string();
	const end_hour_p   = date_str === today_str_p ? Math.min(new Date().getHours() + 1, 23) : 23;
	const x_min = new Date(`${date_str}T${String(cutoff).padStart(2, "0")}:00:00`);
	const x_max = new Date(`${date_str}T${String(end_hour_p).padStart(2, "0")}:59:59`);

	precision_chart_instance = new Chart(elem.getContext("2d"), {
		type: "line",
		data: {
			datasets: [{
				label:           "Pr\u00E9cision (%)",
				data:            pts,
				borderColor:     `rgb(${color})`,
				backgroundColor: `rgba(${color}, 0.2)`,
				fill: true, tension: 0.3, pointRadius: 4,
			}],
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom:   ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallbackHourly,
						label: (ctx) => `Pr\u00E9cision\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0%`,
					},
				},
			},
			scales: {
				x: {
					type: "time",
					min:  x_min,
					max:  x_max,
					time: { unit: "hour", displayFormats: { hour: "H'h'" } },
					grid: { color: GRID_COLOR },
				},
				y: {
					beginAtZero: false, min: 50, max: 100,
					ticks: { callback: (v) => v + "%" },
					grid:  { color: "rgba(128, 128, 128, 0.1)" },
				},
			},
		},
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
	const days    = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"];
	const d       = new Date(context[0].parsed.x);
	const dayName = days[d.getDay()];
	const dd      = String(d.getDate()).padStart(2, "0");
	const mm      = String(d.getMonth() + 1).padStart(2, "0");
	const h       = d.getHours();
	const min     = String(d.getMinutes()).padStart(2, "0");
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
	const act_pts  = [];   // { x: Date, y: chars_count } per 5-min bucket
	const prec_pts = [];   // { x: Date, y: accuracy_pct }

	// Iterate the 5-minute buckets sorted so the chart line is always left-to-right
	const sorted_buckets = Object.keys(app_state.minute5_series).sort();
	sorted_buckets.forEach((bucket) => {
		const bh = parseInt(bucket.split(":")[0], 10);
		// Only show buckets at or after the cutoff hour
		if (bh < cutoff) return;

		const md = app_state.minute5_series[bucket];
		if (!md || md.c === 0) return;

		// Use the bucket start time as the data point x coordinate
		const date_obj = new Date(`${date_str}T${bucket}:00`);
		act_pts.push({ x: date_obj, y: md.c });

		const acc = ((md.c - md.e) / md.c) * 100;
		prec_pts.push({ x: date_obj, y: Math.max(0, Math.min(100, acc)) });
	});

	// Update chart titles for 5-minute context
	const wpm_title_el = document.getElementById("wpm_chart_title");
	if (wpm_title_el) wpm_title_el.textContent = "Activit\u00E9 (touches / 5\u00A0min)";
	const prc_title_el = document.getElementById("precision_chart_title");
	if (prc_title_el) prc_title_el.textContent = "Pr\u00E9cision (%) \u2014 vue 5\u00A0min";

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
	const elem = document.getElementById("wpm_chart");
	if (!elem) return;

	const today_str = get_local_date_string();
	const end_hour  = date_str === today_str ? Math.min(new Date().getHours() + 1, 23) : cutoff + 1;
	const x_min = new Date(`${date_str}T${String(cutoff).padStart(2, "0")}:00:00`);
	const x_max = new Date(`${date_str}T${String(end_hour).padStart(2, "0")}:59:59`);

	wpm_chart_instance = new Chart(elem.getContext("2d"), {
		type: "line",
		data: {
			datasets: [{
				label:           "Touches / 5\u00A0min",
				data:            pts,
				borderColor:     `rgb(${color})`,
				backgroundColor: `rgba(${color}, 0.2)`,
				fill: true, tension: 0.2, pointRadius: 4,
			}],
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom:   ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallbackMinute5,
						label: (ctx) => `Activit\u00E9\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0touches`,
					},
				},
			},
			scales: {
				x: {
					type: "time",
					min:  x_min,
					max:  x_max,
					time: { unit: "minute", stepSize: 5, displayFormats: { minute: "H'h'mm" } },
					grid: { color: GRID_COLOR },
				},
				y: { beginAtZero: true, grid: { color: GRID_COLOR } },
			},
		},
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
	const elem = document.getElementById("precision_chart");
	if (!elem) return;

	const today_str = get_local_date_string();
	const end_hour  = date_str === today_str ? Math.min(new Date().getHours() + 1, 23) : cutoff + 1;
	const x_min = new Date(`${date_str}T${String(cutoff).padStart(2, "0")}:00:00`);
	const x_max = new Date(`${date_str}T${String(end_hour).padStart(2, "0")}:59:59`);

	precision_chart_instance = new Chart(elem.getContext("2d"), {
		type: "line",
		data: {
			datasets: [{
				label:           "Pr\u00E9cision (%)",
				data:            pts,
				borderColor:     `rgb(${color})`,
				backgroundColor: `rgba(${color}, 0.2)`,
				fill: true, tension: 0.2, pointRadius: 4,
			}],
		},
		options: {
			responsive: true,
			maintainAspectRatio: false,
			plugins: {
				legend: { display: false },
				zoom:   ZOOM_OPTIONS,
				tooltip: {
					callbacks: {
						title: tooltipTitleCallbackMinute5,
						label: (ctx) => `Pr\u00E9cision\u00A0: ${format_number_plain(Math.round(ctx.parsed.y))}\u00A0%`,
					},
				},
			},
			scales: {
				x: {
					type: "time",
					min:  x_min,
					max:  x_max,
					time: { unit: "minute", stepSize: 5, displayFormats: { minute: "H'h'mm" } },
					grid: { color: GRID_COLOR },
				},
				y: {
					beginAtZero: false, min: 50, max: 100,
					ticks: { callback: (v) => v + "%" },
					grid:  { color: "rgba(128, 128, 128, 0.1)" },
				},
			},
		},
	});
}
