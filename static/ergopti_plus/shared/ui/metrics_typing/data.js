// ui/metrics_typing/data.js

/**
 * ==============================================================================
 * MODULE: Data Pipeline
 * DESCRIPTION:
 * Handles all data ingestion, transformation, and KPI computation for the
 * typing metrics dashboard. Bridges between the Lua-side manifest/SQLite data
 * and the frontend rendering modules.
 *
 * FEATURES & RATIONALE:
 * 1. WPM Bug Fix (pauses_raw): The previous formula subtracted a pause EVENT
 *    COUNT from the character count, which is dimensionally incorrect and
 *    caused WPM with hotstrings to equal WPM without hotstrings. The fix uses
 *    all typed characters divided by app.time (which already excludes think
 *    pauses as tracked by log_manager).
 * 2. KPI Isolation: compute_manifest_metrics() is the ONLY place that updates
 *    the global WPM/CPM KPI card. render_current_tab() must never touch it.
 * 3. Live Updates: receive_live_update() batches rapid updates via a 10ms
 *    timer to avoid thrashing the renderer during active typing.
 * 4. Pre-Fetch Fast Path: On first load, process_manifest() checks for
 *    window._prefetch_data injected by Lua and renders the table immediately,
 *    skipping the initial poll round-trip to the backend entirely.
 * 5. Source Mode: All KPIs and table data read source flags from
 *    get_source_mode_flags() (defined in filters.js) so that every number
 *    consistently reflects the selected "Sans Ergopti+ / + Hotstrings / + IA"
 *    view mode.
 * 6. Repetitions KPI: render_repetitions_kpi() counts 2-key same-character
 *    bigrams (e.g. "aa", "ll") in the current filtered data to show whether
 *    the user relies on the ★ repeat key or types doublings manually.
 * ==============================================================================
 */



// ===================================
// ===================================
// ======= 1/ N-Gram Merging =======
// ===================================
// ===================================
// ===================================
// ===================================

/**
 * Merges one source n-gram dictionary into a target accumulator, respecting
 * all active toggle filters (HS, LLM, manual, spaces, case-sensitivity).
 * @param {Object}  target         - The accumulator object to write into.
 * @param {Object}  source         - The source dictionary from the cache.
 * @param {boolean} case_sensitive - Whether to preserve original case.
 * @param {boolean} show_spaces    - Whether to include space characters.
 * @param {boolean} show_hs        - Whether to include hotstring-generated chars.
 * @param {boolean} show_llm       - Whether to include LLM-generated chars.
 * @param {boolean} show_manual    - Whether to include manually typed chars.
 * @param {string}  tab_name       - The current tab identifier (sc = shortcuts).
 */
function merge_dict(
	target,
	source,
	case_sensitive,
	show_spaces,
	show_hs,
	show_llm,
	show_manual,
	tab_name
) {
	if (!source || typeof source !== 'object') return;
	// sc/sc_bg/sc_tg/sc_qg/sc_pg entries are always real user actions — never filter by source mode
	const is_shortcuts_tab =
		tab_name === 'sc' ||
		tab_name === 'sc_bg' ||
		tab_name === 'sc_tg' ||
		tab_name === 'sc_qg' ||
		tab_name === 'sc_pg';

	Object.keys(source).forEach((k) => {
		// Fix potential mojibake BEFORE toLowerCase: Hammerspoon's json.encode may pass
		// raw UTF-8 bytes through evaluateJavaScript where each byte is treated as a
		// Latin-1 code point.
		// The UTF-8 encoding of NBSP (U+00A0) is [0xC2, 0xA0] → "Â\u00A0" (2 chars).
		// The UTF-8 encoding of NNBSP (U+202F) is [0xE2, 0x80, 0xAF] → "â\u0080¯" (3 chars).
		// CRITICAL: normalization must happen before toLowerCase() because toLowerCase()
		// converts U+00C2 ("Â") to U+00E2 ("â"), breaking the NBSP replacement pattern.
		// U+0080 (PAD control) never appears in legitimate typed text, making these safe.
		let display_k = k
			.replace(/\u00C2\u00A0/g, '\u00A0') // "Â" + NBSP → NBSP
			.replace(/\u00E2\u0080\u00AF/g, '\u202F'); // "â" + PAD + "¯" → NNBSP

		if (!case_sensitive) display_k = display_k.toLowerCase();

		// Normalize known control characters to their bracket-marker or space equivalents
		// so they pass the ctrl-char filters and render with proper chip labels in all tabs.
		// RS (0x1E) is used by some keylogger versions as a space placeholder.
		display_k = display_k
			.replace(/\x08/g, '[BS]')
			.replace(/\x09/g, '[TAB]')
			// LF (\x0A) was used by older keylogger builds; CR (\x0D) matches
			// some edge cases — both map to [ENTER] so historical data is handled.
			.replace(/[\x0A\x0D]/g, '[ENTER]')
			.replace(/\x1B/g, '[ESC]')
			.replace(/\x1E/g, ' ');

		// Only filter regular ASCII space — NBSP (U+00A0) and NNBSP (U+202F) are
		// distinct characters the user deliberately types (French typography) and
		// must never be hidden by the "masquer les espaces" toggle.
		// w_bg/w_tg/w_qg/w_pg keys use a space as a word separator, not as a typed character — exempt them.
		const is_word_ngram =
			tab_name === 'w_bg' || tab_name === 'w_tg' || tab_name === 'w_qg' || tab_name === 'w_pg';
		if (!show_spaces && !is_word_ngram && display_k.includes(' ')) return;

		const item = source[k];
		const total_c = item.c || 0;
		const hs_c = item.hs || 0;
		const llm_c = item.llm || 0;
		const other_c = item.o || 0;
		const manual_c = Math.max(0, total_c - hs_c - llm_c - other_c);

		let real_count;
		let filtered_hs = hs_c;
		let filtered_llm = llm_c;

		if (is_shortcuts_tab) {
			// Shortcuts are always shown without source filtering
			real_count = total_c;
		} else {
			filtered_hs = show_hs ? hs_c : 0;
			filtered_llm = show_llm ? llm_c : 0;
			real_count = (show_manual ? manual_c : 0) + filtered_hs + filtered_llm + other_c;
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
		target[display_k].synth_hs += filtered_hs;
		target[display_k].synth_llm += filtered_llm;
		target[display_k].synth_other += other_c;
	});
}

// ============================================
// ============================================
// ======= 2/ Manifest Processing & KPI =======
// ============================================
// ============================================

/**
 * Processes the manifest after it is injected by the Lua backend. On first
 * call applies the initial reset; on subsequent calls recomputes KPIs and
 * fetches updated n-gram data.
 */
function process_manifest() {
	if (Object.keys(window.metrics_manifest).length > 0) {
		app_state.manifest_dates_sorted = Object.keys(window.metrics_manifest).sort();

		const app_set = new Set();
		app_state.manifest_dates_sorted.forEach((date) => {
			Object.keys(window.metrics_manifest[date]).forEach((app_name) => {
				if (app_name !== 'Unknown') app_set.add(app_name);
			});
		});

		const prev_apps = new Set(app_state.available_apps);
		const had_all_selected =
			app_state.available_apps.length > 0 &&
			app_state.selected_apps.size === app_state.available_apps.length;

		app_state.available_apps = Array.from(app_set).sort((a, b) => a.localeCompare(b));

		// Preserve existing selection; add new apps if everything was selected before
		if (app_state.selected_apps.size === 0 || had_all_selected) {
			app_state.selected_apps.clear();
			app_state.available_apps.forEach((app) => app_state.selected_apps.add(app));
		} else {
			const next_sel = new Set();
			app_state.available_apps.forEach((app) => {
				if (app_state.selected_apps.has(app) || !prev_apps.has(app)) next_sel.add(app);
			});
			app_state.selected_apps = next_sel;
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

		// reset_filters() → apply_date_app_filters() → request_range_data() already set
		// window._lua_request. If Lua injected pre-fetched data alongside the manifest,
		// cancel that pending round-trip and render immediately with zero additional latency.
		if (window._prefetch_data) {
			window._lua_request = null;
			app_state.loading_data = false;
			receive_range_data(window._prefetch_data);
			window._prefetch_data = null;
		}
		return;
	}

	update_app_btn_text();
	compute_manifest_metrics();
	request_range_data();
	ensure_live_refresh();
}

/**
 * Computes and renders all manifest-level KPIs (global WPM, hotstring stats,
 * LLM stats, time-series data for charts). This is the ONLY function that
 * must write to the WPM KPI card — render_current_tab must never touch it.
 *
 * FIX: Removed the erroneous `- pauses_raw` subtraction from the WPM char
 * count. app.time already represents active typing time (think-pauses are
 * tracked separately by log_manager as think_time). Hotstring chars now
 * correctly increase WPM because more characters are produced in the same
 * active typing time.
 */
function compute_manifest_metrics() {
	app_state.time_series = {};
	app_state.hourly_series = {};
	app_state.minute5_series = {};
	for (let i = 0; i < 24; i++) {
		app_state.hourly_series[i.toString().padStart(2, '0')] = { c: 0, es: 0, e_buckets: {} };
	}

	let global_hs_triggers = 0;
	let global_llm_triggers = 0;
	let global_hs_suggested = 0;
	let global_llm_suggested = 0;

	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	const { show_manual, show_hs, show_llm, mpm_include_hs, mpm_include_llm } =
		get_source_mode_flags();

	const manifest_dates =
		app_state.manifest_dates_sorted.length > 0
			? app_state.manifest_dates_sorted
			: Object.keys(window.metrics_manifest).sort();

	manifest_dates.forEach((date_str) => {
		if (start_val && date_str < start_val) return;
		if (end_val && date_str > end_val) return;

		Object.keys(window.metrics_manifest[date_str]).forEach((app_name) => {
			if (app_name !== 'Unknown' && !app_state.selected_apps.has(app_name)) return;

			const app = window.metrics_manifest[date_str][app_name];

			if (!app_state.time_series[date_str]) {
				app_state.time_series[date_str] = {
					chars: 0,
					wpm_chars: 0,
					time_ms: 0,
					hs_chars: 0,
					llm_chars: 0,
					hs_input_chars: 0,
					llm_input_chars: 0,
					raw_chars: 0,
					output_chars: 0,
					daily_chars: 0,
					// daily_e_buckets[T] = manual backspaces with delay ≤ T. The precision
					// chart picks the bucket matching the UI pause-threshold slider.
					daily_e_buckets: {}
				};
			}

			// app.chars is already manual-only (Lua only increments it when not is_synthetic).
			// hs_chars / llm_chars are separate counters for synthetic expansions.
			// hs_input_chars / llm_input_chars: chars typed manually that were then consumed
			// by an HS/IA expansion (i.e. the trigger keystrokes).
			const manual_chars = app.chars || 0;
			const hs_chars_raw = app.hs_chars || 0;
			const llm_chars_raw = app.llm_chars || 0;
			const hs_input_raw = app.hs_input_chars || 0;
			const llm_input_raw = app.llm_input_chars || 0;

			// MPM/CPM: synthetic chars are added only when their toggle is active
			// (the "+ Hotstrings"/"+ IA" buttons truly add to the manual baseline).
			const mpm_hs = mpm_include_hs ? hs_chars_raw : 0;
			const mpm_llm = mpm_include_llm ? llm_chars_raw : 0;
			const effective_wpm_chars = manual_chars + mpm_hs + mpm_llm;
			// Volume displayed in the KPI text ("X touches tapées") — same logic
			const table_hs = show_hs ? hs_chars_raw : 0;
			const table_llm = show_llm ? llm_chars_raw : 0;
			const effective_volume_chars = manual_chars + table_hs + table_llm;

			// Always surface HS/LLM KPI cards regardless of toggle state
			global_hs_triggers += app.hs_triggers || 0;
			global_hs_suggested += app.hs_suggested || 0;
			global_llm_triggers += app.llm_triggers || 0;
			global_llm_suggested += app.llm_suggested || 0;

			const ts = app_state.time_series[date_str];
			// ts.chars    = volume for display (output view: all sources; raw-input view: triggers only)
			// ts.wpm_chars = output chars for MPM — always includes HS/LLM expansions
			ts.chars += effective_volume_chars;
			ts.wpm_chars += effective_wpm_chars;
			ts.time_ms += app.time || 0;
			ts.hs_chars += hs_chars_raw;
			ts.llm_chars += llm_chars_raw;
			ts.hs_input_chars += hs_input_raw;
			ts.llm_input_chars += llm_input_raw;
			ts.raw_chars += manual_chars;
			ts.output_chars += manual_chars + hs_chars_raw + llm_chars_raw - hs_input_raw - llm_input_raw;

			if (app.hourly) {
				Object.keys(app.hourly).forEach((hour) => {
					const hour_data = app.hourly[hour] || {};
					if (app_state.hourly_series[hour]) {
						app_state.hourly_series[hour].c += hour_data.c || 0;
						app_state.hourly_series[hour].es += hour_data.es || 0;
						// Merge bucketed manual-error counts so the hourly precision
						// chart honours the same UI threshold as the daily view.
						app_state.hourly_series[hour].e_buckets = app_state.hourly_series[hour].e_buckets || {};
						const src_eb = hour_data.e_buckets || {};
						Object.keys(src_eb).forEach((k) => {
							app_state.hourly_series[hour].e_buckets[k] =
								(app_state.hourly_series[hour].e_buckets[k] || 0) + (src_eb[k] || 0);
						});
					}
					ts.daily_chars += hour_data.c || 0;
					const src_eb = hour_data.e_buckets || {};
					Object.keys(src_eb).forEach((k) => {
						ts.daily_e_buckets[k] = (ts.daily_e_buckets[k] || 0) + (src_eb[k] || 0);
					});
				});
			}

			// 5-minute granularity — used by the last-hour chart preset
			if (app.hourly_min5) {
				Object.keys(app.hourly_min5).forEach((bucket) => {
					const md = app.hourly_min5[bucket] || {};
					if (!app_state.minute5_series[bucket]) {
						app_state.minute5_series[bucket] = { c: 0, es: 0, e_buckets: {} };
					}
					app_state.minute5_series[bucket].c += md.c || 0;
					app_state.minute5_series[bucket].es += md.es || 0;
					const src_eb = md.e_buckets || {};
					Object.keys(src_eb).forEach((k) => {
						app_state.minute5_series[bucket].e_buckets[k] =
							(app_state.minute5_series[bucket].e_buckets[k] || 0) + (src_eb[k] || 0);
					});
				});
			}
		});
	});

	// --- Aggregate totals and sparkline/chart data points ---
	const sorted_keys = Object.keys(app_state.time_series).sort();
	const hs_points = [],
		llm_points = [],
		wpm_points = [];
	let hs_chars_total = 0,
		llm_chars_total = 0;
	let global_chars = 0,
		global_time_ms = 0,
		wpm_chars_total = 0;
	let global_raw_chars = 0,
		global_output_chars = 0;

	sorted_keys.forEach((k) => {
		const d = app_state.time_series[k];
		hs_chars_total += d.hs_chars;
		llm_chars_total += d.llm_chars;
		global_chars += d.chars || 0;
		global_time_ms += d.time_ms || 0;
		wpm_chars_total += d.wpm_chars || 0;
		global_raw_chars += d.raw_chars || 0;
		global_output_chars += d.output_chars || 0;

		if (d.chars > 0) {
			hs_points.push({ x: new Date(k + 'T12:00:00'), y: (d.hs_chars / d.chars) * 100 });
			llm_points.push({ x: new Date(k + 'T12:00:00'), y: (d.llm_chars / d.chars) * 100 });
		}

		const day_wpm = d.wpm_chars >= 10 && d.time_ms > 0 ? d.wpm_chars / 5 / (d.time_ms / 60000) : 0;
		if (!isNaN(day_wpm) && day_wpm > 0) {
			wpm_points.push({ x: new Date(k + 'T12:00:00'), y: day_wpm });
		}
	});

	// --- Render HS KPI card ---
	document.getElementById('hs_loading').style.display = 'none';
	document.getElementById('hs_details').style.display = 'flex';
	document.getElementById('hs_val').innerHTML =
		`${format_number(global_hs_triggers)} <span class="stat-unit">activations</span>`;
	document.getElementById('hs_net_val').innerHTML = format_number(hs_chars_total);

	let hs_pct = global_hs_suggested > 0 ? (global_hs_triggers / global_hs_suggested) * 100 : 0;
	if (hs_pct > 100) hs_pct = 100;
	document.getElementById('hs_acc_pct').innerHTML = `${format_number(hs_pct.toFixed(1))}%`;
	document.getElementById('hs_acc_raw').innerHTML =
		`(${format_number(global_hs_triggers)} / ${format_number(global_hs_suggested)})`;
	document.getElementById('hs_trend').innerHTML = get_trend_svg(
		hs_points.map((p) => p.y).filter((y) => y > 0)
	);

	// --- Render LLM KPI card ---
	document.getElementById('llm_loading').style.display = 'none';
	document.getElementById('llm_details').style.display = 'flex';
	document.getElementById('llm_val').innerHTML =
		`${format_number(global_llm_triggers)} <span class="stat-unit">activations</span>`;
	document.getElementById('llm_net_val').innerHTML = format_number(llm_chars_total);

	let llm_pct = global_llm_suggested > 0 ? (global_llm_triggers / global_llm_suggested) * 100 : 0;
	if (llm_pct > 100) llm_pct = 100;
	document.getElementById('llm_acc_pct').innerHTML = `${format_number(llm_pct.toFixed(1))}%`;
	document.getElementById('llm_acc_raw').innerHTML =
		`(${format_number(global_llm_triggers)} / ${format_number(global_llm_suggested)})`;
	document.getElementById('llm_trend').innerHTML = get_trend_svg(
		llm_points.map((p) => p.y).filter((y) => y > 0)
	);

	// --- Render global WPM KPI card (ONLY place allowed to write this KPI) ---
	document.getElementById('wpm_trend').innerHTML = get_trend_svg(
		wpm_points.map((p) => p.y).filter((y) => y > 0)
	);

	const manifest_cpm = global_time_ms > 0 ? wpm_chars_total / (global_time_ms / 60000) : 0;
	const manifest_wpm = manifest_cpm / 5;

	const wpm_val_elem = document.getElementById('wpm_val');
	if (wpm_val_elem) {
		wpm_val_elem.innerHTML =
			`<div style="display:flex;flex-direction:column;justify-content:center;">` +
			`<div style="display:flex;align-items:center;gap:6px;">` +
			`<span>${format_number(manifest_wpm.toFixed(1))} <span class="stat-unit">${_t('ui_typing.unit_mpm')}</span></span>` +
			`<span class="tooltip stat-inline-tooltip">${INFO_SVG}<span class="tooltiptext">${_t('ui_typing.tooltip_mpm')}</span></span>` +
			`</div>` +
			`<div style="display:flex;align-items:center;gap:6px;font-size:0.65em;margin-top:5px;">` +
			`<span>${format_number(manifest_cpm.toFixed(0))} <span class="stat-unit">${_t('ui_typing.unit_cpm')}</span></span>` +
			`<span class="tooltip stat-inline-tooltip">${INFO_SVG}<span class="tooltiptext">${_t('ui_typing.tooltip_cpm_simple')}</span></span>` +
			`</div>` +
			`</div>`;
	}

	const global_details = document.getElementById('global_details');
	if (global_details) {
		global_details.innerHTML =
			`<div style="margin-top:5px;">` +
			`<strong style="color:var(--kpi-wpm-color);font-size:1.1em;">${format_number(global_raw_chars)}</strong>` +
			` <span class="stat-unit" style="font-size:0.9em;">${_t('ui_typing.cpm_unit_raw_chars')}</span>` +
			`</div>` +
			`<div style="margin-top:3px;">` +
			`<strong style="color:var(--kpi-wpm-color);font-size:1.1em;">${format_number(global_output_chars)}</strong>` +
			` <span class="stat-unit" style="font-size:0.9em;">${_t('ui_typing.cpm_unit_output_chars')}</span>` +
			`</div>`;
	}

	render_charts();
}

// ============================================
// ============================================
// ======= 3/ Local Filter Application =======
// ============================================
// ============================================

/**
 * Recomputes the global speed KPI (CPM/MPM) honestly using the precise
 * cache buckets emitted by the keylogger (time_buckets, credited_buckets,
 * hs_input_*_buckets, llm_input_*_buckets).
 *
 * Vocabulary
 * ──────────
 *   transition : a single inter-key delay actually counted in the active
 *                typing time (delay ≤ pause_thresh). The CPM credits one
 *                char per transition rather than one char per keystroke,
 *                which avoids two pathologies:
 *                  • single-char "bursts" (one keystroke whose delay is
 *                    excluded as a pause) would otherwise contribute
 *                    1 char and 0 ms → infinite CPM ;
 *                  • the structural off-by-one between N chars / N-1
 *                    inter-key delays would inflate every short burst.
 *                On long bursts this loses ≤ 1 % so it's invisible there.
 *   trigger    : a manual keystroke that was later consumed (deleted) by
 *                an HS or IA expansion. Both its char and its time must be
 *                excluded from the "pure manual" baseline, otherwise
 *                triggering an expansion would let the user "cheat" by
 *                getting credit for keys whose productivity is already
 *                accounted for by HS / IA.
 *
 * Formula at a given pause threshold T (looked up in the buckets)
 * ────────────────────────────────────────────────────────────────
 *   active_time   = time_buckets[T]                    ← Σ delays ≤ T
 *   active_trans  = credited_buckets[T]                ← #transitions ≤ T
 *   trig_time     = hs_input_time_buckets[T] + llm_input_time_buckets[T]
 *   trig_trans    = hs_input_credited_buckets[T] + llm_input_credited_buckets[T]
 *   pure_time     = active_time  - trig_time
 *   pure_trans    = active_trans - trig_trans
 *   add_HS  = show_hs  ? max(0, hs_chars  - hs_input_chars)  : 0
 *   add_IA  = show_llm ? max(0, llm_chars - llm_input_chars) : 0
 *   chars_total = pure_trans + add_HS + add_IA
 *   CPM = pure_time > 0 ? chars_total × 60000 / pure_time : 0
 *   MPM = CPM / 5
 *
 * Worked example: type "abc" with delays 100 ms, 100 ms (no pause), then
 * pause 30 s, then "d". At threshold 5 s:
 *   active_time = 100 + 100 = 200 ms (the 30 s pause is excluded)
 *   active_trans = 2  (we credit transitions, not chars: the 'd' has no
 *                      counted predecessor so it doesn't add a transition)
 *   pure_time = 200, pure_trans = 2 → CPM = 2 × 60000 / 200 = 600 CPM,
 *   which honestly reflects 200 ms / 2 keys = 100 ms / key = ~120 WPM.
 *
 * Worked example of the bias fix: alternate "type-pause-type-pause-…" with
 * every delay > pause_thresh. active_time = 0, active_trans = 0 →
 * chars_total = 0, denominator = 0 → CPM = 0 (we display 0, not ∞).
 */
function recompute_speed_kpi() {
	const pause_thresh =
		parseInt(document.getElementById('pause_threshold')?.value ?? '5000', 10) || 5000;
	const { show_hs, show_llm } = get_source_mode_flags();
	const bucket_key = pause_thresh_to_bucket_key(pause_thresh);

	// ── Collect totals from manifest for the selected date range ────────────
	const totals = {
		manual_chars: 0,
		hs_chars: 0,
		llm_chars: 0,
		hs_input_chars: 0,
		llm_input_chars: 0,
		// Cache buckets at the user-selected threshold
		active_time_ms: 0,
		active_trans: 0,
		trig_hs_time_ms: 0,
		trig_hs_trans: 0,
		trig_llm_time_ms: 0,
		trig_llm_trans: 0,
		// Fallback when buckets are absent (historical data pre-dating bucket
		// support, or data from a device that never wrote agg_app_day_buckets).
		// Uses app.time (active typing time as measured by log_manager) and
		// raw char counts, mirroring compute_manifest_metrics()'s formula.
		fallback_time_ms: 0,
		fallback_wpm_chars: 0
	};
	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	const manifest_dates =
		app_state.manifest_dates_sorted.length > 0
			? app_state.manifest_dates_sorted
			: Object.keys(window.metrics_manifest).sort();
	const accumulate = (app) => {
		const manual_c = app.chars || 0;
		const hs_c = app.hs_chars || 0;
		const llm_c = app.llm_chars || 0;
		totals.manual_chars += manual_c;
		totals.hs_chars += hs_c;
		totals.llm_chars += llm_c;
		totals.hs_input_chars += app.hs_input_chars || 0;
		totals.llm_input_chars += app.llm_input_chars || 0;
		totals.active_time_ms += app.time_buckets?.[bucket_key] || 0;
		totals.active_trans += app.credited_buckets?.[bucket_key] || 0;
		totals.trig_hs_time_ms += app.hs_input_time_buckets?.[bucket_key] || 0;
		totals.trig_hs_trans += app.hs_input_credited_buckets?.[bucket_key] || 0;
		totals.trig_llm_time_ms += app.llm_input_time_buckets?.[bucket_key] || 0;
		totals.trig_llm_trans += app.llm_input_credited_buckets?.[bucket_key] || 0;
		// Fallback accumulators — only for entries that have a measured app.time,
		// otherwise chars without a matching time denominator inflate CPM to absurdity.
		const entry_time = app.time || 0;
		if (entry_time > 0) {
			totals.fallback_time_ms += entry_time;
			totals.fallback_wpm_chars += manual_c + (show_hs ? hs_c : 0) + (show_llm ? llm_c : 0);
		}
	};
	manifest_dates.forEach((date_str) => {
		if (start_val && date_str < start_val) return;
		if (end_val && date_str > end_val) return;
		Object.keys(window.metrics_manifest[date_str] || {}).forEach((app_name) => {
			if (app_name !== 'Unknown' && !app_state.selected_apps.has(app_name)) return;
			accumulate(window.metrics_manifest[date_str][app_name]);
		});
	});
	const today_str = get_local_date_string();
	const today_in_range =
		(!start_val || today_str >= start_val) && (!end_val || today_str <= end_val);
	if (today_in_range && app_state.today_live_data) {
		Object.entries(app_state.today_live_data).forEach(([app_name, app_data]) => {
			if (app_name !== 'Unknown' && !app_state.selected_apps.has(app_name)) return;
			accumulate(app_data);
		});
	}

	const trig_time_ms = totals.trig_hs_time_ms + totals.trig_llm_time_ms;
	const trig_trans = totals.trig_hs_trans + totals.trig_llm_trans;
	const pure_time_ms = Math.max(0, totals.active_time_ms - trig_time_ms);
	const pure_trans = Math.max(0, totals.active_trans - trig_trans);
	const add_hs = show_hs ? Math.max(0, totals.hs_chars - totals.hs_input_chars) : 0;
	const add_llm = show_llm ? Math.max(0, totals.llm_chars - totals.llm_input_chars) : 0;
	const chars_total = pure_trans + add_hs + add_llm;

	// Guard against divide-by-zero. A small floor (1 ms) would let bogus 0-time
	// data emit a finite huge speed; explicit zero is more honest.
	// When bucket data is absent (agg_app_day_buckets not yet built for historical
	// entries), fall back to the app.time-based formula using only entries that
	// have a measured app.time (prevents chars-without-time inflating CPM to absurdity).
	// If no timing data at all is available, bail out without overwriting the value
	// already written by compute_manifest_metrics() — its estimate is better than 0.
	let output_cpm;
	if (pure_time_ms > 0 && chars_total > 0) {
		output_cpm = (chars_total * 60000) / pure_time_ms;
	} else if (totals.fallback_time_ms > 0 && totals.fallback_wpm_chars > 0) {
		output_cpm = totals.fallback_wpm_chars / (totals.fallback_time_ms / 60000);
	} else {
		// No timing data available — keep whatever compute_manifest_metrics() wrote
		return;
	}
	const output_wpm = output_cpm / 5;

	const wpm_val_elem = document.getElementById('wpm_val');
	if (!wpm_val_elem) return;

	const thresh_label =
		pause_thresh >= 99999000
			? _t('ui_typing.precision_no_filter')
			: pause_thresh >= 60000
				? `> ${pause_thresh / 60000} min`
				: `> ${pause_thresh / 1000} s`;
	const mode_label =
		show_hs && show_llm
			? _t('ui_typing.cpm_mode_hs_ai')
			: show_hs
				? _t('ui_typing.cpm_mode_hs')
				: show_llm
					? _t('ui_typing.cpm_mode_ai')
					: _t('ui_typing.cpm_mode_manual');
	const NBSP = String.fromCharCode(160);

	const using_fallback = pure_time_ms === 0 && totals.fallback_time_ms > 0;
	const formula_tooltip = using_fallback
		? `${mode_label} — ${_t('ui_typing.tooltip_cpm_simple')}`
		: _t('ui_typing.tooltip_cpm_formula')
			.replace('{mode}', mode_label)
			.replace('{pure_trans}', format_number(pure_trans))
			.replace('{thresh}', thresh_label)
			.replace('{add_hs}', show_hs ? `  • + HS : ${format_number(add_hs)} ${_t('ui_typing.tooltip_cpm_hs_chars')}<br>` : '')
			.replace('{add_llm}', show_llm ? `  • + IA : ${format_number(add_llm)} ${_t('ui_typing.tooltip_cpm_llm_chars')}<br>` : '')
			.replace('{chars_total}', format_number(chars_total));

	wpm_val_elem.innerHTML =
		`<div style="display:flex;flex-direction:column;justify-content:center;">` +
		`<div style="display:flex;align-items:center;gap:6px;">` +
		`<span>${format_number(output_wpm.toFixed(1))} <span class="stat-unit">${_t('ui_typing.unit_mpm')}</span></span>` +
		`<span class="tooltip stat-inline-tooltip">${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${formula_tooltip}</span></span>` +
		`</div>` +
		`<div style="display:flex;align-items:center;gap:6px;font-size:0.65em;margin-top:5px;">` +
		`<span>${format_number(output_cpm.toFixed(0))} <span class="stat-unit">${_t('ui_typing.unit_cpm')}</span></span>` +
		`<span class="tooltip stat-inline-tooltip">${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${formula_tooltip}</span></span>` +
		`</div>` +
		`</div>`;

	const global_details = document.getElementById('global_details');
	if (global_details) {
		const total_trig = totals.hs_input_chars + totals.llm_input_chars;
		const output_chars = totals.manual_chars + totals.hs_chars + totals.llm_chars - total_trig;
		global_details.innerHTML =
			`<div style="margin-top:5px;">` +
			`<strong style="color:var(--kpi-wpm-color);font-size:1.1em;">${format_number(totals.manual_chars)}</strong>` +
			` <span class="stat-unit" style="font-size:0.9em;">${_t('ui_typing.cpm_unit_raw_chars')}</span>` +
			`</div>` +
			`<div style="margin-top:3px;">` +
			`<strong style="color:var(--kpi-wpm-color);font-size:1.1em;">${format_number(output_chars)}</strong>` +
			` <span class="stat-unit" style="font-size:0.9em;">${_t('ui_typing.cpm_unit_output_chars')}</span>` +
			`</div>`;
	}
}

/**
 * Applies all active toggle filters to the cached n-gram data and
 * re-renders the current table. Called after data fetch completes or when
 * a toggle filter changes.
 */
function apply_local_filters() {
	if (!app_state.historical_cache && !app_state.today_live_data) return;

	app_state.data = {
		c: {},
		bg: {},
		tg: {},
		qg: {},
		pg: {},
		hx: {},
		hp: {},
		w: {},
		sc: {},
		sc_bg: {},
		sc_tg: {},
		sc_qg: {},
		sc_pg: {},
		w_bg: {},
		w_tg: {},
		w_qg: {},
		w_pg: {},
		kc: {}
	};

	const { show_manual, show_hs, show_llm } = get_source_mode_flags();
	const show_spaces = true; // Espaces toujours visibles (bouton supprimé)
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

	// Merge today's live data if it falls within the selected date range
	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	const today_str = get_local_date_string();

	let include_today = true;
	if (start_val && today_str < start_val) include_today = false;
	if (end_val && today_str > end_val) include_today = false;

	if (include_today && app_state.today_live_data) {
		Object.keys(app_state.today_live_data).forEach((app_name) => {
			// Register newly seen apps from live data
			if (app_name !== 'Unknown' && !app_state.available_apps.includes(app_name)) {
				app_state.available_apps.push(app_name);
				app_state.available_apps.sort((a, b) => a.localeCompare(b));
				app_state.selected_apps.add(app_name);
				update_app_btn_text();
			}

			if (app_name !== 'Unknown' && !app_state.selected_apps.has(app_name)) return;

			const app_data = app_state.today_live_data[app_name];
			Object.keys(app_state.data).forEach((tab) => {
				merge_dict(
					app_state.data[tab],
					app_data[tab],
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

	render_repetitions_kpi();
	render_sfb_kpi();
	render_distance_kpi();
	render_avg_words_kpi();
	render_ergo_bigram_kpi();
	render_ergo_trigram_kpi();
	render_errors_kpi();
	render_roi_kpi();
	render_lexical_kpi();
	render_rhythm_kpi();
	render_sessions_kpi();
	render_records_kpi();
	render_charmix_kpi();
	render_apps_kpi();
	render_wellness_kpi();
	recompute_speed_kpi();
	render_current_tab();
}

// =============================================
// =============================================
// ======= 4/ Repetitions KPI Rendering =======
// =============================================
// =============================================

// Module-level state for the doublings detail table
let _rep_data = []; // [{key, total, manual, star}]
let _rep_sort_col = 'total'; // Active sort column
let _rep_sort_asc = false; // Ascending when true

/**
 * Counts 2-key same-character bigrams (e.g. "aa", "ll") in the current
 * filtered bigram data and renders the repetitions KPI card and detail table.
 * The count reflects the active source mode so the user can compare:
 *   "Sans Ergopti": only manual doublings (user typed "aa" by hand).
 *   "+ Hotstrings": also includes HS-generated doublings (user typed "a★").
 * This highlights whether the ★ repeat key is being used in practice.
 */
function render_repetitions_kpi() {
	const bg_dict = app_state.data.bg || {};
	const { show_hs } = get_source_mode_flags();
	let rep_count = 0;
	let rep_hs = 0;
	let total_count = 0;
	const doublings = [];

	Object.entries(bg_dict).forEach(([k, item]) => {
		const chars = Array.from(k);
		total_count += item.count || 0;
		// Bigram is a "doubling" when both grapheme clusters are identical
		if (chars.length === 2 && chars[0] === chars[1]) {
			const total = item.count || 0;
			// ★ via hotstring is only meaningful as a raw-mode metric — when show_hs is off
			// we are measuring final output text where ★ doublings are just normal doublings
			const star = show_hs ? item.synth_hs || 0 : 0;
			const manual = Math.max(0, total - star - (item.synth_llm || 0) - (item.synth_other || 0));
			rep_count += total;
			rep_hs += star;
			doublings.push({ key: k, total, manual, star });
		}
	});

	// Store for table re-sorting without re-fetching data
	_rep_data = doublings;

	const loading_el = document.getElementById('rep_loading');
	const details_el = document.getElementById('rep_details');
	if (loading_el) loading_el.style.display = 'none';
	if (details_el) details_el.style.display = 'flex';

	const rep_pct = total_count > 0 ? (rep_count / total_count) * 100 : 0;
	const rep_hs_pct = rep_count > 0 ? (rep_hs / rep_count) * 100 : 0;

	// % is the primary KPI — comparable across periods regardless of volume
	const val_el = document.getElementById('rep_val');
	if (val_el) {
		val_el.innerHTML =
			`<div style="display:flex;align-items:center;gap:6px;">` +
			`<span>${format_number(rep_pct.toFixed(1))}<span class="stat-unit">%</span></span>` +
			`<span class="tooltip stat-inline-tooltip" style="color:var(--kpi-rep-color);">${INFO_SVG}` +
			`<span class="tooltiptext">Part des bigrammes qui sont des redoublements (ex. « aa », « ll »). Réflète le mode source actif — comparez « Sans Ergopti+ » et « + Hotstrings » pour voir si la touche ★ est utilisée.</span>` +
			`</span></div>`;
	}

	// Raw count as secondary detail
	const pct_el = document.getElementById('rep_pct');
	if (pct_el) pct_el.innerHTML = `${format_number(rep_count)} ${_t('ui_typing.rep_doublings')}`;

	const hs_pct_el = document.getElementById('rep_hs_pct');
	if (hs_pct_el) hs_pct_el.innerHTML = `${format_number(rep_hs_pct.toFixed(1))}%`;

	const hs_raw_el = document.getElementById('rep_hs_raw');
	if (hs_raw_el) hs_raw_el.innerHTML = `(${format_number(rep_hs)})`;

	render_rep_table();
}

// ==========================================
// ===== 4.1) Doublings Table Rendering =====
// ==========================================

/**
 * Returns a sort direction indicator arrow for a column header cell.
 * @param {string} col         - The column identifier to label.
 * @param {string} active_col  - The currently active sort column.
 * @param {boolean} sort_asc   - Whether the current sort is ascending.
 * @returns {string} Unicode arrow string appended to the column title.
 */
function _sort_arrow(col, active_col, sort_asc) {
	if (col !== active_col) return '\u00A0\u2195';
	return sort_asc ? '\u00A0\u2191' : '\u00A0\u2193';
}

/**
 * Renders (or re-renders after a sort click) the doublings detail table inside
 * the repetitions expanded KPI block. Shows all same-character bigrams with
 * global count, manual count, and ★ (hotstring) count columns.
 */
function render_rep_table() {
	const container = document.getElementById('rep_doublings_container');
	if (!container) return;

	const sorted = [..._rep_data].sort((a, b) => {
		const va = a[_rep_sort_col];
		const vb = b[_rep_sort_col];
		if (typeof va === 'string') return _rep_sort_asc ? va.localeCompare(vb) : vb.localeCompare(va);
		return _rep_sort_asc ? va - vb : vb - va;
	});

	const h_key = `${_t('ui_typing.rep_table_bigram')}${_sort_arrow('key', _rep_sort_col, _rep_sort_asc)}`;
	const h_total = `${_t('ui_typing.rep_table_total')}${_sort_arrow('total', _rep_sort_col, _rep_sort_asc)}`;
	const h_manual = `${_t('ui_typing.rep_table_manual')}${_sort_arrow('manual', _rep_sort_col, _rep_sort_asc)}`;
	const h_star = `${_t('ui_typing.rep_table_via_star')}${_sort_arrow('star', _rep_sort_col, _rep_sort_asc)}`;

	let rows_html;
	if (sorted.length === 0) {
		rows_html = `<tr><td colspan="4" style="text-align:center;padding:12px;color:var(--text-muted);">${_t('ui_typing.rep_no_data')}</td></tr>`;
	} else {
		rows_html = sorted
			.map((d) => {
				const key_html = `<span class="seq-chips">${format_seq_chips(d.key)}</span>`;
				const star_html =
					d.star > 0
						? format_number(d.star)
						: `<span style="color:var(--text-muted)">\u2014</span>`;
				return `<tr>
				<td>${key_html}</td>
				<td style="text-align:right;font-variant-numeric:tabular-nums;">${format_number(d.total)}</td>
				<td style="text-align:right;font-variant-numeric:tabular-nums;">${format_number(d.manual)}</td>
				<td style="text-align:right;font-variant-numeric:tabular-nums;">${star_html}</td>
			</tr>`;
			})
			.join('');
	}

	container.innerHTML = `<table class="ekpi-table">
			<thead><tr>
				<th onclick="sort_rep_table('key')">${h_key}</th>
				<th onclick="sort_rep_table('total')" style="text-align:right">${h_total}</th>
				<th onclick="sort_rep_table('manual')" style="text-align:right">${h_manual}</th>
				<th onclick="sort_rep_table('star')" style="text-align:right">${h_star}</th>
			</tr></thead>
			<tbody>${rows_html}</tbody>
		</table>`;
}

/**
 * Handles a sort click on the doublings table header.
 * @param {string} col - The column to sort by: "key", "total", "manual", or "star".
 */
function sort_rep_table(col) {
	if (_rep_sort_col === col) {
		_rep_sort_asc = !_rep_sort_asc;
	} else {
		_rep_sort_col = col;
		_rep_sort_asc = col === 'key';
	}
	render_rep_table();
}

// ================================================
// ================================================
// ======= 4b/ Same-Finger Bigram KPI (SFB) =======
// ================================================
// ================================================

// Module-level state for the SFB detail table
let _sfb_data = []; // [{pair, count, kc_a, kc_b}]
let _sfb_sort_col = 'count';
let _sfb_sort_asc = false;
// Default true: same-key doublings (AA, BB…) are included — active by default.
// Two independent toggles so the headline KPI / table can be filtered without
// also affecting the heatmap (and vice versa); each has its own button.
let _sfb_include_same_key = true; // SFB block: KPI value, table, headline counts
let _sfb_heatmap_include_same_key = true; // SFB heatmap: per-key heat aggregation only
// Last-rendered SFB heatmap aggregates, kept around so the heatmap-only
// toggle can re-render without re-running the whole bigram scan.
let _sfb_heatmap_full = { sfb_by_kc: {}, sfb_pairs_by_kc: {} };
let _sfb_heatmap_same_only = { sfb_by_kc: {}, sfb_pairs_by_kc: {} };

/**
 * Builds an inverted map from character label → keycode string using the active layout.
 * Multi-character labels (e.g. "return") are excluded — only single-char keys matter for
 * bigram SFB detection since bg dict contains typed characters.
 * @returns {Object} Map of lowercase char → kc_str.
 */
function _build_char_to_kc_map() {
	const layout =
		window.keycode_layout && Object.keys(window.keycode_layout).length > 0
			? window.keycode_layout
			: KEYCODE_NAMES;
	const map = {};
	Object.entries(layout).forEach(([kc_str, label]) => {
		if (typeof label === 'string' && label.length === 1) {
			map[label.toLowerCase()] = kc_str;
		}
	});
	return map;
}

/**
 * Computes same-finger bigrams from app_state.data.bg by mapping each character to its
 * keycode via the active layout and checking whether both keys share a SFB_COLUMNS column.
 * Renders the SFB KPI card value, percentage, and detail table.
 * Called from apply_local_filters() on every filter change.
 */
function render_sfb_kpi() {
	// SFBs always reflect raw physical keystrokes — never HS/LLM output text.
	// Build a manual-only bg dict regardless of the current source mode toggles.
	const raw_bg = {};
	const merge_raw = (src) => {
		if (!src?.bg) return;
		merge_dict(raw_bg, src.bg, false, true, false, false, true, 'bg');
	};
	merge_raw(app_state.historical_cache);
	if (app_state.today_live_data) {
		const start_val = document.getElementById('date_start')?.value ?? '';
		const end_val = document.getElementById('date_end')?.value ?? '';
		const today_str = get_local_date_string();
		let include_today = true;
		if (start_val && today_str < start_val) include_today = false;
		if (end_val && today_str > end_val) include_today = false;
		if (include_today) {
			const selected = app_state.selected_apps;
			Object.entries(app_state.today_live_data).forEach(([app_name, app_data]) => {
				if (app_name !== 'Unknown' && !selected.has(app_name)) return;
				merge_dict(raw_bg, app_data?.bg, false, true, false, false, true, 'bg');
			});
		}
	}
	const bg_dict = raw_bg;
	const char_to_kc = _build_char_to_kc_map();
	const sfb_list = []; // [{pair, count, kc_a, kc_b}]
	const sfb_by_kc = {}; // kc_str → total SFB count involving that key
	const sfb_pairs_by_kc = {}; // kc_str → [{partner_kc, pair_label, count}]
	// Reset the same-key-only delta for this scan; it is module-level and
	// would otherwise accumulate across successive filter changes.
	_sfb_heatmap_same_only = { sfb_by_kc: {}, sfb_pairs_by_kc: {} };
	let sfb_total = 0;
	let bigram_total = 0;

	Object.entries(bg_dict).forEach(([k, item]) => {
		const chars = Array.from(k);
		if (chars.length !== 2) return;
		const count = item.count || 0;
		bigram_total += count;

		const kc_a = char_to_kc[chars[0].toLowerCase()];
		const kc_b = char_to_kc[chars[1].toLowerCase()];
		if (!kc_a || !kc_b) return;

		const col_a = SFB_COLUMNS[kc_a];
		const col_b = SFB_COLUMNS[kc_b];
		// Keys not assigned to a column (modifier-only or unmapped) are ignored
		if (!col_a || !col_b) return;
		// Thumb keys never produce SFBs — they produce space/modifiers, not content chars
		if (col_a.includes('thumb') || col_b.includes('thumb')) return;
		// SFB only when both chars share the same finger column
		if (col_a !== col_b) return;

		const is_same_key = kc_a === kc_b;

		// ── Heatmap aggregation: independent of the table toggle. We always
		// build BOTH the full map and the same-key-only delta so the
		// heatmap-only toggle can switch view without re-running this loop.
		sfb_by_kc[kc_a] = (sfb_by_kc[kc_a] || 0) + count;
		sfb_by_kc[kc_b] = (sfb_by_kc[kc_b] || 0) + count;
		if (!sfb_pairs_by_kc[kc_a]) sfb_pairs_by_kc[kc_a] = [];
		if (!sfb_pairs_by_kc[kc_b]) sfb_pairs_by_kc[kc_b] = [];
		sfb_pairs_by_kc[kc_a].push({ partner_kc: kc_b, pair_label: k, count });
		sfb_pairs_by_kc[kc_b].push({ partner_kc: kc_a, pair_label: k, count });
		if (is_same_key) {
			// Heatmap delta — subtracted at render time when the heatmap
			// toggle is "doublons exclus".
			_sfb_heatmap_same_only.sfb_by_kc[kc_a] =
				(_sfb_heatmap_same_only.sfb_by_kc[kc_a] || 0) + count;
		}

		// ── Table / headline KPI: respect the SFB-block toggle only ─────────
		if (!_sfb_include_same_key && is_same_key) return;

		sfb_total += count;
		const finger_fr = FINGER_LABELS_FR[col_a] || col_a;
		const fp = finger_fr.split(' ');
		const hand = fp[fp.length - 1];
		const finger = fp.slice(0, -1).join(' ');
		sfb_list.push({ pair: k, count, kc_a, kc_b, finger, hand });
	});

	// Cache the aggregates so the heatmap-only toggle can re-render without
	// running the entire bigram scan again.
	_sfb_heatmap_full = { sfb_by_kc, sfb_pairs_by_kc };

	// Compute SFBs avoided by hotstrings: count SFBs in the hs portion of the bg dict.
	// These are output bigrams the user never had to type physically thanks to hotstrings.
	const hs_bg = {};
	const merge_hs = (src) => {
		if (!src?.bg) return;
		merge_dict(hs_bg, src.bg, false, true, true, false, false, 'bg');
	};
	merge_hs(app_state.historical_cache);
	if (app_state.today_live_data) {
		const start_val2 = document.getElementById('date_start')?.value ?? '';
		const end_val2 = document.getElementById('date_end')?.value ?? '';
		const today_str2 = get_local_date_string();
		let include_today2 = true;
		if (start_val2 && today_str2 < start_val2) include_today2 = false;
		if (end_val2 && today_str2 > end_val2) include_today2 = false;
		if (include_today2) {
			const selected2 = app_state.selected_apps;
			Object.entries(app_state.today_live_data).forEach(([app_name, app_data]) => {
				if (app_name !== 'Unknown' && !selected2.has(app_name)) return;
				merge_dict(hs_bg, app_data?.bg, false, true, true, false, false, 'bg');
			});
		}
	}
	let sfb_avoided_hs = 0;
	let bg_hs_total = 0;
	Object.entries(hs_bg).forEach(([k, item]) => {
		const chars = Array.from(k);
		if (chars.length !== 2) return;
		const count = item.count || 0;
		bg_hs_total += count;
		const kc_a = char_to_kc[chars[0].toLowerCase()];
		const kc_b = char_to_kc[chars[1].toLowerCase()];
		if (!kc_a || !kc_b) return;
		const col_a2 = SFB_COLUMNS[kc_a];
		const col_b2 = SFB_COLUMNS[kc_b];
		if (!col_a2 || !col_b2) return;
		if (col_a2.includes('thumb') || col_b2.includes('thumb')) return;
		if (col_a2 !== col_b2) return;
		if (!_sfb_include_same_key && kc_a === kc_b) return;
		sfb_avoided_hs += count;
	});

	// Store for table re-sort without re-fetching data
	_sfb_data = sfb_list;

	const loading_el = document.getElementById('sfb_loading');
	const details_el = document.getElementById('sfb_details');
	if (loading_el) loading_el.style.display = 'none';
	if (details_el) details_el.style.display = 'flex';

	const val_el = document.getElementById('sfb_val');
	const sfb_pct = bigram_total > 0 ? (sfb_total / bigram_total) * 100 : 0;

	// Primary KPI: raw SFB rate with raw count below
	if (val_el) {
		val_el.innerHTML =
			`<div style="display:flex;align-items:center;gap:6px;">` +
			`<span>${format_number(sfb_pct.toFixed(1))}<span class="stat-unit">%</span></span>` +
			`<span class="tooltip stat-inline-tooltip" style="color:var(--kpi-sfb-color);">${INFO_SVG}` +
			`<span class="tooltiptext">Part des bigrammes manuels frappés par le même doigt. Hors hotstrings — ce KPI mesure la difficulté physique brute du layout.</span>` +
			`</span></div>`;
	}

	// Raw count + avoided count as secondary detail
	const pct_el = document.getElementById('sfb_pct');
	if (pct_el) pct_el.innerHTML = `${format_number(sfb_total)} ${_t('ui_typing.sfb_raw_count')}`;

	const avoided_el = document.getElementById('sfb_avoided');
	if (avoided_el) {
		const avoided_pct = bigram_total > 0 ? (sfb_avoided_hs / bigram_total) * 100 : 0;
		avoided_el.innerHTML =
			sfb_avoided_hs > 0
				? `${format_number(sfb_avoided_hs)} ${_t('ui_typing.sfb_avoided')} (${format_number(avoided_pct.toFixed(1))}%)`
				: _t('ui_typing.sfb_avoided_none');
	}

	// Render the SFB heatmap with its own toggle state (independent of the
	// SFB-block button above).
	_render_sfb_heatmap_with_toggle();

	render_sfb_table();
}

/**
 * Re-renders the SFB heatmap from the cached aggregates, applying the
 * heatmap-specific same-key toggle. When the toggle is OFF, subtracts the
 * same-key contributions from the full map so AA/BB no longer count.
 */
function _render_sfb_heatmap_with_toggle() {
	if (typeof render_sfb_heatmap !== 'function') return;
	const full = _sfb_heatmap_full || { sfb_by_kc: {}, sfb_pairs_by_kc: {} };
	if (_sfb_heatmap_include_same_key) {
		render_sfb_heatmap(full.sfb_by_kc, full.sfb_pairs_by_kc, app_state.data.kc || {});
		return;
	}
	// Subtract same-key deltas from the full map (each side of the pair was
	// the same key so we credit twice — count is doubled in sfb_by_kc).
	const adjusted = {};
	const same = (_sfb_heatmap_same_only && _sfb_heatmap_same_only.sfb_by_kc) || {};
	Object.entries(full.sfb_by_kc).forEach(([kc_str, n]) => {
		const dup = same[kc_str] || 0;
		const v = n - dup * 2;
		if (v > 0) adjusted[kc_str] = v;
	});
	// Filter pair lists too — drop any entry where partner_kc === kc itself
	const adjusted_pairs = {};
	Object.entries(full.sfb_pairs_by_kc).forEach(([kc_str, arr]) => {
		const filtered = arr.filter((p) => p.partner_kc !== kc_str);
		if (filtered.length > 0) adjusted_pairs[kc_str] = filtered;
	});
	render_sfb_heatmap(adjusted, adjusted_pairs, app_state.data.kc || {});
}

/**
 * Toggles the SFB heatmap-only same-key inclusion and re-renders.
 * Independent of toggle_sfb_same_key (which only affects the SFB block).
 */
function toggle_sfb_heatmap_same_key() {
	_sfb_heatmap_include_same_key = !_sfb_heatmap_include_same_key;
	const btn = document.getElementById('sfb_heatmap_same_key_btn');
	if (btn) {
		btn.classList.toggle('active', _sfb_heatmap_include_same_key);
		btn.textContent = _sfb_heatmap_include_same_key ? _t('ui_typing.btn_doublings_included') : _t('ui_typing.btn_doublings_excluded');
	}
	_render_sfb_heatmap_with_toggle();
}

// ============================================
// ===== 4b.1) SFB Detail Table Rendering =====
// ============================================

/**
 * Renders (or re-renders) the SFB detail table inside the SFB expanded KPI block.
 * Shows the top same-finger bigram pairs sorted by count.
 */
function render_sfb_table() {
	const container = document.getElementById('sfb_pairs_container');
	if (!container) return;

	const sorted = [..._sfb_data].sort((a, b) => {
		const va = a[_sfb_sort_col];
		const vb = b[_sfb_sort_col];
		if (typeof va === 'string') return _sfb_sort_asc ? va.localeCompare(vb) : vb.localeCompare(va);
		return _sfb_sort_asc ? va - vb : vb - va;
	});

	const h_pair = `${_t('ui_typing.sfb_table_pair')}${_sort_arrow('pair', _sfb_sort_col, _sfb_sort_asc)}`;
	const h_count = `${_t('ui_typing.rep_table_total')}${_sort_arrow('count', _sfb_sort_col, _sfb_sort_asc)}`;
	const h_finger = `${_t('ui_typing.sfb_table_finger')}${_sort_arrow('finger', _sfb_sort_col, _sfb_sort_asc)}`;
	const h_hand = `${_t('ui_typing.sfb_table_hand')}${_sort_arrow('hand', _sfb_sort_col, _sfb_sort_asc)}`;

	let rows_html;
	if (sorted.length === 0) {
		rows_html = `<tr><td colspan="4" style="text-align:center;padding:12px;color:var(--text-muted);">${_t('ui_typing.sfb_no_data')}</td></tr>`;
	} else {
		rows_html = sorted
			.slice(0, 200)
			.map((d) => {
				// finger and hand are pre-computed in render_sfb_kpi() for sortability
				// "doigt" / "main" share the same FINGER_LABELS_FR convention as the
				// distance card; strip the trailing G/D from the finger label since the
				// hand is already shown in its own column.
				const doigt_str = (d.finger || '').replace(/\s+[GD]$/, '');
				const main_str = d.hand || '';
				const pair_html = `<span class="seq-chips">${format_seq_chips(d.pair)}</span>`;
				return `<tr>
				<td>${pair_html}</td>
				<td style="text-align:right;font-variant-numeric:tabular-nums;">${format_number(d.count)}</td>
				<td style="color:var(--text-muted);">${escape_html(doigt_str)}</td>
				<td style="text-align:center;">${escape_html(main_str)}</td>
			</tr>`;
			})
			.join('');
	}

	container.innerHTML = `<table class="ekpi-table">
			<thead><tr>
				<th onclick="sort_sfb_table('pair')">${h_pair}</th>
				<th onclick="sort_sfb_table('count')" style="text-align:right">${h_count}</th>
				<th onclick="sort_sfb_table('finger')">${h_finger}</th>
				<th onclick="sort_sfb_table('hand')" style="text-align:center">${h_hand}</th>
			</tr></thead>
			<tbody>${rows_html}</tbody>
		</table>`;
}

/**
 * Handles a sort click on the SFB pairs table header.
 * @param {string} col - Column to sort by: "pair", "count", "finger", or "hand".
 */
function sort_sfb_table(col) {
	if (_sfb_sort_col === col) {
		_sfb_sort_asc = !_sfb_sort_asc;
	} else {
		_sfb_sort_col = col;
		_sfb_sort_asc = col === 'pair';
	}
	render_sfb_table();
}

/**
 * Toggles whether same-key doublings (AA, BB…) count as SFBs and re-renders.
 * Same-key repeats involve no lateral finger movement — excluding them gives a
 * purer measure of uncomfortable cross-key same-finger usage.
 */
function toggle_sfb_same_key() {
	_sfb_include_same_key = !_sfb_include_same_key;
	const btn = document.getElementById('sfb_same_key_btn');
	if (btn) {
		btn.classList.toggle('active', _sfb_include_same_key);
		btn.textContent = _sfb_include_same_key ? 'Doublons inclus' : 'Doublons exclus';
	}
	render_sfb_kpi();
}

// =================================================
// =================================================
// ======= 5/ Finger Distance KPI Rendering =======
// =================================================
// =================================================

// Module-level state for the finger distance detail table
let _dist_data = []; // [{finger, label, hand, km}]
let _dist_sort_col = 'km'; // Active sort column
let _dist_sort_asc = false; // Ascending when true

/**
 * Computes the total finger travel distance in km from the current filtered
 * keycode and bigram data, and renders the distance KPI card, the km sub-line
 * inside the WPM card, and the per-finger detail table.
 * Called from apply_local_filters() so it reacts to every source-mode change.
 *
 * Algorithm
 * ─────────
 * The naive "every keystroke = round-trip from home" formula overcounts when
 * the same finger types two keys in a row (e.g. "de" with the right index
 * across kc 2 and kc 7 would otherwise charge two full home-key round-trips
 * even though the finger goes home → d → e → home, not home → d → home →
 * e → home). We split the cost into three terms per finger F:
 *
 *   1. Burst start  : home → first_key, charged once per "burst" of
 *                     consecutive F-keystrokes.
 *   2. Transitions  : key_a → key_b for every pair of consecutive F-keystrokes
 *                     (sourced from bigram counts).
 *   3. Burst end    : last_key → home, charged once per burst.
 *
 * count_first(K) = count(K) − Σ over Ka with finger(Ka)=F: bg(Ka,K)
 *                  (occurrences of K NOT preceded by an F-key)
 * count_last(K)  = count(K) − Σ over Kb with finger(Kb)=F: bg(K,Kb)
 *                  (occurrences of K NOT followed by an F-key)
 *
 * The keyboard is treated as an orthogonal grid (no row stagger). Distances
 * are Euclidean in KEY_POSITIONS units, then multiplied by KEY_UNIT_MM. See
 * FINGER_DISTANCE_TOOLTIP_HTML for the user-facing explanation.
 */
function render_distance_kpi() {
	const kc_data = app_state.data.kc || {};
	const bg_dict = app_state.data.bg || {};

	// Build kc-bigram counts from text bigrams using the active layout map.
	// Some chars (e.g. accented capitals) may not resolve to a kc; those bigrams
	// are dropped — they would also be invisible to KEY_POSITIONS / KEY_FINGER
	// downstream so excluding them is the correct behaviour.
	const char_to_kc = _build_char_to_kc_map();
	const kc_bigram = {}; // kc_a → kc_b → count
	Object.entries(bg_dict).forEach(([k, item]) => {
		const chars = Array.from(k);
		if (chars.length !== 2) return;
		const kc_a = char_to_kc[chars[0].toLowerCase()];
		const kc_b = char_to_kc[chars[1].toLowerCase()];
		if (!kc_a || !kc_b) return;
		kc_bigram[kc_a] = kc_bigram[kc_a] || {};
		kc_bigram[kc_a][kc_b] = (kc_bigram[kc_a][kc_b] || 0) + (item.count || 0);
	});

	const euclid_units = (a, b) => {
		const dx = a.x - b.x;
		const dy = a.y - b.y;
		return Math.sqrt(dx * dx + dy * dy);
	};

	const by_finger = {}; // finger → mm

	// Term 2: transitions between same-finger consecutive keystrokes.
	// Iterating bigrams instead of pairwise products keeps this O(#bigrams).
	Object.entries(kc_bigram).forEach(([kc_a, succ]) => {
		const fa = KEY_FINGER[kc_a];
		const pa = KEY_POSITIONS[kc_a];
		if (!fa || !pa) return;
		Object.entries(succ).forEach(([kc_b, n]) => {
			if (!n) return;
			const fb = KEY_FINGER[kc_b];
			const pb = KEY_POSITIONS[kc_b];
			if (fb !== fa || !pb) return;
			const mm = euclid_units(pa, pb) * KEY_UNIT_MM * n;
			by_finger[fa] = (by_finger[fa] || 0) + mm;
		});
	});

	// Terms 1 and 3: home→first and last→home, one each per "burst".
	Object.entries(kc_data).forEach(([kc_str, item]) => {
		const finger = KEY_FINGER[kc_str];
		const pos = KEY_POSITIONS[kc_str];
		if (!finger || !pos) return;
		const home = FINGER_HOME[finger];
		if (!home) return;
		const total = item.count || 0;
		if (total === 0) return;

		// How many times was this kc preceded / followed by a key on the same finger?
		let preceded_by_same = 0;
		Object.entries(kc_bigram).forEach(([kc_a, succ]) => {
			if (KEY_FINGER[kc_a] !== finger) return;
			preceded_by_same += succ[kc_str] || 0;
		});
		const succ_map = kc_bigram[kc_str] || {};
		let followed_by_same = 0;
		Object.entries(succ_map).forEach(([kc_b, n]) => {
			if (KEY_FINGER[kc_b] === finger) followed_by_same += n;
		});
		// Clamp because bg counts can exceed kc counts when filtering removes
		// individual chars but keeps their bigram sample set (rare but possible).
		const first_count = Math.max(0, total - Math.min(total, preceded_by_same));
		const last_count = Math.max(0, total - Math.min(total, followed_by_same));

		const dist_to_home = euclid_units(pos, home) * KEY_UNIT_MM;
		const mm = (first_count + last_count) * dist_to_home;
		by_finger[finger] = (by_finger[finger] || 0) + mm;
	});

	let total_mm = 0;
	Object.values(by_finger).forEach((mm) => {
		total_mm += mm;
	});

	const total_km = total_mm / 1_000_000;

	// Per-finger keystroke counts (count-based, independent of distance) so we can
	// expose a stroke-volume "usage %" alongside the km-distance metric.
	const strokes_by_finger = {};
	let total_strokes = 0;
	Object.entries(kc_data).forEach(([kc_str, item]) => {
		const finger = KEY_FINGER[kc_str];
		if (!finger) return;
		const c = item.count || 0;
		strokes_by_finger[finger] = (strokes_by_finger[finger] || 0) + c;
		total_strokes += c;
	});

	// Hand balance: percentage of strokes typed by the left ("l_*") vs right ("r_*")
	// hands. Note that under the variante-en-A finger naming this maps to physical
	// hands consistent with FINGER_LABELS_FR.
	let strokes_left = 0,
		strokes_right = 0;
	Object.entries(strokes_by_finger).forEach(([f, n]) => {
		if (f.startsWith('l')) strokes_left += n;
		else strokes_right += n;
	});
	const hand_balance_el = document.getElementById('dist_hand_balance');
	if (hand_balance_el) {
		if (total_strokes > 0) {
			const pct_g = ((strokes_left / total_strokes) * 100).toFixed(1);
			const pct_d = ((strokes_right / total_strokes) * 100).toFixed(1);
			hand_balance_el.innerHTML = `${pct_g}% / ${pct_d}%`;
		} else {
			hand_balance_el.innerHTML = '—';
		}
	}

	// Build table data — all fingers with non-zero distance, joined with usage %.
	_dist_data = Object.entries(by_finger)
		.filter(([, mm]) => mm > 0)
		.map(([finger, mm]) => ({
			finger,
			// FINGER_LABELS_FR includes the hand suffix ("Auriculaire G", "Index D", …);
			// strip it here because the dedicated "Main" column already shows G/D.
			label: (FINGER_LABELS_FR[finger] || finger).replace(/\s+[GD]$/, ''),
			// Fingers starting with "l" are left-hand; "r" are right-hand
			hand: finger.startsWith('l') ? 'G' : 'D',
			km: mm / 1_000_000,
			usage_pct: total_strokes > 0 ? ((strokes_by_finger[finger] || 0) / total_strokes) * 100 : 0
		}));

	// ── KPI card ──────────────────────────────────────────────────────────────
	const dist_loading = document.getElementById('dist_loading');
	const dist_details = document.getElementById('dist_details');
	if (dist_loading) dist_loading.style.display = 'none';
	if (dist_details) dist_details.style.display = 'flex';

	const dist_val_el = document.getElementById('dist_val');
	if (dist_val_el) {
		// Always display in km with 3 decimal places — avoids unit switching on small values
		// and keeps the display consistent across sessions regardless of distance magnitude.
		const unit_str = `${format_number(total_km.toFixed(3))} <span class="stat-unit">km</span>`;
		dist_val_el.innerHTML =
			`<div style="display:flex;align-items:center;gap:6px;">` +
			`<span>${unit_str}</span>` +
			`<span class="tooltip stat-inline-tooltip" style="color:var(--kpi-dist-color);">${INFO_SVG}` +
			`<span class="tooltiptext" style="text-align:left;">${FINGER_DISTANCE_TOOLTIP_HTML}</span>` +
			`</span></div>`;
	}

	// Identify the most-active finger
	let max_finger = null,
		max_dist_mm = 0;
	Object.entries(by_finger).forEach(([f, d]) => {
		if (d > max_dist_mm) {
			max_dist_mm = d;
			max_finger = f;
		}
	});

	const dist_top_el = document.getElementById('dist_top_finger');
	if (dist_top_el && max_finger) {
		const label = FINGER_LABELS_FR[max_finger] || max_finger;
		const km = max_dist_mm / 1_000_000;
		dist_top_el.innerHTML = `${label}\u00A0: ${format_number(km.toFixed(2))}\u00A0km`;
	}

	render_dist_table();
}

// =========================================
// ===== 5.1) Distance Table Rendering =====
// =========================================

/**
 * Renders (or re-renders after a sort click) the per-finger distance table
 * inside the distance expanded KPI block. Shows all fingers with non-zero
 * distance: name, hand (G/D), km traveled. Top 10 by default (≤10 fingers).
 */
function render_dist_table() {
	const container = document.getElementById('dist_fingers_container');
	if (!container) return;

	const sorted = [..._dist_data].sort((a, b) => {
		const va = a[_dist_sort_col];
		const vb = b[_dist_sort_col];
		if (typeof va === 'string') return _dist_sort_asc ? va.localeCompare(vb) : vb.localeCompare(va);
		return _dist_sort_asc ? va - vb : vb - va;
	});

	const h_name = `Doigt${_sort_arrow('label', _dist_sort_col, _dist_sort_asc)}`;
	const h_hand = `Main${_sort_arrow('hand', _dist_sort_col, _dist_sort_asc)}`;
	const h_usage = `Charge${_sort_arrow('usage_pct', _dist_sort_col, _dist_sort_asc)}`;
	const h_km = `Km parcourus${_sort_arrow('km', _dist_sort_col, _dist_sort_asc)}`;

	let rows_html;
	if (sorted.length === 0) {
		rows_html = `<tr><td colspan="4" style="text-align:center;padding:12px;color:var(--text-muted);">${_t('ui_typing.no_data')}</td></tr>`;
	} else {
		// Inline horizontal bar showing finger usage % so the table doubles as a
		// visualization of the workload distribution.
		const max_pct = Math.max(0.001, ...sorted.map((d) => d.usage_pct));
		rows_html = sorted
			.slice(0, 10)
			.map((d) => {
				const km_str = `${format_number(d.km.toFixed(4))} km`;
				const pct_str = `${d.usage_pct.toFixed(1)}%`;
				const bar_width = Math.round((d.usage_pct / max_pct) * 100);
				const bar_color = d.hand === 'G' ? 'rgb(34, 211, 238)' : 'rgb(245, 158, 11)';
				return `<tr>
				<td>${d.label}</td>
				<td style="text-align:center;">${d.hand}</td>
				<td style="font-variant-numeric:tabular-nums;">
					<div style="display:flex;align-items:center;gap:6px;">
						<div style="flex:1;height:8px;background:rgba(255,255,255,0.05);border-radius:4px;overflow:hidden;min-width:40px;">
							<div style="height:100%;width:${bar_width}%;background:${bar_color};"></div>
						</div>
						<span style="min-width:42px;text-align:right;">${pct_str}</span>
					</div>
				</td>
				<td style="text-align:right;font-variant-numeric:tabular-nums;">${km_str}</td>
			</tr>`;
			})
			.join('');
	}

	container.innerHTML = `<table class="ekpi-table">
			<thead><tr>
				<th onclick="sort_dist_table('label')">${h_name}</th>
				<th onclick="sort_dist_table('hand')" style="text-align:center">${h_hand}</th>
				<th onclick="sort_dist_table('usage_pct')">${h_usage}</th>
				<th onclick="sort_dist_table('km')" style="text-align:right">${h_km}</th>
			</tr></thead>
			<tbody>${rows_html}</tbody>
		</table>`;
}

/**
 * Handles a sort click on the finger distance table header.
 * @param {string} col - The column to sort by: "label", "hand", or "km".
 */
function sort_dist_table(col) {
	if (_dist_sort_col === col) {
		_dist_sort_asc = !_dist_sort_asc;
	} else {
		_dist_sort_col = col;
		// Alphabetical columns default to ascending; km defaults to descending
		_dist_sort_asc = col !== 'km';
	}
	render_dist_table();
}

// =====================================================
// =====================================================
// ======= 6/ Average Words per Sentence KPI =======
// =====================================================
// =====================================================

/**
 * Computes and renders the average number of words per sentence into the
 * #wpm_words_sub element inside the speed KPI card.
 * Method: total word occurrences (from the w dict) divided by total sentence-
 * ending punctuation hits (. ! ? from the c dict).
 * Respects the active source/date/app filters because it reads from the
 * already-filtered app_state.data dictionaries.
 * Called from apply_local_filters() so it updates on every filter change.
 */
function render_avg_words_kpi() {
	const sub_el = document.getElementById('wpm_words_sub');
	if (!sub_el) return;

	const w_dict = app_state.data.w || {};

	// Count total word occurrences across all entries in the words dict
	let total_words = 0;
	Object.values(w_dict).forEach((item) => {
		total_words += item.count || 0;
	});

	if (total_words === 0) {
		sub_el.innerHTML = '';
		return;
	}

	sub_el.innerHTML =
		`<div style="margin-top:5px;">` +
		`<strong style="color:var(--kpi-wpm-color);font-size:1.1em;">${format_number(total_words)}</strong>` +
		` <span class="stat-unit" style="font-size:0.9em;">mots tapés au total</span>` +
		`</div>`;
}

// ===================================================
// ===================================================
// ======= 6.X/ Ergonomic Bigram KPI Rendering =======
// ===================================================
// ===================================================

// State for the ergonomic-bigrams sortable table
let _ergo_bg_data = []; // [{pair, count, kind, label}]
let _ergo_bg_sort_col = 'count';
let _ergo_bg_sort_asc = false;

/**
 * Returns the ergonomic classification of a bigram (kc_a, kc_b) given the
 * active KEY_FINGER, KEY_POSITIONS and FINGER_HOME maps.
 *
 * Categories (mutually exclusive within each axis, returned as a flag set so
 * a single bigram can be e.g. both an "outward roll" and a "scissor"):
 *   - sfb       : same finger, different key (already covered elsewhere but
 *                 reported here for completeness in the ergonomic view)
 *   - skb       : same key (doubling). Not counted as SHB.
 *   - shb       : same hand, different finger. Roll candidate.
 *   - roll_in   : SHB from pinky toward index (inward — most comfortable).
 *   - roll_out  : SHB from index toward pinky (outward).
 *   - lsb       : SHB where one of the keys is "extended" (column off the
 *                 finger's home column by ≥ 1.5 u, OR row distance ≥ 2 u).
 *   - scissor   : SHB on different rows where the row delta is ≥ 1.5 u and
 *                 the lower-row finger is shorter than the upper-row one
 *                 (pinky < ring < index < middle in the simplified ranking).
 * @param {string} kc_a - keycode of the first key.
 * @param {string} kc_b - keycode of the second key.
 * @returns {Object|null} flags or null if either key is missing data.
 */
function _classify_bigram_ergo(kc_a, kc_b) {
	const fa = KEY_FINGER[kc_a];
	const fb = KEY_FINGER[kc_b];
	const pa = KEY_POSITIONS[kc_a];
	const pb = KEY_POSITIONS[kc_b];
	if (!fa || !fb || !pa || !pb) return null;
	if (fa.endsWith('thumb') || fb.endsWith('thumb')) return null;
	const out = {
		sfb: false,
		skb: false,
		shb: false,
		roll_in: false,
		roll_out: false,
		lsb: false,
		scissor: false
	};
	const same_hand = fa[0] === fb[0]; // "l_…" / "r_…"
	if (kc_a === kc_b) {
		out.skb = true;
		return out;
	}
	if (fa === fb) {
		out.sfb = true;
		return out;
	}
	if (!same_hand) return out;

	out.shb = true;

	// Roll direction. Map finger → 0..3 from pinky to index. In our data convention
	// l_pinky / r_pinky are pinky, l_idx / r_idx are index, etc. Inward = pinky→idx.
	const FINGER_RANK = { pinky: 0, ring: 1, mid: 2, idx: 3 };
	const ra = FINGER_RANK[fa.split('_')[1]];
	const rb = FINGER_RANK[fb.split('_')[1]];
	if (ra < rb) out.roll_in = true;
	else if (ra > rb) out.roll_out = true;

	// LSB : at least one of the keys is laterally extended from its finger's
	// home column. We look at column distance from the finger's home (x).
	const home_a = FINGER_HOME[fa];
	const home_b = FINGER_HOME[fb];
	const ext_a = home_a ? Math.abs(pa.x - home_a.x) : 0;
	const ext_b = home_b ? Math.abs(pb.x - home_b.x) : 0;
	if (ext_a >= 1.5 || ext_b >= 1.5) out.lsb = true;

	// Scissor : row delta ≥ 1.5 (= crossing two rows) and the lower-row finger
	// is shorter than the upper-row finger. Length ranking: pinky < ring < idx < mid.
	const FINGER_LEN = { pinky: 0, ring: 1, idx: 2, mid: 3 };
	const len_a = FINGER_LEN[fa.split('_')[1]];
	const len_b = FINGER_LEN[fb.split('_')[1]];
	const dy = pb.y - pa.y;
	if (Math.abs(dy) >= 1.5) {
		// Lower row = smaller y. Identify which key is lower and check finger length.
		const lower_len = dy > 0 ? len_a : len_b;
		const upper_len = dy > 0 ? len_b : len_a;
		if (lower_len < upper_len) out.scissor = true;
	}
	return out;
}

/**
 * Computes Ergo-L style ergonomic bigram metrics from the currently filtered
 * bigram dictionary and renders the "Ergonomie bigrammes" KPI block + table.
 *
 * Definitions (Ergo-L vocabulary):
 *   SHB / SHU = Same-hand bigrams / share among all manual bigrams.
 *   LSB = SHB with a lateral stretch (extended column).
 *   Ciseaux = SHB with an awkward row crossing (≥ 2 rows).
 *   Roul. int. / ext. = SHB pinky→index / index→pinky.
 */
function render_ergo_bigram_kpi() {
	const bg_dict = app_state.data.bg || {};
	const char_to_kc = _build_char_to_kc_map();

	let total = 0,
		shb = 0,
		roll_in = 0,
		roll_out = 0,
		lsb = 0,
		scissor = 0;
	const top_lsb = [],
		top_scissor = [],
		top_roll_in = [],
		top_roll_out = [];

	Object.entries(bg_dict).forEach(([k, item]) => {
		const chars = Array.from(k);
		if (chars.length !== 2) return;
		const count = item.count || 0;
		if (count <= 0) return;
		const kc_a = char_to_kc[chars[0].toLowerCase()];
		const kc_b = char_to_kc[chars[1].toLowerCase()];
		if (!kc_a || !kc_b) return;
		const cls = _classify_bigram_ergo(kc_a, kc_b);
		if (!cls) return;
		total += count;
		if (cls.shb) {
			shb += count;
			if (cls.roll_in) {
				roll_in += count;
				top_roll_in.push({ pair: k, count, kind: 'Roul. int.' });
			}
			if (cls.roll_out) {
				roll_out += count;
				top_roll_out.push({ pair: k, count, kind: 'Roul. ext.' });
			}
			if (cls.lsb) {
				lsb += count;
				top_lsb.push({ pair: k, count, kind: 'LSB' });
			}
			if (cls.scissor) {
				scissor += count;
				top_scissor.push({ pair: k, count, kind: 'Ciseau' });
			}
		}
	});

	const pct = (n) => (total > 0 ? (n / total) * 100 : 0);

	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	set('ergo_shu_val', `${pct(shb).toFixed(1)}<span class="stat-unit">% SHU</span>`);
	set('ergo_roll_in_pct', `${pct(roll_in).toFixed(1)}%`);
	set('ergo_roll_out_pct', `${pct(roll_out).toFixed(1)}%`);
	set('ergo_lsb_pct', `${pct(lsb).toFixed(2)}%`);
	set('ergo_scissor_pct', `${pct(scissor).toFixed(2)}%`);

	const loading = document.getElementById('ergo_bigram_loading');
	const details = document.getElementById('ergo_bigram_details');
	if (loading) loading.style.display = total > 0 ? 'none' : '';
	if (details) details.style.display = total > 0 ? 'flex' : 'none';

	// Info tooltip — concise glossary so users can self-serve the meaning.
	const info = document.getElementById('ergo_bigram_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>SHB / SHU${NBSP}:</strong> bigrammes même main / leur part dans le total des bigrammes.<br>` +
			`<strong>Roulement intérieur${NBSP}:</strong> auriculaire vers index. Le plus confortable.<br>` +
			`<strong>Roulement extérieur${NBSP}:</strong> index vers auriculaire.<br>` +
			`<strong>LSB${NBSP}:</strong> Lateral Stretch Bigram — un des deux doigts s'écarte d'au moins 1,5 colonne de son repos.<br>` +
			`<strong>Ciseau${NBSP}:</strong> SHB qui croise ≥ 2 rangées avec le doigt court qui descend (ex. auriculaire en bas + majeur en haut).`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}

	// Build a sortable detail table — the 12 worst pairs from each "bad" group
	// plus the 12 best inward rolls so the user sees what to celebrate too.
	const top_n = (arr, n) => arr.sort((a, b) => b.count - a.count).slice(0, n);
	_ergo_bg_data = []
		.concat(top_n(top_scissor, 8))
		.concat(top_n(top_lsb, 8))
		.concat(top_n(top_roll_out, 8))
		.concat(top_n(top_roll_in, 8));
	render_ergo_bigram_table();
}

/**
 * Renders the sortable detail table beneath the ergonomic-bigrams KPI block.
 */
function render_ergo_bigram_table() {
	const container = document.getElementById('ergo_bigram_table_container');
	if (!container) return;
	if (_ergo_bg_data.length === 0) {
		container.innerHTML = '';
		return;
	}

	const sorted = [..._ergo_bg_data].sort((a, b) => {
		const cmp =
			_ergo_bg_sort_col === 'pair'
				? a.pair.localeCompare(b.pair)
				: _ergo_bg_sort_col === 'kind'
					? a.kind.localeCompare(b.kind)
					: a.count - b.count;
		return _ergo_bg_sort_asc ? cmp : -cmp;
	});

	const arrow = (col) => (_ergo_bg_sort_col === col ? (_ergo_bg_sort_asc ? ' ▲' : ' ▼') : '');
	const rows = sorted
		.map(
			(d) =>
				`<tr><td>${escape_html(d.pair)}</td>` +
				`<td style="text-align:right;">${format_number(d.count)}</td>` +
				`<td style="text-align:center;color:#aaa;">${d.kind}</td></tr>`
		)
		.join('');

	container.innerHTML =
		`<table class="ekpi-table"><thead><tr>` +
		`<th onclick="sort_ergo_bigram_table('pair')" style="cursor:pointer;">Bigramme${arrow('pair')}</th>` +
		`<th onclick="sort_ergo_bigram_table('count')" style="cursor:pointer;text-align:right;">Occurrences${arrow('count')}</th>` +
		`<th onclick="sort_ergo_bigram_table('kind')" style="cursor:pointer;text-align:center;">Type${arrow('kind')}</th>` +
		`</tr></thead><tbody>${rows}</tbody></table>`;
}

/**
 * Sort handler for the ergonomic bigram table.
 * @param {string} col - "pair" | "count" | "kind"
 */
function sort_ergo_bigram_table(col) {
	if (_ergo_bg_sort_col === col) {
		_ergo_bg_sort_asc = !_ergo_bg_sort_asc;
	} else {
		_ergo_bg_sort_col = col;
		_ergo_bg_sort_asc = col === 'pair' || col === 'kind';
	}
	render_ergo_bigram_table();
}

// =====================================================
// =====================================================
// ======= 6.Y/ Ergonomic Trigram KPI Rendering =======
// =====================================================
// =====================================================

let _ergo_tg_data = []; // [{seq, count, kind}]
let _ergo_tg_sort_col = 'count';
let _ergo_tg_sort_asc = false;

/**
 * Classifies a trigram (kc1, kc2, kc3) into Ergo-L ergonomic categories.
 * Returns flags so a single trigram can be both "bad redirection" and SFS, etc.
 *
 * Categories:
 *   - sfs        : same-finger skipgram. finger(1) == finger(3), finger(2) ≠ them, kc1 ≠ kc3.
 *   - sks        : same-key skipgram. kc1 == kc3, kc2 ≠ kc1.
 *   - redir      : same hand throughout, with a finger-rank direction change
 *                  (peak: 1<2>3, valley: 1>2<3). The most cited bad pattern in
 *                  the keyboard analyzer community.
 *   - bad_redir  : redirection where none of the three keys is on the index
 *                  finger. The "worst possible" sequence per Ergo-L.
 */
function _classify_trigram_ergo(kc1, kc2, kc3) {
	const f1 = KEY_FINGER[kc1],
		f2 = KEY_FINGER[kc2],
		f3 = KEY_FINGER[kc3];
	if (!f1 || !f2 || !f3) return null;
	if (f1.endsWith('thumb') || f2.endsWith('thumb') || f3.endsWith('thumb')) return null;
	const out = { sfs: false, sks: false, redir: false, bad_redir: false };

	// SKS — kc1 == kc3 and kc2 different
	if (kc1 === kc3 && kc2 !== kc1) out.sks = true;

	// SFS — same finger on positions 1 and 3, but different keys, with a different
	// finger in the middle. SKS is excluded because kc1 == kc3 there.
	if (f1 === f3 && f2 !== f1 && kc1 !== kc3) out.sfs = true;

	// Redirection — same hand throughout, finger rank changes direction
	const same_hand_all = f1[0] === f2[0] && f2[0] === f3[0];
	if (same_hand_all && f1 !== f2 && f2 !== f3) {
		const FR = { pinky: 0, ring: 1, mid: 2, idx: 3 };
		const r1 = FR[f1.split('_')[1]];
		const r2 = FR[f2.split('_')[1]];
		const r3 = FR[f3.split('_')[1]];
		const peak = r1 < r2 && r2 > r3;
		const valley = r1 > r2 && r2 < r3;
		if (peak || valley) {
			out.redir = true;
			const idx_seen = f1.endsWith('idx') || f2.endsWith('idx') || f3.endsWith('idx');
			if (!idx_seen) out.bad_redir = true;
		}
	}
	return out;
}

/**
 * Computes Ergo-L style ergonomic trigram metrics from app_state.data.tg.
 * Renders the "Ergonomie trigrammes" KPI block + a sortable detail table.
 */
function render_ergo_trigram_kpi() {
	const tg_dict = app_state.data.tg || {};
	const char_to_kc = _build_char_to_kc_map();

	let total = 0,
		sfs = 0,
		sks = 0,
		redir = 0,
		bad_redir = 0;
	const top_sfs = [],
		top_sks = [],
		top_redir = [],
		top_bad_redir = [];

	Object.entries(tg_dict).forEach(([k, item]) => {
		const chars = Array.from(k);
		if (chars.length !== 3) return;
		const count = item.count || 0;
		if (count <= 0) return;
		const kc1 = char_to_kc[chars[0].toLowerCase()];
		const kc2 = char_to_kc[chars[1].toLowerCase()];
		const kc3 = char_to_kc[chars[2].toLowerCase()];
		if (!kc1 || !kc2 || !kc3) return;
		const cls = _classify_trigram_ergo(kc1, kc2, kc3);
		if (!cls) return;
		total += count;
		if (cls.sfs) {
			sfs += count;
			top_sfs.push({ seq: k, count, kind: 'SFS' });
		}
		if (cls.sks) {
			sks += count;
			top_sks.push({ seq: k, count, kind: 'SKS' });
		}
		if (cls.redir) {
			redir += count;
			top_redir.push({ seq: k, count, kind: 'Redirection' });
		}
		if (cls.bad_redir) {
			bad_redir += count;
			top_bad_redir.push({ seq: k, count, kind: 'Mauv. redir.' });
		}
	});

	const pct = (n) => (total > 0 ? (n / total) * 100 : 0);
	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	set('ergo_trigram_val', `${pct(redir).toFixed(2)}<span class="stat-unit">% Redir.</span>`);
	set('ergo_sfs_pct', `${pct(sfs).toFixed(2)}%`);
	set('ergo_sks_pct', `${pct(sks).toFixed(2)}%`);
	set('ergo_redir_pct', `${pct(redir).toFixed(2)}%`);
	set('ergo_bad_redir_pct', `${pct(bad_redir).toFixed(2)}%`);

	const loading = document.getElementById('ergo_trigram_loading');
	const details = document.getElementById('ergo_trigram_details');
	if (loading) loading.style.display = total > 0 ? 'none' : '';
	if (details) details.style.display = total > 0 ? 'flex' : 'none';

	const info = document.getElementById('ergo_trigram_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>SFS${NBSP}:</strong> Same-Finger Skipgram — un SFB avec une touche d'un autre doigt intercalée (ex. EAD).<br>` +
			`<strong>SKS${NBSP}:</strong> Same-Key Skipgram — la même touche en positions 1 et 3 (ex. ELE).<br>` +
			`<strong>Redirection${NBSP}:</strong> trois touches même main avec un changement de direction (auriculaire→majeur→annulaire = pic). Inconfortable.<br>` +
			`<strong>Mauv. redir.${NBSP}:</strong> redirection où aucun des trois doigts n'est l'index. Parmi les pires enchaînements faisables sur un clavier.`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}

	const top_n = (arr, n) => arr.sort((a, b) => b.count - a.count).slice(0, n);
	_ergo_tg_data = []
		.concat(top_n(top_bad_redir, 8))
		.concat(top_n(top_redir, 6))
		.concat(top_n(top_sfs, 8))
		.concat(top_n(top_sks, 6));
	render_ergo_trigram_table();
}

/** Renders the sortable detail table beneath the ergonomic-trigrams KPI block. */
function render_ergo_trigram_table() {
	const container = document.getElementById('ergo_trigram_table_container');
	if (!container) return;
	if (_ergo_tg_data.length === 0) {
		container.innerHTML = '';
		return;
	}

	const sorted = [..._ergo_tg_data].sort((a, b) => {
		const cmp =
			_ergo_tg_sort_col === 'seq'
				? a.seq.localeCompare(b.seq)
				: _ergo_tg_sort_col === 'kind'
					? a.kind.localeCompare(b.kind)
					: a.count - b.count;
		return _ergo_tg_sort_asc ? cmp : -cmp;
	});

	const arrow = (col) => (_ergo_tg_sort_col === col ? (_ergo_tg_sort_asc ? ' ▲' : ' ▼') : '');
	const rows = sorted
		.map(
			(d) =>
				`<tr><td>${escape_html(d.seq)}</td>` +
				`<td style="text-align:right;">${format_number(d.count)}</td>` +
				`<td style="text-align:center;color:#aaa;">${d.kind}</td></tr>`
		)
		.join('');

	container.innerHTML =
		`<table class="ekpi-table"><thead><tr>` +
		`<th onclick="sort_ergo_trigram_table('seq')" style="cursor:pointer;">Trigramme${arrow('seq')}</th>` +
		`<th onclick="sort_ergo_trigram_table('count')" style="cursor:pointer;text-align:right;">Occurrences${arrow('count')}</th>` +
		`<th onclick="sort_ergo_trigram_table('kind')" style="cursor:pointer;text-align:center;">Type${arrow('kind')}</th>` +
		`</tr></thead><tbody>${rows}</tbody></table>`;
}

function sort_ergo_trigram_table(col) {
	if (_ergo_tg_sort_col === col) {
		_ergo_tg_sort_asc = !_ergo_tg_sort_asc;
	} else {
		_ergo_tg_sort_col = col;
		_ergo_tg_sort_asc = col === 'seq' || col === 'kind';
	}
	render_ergo_trigram_table();
}

// ===============================================
// ===============================================
// ======= 6.Z/ Errors KPI Rendering =======
// ===============================================
// ===============================================

let _err_data = []; // [{pair, count, errors, rate}]
let _err_sort_col = 'rate';
let _err_sort_asc = false;

/**
 * Surfaces the bigrams the user gets wrong most often.
 *
 * Source: app_state.data.bg, where merge_dict aggregates `errors` from item.e
 * for each entry. Lua tags a bigram as an "error occurrence" when the second
 * char of that bigram is deleted by a manual backspace immediately after — so
 * the count reflects "this bigram preceded a backspace correction".
 *
 * Ranking is by error RATE (errors / count), not absolute errors, so that high-
 * frequency bigrams ("er", "es", "le"…) don't drown out the truly problematic
 * ones. A floor of 5 occurrences avoids surfacing rare bigrams whose rate is
 * just statistical noise.
 */
function render_errors_kpi() {
	const bg_dict = app_state.data.bg || {};
	let total_count = 0,
		total_errs = 0;
	const rows = [];
	Object.entries(bg_dict).forEach(([k, item]) => {
		const chars = Array.from(k);
		if (chars.length !== 2) return;
		// Skip bigrams whose second char is a control / bracket marker (already
		// represented by [BS] / [ENTER] etc.) — they're not "user-correctable" pairs.
		if (chars[1].charCodeAt(0) < 32 || chars[1] === '[') return;
		const count = item.count || 0;
		const errors = item.errors || 0;
		if (count <= 0) return;
		total_count += count;
		total_errs += errors;
		if (errors >= 1 && count >= 5) {
			rows.push({ pair: k, count, errors, rate: errors / count });
		}
	});

	const overall_rate = total_count > 0 ? (total_errs / total_count) * 100 : 0;
	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	set('errors_val', `${overall_rate.toFixed(2)}<span class="stat-unit">% taux global</span>`);
	set('errors_total', format_number(total_errs));

	const worst = rows.slice().sort((a, b) => b.rate - a.rate)[0];
	set(
		'errors_worst',
		worst ? `${escape_html(worst.pair)} (${(worst.rate * 100).toFixed(1)}%)` : '—'
	);

	// Cascade / recovery aggregates from the per-app fields populated Lua-side.
	let cascade_count = 0,
		cascade_max = 0;
	let rec_sum = 0,
		rec_count = 0;
	_foreach_filtered_app((app) => {
		cascade_count += app.cascade_count_total || 0;
		if ((app.cascade_max_len || 0) > cascade_max) cascade_max = app.cascade_max_len;
		rec_sum += app.recovery_time_sum_ms || 0;
		rec_count += app.recovery_time_count || 0;
	});
	set(
		'errors_cascades',
		cascade_count > 0 ? `${format_number(cascade_count)} (max ${cascade_max} BS)` : '—'
	);
	set(
		'errors_recovery',
		rec_count > 0
			? `${(rec_sum / rec_count).toFixed(0)} ms (${format_number(rec_count)} corrections)`
			: '—'
	);

	const loading = document.getElementById('errors_loading');
	const details = document.getElementById('errors_details');
	if (loading) loading.style.display = total_errs > 0 ? 'none' : '';
	if (details) details.style.display = total_errs > 0 ? 'flex' : 'none';

	const info = document.getElementById('errors_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>Lecture${NBSP}:</strong> bigrammes (deux touches consécutives) classés par <em>taux d'erreur</em> = nombre de fois où la 2ᵉ touche a été effacée par un backspace, divisé par le nombre d'occurrences totales.<br><br>` +
			`<strong>Filtre${NBSP}:</strong> seuls les bigrammes apparus ≥ 5 fois sur la période sont affichés, pour éviter le bruit statistique des séquences rares.<br><br>` +
			`<strong>Cascades${NBSP}:</strong> runs de ≥ 3 backspaces consécutifs (correction majeure : un mot ou une phrase effacés). Le compteur sépare ce signal des erreurs ponctuelles.<br><br>` +
			`<strong>Temps de récup.${NBSP}:</strong> délai moyen entre un backspace et la touche suivante. Plus c'est long, plus la correction casse votre flux mental.`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}

	_err_data = rows;
	render_errors_table();
}

function render_errors_table() {
	const container = document.getElementById('errors_bigrams_container');
	if (!container) return;
	if (_err_data.length === 0) {
		container.innerHTML = `<div style="text-align:center;color:var(--text-muted);padding:12px;">${_t('ui_typing.errors_no_data')}</div>`;
		return;
	}

	const sorted = [..._err_data]
		.sort((a, b) => {
			const cmp =
				_err_sort_col === 'pair'
					? a.pair.localeCompare(b.pair)
					: a[_err_sort_col] - b[_err_sort_col];
			return _err_sort_asc ? cmp : -cmp;
		})
		.slice(0, 20);

	const arrow = (col) => (_err_sort_col === col ? (_err_sort_asc ? ' ▲' : ' ▼') : '');
	const rows = sorted
		.map(
			(d) =>
				`<tr><td>${escape_html(d.pair)}</td>` +
				`<td style="text-align:right;">${format_number(d.count)}</td>` +
				`<td style="text-align:right;color:#f87171;">${format_number(d.errors)}</td>` +
				`<td style="text-align:right;font-variant-numeric:tabular-nums;color:#f87171;"><b>${(d.rate * 100).toFixed(1)}%</b></td>` +
				`</tr>`
		)
		.join('');

	container.innerHTML =
		`<table class="ekpi-table"><thead><tr>` +
		`<th onclick="sort_errors_table('pair')" style="cursor:pointer;">${_t('ui_typing.errors_table_bigram')}${arrow('pair')}</th>` +
		`<th onclick="sort_errors_table('count')" style="cursor:pointer;text-align:right;">${_t('ui_typing.errors_table_occ')}${arrow('count')}</th>` +
		`<th onclick="sort_errors_table('errors')" style="cursor:pointer;text-align:right;">${_t('ui_typing.errors_table_errors')}${arrow('errors')}</th>` +
		`<th onclick="sort_errors_table('rate')" style="cursor:pointer;text-align:right;">${_t('ui_typing.errors_table_rate')}${arrow('rate')}</th>` +
		`</tr></thead><tbody>${rows}</tbody></table>`;
}

function sort_errors_table(col) {
	if (_err_sort_col === col) {
		_err_sort_asc = !_err_sort_asc;
	} else {
		_err_sort_col = col;
		_err_sort_asc = col === 'pair';
	}
	render_errors_table();
}

// ===============================================
// ===============================================
// ======= 6.W/ HS / IA ROI KPI Rendering =======
// ===============================================
// ===============================================

/**
 * Surfaces the productivity gain from hotstrings and IA: net characters saved
 * and an estimate of the time those characters would have cost to type
 * manually at the user's average cadence.
 *
 * Net chars saved is the unambiguous quantity (output − trigger length, summed
 * across every expansion). Time saved is necessarily an estimate because we
 * don't time individual expansion events, but multiplying by the average
 * inter-keydown delay over the same period gives a fair "if you had typed
 * these characters yourself" lower bound.
 */
function render_roi_kpi() {
	let manual_chars = 0,
		manual_time_ms = 0;
	let hs_chars = 0,
		hs_input_chars = 0,
		hs_triggers = 0;
	let llm_chars = 0,
		llm_input_chars = 0,
		llm_triggers = 0,
		llm_suggested = 0;
	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	const manifest_dates =
		app_state.manifest_dates_sorted.length > 0
			? app_state.manifest_dates_sorted
			: Object.keys(window.metrics_manifest).sort();
	const accumulate = (app) => {
		manual_chars += app.chars || 0;
		manual_time_ms += app.time || 0;
		hs_chars += app.hs_chars || 0;
		hs_input_chars += app.hs_input_chars || 0;
		hs_triggers += app.hs_triggers || 0;
		llm_chars += app.llm_chars || 0;
		llm_input_chars += app.llm_input_chars || 0;
		llm_triggers += app.llm_triggers || 0;
		llm_suggested += app.llm_suggested || 0;
	};
	manifest_dates.forEach((date_str) => {
		if (start_val && date_str < start_val) return;
		if (end_val && date_str > end_val) return;
		Object.keys(window.metrics_manifest[date_str] || {}).forEach((app_name) => {
			if (app_name !== 'Unknown' && !app_state.selected_apps.has(app_name)) return;
			accumulate(window.metrics_manifest[date_str][app_name]);
		});
	});
	const today_str = get_local_date_string();
	const today_in_range =
		(!start_val || today_str >= start_val) && (!end_val || today_str <= end_val);
	if (today_in_range && app_state.today_live_data) {
		Object.entries(app_state.today_live_data).forEach(([app_name, app_data]) => {
			if (app_name !== 'Unknown' && !app_state.selected_apps.has(app_name)) return;
			accumulate(app_data);
		});
	}

	const hs_saved = Math.max(0, hs_chars - hs_input_chars);
	const llm_saved = Math.max(0, llm_chars - llm_input_chars);
	const total_saved = hs_saved + llm_saved;
	// Estimated time the user would have spent typing the saved chars at their
	// average inter-keydown cadence over the period.
	const avg_ms_per_char = manual_chars > 0 ? manual_time_ms / manual_chars : 0;
	const time_saved_ms = total_saved * avg_ms_per_char;

	const fmt_duration = (ms) => {
		if (ms < 1000) return `${Math.round(ms)} ms`;
		const sec = ms / 1000;
		if (sec < 60) return `${sec.toFixed(1)} s`;
		const min = sec / 60;
		if (min < 60) return `${min.toFixed(1)} min`;
		const hr = min / 60;
		return `${hr.toFixed(2)} h`;
	};

	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	set(
		'roi_val',
		`${format_number(total_saved)}<span class="stat-unit">caractères économisés</span>`
	);
	set('roi_time_saved', total_saved > 0 ? fmt_duration(time_saved_ms) : '—');
	set('roi_hs_saved', `${format_number(hs_saved)} (${hs_triggers} déclench.)`);
	set('roi_llm_saved', `${format_number(llm_saved)} (${llm_triggers} déclench.)`);
	set(
		'roi_llm_acc',
		llm_suggested > 0
			? `${((llm_triggers / llm_suggested) * 100).toFixed(1)}% (${llm_triggers}/${llm_suggested})`
			: '—'
	);

	const loading = document.getElementById('roi_loading');
	const details = document.getElementById('roi_details');
	const has_data = hs_chars + llm_chars > 0;
	if (loading) loading.style.display = has_data ? 'none' : '';
	if (details) details.style.display = has_data ? 'flex' : 'none';

	const info = document.getElementById('roi_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>Caractères économisés${NBSP}:</strong> sortie nette des expansions HS / IA, c.-à-d. caractères ajoutés à l'écran moins ceux qui ont déclenché l'expansion (et qui ont donc été tapés manuellement).<br><br>` +
			`<strong>Temps économisé${NBSP}:</strong> caractères économisés × cadence moyenne (temps actif manuel ÷ nombre de frappes manuelles) sur la même période. C'est une borne inférieure honnête : c'est ce que vous auriez mis pour les taper vous-même.<br><br>` +
			`<strong>Acceptation IA${NBSP}:</strong> part des suggestions IA affichées qui ont été acceptées par l'utilisateur.`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}
}

// ===============================================
// ===============================================
// ======= 6.V/ Lexical KPI Rendering =======
// ===============================================
// ===============================================

/**
 * Surfaces lexical-level diagnostics from the words dictionary:
 *   - Vocabulary richness  : unique words / total words. A novelist's text
 *                            sits around 50–60 %, casual speech around 30 %,
 *                            highly repetitive text (chat, code) much lower.
 *   - Mean word length     : weighted average of word lengths, i.e. average
 *                            length of a typed character belongs-to-word —
 *                            captures how much "long-word" typing dominates.
 *   - Word length histogram: ASCII-bar chart of lengths 1..15+.
 *   - Top word             : the single most-typed word on the period.
 */
function render_lexical_kpi() {
	const w_dict = app_state.data.w || {};
	let total_words = 0;
	let unique_words = 0;
	let total_chars = 0;
	let top_word = null,
		top_count = 0;
	const length_buckets = {}; // length → count
	Object.entries(w_dict).forEach(([word, item]) => {
		const count = item.count || 0;
		if (count <= 0 || !word || word.length === 0) return;
		// Filter out single-character "words" — they're typically punctuation slipping
		// through the word boundary detection and would skew the richness metric.
		const len = Array.from(word).length;
		if (len < 2) return;
		total_words += count;
		unique_words += 1;
		total_chars += count * len;
		const bucket = len >= 15 ? 15 : len;
		length_buckets[bucket] = (length_buckets[bucket] || 0) + count;
		if (count > top_count) {
			top_count = count;
			top_word = word;
		}
	});

	const richness = total_words > 0 ? (unique_words / total_words) * 100 : 0;
	const avg_len = total_words > 0 ? total_chars / total_words : 0;

	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	set('lexical_val', `${richness.toFixed(1)}<span class="stat-unit">% richesse</span>`);
	set('lexical_unique', format_number(unique_words));
	set('lexical_total', format_number(total_words));
	set('lexical_avg_len', `${avg_len.toFixed(2)} car.`);
	set('lexical_top', top_word ? `${escape_html(top_word)} (${format_number(top_count)})` : '—');

	const loading = document.getElementById('lexical_loading');
	const details = document.getElementById('lexical_details');
	if (loading) loading.style.display = total_words > 0 ? 'none' : '';
	if (details) details.style.display = total_words > 0 ? 'flex' : 'none';

	const info = document.getElementById('lexical_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>Richesse${NBSP}:</strong> mots uniques ÷ mots totaux. Plus c'est haut, plus le vocabulaire est varié. Un texte littéraire sera vers 40–60${NBSP}%, du chat ou du code beaucoup plus bas.<br><br>` +
			`<strong>Longueur moyenne${NBSP}:</strong> moyenne pondérée par fréquence — c'est la longueur du mot que vous tapez "en moyenne", pas la longueur médiane du dictionnaire.<br><br>` +
			`<strong>Filtre${NBSP}:</strong> les mots de moins de 2 caractères sont ignorés (ce sont presque toujours des résidus de découpage par ponctuation).`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}

	// Histogram of word lengths — horizontal bars normalised to the max bucket.
	const container = document.getElementById('lexical_distribution_container');
	if (!container) return;
	if (total_words === 0) {
		container.innerHTML = '';
		return;
	}
	const max_count = Math.max(...Object.values(length_buckets));
	const bars_html = [];
	for (let l = 2; l <= 15; l++) {
		const n = length_buckets[l] || 0;
		const pct = max_count > 0 ? (n / max_count) * 100 : 0;
		const label = l === 15 ? '15+' : String(l);
		bars_html.push(
			`<tr>` +
				`<td style="text-align:right;font-variant-numeric:tabular-nums;color:#aaa;width:42px;">${label} car.</td>` +
				`<td style="padding:2px 6px;">` +
				`<div style="height:10px;background:rgba(255,255,255,0.05);border-radius:5px;overflow:hidden;">` +
				`<div style="height:100%;width:${pct}%;background:rgb(251, 191, 36);"></div>` +
				`</div>` +
				`</td>` +
				`<td style="text-align:right;font-variant-numeric:tabular-nums;width:60px;">${format_number(n)}</td>` +
				`</tr>`
		);
	}
	container.innerHTML =
		`<div style="font-size:11px;color:var(--text-muted);margin:8px 0 4px 0;">Distribution des longueurs (pondérée par fréquence)</div>` +
		`<table style="width:100%;border-collapse:collapse;font-size:12px;"><tbody>${bars_html.join('')}</tbody></table>`;
}

// ===============================================
// ===============================================
// ======= 6.U/ Burst / Rhythm KPI Rendering =======
// ===============================================
// ===============================================

/**
 * Walks every app entry in the currently-filtered date range and feeds it to
 * the supplied callback. Centralised so each per-period KPI doesn't repeat the
 * date / app / today-live filter dance.
 */
function _foreach_filtered_app(fn) {
	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	const dates =
		app_state.manifest_dates_sorted.length > 0
			? app_state.manifest_dates_sorted
			: Object.keys(window.metrics_manifest).sort();
	dates.forEach((date_str) => {
		if (start_val && date_str < start_val) return;
		if (end_val && date_str > end_val) return;
		Object.entries(window.metrics_manifest[date_str] || {}).forEach(([app_name, app]) => {
			if (app_name !== 'Unknown' && !app_state.selected_apps.has(app_name)) return;
			fn(app, date_str, app_name);
		});
	});
	const today_str = get_local_date_string();
	const today_in_range =
		(!start_val || today_str >= start_val) && (!end_val || today_str <= end_val);
	if (today_in_range && app_state.today_live_data) {
		Object.entries(app_state.today_live_data).forEach(([app_name, app]) => {
			if (app_name !== 'Unknown' && !app_state.selected_apps.has(app_name)) return;
			fn(app, today_str, app_name);
		});
	}
}

/**
 * Surfaces typing-rhythm diagnostics read from the per-app burst aggregates
 * emitted by Lua: peak burst CPM, longest burst, total burst count, mean and
 * coefficient-of-variation of inter-key delays. Burst length distribution is
 * shown as a small histogram beneath the headline KPI row.
 *
 * Definitions:
 *   - Burst        : stretch of typing with no inter-keydown gap > 1 s.
 *   - Peak CPM     : best CPM observed over a single burst of ≥ 10 chars
 *                    (sustained, not a 3-key flash).
 *   - CV (regularity) : std-dev(delays) / mean(delays). 0 = metronome,
 *                    > 0.6 = irregular.
 */
function render_rhythm_kpi() {
	let total_bursts = 0,
		max_chars = 0,
		max_cpm = 0;
	let inter_count = 0,
		inter_sum = 0,
		inter_sumsq = 0;
	const length_buckets = {};

	_foreach_filtered_app((app) => {
		total_bursts += app.burst_count_total || 0;
		if ((app.burst_max_chars || 0) > max_chars) max_chars = app.burst_max_chars;
		if ((app.burst_max_cpm || 0) > max_cpm) max_cpm = app.burst_max_cpm;
		inter_count += app.burst_inter_delay_count || 0;
		inter_sum += app.burst_inter_delay_sum || 0;
		inter_sumsq += app.burst_inter_delay_sumsq || 0;
		const lb = app.burst_length_buckets || {};
		Object.keys(lb).forEach((k) => {
			length_buckets[k] = (length_buckets[k] || 0) + (lb[k] || 0);
		});
	});

	const mean_delay = inter_count > 0 ? inter_sum / inter_count : 0;
	// Variance = E[X²] − (E[X])². Numerically stable enough for our scales.
	const variance =
		inter_count > 0 ? Math.max(0, inter_sumsq / inter_count - mean_delay * mean_delay) : 0;
	const std_delay = Math.sqrt(variance);
	const cv = mean_delay > 0 ? std_delay / mean_delay : 0;

	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	set(
		'rhythm_val',
		`${format_number(max_cpm.toFixed(0))}<span class="stat-unit">${_t('ui_typing.unit_cpm_burst')}</span>`
	);
	set('rhythm_max_chars', max_chars > 0 ? `${format_number(max_chars)} car.` : '—');
	set('rhythm_count', format_number(total_bursts));
	set('rhythm_mean_delay', mean_delay > 0 ? `${mean_delay.toFixed(0)} ms` : '—');
	set('rhythm_cv', inter_count > 0 ? cv.toFixed(2) : '—');

	const loading = document.getElementById('rhythm_loading');
	const details = document.getElementById('rhythm_details');
	if (loading) loading.style.display = total_bursts > 0 ? 'none' : '';
	if (details) details.style.display = total_bursts > 0 ? 'flex' : 'none';

	const info = document.getElementById('rhythm_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>Rafale${NBSP}:</strong> stretch de frappe sans gap > 1${NBSP}s entre deux touches.<br><br>` +
			`<strong>CPM pic${NBSP}:</strong> meilleur CPM observé sur une rafale d'au moins 10 caractères. Le seuil exclut les sprints fugaces non représentatifs.<br><br>` +
			`<strong>Régularité (CV)${NBSP}:</strong> coefficient de variation = écart-type ÷ moyenne. 0 = métronome parfait, > 0,6 = très irrégulier.`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}

	const container = document.getElementById('rhythm_distribution_container');
	if (!container) return;
	const order = ['1', '5', '10', '20', '50', '100', '200', '500', '500+'];
	const sum_buckets = order.reduce((s, k) => s + (length_buckets[k] || 0), 0);
	if (sum_buckets === 0) {
		container.innerHTML = '';
		return;
	}
	const max_bucket = Math.max(...order.map((k) => length_buckets[k] || 0));
	const bars = order
		.map((k) => {
			const n = length_buckets[k] || 0;
			const pct = max_bucket > 0 ? (n / max_bucket) * 100 : 0;
			const label = k === '500+' ? '500+ car.' : `≤ ${k} car.`;
			return (
				`<tr>` +
				`<td style="text-align:right;font-variant-numeric:tabular-nums;color:#aaa;width:78px;">${label}</td>` +
				`<td style="padding:2px 6px;">` +
				`<div style="height:10px;background:rgba(255,255,255,0.05);border-radius:5px;overflow:hidden;">` +
				`<div style="height:100%;width:${pct}%;background:rgb(56, 189, 248);"></div>` +
				`</div>` +
				`</td>` +
				`<td style="text-align:right;font-variant-numeric:tabular-nums;width:60px;">${format_number(n)}</td>` +
				`</tr>`
			);
		})
		.join('');
	container.innerHTML =
		`<div style="font-size:11px;color:var(--text-muted);margin:8px 0 4px 0;">Distribution des longueurs de rafales</div>` +
		`<table style="width:100%;border-collapse:collapse;font-size:12px;"><tbody>${bars}</tbody></table>`;
}

// =================================================
// =================================================
// ======= 6.T/ Sessions KPI Rendering =======
// =================================================
// =================================================

function _fmt_duration_ms(ms) {
	if (ms < 1000) return `${Math.round(ms)} ms`;
	const sec = ms / 1000;
	if (sec < 60) return `${sec.toFixed(1)} s`;
	const min = sec / 60;
	if (min < 60) return `${min.toFixed(1)} min`;
	const hr = min / 60;
	return `${hr.toFixed(2)} h`;
}

/**
 * Surfaces session-level diagnostics: a "session" is a block of typing with no
 * inter-keydown gap > 5 min (definition fixed Lua-side). The KPI summarises
 * total active typing time, longest session in both duration and character
 * dimensions, and average session length.
 */
function render_sessions_kpi() {
	let count = 0,
		total_active_ms = 0,
		longest_ms = 0,
		longest_chars = 0;
	_foreach_filtered_app((app) => {
		count += app.session_count_total || 0;
		total_active_ms += app.session_total_active_ms || 0;
		if ((app.session_longest_ms || 0) > longest_ms) longest_ms = app.session_longest_ms;
		if ((app.session_longest_chars || 0) > longest_chars) longest_chars = app.session_longest_chars;
	});
	const avg_ms = count > 0 ? total_active_ms / count : 0;

	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	set('sessions_val', `${format_number(count)}<span class="stat-unit">séances</span>`);
	set('sessions_total_time', count > 0 ? _fmt_duration_ms(total_active_ms) : '—');
	set('sessions_longest_time', longest_ms > 0 ? _fmt_duration_ms(longest_ms) : '—');
	set('sessions_longest_chars', longest_chars > 0 ? `${format_number(longest_chars)} car.` : '—');
	set('sessions_avg_time', avg_ms > 0 ? _fmt_duration_ms(avg_ms) : '—');

	const loading = document.getElementById('sessions_loading');
	const details = document.getElementById('sessions_details');
	if (loading) loading.style.display = count > 0 ? 'none' : '';
	if (details) details.style.display = count > 0 ? 'flex' : 'none';

	const info = document.getElementById('sessions_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>Séance${NBSP}:</strong> bloc de typing avec aucun gap > 5${NBSP}min entre deux frappes consécutives. Détecté côté keylogger, donc indépendant du filtre de pause de l'UI.<br><br>` +
			`<strong>Temps actif total${NBSP}:</strong> somme des durées de toutes les séances — c'est-à-dire le temps réellement passé à taper, en ignorant les pauses > 5${NBSP}min.<br><br>` +
			`<strong>Plus longue (chars)${NBSP}:</strong> peut concerner une séance différente de celle qui a la plus longue durée — par exemple une longue séance lente versus une courte séance ultra-rapide.`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}
}

// =================================================
// =================================================
// ======= 6.S/ Personal Records Rendering =======
// =================================================
// =================================================

/**
 * Surfaces "personal best" headlines computed across the ENTIRE manifest,
 * deliberately ignoring the date filter — a record is by definition the
 * all-time best, you don't want it to disappear when you zoom into a recent
 * week. App filter still applies so e.g. "best in code editors" works.
 */
function render_records_kpi() {
	let max_cpm = 0;
	let max_burst = 0,
		max_burst_app = '';
	let max_session_ms = 0,
		max_session_date = '';
	let best_day = '';
	let best_day_chars = 0;

	// chars per day (across selected apps) for streak + best-day computation
	const per_day = {};

	const visit = (app, date_str, app_name) => {
		if (app_name !== 'Unknown' && !app_state.selected_apps.has(app_name)) return;
		const cpm = app.burst_max_cpm || 0;
		if (cpm > max_cpm) max_cpm = cpm;
		const burst = app.burst_max_chars || 0;
		if (burst > max_burst) {
			max_burst = burst;
			max_burst_app = app_name;
		}
		const ses = app.session_longest_ms || 0;
		if (ses > max_session_ms) {
			max_session_ms = ses;
			max_session_date = date_str;
		}
		per_day[date_str] = (per_day[date_str] || 0) + (app.chars || 0);
	};

	if (window.metrics_manifest) {
		Object.entries(window.metrics_manifest).forEach(([date_str, apps]) => {
			Object.entries(apps || {}).forEach(([app_name, app]) => visit(app, date_str, app_name));
		});
	}
	if (app_state.today_live_data) {
		const today_str = get_local_date_string();
		Object.entries(app_state.today_live_data).forEach(([app_name, app]) =>
			visit(app, today_str, app_name)
		);
	}

	Object.entries(per_day).forEach(([date_str, n]) => {
		if (n > best_day_chars) {
			best_day_chars = n;
			best_day = date_str;
		}
	});

	// Streak: longest run of consecutive dates that have at least one keystroke.
	const sorted_dates = Object.keys(per_day)
		.filter((d) => per_day[d] > 0)
		.sort();
	let streak_max = 0,
		streak_cur = 0,
		prev = null;
	const ymd = (s) => new Date(s + 'T12:00:00').getTime();
	sorted_dates.forEach((d) => {
		if (prev && ymd(d) - prev === 86400_000) streak_cur += 1;
		else streak_cur = 1;
		if (streak_cur > streak_max) streak_max = streak_cur;
		prev = ymd(d);
	});

	const fr_short = (date_str) => {
		if (!date_str) return '—';
		const d = new Date(date_str + 'T12:00:00');
		return d.toLocaleDateString('fr-FR', { day: 'numeric', month: 'short', year: '2-digit' });
	};

	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	set(
		'records_val',
		`${format_number(max_cpm.toFixed(0))}<span class="stat-unit">${_t('ui_typing.unit_cpm_record')}</span>`
	);
	set(
		'records_burst_chars',
		max_burst > 0 ? `${format_number(max_burst)} car. (${escape_html(max_burst_app)})` : '—'
	);
	set(
		'records_session',
		max_session_ms > 0 ? `${_fmt_duration_ms(max_session_ms)} (${fr_short(max_session_date)})` : '—'
	);
	set(
		'records_best_day',
		best_day_chars > 0 ? `${format_number(best_day_chars)} car. (${fr_short(best_day)})` : '—'
	);
	set('records_streak', streak_max > 0 ? `${streak_max} jour${streak_max > 1 ? 's' : ''}` : '—');

	const has_data = max_burst > 0 || max_session_ms > 0 || best_day_chars > 0;
	const loading = document.getElementById('records_loading');
	const details = document.getElementById('records_details');
	if (loading) loading.style.display = has_data ? 'none' : '';
	if (details) details.style.display = has_data ? 'flex' : 'none';

	const info = document.getElementById('records_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>Portée${NBSP}:</strong> les records sont calculés sur <em>toute</em> la base de données — ils ne suivent pas le filtre de dates de l'UI (sinon le record disparaît dès qu'on zoome). Le filtre d'apps reste appliqué.<br><br>` +
			`<strong>Streak${NBSP}:</strong> plus longue suite de jours consécutifs avec au moins une frappe. Manquer une journée remet le compteur à zéro.`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}
}

// =================================================
// =================================================
// ======= 6.R/ Char-Type Mix Rendering =======
// =================================================
// =================================================

const CHARMIX_CATEGORIES = [
	{ key: 'letter', label: 'Lettres', color: 'rgb(96,165,250)' },
	{ key: 'digit', label: 'Chiffres', color: 'rgb(251,191,36)' },
	{ key: 'punct', label: 'Ponctuation', color: 'rgb(248,113,113)' },
	{ key: 'space', label: 'Espaces', color: 'rgb(74,222,128)' },
	{ key: 'other', label: 'Autres', color: 'rgb(168,162,158)' }
];

/**
 * Surfaces the breakdown of typed characters by category (letter / digit /
 * punct / space / other), aggregated from the Lua-side classifier. Renders a
 * horizontal stacked bar so the user can see at a glance whether the period
 * was code-heavy (lots of punctuation / digits), prose-heavy (mostly letters
 * + spaces), or chat-heavy (mid-mix).
 */
function render_charmix_kpi() {
	const totals = { letter: 0, digit: 0, punct: 0, space: 0, other: 0 };
	_foreach_filtered_app((app) => {
		totals.letter += app.char_letter || 0;
		totals.digit += app.char_digit || 0;
		totals.punct += app.char_punct || 0;
		totals.space += app.char_space || 0;
		totals.other += app.char_other || 0;
	});
	const grand = totals.letter + totals.digit + totals.punct + totals.space + totals.other;

	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	const fmt_pct = (n) => (grand > 0 ? `${((n / grand) * 100).toFixed(1)}%` : '—');
	set(
		'charmix_letter',
		grand > 0 ? `${format_number(totals.letter)} (${fmt_pct(totals.letter)})` : '—'
	);
	set(
		'charmix_digit',
		grand > 0 ? `${format_number(totals.digit)} (${fmt_pct(totals.digit)})` : '—'
	);
	set(
		'charmix_punct',
		grand > 0 ? `${format_number(totals.punct)} (${fmt_pct(totals.punct)})` : '—'
	);
	set(
		'charmix_space',
		grand > 0 ? `${format_number(totals.space)} (${fmt_pct(totals.space)})` : '—'
	);
	set(
		'charmix_other',
		grand > 0 ? `${format_number(totals.other)} (${fmt_pct(totals.other)})` : '—'
	);

	// Headline: the dominant category and its share, gives an instant "type of
	// content" cue (e.g. "73% lettres" → prose).
	let dominant = null,
		dom_n = 0;
	CHARMIX_CATEGORIES.forEach((c) => {
		const n = totals[c.key] || 0;
		if (n > dom_n) {
			dom_n = n;
			dominant = c;
		}
	});
	set(
		'charmix_val',
		dominant && grand > 0
			? `${((dom_n / grand) * 100).toFixed(0)}<span class="stat-unit">% ${dominant.label.toLowerCase()}</span>`
			: `—`
	);

	const loading = document.getElementById('charmix_loading');
	const details = document.getElementById('charmix_details');
	if (loading) loading.style.display = grand > 0 ? 'none' : '';
	if (details) details.style.display = grand > 0 ? 'flex' : 'none';

	const info = document.getElementById('charmix_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>Catégories${NBSP}:</strong> chaque caractère manuel typé est rangé Lua-side dans une des cinq catégories — lettres latines (incluant accentuées courantes), chiffres, ponctuation et symboles, espaces (incluant NBSP / NNBSP / tab / retour), et autres (caractères non-latins, marqueurs spéciaux du keylogger).<br><br>` +
			`<strong>Indication${NBSP}:</strong> code-heavy = beaucoup de ponctuation et chiffres ; prose-heavy = essentiellement lettres et espaces ; chat = équilibre avec un peu de tout.`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}

	// Stacked horizontal bar — segments proportional to each category's share,
	// labelled inline when the segment is wide enough to fit text.
	const container = document.getElementById('charmix_bar_container');
	if (!container) return;
	if (grand === 0) {
		container.innerHTML = '';
		return;
	}
	const segments = CHARMIX_CATEGORIES.map((c) => {
		const n = totals[c.key] || 0;
		const pct = (n / grand) * 100;
		const label =
			pct >= 6 ? `${c.label.charAt(0).toUpperCase()}${c.label.slice(1)} ${pct.toFixed(0)}%` : '';
		return { ...c, n, pct, label };
	}).filter((s) => s.pct > 0);
	const bar_html = segments
		.map(
			(s) =>
				`<div title="${s.label || (s.label || '') + ' ' + s.pct.toFixed(2) + '%'}" ` +
				`style="flex-basis:${s.pct}%;background:${s.color};display:flex;align-items:center;justify-content:center;` +
				`color:#0f172a;font-size:11px;font-weight:600;overflow:hidden;white-space:nowrap;">${s.label}</div>`
		)
		.join('');
	container.innerHTML =
		`<div style="font-size:11px;color:var(--text-muted);margin:8px 0 4px 0;">Répartition (${format_number(grand)} caractères)</div>` +
		`<div style="display:flex;height:24px;border-radius:6px;overflow:hidden;">${bar_html}</div>`;
}

// =================================================
// =================================================
// ======= 6.Q/ Apps KPI Rendering =======
// =================================================
// =================================================

let _apps_data = []; // [{name, chars, time_ms, cpm, switches}]
let _apps_sort_col = 'chars';
let _apps_sort_asc = false;

/**
 * Surfaces per-app activity diagnostics: total characters typed in each app,
 * average CPM in that app, and the dominant follow-up app (workflow signal).
 *
 * The "App pair affinity" headline uses the manifest's `switches_to` map: each
 * app records, per day, how many times the user moved to each other app right
 * after using it. The pair with the highest reciprocal sum across the period
 * is the user's most-alternated workflow (typically editor ↔ browser).
 */
function render_apps_kpi() {
	const per_app = {}; // app → { chars, time_ms, switches_out: { other: count } }
	const layouts_total = {}; // layout_id → cumulative count across filtered apps
	const kc_hold_total = {}; // kc_str → { s, n, m } summed across filtered apps
	_foreach_filtered_app((app, date_str, app_name) => {
		const a =
			per_app[app_name] ||
			(per_app[app_name] = { chars: 0, time_ms: 0, app_time_ms: 0, switches_out: {} });
		a.chars += app.chars || 0;
		a.time_ms += app.time || 0;
		a.app_time_ms += app.app_time_ms || 0;
		const sw = app.switches_to || {};
		Object.entries(sw).forEach(([other, n]) => {
			a.switches_out[other] = (a.switches_out[other] || 0) + (n || 0);
		});
		// Layouts seen on this app/day
		const ls = app.layouts_seen || {};
		Object.entries(ls).forEach(([layout_id, n]) => {
			layouts_total[layout_id] = (layouts_total[layout_id] || 0) + (n || 0);
		});
		// Per-keycode modifier hold: aggregate sum / count / max
		const kh = app.kc_hold || {};
		Object.entries(kh).forEach(([kc_str, h]) => {
			const t = kc_hold_total[kc_str] || (kc_hold_total[kc_str] = { s: 0, n: 0, m: 0 });
			t.s += h.s || 0;
			t.n += h.n || 0;
			if ((h.m || 0) > t.m) t.m = h.m;
		});
	});

	_apps_data = Object.entries(per_app)
		.filter(([name, a]) => a.chars > 0)
		.map(([name, a]) => ({
			name,
			chars: a.chars,
			time_ms: a.time_ms,
			app_time_ms: a.app_time_ms,
			cpm: a.time_ms > 0 ? (a.chars * 60000) / a.time_ms : 0,
			switches_out: a.switches_out
		}));

	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};
	set('apps_val', `${format_number(_apps_data.length)}<span class="stat-unit">apps actives</span>`);

	if (_apps_data.length === 0) {
		const loading = document.getElementById('apps_loading');
		const details = document.getElementById('apps_details');
		if (loading) loading.style.display = '';
		if (details) details.style.display = 'none';
		const container = document.getElementById('apps_table_container');
		if (container) container.innerHTML = '';
		return;
	}

	// Headline: fastest app (CPM) — only consider apps with ≥ 200 chars to avoid
	// crowning a 3-keystroke fluke.
	const fastest = _apps_data.filter((d) => d.chars >= 200).sort((a, b) => b.cpm - a.cpm)[0];
	set(
		'apps_fastest',
		fastest ? `${escape_html(fastest.name)} (${fastest.cpm.toFixed(0)} CPM)` : '—'
	);

	const top_vol = _apps_data.slice().sort((a, b) => b.chars - a.chars)[0];
	set(
		'apps_top_volume',
		top_vol ? `${escape_html(top_vol.name)} (${format_number(top_vol.chars)} car.)` : '—'
	);

	// Build symmetric app-pair affinity: both directions of switching count.
	const pair_count = {};
	_apps_data.forEach((d) => {
		Object.entries(d.switches_out).forEach(([other, n]) => {
			const key = [d.name, other].sort().join(' ↔ ');
			pair_count[key] = (pair_count[key] || 0) + n;
		});
	});
	const top_pair = Object.entries(pair_count).sort((a, b) => b[1] - a[1])[0];
	set(
		'apps_top_pair',
		top_pair ? `${escape_html(top_pair[0])} (${format_number(top_pair[1])}×)` : '—'
	);

	// Layouts seen — sorted by usage, top 3 to keep the value compact
	const layouts_sorted = Object.entries(layouts_total).sort((a, b) => b[1] - a[1]);
	if (layouts_sorted.length === 0) {
		set('apps_layouts', '—');
	} else {
		const txt = layouts_sorted
			.slice(0, 3)
			.map(([id, n]) => `${escape_html(id)} (${format_number(n)}×)`)
			.join(', ');
		const more = layouts_sorted.length > 3 ? ` +${layouts_sorted.length - 3}` : '';
		set('apps_layouts', txt + more);
	}

	// Modifier with the highest mean hold — only consider entries with ≥ 5
	// samples to avoid crowning a single 800 ms outlier.
	const KC_LABELS_LOCAL = (typeof KEYCODE_NAMES === 'object' && KEYCODE_NAMES) || {};
	let top_mod = null,
		top_mean = 0;
	Object.entries(kc_hold_total).forEach(([kc_str, h]) => {
		if ((h.n || 0) < 5) return;
		const mean = h.s / h.n;
		if (mean > top_mean) {
			top_mean = mean;
			top_mod = { kc: kc_str, mean, n: h.n, m: h.m };
		}
	});
	if (top_mod) {
		const label = KC_LABELS_LOCAL[top_mod.kc] || `kc${top_mod.kc}`;
		set(
			'apps_top_mod_hold',
			`${escape_html(label)} <span style="color:var(--text-muted);font-weight:400;">${Math.round(top_mod.mean)} ms (max ${top_mod.m})</span>`
		);
	} else {
		set('apps_top_mod_hold', '—');
	}

	const loading = document.getElementById('apps_loading');
	const details = document.getElementById('apps_details');
	if (loading) loading.style.display = 'none';
	if (details) details.style.display = 'flex';

	const info = document.getElementById('apps_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>App la + rapide${NBSP}:</strong> CPM moyen le plus élevé sur les apps avec ≥ 200 caractères tapés (en dessous on tomberait sur des apps utilisées 2 secondes).<br><br>` +
			`<strong>Paire fréquente${NBSP}:</strong> les deux apps entre lesquelles vous alternez le plus, dans les deux sens. Indique votre workflow type (éditeur ↔ navigateur, doc ↔ chat…).`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}

	render_apps_table();
}

function render_apps_table() {
	const container = document.getElementById('apps_table_container');
	if (!container) return;
	if (_apps_data.length === 0) {
		container.innerHTML = '';
		return;
	}

	const sorted = [..._apps_data]
		.sort((a, b) => {
			const va = a[_apps_sort_col];
			const vb = b[_apps_sort_col];
			if (typeof va === 'string')
				return _apps_sort_asc ? va.localeCompare(vb) : vb.localeCompare(va);
			return _apps_sort_asc ? va - vb : vb - va;
		})
		.slice(0, 12);

	const arrow = (col) => (_apps_sort_col === col ? (_apps_sort_asc ? ' ▲' : ' ▼') : '');
	const max_chars = Math.max(...sorted.map((d) => d.chars));
	const fmt_dur = (ms) => {
		if (ms < 60_000) return `${(ms / 1000).toFixed(0)} s`;
		if (ms < 3600_000) return `${(ms / 60_000).toFixed(1)} min`;
		return `${(ms / 3600_000).toFixed(2)} h`;
	};
	const rows = sorted
		.map((d) => {
			const bar_pct = max_chars > 0 ? Math.round((d.chars / max_chars) * 100) : 0;
			return (
				`<tr>` +
				`<td>${escape_html(d.name)}</td>` +
				`<td style="font-variant-numeric:tabular-nums;">` +
				`<div style="display:flex;align-items:center;gap:6px;">` +
				`<div style="flex:1;height:8px;background:rgba(255,255,255,0.05);border-radius:4px;overflow:hidden;min-width:40px;">` +
				`<div style="height:100%;width:${bar_pct}%;background:rgb(232, 121, 249);"></div>` +
				`</div>` +
				`<span style="min-width:64px;text-align:right;">${format_number(d.chars)}</span>` +
				`</div>` +
				`</td>` +
				`<td style="text-align:right;font-variant-numeric:tabular-nums;">${d.cpm > 0 ? d.cpm.toFixed(0) : '—'}</td>` +
				`<td style="text-align:right;font-variant-numeric:tabular-nums;color:#aaa;">${fmt_dur(d.time_ms)}</td>` +
				`</tr>`
			);
		})
		.join('');

	container.innerHTML =
		`<table class="ekpi-table"><thead><tr>` +
		`<th onclick="sort_apps_table('name')" style="cursor:pointer;">${_t('ui_typing.col_app')}${arrow('name')}</th>` +
		`<th onclick="sort_apps_table('chars')" style="cursor:pointer;">${_t('ui_typing.col_chars')}${arrow('chars')}</th>` +
		`<th onclick="sort_apps_table('cpm')" style="cursor:pointer;text-align:right;">${_t('ui_typing.unit_cpm')}${arrow('cpm')}</th>` +
		`<th onclick="sort_apps_table('time_ms')" style="cursor:pointer;text-align:right;">${_t('ui_typing.col_active_time')}${arrow('time_ms')}</th>` +
		`</tr></thead><tbody>${rows}</tbody></table>`;
}

function sort_apps_table(col) {
	if (_apps_sort_col === col) _apps_sort_asc = !_apps_sort_asc;
	else {
		_apps_sort_col = col;
		_apps_sort_asc = col === 'name';
	}
	render_apps_table();
}

// ===================================================
// ===================================================
// ======= 6.P/ Wellness / Ergonomics Dashboard =======
// ===================================================
// ===================================================

const LONG_SESSION_THRESHOLD_MS = 90 * 60 * 1000; // 90 min — clinical RSI risk threshold

/**
 * Surfaces health-relevant ergonomic signals: active-vs-passive ratio (am I
 * really typing or mostly reading?), longest same-finger / same-hand streaks
 * (anti-alternation = uneven load), how many "marathon" sessions occurred
 * (≥ 90 min without a 5 min break — RSI risk), and the auto-repeat count
 * (held keys are one motor decision but inflate the keystroke counter).
 */
function render_wellness_kpi() {
	let app_time_ms = 0,
		active_time_ms = 0;
	let max_finger_streak = 0,
		max_hand_streak = 0;
	let auto_repeat = 0,
		total_chars = 0;
	let long_sessions = 0;
	let session_count = 0,
		session_total_active_ms = 0;
	let focus_lat_sum_ms = 0,
		focus_lat_count = 0;
	const finger_load = {}; // finger → strokes (for the bottom load chart)

	_foreach_filtered_app((app) => {
		app_time_ms += app.app_time_ms || 0;
		active_time_ms += app.time || 0;
		total_chars += app.chars || 0;
		auto_repeat += app.auto_repeat_count || 0;
		if ((app.same_finger_streak_max || 0) > max_finger_streak)
			max_finger_streak = app.same_finger_streak_max;
		if ((app.same_hand_streak_max || 0) > max_hand_streak)
			max_hand_streak = app.same_hand_streak_max;
		// Long-sessions estimate: if the longest single session exceeds the
		// threshold, count one. We don't track per-session lengths individually
		// in the manifest, so this lower-bounds the count by 1 per app per day.
		if ((app.session_longest_ms || 0) >= LONG_SESSION_THRESHOLD_MS) long_sessions += 1;
		session_count += app.session_count_total || 0;
		session_total_active_ms += app.session_total_active_ms || 0;
		focus_lat_sum_ms += app.focus_to_first_key_sum_ms || 0;
		focus_lat_count += app.focus_to_first_key_count || 0;
	});

	// Aggregate system-wide passive time (lock + sleep) across the filtered
	// date range. The "_system" pseudo-app is populated by Lua's caffeinate
	// callbacks and is bypassed by _foreach_filtered_app's app filter, so we
	// iterate the manifest directly here.
	let passive_ms = 0;
	const start_val = document.getElementById('date_start').value;
	const end_val = document.getElementById('date_end').value;
	Object.entries(window.metrics_manifest || {}).forEach(([date_str, apps]) => {
		if (start_val && date_str < start_val) return;
		if (end_val && date_str > end_val) return;
		const sys = apps && apps._system;
		if (!sys) return;
		passive_ms += (sys.locked_ms || 0) + (sys.sleep_ms || 0);
	});
	// Subtract passive time from foreground app time for a precise denominator
	const active_app_time_ms = Math.max(0, app_time_ms - passive_ms);

	// Per-finger keystroke totals — same source as the distance card so the
	// bottom load chart is consistent with what shows there.
	const kc_data = app_state.data.kc || {};
	let total_strokes = 0;
	Object.entries(kc_data).forEach(([kc_str, item]) => {
		const finger = KEY_FINGER[kc_str];
		if (!finger) return;
		const c = item.count || 0;
		finger_load[finger] = (finger_load[finger] || 0) + c;
		total_strokes += c;
	});

	// Use foreground-minus-passive as the denominator so locked/sleeping screen
	// time never inflates the "you weren't typing" share.
	const active_ratio = active_app_time_ms > 0 ? (active_time_ms / active_app_time_ms) * 100 : 0;
	const set = (id, html) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = html;
	};

	// Format ms → "Xh Ym" / "Xm Ys" / "Xs" for compact display
	const fmt_dur = (ms) => {
		if (!ms || ms <= 0) return '—';
		const s = Math.floor(ms / 1000);
		if (s >= 3600) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
		if (s >= 60) return `${Math.floor(s / 60)}m ${s % 60}s`;
		return `${s}s`;
	};

	// Headline: a colour-coded "wellness signal". Red when long sessions or
	// extreme finger streaks dominate; green when balanced.
	let signal_label = '—',
		signal_color = '';
	if (total_chars > 0) {
		if (long_sessions >= 2 || max_finger_streak >= 8) {
			signal_label = 'Vigilance';
			signal_color = 'color:rgb(248,113,113);';
		} else if (long_sessions >= 1 || max_finger_streak >= 6 || max_hand_streak >= 12) {
			signal_label = 'Surveillé';
			signal_color = 'color:rgb(251,191,36);';
		} else {
			signal_label = 'Équilibré';
			signal_color = 'color:rgb(74,222,128);';
		}
	}
	set('wellness_val', `<span style="${signal_color}">${signal_label}</span>`);

	set('wellness_active_ratio', app_time_ms > 0 ? `${active_ratio.toFixed(1)}%` : '—');
	set('wellness_finger_streak', max_finger_streak > 0 ? `${max_finger_streak} touches` : '—');
	set('wellness_hand_streak', max_hand_streak > 0 ? `${max_hand_streak} touches` : '—');
	set('wellness_long_sessions', `${long_sessions}`);
	set(
		'wellness_autorepeat',
		auto_repeat > 0
			? `${format_number(auto_repeat)} (${((auto_repeat / Math.max(1, total_chars)) * 100).toFixed(2)}%)`
			: '—'
	);
	set(
		'wellness_focus_latency',
		focus_lat_count > 0
			? `${Math.round(focus_lat_sum_ms / focus_lat_count)} ms <span style="color:var(--text-muted);font-weight:400;">(n=${focus_lat_count})</span>`
			: '—'
	);
	set('wellness_passive_ms', passive_ms > 0 ? fmt_dur(passive_ms) : '—');

	const has_data = total_chars > 0 || total_strokes > 0;
	const loading = document.getElementById('wellness_loading');
	const details = document.getElementById('wellness_details');
	if (loading) loading.style.display = has_data ? 'none' : '';
	if (details) details.style.display = has_data ? 'flex' : 'none';

	const info = document.getElementById('wellness_info');
	if (info && typeof INFO_SVG === 'string') {
		const NBSP = String.fromCharCode(160);
		const tip =
			`<strong>Signal global${NBSP}:</strong> rouge "Vigilance" si ≥ 2 séances de plus de 90${NBSP}min ou un streak doigt ≥ 8 ; orange "Surveillé" si ≥ 1 séance longue ou streak doigt ≥ 6 ou main ≥ 12 ; vert "Équilibré" sinon.<br><br>` +
			`<strong>Ratio actif${NBSP}:</strong> temps réellement passé à taper ÷ temps où l'app était en focus. Bas = vous lisez beaucoup, ce qui réduit la charge frappe mais signale aussi un déséquilibre input/output si chronique.<br><br>` +
			`<strong>Streak doigt / main${NBSP}:</strong> longest run de touches consécutives sur le même doigt ou la même main. Au-delà de 5 (doigt) ou 12 (main), la charge n'est plus distribuée.<br><br>` +
			`<strong>Séances longues${NBSP}:</strong> séances ≥ 90${NBSP}min sans pause. Seuil clinique au-delà duquel le risque TMS augmente sensiblement.`;
		info.innerHTML = `${INFO_SVG}<span class="tooltiptext" style="text-align:left;">${tip}</span>`;
	}

	// Cumulative finger load: horizontal bar showing each finger's share of
	// strokes, colour-coded by hand. Highlights chronic asymmetry over the
	// period (e.g. r_idx doing 22% while r_pinky idles at 1%).
	const container = document.getElementById('wellness_finger_load_container');
	if (!container) return;
	if (total_strokes === 0) {
		container.innerHTML = '';
		return;
	}

	const FINGER_ORDER = [
		'r_pinky',
		'r_ring',
		'r_mid',
		'r_idx',
		'l_idx',
		'l_mid',
		'l_ring',
		'l_pinky'
	];
	const max_load = Math.max(...FINGER_ORDER.map((f) => finger_load[f] || 0));
	const rows = FINGER_ORDER.map((f) => {
		const n = finger_load[f] || 0;
		const pct = total_strokes > 0 ? (n / total_strokes) * 100 : 0;
		const bar_pct = max_load > 0 ? (n / max_load) * 100 : 0;
		const label = (FINGER_LABELS_FR[f] || f).replace(/\s+[GD]$/, '');
		const hand_color = f.startsWith('l') ? 'rgb(34, 211, 238)' : 'rgb(245, 158, 11)';
		// Colour cells with > 18% of total load in red — well above the ~12.5%
		// expected for an even 8-finger distribution.
		const text_color = pct > 18 ? 'color:rgb(248,113,113);font-weight:600;' : '';
		return (
			`<tr>` +
			`<td style="color:#aaa;width:90px;">${label}</td>` +
			`<td style="text-align:center;width:24px;">${f.startsWith('l') ? 'G' : 'D'}</td>` +
			`<td style="padding:2px 6px;">` +
			`<div style="display:flex;align-items:center;gap:6px;">` +
			`<div style="flex:1;height:8px;background:rgba(255,255,255,0.05);border-radius:4px;overflow:hidden;min-width:40px;">` +
			`<div style="height:100%;width:${bar_pct}%;background:${hand_color};"></div>` +
			`</div>` +
			`<span style="min-width:48px;text-align:right;${text_color}">${pct.toFixed(1)}%</span>` +
			`</div>` +
			`</td>` +
			`<td style="text-align:right;font-variant-numeric:tabular-nums;width:80px;">${format_number(n)}</td>` +
			`</tr>`
		);
	}).join('');
	container.innerHTML =
		`<div style="font-size:11px;color:var(--text-muted);margin:8px 0 4px 0;">Charge cumulée par doigt — répartition idéale ≈ 12,5% chacun</div>` +
		`<table style="width:100%;border-collapse:collapse;font-size:12px;"><tbody>${rows}</tbody></table>`;
}

// ============================================
// ============================================
// ======= 7/ Backend Data Requests =======
// ============================================
// ============================================

/**
 * Signals the Lua backend to send n-gram data for the current range/app
 * selection. The Lua timer polls window._lua_request every 300ms.
 * @param {boolean} [show_loader=true] - Whether to show the loading spinner.
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
			'<tr><td colspan="8" style="text-align:center;padding:30px;">' +
			'<div class="loader-spinner"></div> R\u00E9cup\u00E9ration et d\u00E9chiffrement depuis la DB...' +
			'</td></tr>';
	}

	// Slight delay so the UI renders the loader before the heavy decode starts
	setTimeout(() => {
		window._lua_request = JSON.stringify(req);
	}, 50);
}

/**
 * Receives the decoded n-gram payload from the Lua backend and triggers the
 * local filter/render pipeline.
 * @param {Object} payload - Contains { historical, today } n-gram dictionaries.
 */
function receive_range_data(payload) {
	app_state.loading_data = false;
	if (!payload) return;
	app_state.historical_cache = payload.historical;
	app_state.today_live_data = payload.today;
	apply_local_filters();
}

/**
 * Receives a real-time live-update push from the Lua keylogger and
 * re-renders the table after a short debounce to batch rapid keystrokes.
 * @param {Object} today_idx - The current session's live n-gram data.
 */
window.receive_live_update = function (today_idx) {
	app_state.today_live_data = today_idx;
	if (app_state.live_update_timer) clearTimeout(app_state.live_update_timer);
	app_state.live_update_timer = setTimeout(() => {
		apply_local_filters();
	}, 10);
};
