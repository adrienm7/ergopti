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
 * 2. Source Mode: Two independent toggles (+ Hotstrings, + IA) control which
 *    synthetic sources are included. An alternate "Sans Ergopti+" button shows
 *    the full output text (all sources) with WPM inferred at manual typing speed,
 *    giving a sense of what would have been typed without Ergopti+.
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
 * Manual keystrokes are always included. Hotstrings and LLM are independent
 * toggles: either or both may be active at the same time.
 * When "Texte final" mode is active, all sources are shown but the WPM
 * computation uses only manual keystrokes (inferred timing for synthetic chars).
 * @returns {{show_manual: boolean, show_hs: boolean, show_llm: boolean, texte_final: boolean}}
 */
function get_source_mode_flags() {
	const is_texte_final = document.getElementById("btn_texte_final")?.classList.contains("active") ?? false;
	// In Texte final mode, all sources are included for table/volume display
	if (is_texte_final) {
		return { show_manual: true, show_hs: true, show_llm: true, texte_final: true };
	}
	return {
		show_manual: true,
		show_hs:     document.getElementById("btn_toggle_hs")?.classList.contains("active")  ?? true,
		show_llm:    document.getElementById("btn_toggle_llm")?.classList.contains("active") ?? true,
		texte_final: false,
	};
}

/**
 * Toggles Hotstrings inclusion independently of the LLM toggle.
 * Deactivates "Texte final" mode if it was active (the individual toggles
 * are only meaningful in the regular trigger-based view).
 */
function toggle_hs_source() {
	document.getElementById("btn_texte_final")?.classList.remove("active");
	document.getElementById("btn_toggle_hs")?.classList.toggle("active");
	compute_manifest_metrics();
	apply_local_filters();
}

/**
 * Toggles LLM/IA inclusion independently of the Hotstrings toggle.
 * Deactivates "Texte final" mode if it was active.
 */
function toggle_llm_source() {
	document.getElementById("btn_texte_final")?.classList.remove("active");
	document.getElementById("btn_toggle_llm")?.classList.toggle("active");
	compute_manifest_metrics();
	apply_local_filters();
}

/**
 * Toggles the "Texte final" view mode.
 * When active: shows the full output text that would have been typed without
 * Ergopti+, with WPM inferred at the user's manual typing speed.
 * When inactive: reverts to the regular trigger-based view driven by the
 * individual Hotstrings / IA toggles.
 */
function toggle_texte_final() {
	document.getElementById("btn_texte_final")?.classList.toggle("active");
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

	// Default: both Hotstrings and IA active, Texte final off
	// (= equivalent of the old "+IA" default that showed everything)
	document.getElementById("btn_toggle_hs")?.classList.add("active");
	document.getElementById("btn_toggle_llm")?.classList.add("active");
	document.getElementById("btn_texte_final")?.classList.remove("active");

	// Restore remaining toggle buttons to their defaults
	document.getElementById("btn_show_spaces").classList.add("active");
	document.getElementById("btn_case_sensitive").classList.remove("active");

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
