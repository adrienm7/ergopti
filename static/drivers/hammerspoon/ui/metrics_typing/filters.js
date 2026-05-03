// ui/metrics_typing/filters.js

/**
 * ==============================================================================
 * MODULE: Filter Management
 * DESCRIPTION:
 * Manages all date range, quick-period, toggle, and reset controls for the
 * metrics dashboard. Acts as the coordinator between UI controls and the
 * data/rendering pipeline.
 *
 * FEATURES & RATIONALE:
 * 1. Quick Date Ranges: Presets (today, week, month, 3m, 6m, year, all) save
 *    time when jumping to common analysis windows.
 * 2. Source Mode: Two independent toggles (+ Hotstrings, + IA) switch between
 *    output view (default, no toggle) and raw-input view (toggle active).
 *    Output view: tables show the final text that appeared on screen.
 *    Raw-input view: tables show only the trigger chars the user actually typed;
 *    MPM still counts output chars so the productivity boost remains visible.
 *    All KPIs, charts, and table sections respond to the selected mode.
 * 3. Pause Threshold: Filters only the per-row WPM in the table; the global
 *    KPI always uses the full manifest time (which already excludes pauses).
 * 4. Tab-Preserving Reset: Resetting filters does not change the active tab,
 *    which would discard the user's current view.
 * ==============================================================================
 */


// ============================================
// ============================================
// ======= 1/ Date Range Helpers =======
// ============================================
// ============================================

/**
 * Returns the default date range: first logged date to today.
 * @returns {{start: string, end: string}} ISO date strings.
 */
function get_default_date_range() {
	const sorted_dates =
		app_state.manifest_dates_sorted.length > 0
			? app_state.manifest_dates_sorted
			: Object.keys(window.metrics_manifest).sort();
	const today            = get_local_date_string();
	const first_logged     = sorted_dates.length > 0 ? sorted_dates[0] : today;
	return { start: first_logged, end: today };
}

/**
 * Writes the default date range into the date picker inputs.
 */
function apply_default_date_range() {
	const start_input = document.getElementById("date_start");
	const end_input   = document.getElementById("date_end");
	if (!start_input || !end_input) return;
	const range       = get_default_date_range();
	start_input.value = range.start;
	end_input.value   = range.end;
}

/**
 * Applies a quick date range preset and triggers a full data refresh.
 * Resets the dropdown to the placeholder after applying to avoid stale state.
 * Sets app_state.hour_cutoff so the chart layer knows which granularity to use:
 *   null → daily (multi-day); 0 → today all-day (hourly); N → last hour (hours ≥ N).
 */
function apply_quick_date_range() {
	const sel   = document.getElementById("quick_range");
	const val   = sel ? sel.value : "";
	if (!val) return;

	const today = get_local_date_string();
	const now   = new Date();
	let start   = today;

	if (val === "last_hour") {
		// Show the current hour and the previous one — max 2 hourly data points
		start = today;
		app_state.hour_cutoff = Math.max(0, now.getHours() - 1);
	} else if (val === "today") {
		start = today;
		app_state.hour_cutoff = 0;
	} else {
		// All multi-day presets switch back to daily granularity
		app_state.hour_cutoff = null;

		if (val === "week") {
			// ISO week: starts on Monday
			const d = new Date(now);
			const day = d.getDay() || 7;
			d.setDate(d.getDate() - day + 1);
			start = format_date_iso(d);
		} else if (val === "month") {
			start = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-01`;
		} else if (val === "3m") {
			const d = new Date(now);
			d.setMonth(d.getMonth() - 3);
			start = format_date_iso(d);
		} else if (val === "6m") {
			const d = new Date(now);
			d.setMonth(d.getMonth() - 6);
			start = format_date_iso(d);
		} else if (val === "year") {
			start = `${now.getFullYear()}-01-01`;
		} else if (val === "all") {
			const range = get_default_date_range();
			start = range.start;
		}
	}

	document.getElementById("date_start").value = start;
	document.getElementById("date_end").value   = today;
	// Reset dropdown to placeholder so re-selecting the same option still fires
	if (sel) sel.value = "";

	apply_date_app_filters();
}


// ==========================================
// ==========================================
// ======= 2/ Toggle & Filter Actions =======
// ==========================================
// ==========================================

/**
 * Returns the current source-mode flags.
 *
 * The two toggles work as "raw input" lenses — each one switches the
 * corresponding source from "show the expanded output chars" to "show only
 * the trigger chars actually typed".
 *
 * Default (no toggle active):
 *   Tables show the final text that appeared on screen (output).
 *   MPM is based on output chars / active typing time.
 *
 * + Hotstrings active:
 *   Tables show only the manual trigger chars (e.g. "at", not "attend").
 *   MPM is still based on output chars / active typing time so the speed
 *   boost from hotstrings is visible in the KPI even though the table shows
 *   fewer characters.
 *
 * + IA active: same principle for LLM-generated chars.
 *
 * @returns {{show_hs_in_table: boolean, show_llm_in_table: boolean,
 *            hs_raw_mode: boolean, llm_raw_mode: boolean}}
 */
function get_source_mode_flags() {
	const hs_raw  = document.getElementById("btn_toggle_hs")?.classList.contains("active")  ?? false;
	const llm_raw = document.getElementById("btn_toggle_llm")?.classList.contains("active") ?? false;
	return {
		show_manual:       true,
		// When raw mode is ON for a source, hide its synthetic chars from tables
		// (user sees triggers only). When raw mode is OFF, include them (output view).
		show_hs:           !hs_raw,
		show_llm:          !llm_raw,
		hs_raw_mode:       hs_raw,
		llm_raw_mode:      llm_raw,
		// MPM always counts output chars so the productivity boost is visible
		mpm_include_hs:    true,
		mpm_include_llm:   true,
		// Kept for backward compatibility with any remaining callers
		texte_final:       false,
	};
}

/**
 * Toggles Hotstrings raw-input mode.
 * When active: tables show trigger chars only; MPM still uses output chars.
 */
function toggle_hs_source() {
	document.getElementById("btn_toggle_hs")?.classList.toggle("active");
	compute_manifest_metrics();
	apply_local_filters();
}

/**
 * Toggles IA raw-input mode.
 * When active: tables show trigger chars only; MPM still uses output chars.
 */
function toggle_llm_source() {
	document.getElementById("btn_toggle_llm")?.classList.toggle("active");
	compute_manifest_metrics();
	apply_local_filters();
}

/**
 * Toggles one of the boolean filter buttons and re-runs the full pipeline.
 * @param {string} btn_id - DOM ID of the button to toggle.
 */
function toggle_filter(btn_id) {
	document.getElementById(btn_id).classList.toggle("active");
	compute_manifest_metrics();
	apply_local_filters();
}

/**
 * Applies date and app filters: recomputes manifest KPIs and re-fetches the
 * n-gram data from the backend for the new range.
 */
function apply_date_app_filters() {
	compute_manifest_metrics();
	request_range_data();
}

/**
 * Resets all filters (dates, source mode, toggles, app selection, pause
 * threshold, quick range) to their defaults WITHOUT changing the active tab.
 */
function reset_filters() {
	apply_default_date_range();

	// Default: HS, IA and case-sensitive all ON out of the box
	document.getElementById("btn_toggle_hs")?.classList.add("active");
	document.getElementById("btn_toggle_llm")?.classList.add("active");

	// Restore remaining toggle buttons to their defaults
	document.getElementById("btn_case_sensitive").classList.add("active");

	// Restore pause threshold and quick range selects to their defaults
	const pause_sel = document.getElementById("pause_threshold");
	if (pause_sel) pause_sel.value = "2000";
	const quick_sel = document.getElementById("quick_range");
	if (quick_sel) quick_sel.value = "";

	// Revert to daily chart granularity
	app_state.hour_cutoff = null;

	// Re-select all available apps
	app_state.available_apps.forEach((app) => app_state.selected_apps.add(app));
	update_app_btn_text();

	// Intentionally does NOT change app_state.current_tab
	apply_date_app_filters();
}


// ==========================================
// ==========================================
// ======= 3/ Live Refresh Binding =======
// ==========================================
// ==========================================

/**
 * Binds visibility/focus events so the dashboard auto-refreshes when the
 * window regains focus (e.g. after switching back from another app).
 * Guards against duplicate binding.
 */
function ensure_live_refresh() {
	if (auto_refresh_bound) return;
	auto_refresh_bound = true;

	const refresh_if_idle = () => {
		if (app_state.loading_data) return;
		request_range_data(false);
	};

	document.addEventListener("visibilitychange", () => {
		if (!document.hidden) refresh_if_idle();
	});
	window.addEventListener("focus", refresh_if_idle);
}
