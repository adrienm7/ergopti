// ui/metrics_typing/modal.js

/**
 * ==============================================================================
 * MODULE: App Filter Modal
 * DESCRIPTION:
 * Manages the application selector modal: rendering the app list with icons,
 * handling search/select/deselect, and syncing the filter button label.
 *
 * FEATURES & RATIONALE:
 * 1. Bug Fix — get_app_color: The original code called get_app_color() which
 *    was never defined, causing a ReferenceError that silently prevented the
 *    modal from opening. This module implements the missing function.
 * 2. Deterministic Colors: App icon fallback colors are seeded from the app
 *    name so the same app always gets the same color across sessions.
 * ==============================================================================
 */


// =============================================
// =============================================
// ======= 1/ App Color & Icon Helpers =======
// =============================================
// =============================================

// Color palette for app icon fallback badges
const APP_BADGE_COLORS = [
	"#007AFF", "#34C759", "#FF3B30", "#FF9500", "#AF52DE",
	"#FF2D55", "#5AC8FA", "#FFCC00", "#4CD964", "#FF6B00",
	"#30B0C7", "#FF6961", "#77DD77", "#AEC6CF", "#CB99C9",
];

/**
 * Returns a deterministic badge color for an app based on its name.
 * Same name always returns the same color so the UI stays stable.
 * @param {string} name - The application display name.
 * @returns {string} A hex color string.
 */
function get_app_color(name) {
	let hash = 0;
	for (let i = 0; i < name.length; i++) {
		hash = ((hash << 5) - hash) + name.charCodeAt(i);
		hash |= 0;
	}
	return APP_BADGE_COLORS[Math.abs(hash) % APP_BADGE_COLORS.length];
}


// ============================================
// ============================================
// ======= 2/ Filter Button Label =======
// ============================================
// ============================================

/**
 * Updates the "Apps" filter button text to reflect the current selection count.
 */
function update_app_btn_text() {
	const btn = document.getElementById("app_filter_btn");
	if (!btn) return;

	const sel = app_state.selected_apps.size;
	const tot = app_state.available_apps.length;

	if (sel === tot) {
		btn.innerText = "Apps (Toutes)";
		btn.classList.add("active");
	} else {
		btn.innerText = sel === 0 ? "Apps (Aucune)" : `Apps (${sel}/${tot})`;
		btn.classList.remove("active");
	}
}


// ======================================
// ======================================
// ======= 3/ Modal Open / Close =======
// ======================================
// ======================================

/**
 * Opens the app filter modal and renders the current app list.
 */
function open_app_modal() {
	const search_input = document.getElementById("app_search");
	if (search_input) search_input.value = "";
	render_app_list();
	document.getElementById("app_modal").style.display = "flex";
	if (search_input) search_input.focus();
}

/**
 * Closes the app filter modal and applies the updated selection.
 */
function close_app_modal() {
	document.getElementById("app_modal").style.display = "none";
	update_app_btn_text();
	apply_date_app_filters();
}

/**
 * Selects all available apps and re-renders the list.
 */
function select_all_apps() {
	app_state.available_apps.forEach((app) => app_state.selected_apps.add(app));
	render_app_list();
}

/**
 * Deselects all available apps and re-renders the list.
 */
function deselect_all_apps() {
	app_state.selected_apps.clear();
	render_app_list();
}

/**
 * Toggles a single app's selection state from its checkbox.
 * @param {HTMLInputElement} checkbox - The checkbox element that changed.
 */
function toggle_app_selection(checkbox) {
	if (checkbox.checked) {
		app_state.selected_apps.add(checkbox.value);
	} else {
		app_state.selected_apps.delete(checkbox.value);
	}
}


// =====================================
// =====================================
// ======= 4/ App List Rendering =======
// =====================================
// =====================================

/**
 * Re-renders the scrollable app list inside the modal, filtered by the
 * search input and decorated with icons or colored badge fallbacks.
 */
function render_app_list() {
	const query     = (document.getElementById("app_search")?.value ?? "").toLowerCase();
	const container = document.getElementById("app_list");
	if (!container) return;

	let html = "";

	app_state.available_apps.forEach((app) => {
		if (!app.toLowerCase().includes(query)) return;

		const checked  = app_state.selected_apps.has(app) ? "checked" : "";
		const icon_src = window.app_icons?.[app];
		const icon_html = icon_src
			? `<img src="${icon_src}" class="app-icon-img" alt="${escape_html(app)}" />`
			: `<div class="app-icon-div" style="background-color:${get_app_color(app)}">${app.charAt(0).toUpperCase()}</div>`;

		html += `<label class="app-item">` +
			`<input type="checkbox" value="${escape_html(app)}" ${checked} onchange="toggle_app_selection(this)">` +
			`<div class="app-icon-wrapper">${icon_html}</div>` +
			`<span class="app-name">${escape_html(app)}</span>` +
			`</label>`;
	});

	container.innerHTML = html ||
		"<div style=\"padding:15px; color:var(--text-muted); text-align:center;\">Aucune application trouv\u00E9e</div>";
}
