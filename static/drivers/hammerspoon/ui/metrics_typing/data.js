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
function merge_dict(target, source, case_sensitive, show_spaces, show_hs, show_llm, show_manual, tab_name) {
	if (!source || typeof source !== "object") return;
	// sc and sc_bg entries are always real user actions — never filter by source mode
	const is_shortcuts_tab = tab_name === "sc" || tab_name === "sc_bg";

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
			.replace(/\u00C2\u00A0/g, "\u00A0")         // "Â" + NBSP → NBSP
			.replace(/\u00E2\u0080\u00AF/g, "\u202F");   // "â" + PAD + "¯" → NNBSP

		if (!case_sensitive) display_k = display_k.toLowerCase();

		// Normalize known control characters to their bracket-marker or space equivalents
		// so they pass the ctrl-char filters and render with proper chip labels in all tabs.
		// RS (0x1E) is used by some keylogger versions as a space placeholder.
		display_k = display_k
			.replace(/\x08/g, "[BS]")
			.replace(/\x09/g, "[TAB]")
			// LF (\x0A) was used by older keylogger builds; CR (\x0D) matches
			// some edge cases — both map to [ENTER] so historical data is handled.
			.replace(/[\x0A\x0D]/g, "[ENTER]")
			.replace(/\x1B/g, "[ESC]")
			.replace(/\x1E/g, " ");

		// Only filter regular ASCII space — NBSP (U+00A0) and NNBSP (U+202F) are
		// distinct characters the user deliberately types (French typography) and
		// must never be hidden by the "masquer les espaces" toggle.
		// w_bg keys use a space as a word separator, not as a typed character — exempt them.
		if (!show_spaces && tab_name !== "w_bg" && display_k.includes(" ")) return;

		const item      = source[k];
		const total_c   = item.c  || 0;
		const hs_c      = item.hs || 0;
		const llm_c     = item.llm || 0;
		const other_c   = item.o  || 0;
		const manual_c  = Math.max(0, total_c - hs_c - llm_c - other_c);

		let real_count;
		let filtered_hs  = hs_c;
		let filtered_llm = llm_c;

		if (is_shortcuts_tab) {
			// Shortcuts are always shown without source filtering
			real_count = total_c;
		} else {
			filtered_hs  = show_hs  ? hs_c  : 0;
			filtered_llm = show_llm ? llm_c : 0;
			real_count   =
				(show_manual ? manual_c : 0) +
				filtered_hs +
				filtered_llm +
				other_c;
		}

		if (real_count <= 0) return;

		if (!target[display_k]) {
			target[display_k] = { count: 0, time: 0, errors: 0, synth_hs: 0, synth_llm: 0, synth_other: 0 };
		}

		target[display_k].count      += real_count;
		target[display_k].time       += item.t  || 0;
		target[display_k].errors     += item.e  || 0;
		target[display_k].synth_hs   += filtered_hs;
		target[display_k].synth_llm  += filtered_llm;
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
				if (app_name !== "Unknown") app_set.add(app_name);
			});
		});

		const prev_apps       = new Set(app_state.available_apps);
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

		const start_input = document.getElementById("date_start");
		const end_input   = document.getElementById("date_end");
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
			window._lua_request    = null;
			app_state.loading_data = false;
			receive_range_data(window._prefetch_data);
			window._prefetch_data  = null;
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
	app_state.time_series    = {};
	app_state.hourly_series  = {};
	app_state.minute5_series = {};
	for (let i = 0; i < 24; i++) {
		app_state.hourly_series[i.toString().padStart(2, "0")] = { c: 0, e: 0, es: 0 };
	}

	let global_hs_triggers  = 0;
	let global_llm_triggers = 0;
	let global_hs_suggested = 0;
	let global_llm_suggested = 0;

	const start_val   = document.getElementById("date_start").value;
	const end_val     = document.getElementById("date_end").value;
	const { show_manual, show_hs, show_llm, mpm_include_hs, mpm_include_llm } = get_source_mode_flags();

	const manifest_dates =
		app_state.manifest_dates_sorted.length > 0
			? app_state.manifest_dates_sorted
			: Object.keys(window.metrics_manifest).sort();

	manifest_dates.forEach((date_str) => {
		if (start_val && date_str < start_val) return;
		if (end_val   && date_str > end_val)   return;

		Object.keys(window.metrics_manifest[date_str]).forEach((app_name) => {
			if (app_name !== "Unknown" && !app_state.selected_apps.has(app_name)) return;

			const app = window.metrics_manifest[date_str][app_name];

			if (!app_state.time_series[date_str]) {
				app_state.time_series[date_str] = {
					chars: 0, wpm_chars: 0, time_ms: 0,
					hs_chars: 0, llm_chars: 0,
					daily_chars: 0, daily_manual_errors: 0,
				};
			}

			const total_chars    = app.chars      || 0;
			const hs_chars_raw   = app.hs_chars   || 0;
			const llm_chars_raw  = app.llm_chars  || 0;

			const manual_chars    = Math.max(0, total_chars - hs_chars_raw - llm_chars_raw);
			// MPM always counts output chars: HS/LLM expansions count even in raw-input
			// mode so the productivity boost is visible in the KPI while tables show triggers.
			const mpm_hs          = mpm_include_hs  ? hs_chars_raw  : 0;
			const mpm_llm         = mpm_include_llm ? llm_chars_raw : 0;
			const effective_wpm_chars    = manual_chars + mpm_hs + mpm_llm;
			// Volume displayed in the KPI text ("X touches tapées"):
			// In output view (no toggle) = total output; in raw-input view = manual triggers only.
			const table_hs        = show_hs  ? hs_chars_raw  : 0;
			const table_llm       = show_llm ? llm_chars_raw : 0;
			const effective_volume_chars = manual_chars + table_hs + table_llm;

			// Always surface HS/LLM KPI cards regardless of toggle state
			global_hs_triggers  += app.hs_triggers  || 0;
			global_hs_suggested += app.hs_suggested || 0;
			global_llm_triggers  += app.llm_triggers  || 0;
			global_llm_suggested += app.llm_suggested || 0;

			const ts = app_state.time_series[date_str];
			// ts.chars    = volume for display (output view: all sources; raw-input view: triggers only)
			// ts.wpm_chars = output chars for MPM — always includes HS/LLM expansions
			ts.chars     += effective_volume_chars;
			ts.wpm_chars += effective_wpm_chars;
			ts.time_ms   += app.time || 0;
			ts.hs_chars  += hs_chars_raw;
			ts.llm_chars += llm_chars_raw;

			if (app.hourly) {
				Object.keys(app.hourly).forEach((hour) => {
					const hour_data    = app.hourly[hour] || {};
					const manual_errs  = typeof hour_data.em === "number" ? hour_data.em : hour_data.e || 0;

					if (app_state.hourly_series[hour]) {
						app_state.hourly_series[hour].c  += hour_data.c  || 0;
						app_state.hourly_series[hour].e  += manual_errs;
						app_state.hourly_series[hour].es += hour_data.es || 0;
					}
					ts.daily_chars         += hour_data.c || 0;
					ts.daily_manual_errors += manual_errs;
				});
			}

			// 5-minute granularity — used by the last-hour chart preset
			if (app.hourly_min5) {
				Object.keys(app.hourly_min5).forEach((bucket) => {
					const md          = app.hourly_min5[bucket] || {};
					const manual_errs = md.e || 0;

					if (!app_state.minute5_series[bucket]) {
						app_state.minute5_series[bucket] = { c: 0, e: 0, es: 0 };
					}
					app_state.minute5_series[bucket].c  += md.c  || 0;
					app_state.minute5_series[bucket].e  += manual_errs;
					app_state.minute5_series[bucket].es += md.es || 0;
				});
			}
		});
	});

	// --- Aggregate totals and sparkline/chart data points ---
	const sorted_keys    = Object.keys(app_state.time_series).sort();
	const hs_points      = [], llm_points = [], wpm_points = [];
	let hs_chars_total   = 0, llm_chars_total   = 0;
	let global_chars     = 0, global_time_ms    = 0, wpm_chars_total = 0;

	sorted_keys.forEach((k) => {
		const d  = app_state.time_series[k];
		hs_chars_total   += d.hs_chars;
		llm_chars_total  += d.llm_chars;
		global_chars     += d.chars    || 0;
		global_time_ms   += d.time_ms  || 0;
		wpm_chars_total  += d.wpm_chars || 0;

		if (d.chars > 0) {
			hs_points.push(  { x: new Date(k + "T12:00:00"), y: (d.hs_chars  / d.chars) * 100 });
			llm_points.push( { x: new Date(k + "T12:00:00"), y: (d.llm_chars / d.chars) * 100 });
		}

		const day_wpm = d.wpm_chars >= 10 && d.time_ms > 0
			? d.wpm_chars / 5 / (d.time_ms / 60000)
			: 0;
		if (!isNaN(day_wpm) && day_wpm > 0) {
			wpm_points.push({ x: new Date(k + "T12:00:00"), y: day_wpm });
		}
	});

	// --- Render HS KPI card ---
	document.getElementById("hs_loading").style.display = "none";
	document.getElementById("hs_details").style.display = "flex";
	document.getElementById("hs_val").innerHTML =
		`${format_number(global_hs_triggers)} <span class="stat-unit">activations</span>`;
	document.getElementById("hs_net_val").innerHTML = format_number(hs_chars_total);

	let hs_pct = global_hs_suggested > 0 ? (global_hs_triggers / global_hs_suggested) * 100 : 0;
	if (hs_pct > 100) hs_pct = 100;
	document.getElementById("hs_acc_pct").innerHTML = `${format_number(hs_pct.toFixed(1))}%`;
	document.getElementById("hs_acc_raw").innerHTML =
		`(${format_number(global_hs_triggers)} / ${format_number(global_hs_suggested)})`;
	document.getElementById("hs_trend").innerHTML =
		get_trend_svg(hs_points.map(p => p.y).filter(y => y > 0));

	// --- Render LLM KPI card ---
	document.getElementById("llm_loading").style.display = "none";
	document.getElementById("llm_details").style.display = "flex";
	document.getElementById("llm_val").innerHTML =
		`${format_number(global_llm_triggers)} <span class="stat-unit">activations</span>`;
	document.getElementById("llm_net_val").innerHTML = format_number(llm_chars_total);

	let llm_pct = global_llm_suggested > 0 ? (global_llm_triggers / global_llm_suggested) * 100 : 0;
	if (llm_pct > 100) llm_pct = 100;
	document.getElementById("llm_acc_pct").innerHTML = `${format_number(llm_pct.toFixed(1))}%`;
	document.getElementById("llm_acc_raw").innerHTML =
		`(${format_number(global_llm_triggers)} / ${format_number(global_llm_suggested)})`;
	document.getElementById("llm_trend").innerHTML =
		get_trend_svg(llm_points.map(p => p.y).filter(y => y > 0));

	// --- Render global WPM KPI card (ONLY place allowed to write this KPI) ---
	document.getElementById("wpm_trend").innerHTML =
		get_trend_svg(wpm_points.map(p => p.y).filter(y => y > 0));

	const manifest_cpm = global_time_ms > 0 ? wpm_chars_total / (global_time_ms / 60000) : 0;
	const manifest_wpm = manifest_cpm / 5;

	const wpm_val_elem = document.getElementById("wpm_val");
	if (wpm_val_elem) {
		wpm_val_elem.innerHTML =
			`<div style="display:flex;flex-direction:column;justify-content:center;">` +
			`<div style="display:flex;align-items:center;gap:6px;">` +
			`<span>${format_number(manifest_wpm.toFixed(1))} <span class="stat-unit">MPM</span></span>` +
			`<span class="tooltip stat-inline-tooltip">${INFO_SVG}<span class="tooltiptext">MPM&nbsp;: Mots par minute, convention 1\u00A0mot = 5\u00A0touches</span></span>` +
			`</div>` +
			`<div style="display:flex;align-items:center;gap:6px;font-size:0.65em;margin-top:5px;">` +
			`<span>${format_number(manifest_cpm.toFixed(0))} <span class="stat-unit">CPM</span></span>` +
			`<span class="tooltip stat-inline-tooltip">${INFO_SVG}<span class="tooltiptext">CPM&nbsp;: Caract\u00E8res par minute</span></span>` +
			`</div>` +
			`</div>`;
	}

	const global_details = document.getElementById("global_details");
	if (global_details) {
		const { hs_raw_mode, llm_raw_mode } = get_source_mode_flags();
		const raw_note = (hs_raw_mode || llm_raw_mode)
			? `<div style="font-size:0.7em;color:var(--text-muted);margin-top:3px;">` +
			  `Frappes brutes (triggers) — MPM basé sur l’output</div>`
			: "";
		global_details.innerHTML =
			`<div style="margin-top:5px;">` +
			`<strong style="color:var(--kpi-wpm-color);font-size:1.1em;">${format_number(global_chars)}</strong>` +
			` <span class="stat-unit" style="font-size:0.9em;">touches tapées</span>` +
			`</div>${raw_note}`;
	}

	render_charts();
}


// ============================================
// ============================================
// ======= 3/ Local Filter Application =======
// ============================================
// ============================================

/**
 * Recomputes the global speed KPI (MPM/CPM) from the per-character timing data
 * in app_state.data.c, applying the user-selected pause threshold. Called from
 * apply_local_filters() so every threshold or source-mode change updates the KPI.
 *
 * Method: sum all (time, count) pairs from character entries whose mean inter-key
 * interval is ≤ pause_threshold. Intervals above the threshold indicate a pause
 * between bursts and are excluded from the active-typing time, giving a more
 * accurate speed that scales correctly with the selected threshold value.
 *
 * For hotstrings mode: the manifest-level app.time already bakes in output chars,
 * so we independently estimate raw-input speed and use an n-gram-based multiplier
 * to derive the equivalent output speed (marked "estimé").
 */
function recompute_speed_kpi() {
	const pause_thresh = parseInt(document.getElementById("pause_threshold")?.value ?? "2000", 10) || 2000;
	const { hs_raw_mode, llm_raw_mode } = get_source_mode_flags();
	const c_dict = app_state.data.c || {};

	// Sum time and char count for entries whose mean inter-key interval is ≤ threshold.
	// Each entry in c_dict has .time (total inter-key ms, manual chars) and .manual_count.
	let active_ms     = 0;
	let manual_active = 0;

	// c_dict.time only accumulates inter-key intervals for manually typed chars,
	// so it naturally excludes HS/LLM expansion bursts. Pause threshold applied
	// per-character: chars whose mean inter-key interval exceeds the threshold
	// indicate sustained pauses and are excluded from active typing time.
	Object.values(c_dict).forEach(item => {
		const mc = item.count - (item.synth_hs || 0) - (item.synth_llm || 0) - (item.synth_other || 0);
		if (mc <= 0) return;
		const avg = (item.time || 0) / mc;
		if (avg <= pause_thresh) {
			active_ms     += item.time || 0;
			manual_active += mc;
		}
	});

	// Estimate output chars = manual + HS output + LLM output.
	// In raw-input view, hs_chars/llm_chars from c_dict are trigger chars, not outputs.
	// We don't have output counts here, so we use the manifest totals for the ratio.
	// Manifest wpm_chars / manifest manual_chars gives an output-to-input multiplier.
	let manifest_total = 0;
	let manifest_hs    = 0;
	let manifest_llm   = 0;
	const start_val = document.getElementById("date_start").value;
	const end_val   = document.getElementById("date_end").value;
	const manifest_dates = app_state.manifest_dates_sorted.length > 0
		? app_state.manifest_dates_sorted
		: Object.keys(window.metrics_manifest).sort();
	manifest_dates.forEach(date_str => {
		if (start_val && date_str < start_val) return;
		if (end_val   && date_str > end_val)   return;
		Object.keys(window.metrics_manifest[date_str] || {}).forEach(app_name => {
			if (app_name !== "Unknown" && !app_state.selected_apps.has(app_name)) return;
			const app = window.metrics_manifest[date_str][app_name];
			manifest_total += app.chars     || 0;
			manifest_hs    += app.hs_chars  || 0;
			manifest_llm   += app.llm_chars || 0;
		});
	});
	const manifest_manual = Math.max(0, manifest_total - manifest_hs - manifest_llm);

	// Speed boost semantics: the "+ Hotstrings" and "+ IA" toggle buttons mean
	// "include this source's output boost in the speed display". When a toggle is
	// ACTIVE (raw_mode = true), that source's expansion IS included → higher MPM.
	// When a toggle is INACTIVE, that source is excluded → slower, manual-only speed.
	// - Both toggles OFF (default)  → eff = manual only            → lowest (raw speed)
	// - HS ON, LLM OFF              → eff = manual + hs            → middle
	// - HS OFF, LLM ON              → eff = manual + llm           → middle
	// - Both ON                     → eff = manual + hs + llm      → highest (full boost)
	const eff_output_chars =
		manifest_manual +
		(hs_raw_mode  ? manifest_hs  : 0) +
		(llm_raw_mode ? manifest_llm : 0);

	const output_multiplier = manifest_manual > 0
		? eff_output_chars / manifest_manual
		: 1.0;

	// "(estimé)" appears when at least one boost source is included — the resulting
	// speed is inferred from a manifest-level ratio, not directly measured.
	// When both toggles are OFF (multiplier = 1.0) the speed is purely measured.
	const is_estimated = output_multiplier > 1.01;

	const output_cpm = active_ms > 0
		? (manual_active * output_multiplier) / (active_ms / 60000)
		: 0;
	const output_wpm = output_cpm / 5;

	const wpm_val_elem = document.getElementById("wpm_val");
	if (!wpm_val_elem) return;

	const thresh_label = pause_thresh >= 99999000 ? "sans filtre"
		: pause_thresh >= 60000 ? `> ${pause_thresh/60000} min`
		: `> ${pause_thresh/1000} s`;
	const est_badge = is_estimated
		? `<span style="color:var(--text-muted);margin-left:4px;">(estimé)</span>`
		: "";

	wpm_val_elem.innerHTML =
		`<div style="display:flex;flex-direction:column;justify-content:center;">` +
		`<div style="display:flex;align-items:center;gap:6px;">` +
		`<span>${format_number(output_wpm.toFixed(1))} <span class="stat-unit">MPM${est_badge}</span></span>` +
		`<span class="tooltip stat-inline-tooltip">${INFO_SVG}<span class="tooltiptext">` +
		`MPM : Mots par minute (1 mot = 5 touches).<br>` +
		`Seuil de pause : pauses ${thresh_label} exclues du temps actif.<br>` +
		(is_estimated ? `Vitesse estimée : les chars générés par hotstrings/IA sont inférés via un ratio output/input (×${format_number(output_multiplier.toFixed(2))}).` : `Vitesse mesurée à partir du temps de frappe manuel.`) +
		`</span></span>` +
		`</div>` +
		`<div style="display:flex;align-items:center;gap:6px;font-size:0.65em;margin-top:5px;">` +
		`<span>${format_number(output_cpm.toFixed(0))} <span class="stat-unit">CPM</span></span>` +
		`<span class="tooltip stat-inline-tooltip">${INFO_SVG}<span class="tooltiptext">CPM : Caractères par minute</span></span>` +
		`</div>` +
		`</div>`;

	const global_details = document.getElementById("global_details");
	if (global_details) {
		const raw_note = (hs_raw_mode || llm_raw_mode)
			? `<div style="font-size:0.7em;color:var(--text-muted);margin-top:3px;">` +
			  `Frappes brutes (triggers) — MPM basé sur l’output</div>`
			: "";
		const total_display = Object.values(c_dict).reduce((s, i) => s + (i.count || 0), 0);
		global_details.innerHTML =
			`<div style="margin-top:5px;">` +
			`<strong style="color:var(--kpi-wpm-color);font-size:1.1em;">${format_number(total_display)}</strong>` +
			` <span class="stat-unit" style="font-size:0.9em;">touches tapées</span>` +
			`</div>${raw_note}`;
	}
}

/**
 * Applies all active toggle filters to the cached n-gram data and
 * re-renders the current table. Called after data fetch completes or when
 * a toggle filter changes.
 */
function apply_local_filters() {
	if (!app_state.historical_cache && !app_state.today_live_data) return;

	app_state.data = { c: {}, bg: {}, tg: {}, qg: {}, pg: {}, hx: {}, hp: {}, w: {}, sc: {}, sc_bg: {}, w_bg: {}, kc: {} };

	const { show_manual, show_hs, show_llm } = get_source_mode_flags();
	const show_spaces    = true; // Espaces toujours visibles (bouton supprimé)
	const case_sensitive = document.getElementById("btn_case_sensitive").classList.contains("active");

	const merge_source = (source_cache) => {
		if (!source_cache) return;
		Object.keys(app_state.data).forEach((tab) => {
			merge_dict(
				app_state.data[tab], source_cache[tab],
				case_sensitive, show_spaces, show_hs, show_llm, show_manual, tab
			);
		});
	};

	merge_source(app_state.historical_cache);

	// Merge today's live data if it falls within the selected date range
	const start_val  = document.getElementById("date_start").value;
	const end_val    = document.getElementById("date_end").value;
	const today_str  = get_local_date_string();

	let include_today = true;
	if (start_val && today_str < start_val) include_today = false;
	if (end_val   && today_str > end_val)   include_today = false;

	if (include_today && app_state.today_live_data) {
		Object.keys(app_state.today_live_data).forEach((app_name) => {
			// Register newly seen apps from live data
			if (app_name !== "Unknown" && !app_state.available_apps.includes(app_name)) {
				app_state.available_apps.push(app_name);
				app_state.available_apps.sort((a, b) => a.localeCompare(b));
				app_state.selected_apps.add(app_name);
				update_app_btn_text();
			}

			if (app_name !== "Unknown" && !app_state.selected_apps.has(app_name)) return;

			const app_data = app_state.today_live_data[app_name];
			Object.keys(app_state.data).forEach((tab) => {
				merge_dict(
					app_state.data[tab], app_data[tab],
					case_sensitive, show_spaces, show_hs, show_llm, show_manual, tab
				);
			});
		});
	}

	render_repetitions_kpi();
	render_distance_kpi();
	render_avg_words_kpi();
	recompute_speed_kpi();
	render_current_tab();
}


// =============================================
// =============================================
// ======= 4/ Repetitions KPI Rendering =======
// =============================================
// =============================================

// Module-level state for the doublings detail table
let _rep_data     = [];      // [{key, total, manual, star}]
let _rep_sort_col = "total"; // Active sort column
let _rep_sort_asc = false;   // Ascending when true

/**
 * Counts 2-key same-character bigrams (e.g. "aa", "ll") in the current
 * filtered bigram data and renders the repetitions KPI card and detail table.
 * The count reflects the active source mode so the user can compare:
 *   "Sans Ergopti": only manual doublings (user typed "aa" by hand).
 *   "+ Hotstrings": also includes HS-generated doublings (user typed "a★").
 * This highlights whether the ★ repeat key is being used in practice.
 */
function render_repetitions_kpi() {
	const bg_dict   = app_state.data.bg || {};
	let rep_count   = 0;
	let rep_hs      = 0;
	let total_count = 0;
	const doublings = [];

	Object.entries(bg_dict).forEach(([k, item]) => {
		const chars = Array.from(k);
		total_count += item.count || 0;
		// Bigram is a "doubling" when both grapheme clusters are identical
		if (chars.length === 2 && chars[0] === chars[1]) {
			const total  = item.count      || 0;
			const star   = item.synth_hs   || 0;
			const manual = Math.max(0, total - star - (item.synth_llm || 0) - (item.synth_other || 0));
			rep_count   += total;
			rep_hs      += star;
			doublings.push({ key: k, total, manual, star });
		}
	});

	// Store for table re-sorting without re-fetching data
	_rep_data = doublings;

	const loading_el = document.getElementById("rep_loading");
	const details_el = document.getElementById("rep_details");
	if (loading_el) loading_el.style.display = "none";
	if (details_el) details_el.style.display = "flex";

	// Render the value with the (i) tooltip inline — same superscript-like pattern
	// as the MPM KPI in the vitesse moyenne card.
	const val_el = document.getElementById("rep_val");
	if (val_el) {
		val_el.innerHTML =
			`<div style="display:flex;align-items:center;gap:6px;">` +
			`<span>${format_number(rep_count)} <span class="stat-unit">redoublements</span></span>` +
			`<span class="tooltip stat-inline-tooltip" style="color:var(--kpi-rep-color);">${INFO_SVG}` +
			`<span class="tooltiptext">Bigrammes o\u00F9 les deux touches sont identiques (ex.\u00A0\u00AB\u00A0aa\u00A0\u00BB, \u00AB\u00A0ll\u00A0\u00BB). R\u00E9fl\u00E8te le mode source actif\u00A0\u2014 comparez \u00AB\u00A0Sans Ergopti+\u00A0\u00BB et \u00AB\u00A0+\u00A0Hotstrings\u00A0\u00BB pour voir si la touche \u2605 est utilis\u00E9e.</span>` +
			`</span></div>`;
	}

	const rep_pct    = total_count > 0 ? (rep_count / total_count) * 100 : 0;
	const rep_hs_pct = rep_count   > 0 ? (rep_hs    / rep_count)   * 100 : 0;

	const pct_el = document.getElementById("rep_pct");
	if (pct_el) pct_el.innerHTML = `${format_number(rep_pct.toFixed(1))}%`;

	const hs_pct_el = document.getElementById("rep_hs_pct");
	if (hs_pct_el) hs_pct_el.innerHTML = `${format_number(rep_hs_pct.toFixed(1))}%`;

	const hs_raw_el = document.getElementById("rep_hs_raw");
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
	if (col !== active_col) return "\u00A0\u2195";
	return sort_asc ? "\u00A0\u2191" : "\u00A0\u2193";
}

/**
 * Renders (or re-renders after a sort click) the doublings detail table inside
 * the repetitions expanded KPI block. Shows all same-character bigrams with
 * global count, manual count, and ★ (hotstring) count columns.
 */
function render_rep_table() {
	const container = document.getElementById("rep_doublings_container");
	if (!container) return;

	const sorted = [..._rep_data].sort((a, b) => {
		const va = a[_rep_sort_col];
		const vb = b[_rep_sort_col];
		if (typeof va === "string") return _rep_sort_asc ? va.localeCompare(vb) : vb.localeCompare(va);
		return _rep_sort_asc ? va - vb : vb - va;
	});

	const h_key    = `Bigramme${_sort_arrow("key",    _rep_sort_col, _rep_sort_asc)}`;
	const h_total  = `Total${_sort_arrow("total",  _rep_sort_col, _rep_sort_asc)}`;
	const h_manual = `Manuel${_sort_arrow("manual", _rep_sort_col, _rep_sort_asc)}`;
	const h_star   = `Via\u00A0\u2605${_sort_arrow("star",   _rep_sort_col, _rep_sort_asc)}`;

	let rows_html;
	if (sorted.length === 0) {
		rows_html = `<tr><td colspan="4" style="text-align:center;padding:12px;color:var(--text-muted);">Aucun redoublement</td></tr>`;
	} else {
		rows_html = sorted.map(d => {
			const key_html  = `<span class="seq-chips">${format_seq_chips(d.key)}</span>`;
			const star_html = d.star > 0
				? format_number(d.star)
				: `<span style="color:var(--text-muted)">\u2014</span>`;
			return `<tr>
				<td>${key_html}</td>
				<td style="text-align:right;font-variant-numeric:tabular-nums;">${format_number(d.total)}</td>
				<td style="text-align:right;font-variant-numeric:tabular-nums;">${format_number(d.manual)}</td>
				<td style="text-align:right;font-variant-numeric:tabular-nums;">${star_html}</td>
			</tr>`;
		}).join("");
	}

	container.innerHTML =
		`<table class="ekpi-table">
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
		_rep_sort_asc = col === "key";
	}
	render_rep_table();
}


// =================================================
// =================================================
// ======= 5/ Finger Distance KPI Rendering =======
// =================================================
// =================================================

// Module-level state for the finger distance detail table
let _dist_data     = [];    // [{finger, label, hand, km}]
let _dist_sort_col = "km";  // Active sort column
let _dist_sort_asc = false; // Ascending when true

/**
 * Computes the total finger travel distance in km from the current filtered
 * keycode data and renders the distance KPI card, the km sub-line inside
 * the WPM card, and the per-finger detail table.
 * Called from apply_local_filters() so it reacts to every source-mode change.
 *
 * Method: for each keycode, retrieve its physical (x, y) position and the
 * rest position of the finger that types it. Distance per keystroke = Euclidean
 * distance from home to key × 2 (round-trip) × KEY_UNIT_MM. Summed over all
 * keycode counts and converted to km.
 */
function render_distance_kpi() {
	const kc_data = app_state.data.kc || {};
	let total_mm  = 0;

	// Per-finger accumulator: finger key → total mm
	const by_finger = {};

	Object.entries(kc_data).forEach(([kc_str, item]) => {
		const pos    = KEY_POSITIONS[kc_str];
		const finger = KEY_FINGER[kc_str];
		if (!pos || !finger) return;
		const home = FINGER_HOME[finger];
		if (!home) return;

		const dx         = pos.x - home.x;
		const dy         = pos.y - home.y;
		const dist_units = Math.sqrt(dx * dx + dy * dy);
		// Round-trip distance in mm for one keystroke
		const dist_mm    = dist_units * 2 * KEY_UNIT_MM * (item.count || 0);

		total_mm              += dist_mm;
		by_finger[finger]      = (by_finger[finger] || 0) + dist_mm;
	});

	const total_km = total_mm / 1_000_000;

	// Build table data — all fingers with non-zero distance
	_dist_data = Object.entries(by_finger)
		.filter(([, mm]) => mm > 0)
		.map(([finger, mm]) => ({
			finger,
			label: FINGER_LABELS_FR[finger] || finger,
			// Fingers starting with "l" are left-hand; "r" are right-hand
			hand:  finger.startsWith("l") ? "G" : "D",
			km:    mm / 1_000_000,
		}));

	// ── KPI card ──────────────────────────────────────────────────────────────
	const dist_loading = document.getElementById("dist_loading");
	const dist_details = document.getElementById("dist_details");
	if (dist_loading) dist_loading.style.display = "none";
	if (dist_details) dist_details.style.display = "flex";

	const dist_val_el = document.getElementById("dist_val");
	if (dist_val_el) {
		// Show in km when ≥ 1 km, otherwise in metres. The (i) tooltip is rendered inline
		// in a flex row so it sits in superscript-like position next to the unit — same
		// pattern as the MPM KPI in the vitesse moyenne card.
		const unit_str = total_km >= 1
			? `${format_number(total_km.toFixed(2))} <span class="stat-unit">km</span>`
			: `${format_number((total_mm / 1000).toFixed(1))} <span class="stat-unit">m</span>`;
		dist_val_el.innerHTML =
			`<div style="display:flex;align-items:center;gap:6px;">` +
			`<span>${unit_str}</span>` +
			`<span class="tooltip stat-inline-tooltip" style="color:var(--kpi-dist-color);">${INFO_SVG}` +
			`<span class="tooltiptext">Distance parcourue par les doigts, calcul\u00E9e doigt par doigt depuis leur position de repos (F\u00A0/\u00A0J\u00A0/\u00A0espace). Diminue significativement quand les hotstrings ou l\u2019IA g\u00E9n\u00E8rent des caract\u00E8res \u00E0 votre place.</span>` +
			`</span></div>`;
	}

	// Identify the most-active finger
	let max_finger = null, max_dist_mm = 0;
	Object.entries(by_finger).forEach(([f, d]) => {
		if (d > max_dist_mm) { max_dist_mm = d; max_finger = f; }
	});

	const dist_top_el = document.getElementById("dist_top_finger");
	if (dist_top_el && max_finger) {
		const label = FINGER_LABELS_FR[max_finger] || max_finger;
		const km    = max_dist_mm / 1_000_000;
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
	const container = document.getElementById("dist_fingers_container");
	if (!container) return;

	const sorted = [..._dist_data].sort((a, b) => {
		const va = a[_dist_sort_col];
		const vb = b[_dist_sort_col];
		if (typeof va === "string") return _dist_sort_asc ? va.localeCompare(vb) : vb.localeCompare(va);
		return _dist_sort_asc ? va - vb : vb - va;
	});

	const h_name = `Doigt${_sort_arrow("label", _dist_sort_col, _dist_sort_asc)}`;
	const h_hand = `Main${_sort_arrow("hand",  _dist_sort_col, _dist_sort_asc)}`;
	const h_km   = `Km parcourus${_sort_arrow("km", _dist_sort_col, _dist_sort_asc)}`;

	let rows_html;
	if (sorted.length === 0) {
		rows_html = `<tr><td colspan="3" style="text-align:center;padding:12px;color:var(--text-muted);">Aucune donn\u00E9e</td></tr>`;
	} else {
		rows_html = sorted.slice(0, 10).map(d => {
			const km_str = d.km >= 0.01
				? `${format_number(d.km.toFixed(3))}\u00A0km`
				: `${format_number((d.km * 1000).toFixed(1))}\u00A0m`;
			// Left-hand fingers in a warm tint, right-hand in the dist accent color
			const hand_color = d.hand === "G"
				? "var(--kpi-hs-color)"
				: "var(--kpi-dist-color)";
			return `<tr>
				<td>${d.label}</td>
				<td style="text-align:center;font-weight:bold;color:${hand_color}">${d.hand}</td>
				<td style="text-align:right;font-variant-numeric:tabular-nums;">${km_str}</td>
			</tr>`;
		}).join("");
	}

	container.innerHTML =
		`<table class="ekpi-table">
			<thead><tr>
				<th onclick="sort_dist_table('label')">${h_name}</th>
				<th onclick="sort_dist_table('hand')" style="text-align:center">${h_hand}</th>
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
		_dist_sort_asc = col !== "km";
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
	const sub_el = document.getElementById("wpm_words_sub");
	if (!sub_el) return;

	const w_dict = app_state.data.w || {};
	const c_dict = app_state.data.c || {};

	// Count total word occurrences across all entries in the words dict
	let total_words = 0;
	Object.values(w_dict).forEach(item => { total_words += item.count || 0; });

	// Sentence endings: sum of ., !, ? counts (case-insensitive keys just in case)
	const sentence_chars = [".", "!", "?"];
	let total_sentences = 0;
	sentence_chars.forEach(ch => {
		const entry = c_dict[ch];
		if (entry) total_sentences += entry.count || 0;
	});

	if (total_words === 0 || total_sentences === 0) {
		sub_el.innerHTML = "";
		return;
	}

	const avg = total_words / total_sentences;
	sub_el.innerHTML =
		`<div style="margin-top:5px;">` +
		`<strong style="color:var(--kpi-wpm-color);font-size:1.1em;">${format_number(avg.toFixed(1))}</strong>` +
		` <span class="stat-unit" style="font-size:0.9em;">mots par phrase en moyenne</span>` +
		`</div>`;
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
		start_date: document.getElementById("date_start").value,
		end_date:   document.getElementById("date_end").value,
		apps:       Array.from(app_state.selected_apps),
	};

	if (show_loader) {
		document.getElementById("metrics_table_body").innerHTML =
			"<tr><td colspan=\"8\" style=\"text-align:center;padding:30px;\">" +
			"<div class=\"loader-spinner\"></div> R\u00E9cup\u00E9ration et d\u00E9chiffrement depuis la DB..." +
			"</td></tr>";
	}

	// Slight delay so the UI renders the loader before the heavy decode starts
	setTimeout(() => { window._lua_request = JSON.stringify(req); }, 50);
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
	app_state.today_live_data  = payload.today;
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
	app_state.live_update_timer = setTimeout(() => { apply_local_filters(); }, 10);
};
