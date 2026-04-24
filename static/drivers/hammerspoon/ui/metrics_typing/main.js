// ui/metrics_typing/main.js

/**
 * ==============================================================================
 * MODULE: Main Entry Point
 * DESCRIPTION:
 * Exports all public functions to the global window object so that HTML
 * inline event handlers (onclick, onchange, onkeyup) can find them.
 * Also binds keyboard shortcuts and drives the custom find-in-page bar.
 *
 * FEATURES & RATIONALE:
 * 1. Explicit Exports: Every function called from HTML is explicitly listed here
 *    so there is a single place to audit what the HTML layer can call.
 * 2. Escape-to-Close: Both the app filter modal and the find bar can be dismissed
 *    with Escape for keyboard users.
 * 3. Custom Find-in-Page: window.find() is unreliable in Hammerspoon's WKWebView.
 *    Instead we walk all visible text nodes with a TreeWalker, wrap matches in
 *    <span class="find-highlight"> elements, and navigate between them while
 *    displaying an "i / n" counter.  A full re-scan runs whenever the query
 *    changes; same-query presses only advance the index.  If the table re-renders
 *    mid-search the stale spans are detected and a transparent re-scan fires.
 * ==============================================================================
 */


// ===================================
// ===================================
// ======= 1/ Window Exports =======
// ===================================
// ===================================

// Data pipeline
window.process_manifest    = process_manifest;
window.receive_range_data  = receive_range_data;
// receive_live_update is already assigned in data.js via window.receive_live_update = ...

// Filter management
window.toggle_filter           = toggle_filter;
window.apply_date_app_filters  = apply_date_app_filters;
window.apply_quick_date_range  = apply_quick_date_range;
window.toggle_hs_source        = toggle_hs_source;
window.toggle_llm_source       = toggle_llm_source;
window.toggle_texte_final      = toggle_texte_final;
window.reset_filters           = reset_filters;

// Table interactions
window.switch_tab    = switch_tab;
window.handle_search = handle_search;
window.handle_sort   = handle_sort;

// Modal management
window.open_app_modal       = open_app_modal;
window.close_app_modal      = close_app_modal;
window.select_all_apps      = select_all_apps;
window.deselect_all_apps    = deselect_all_apps;
window.toggle_app_selection = toggle_app_selection;
window.render_app_list      = render_app_list;

// Chart zoom reset
window.reset_chart_zoom = reset_chart_zoom;

// Expanded KPI block sort handlers
window.sort_dist_table = sort_dist_table;
window.sort_rep_table  = sort_rep_table;

// Find-in-page bar
window.show_find_bar  = show_find_bar;
window.close_find_bar = close_find_bar;
window.find_in_page   = find_in_page;


// =================================
// =================================
// ======= 2/ Find-in-Page =======
// =================================
// =================================

// Internal state — all private (underscore prefix, not exported)
let _find_matches = [];   // Ordered array of .find-highlight <span> elements
let _find_index   = -1;   // Index of the currently active match
let _find_query   = "";   // Lower-cased query that produced _find_matches


/**
 * Shows the find-in-page bar and focuses the text input.
 */
function show_find_bar() {
	const bar = document.getElementById("find_bar");
	if (!bar) return;
	bar.style.display = "flex";
	const input = document.getElementById("find_input");
	if (input) { input.focus(); input.select(); }
}

/**
 * Hides the find bar, removes all highlights, and resets internal state.
 */
function close_find_bar() {
	const bar = document.getElementById("find_bar");
	if (bar) bar.style.display = "none";
	_clear_highlights();
	_find_matches = [];
	_find_index   = -1;
	_find_query   = "";
	_set_find_status("", false);
}

/**
 * Removes every .find-highlight span from the DOM, restoring plain text nodes.
 * Adjacent text nodes are merged afterwards so the DOM stays clean.
 */
function _clear_highlights() {
	const parents = new Set();
	document.querySelectorAll("span.find-highlight").forEach(span => {
		const parent = span.parentNode;
		if (!parent) return;
		parent.replaceChild(document.createTextNode(span.textContent), span);
		parents.add(parent);
	});
	// Merge adjacent text nodes so the next scan produces clean results
	parents.forEach(p => { try { p.normalize(); } catch (_) {} });
}

/**
 * Walks all visible text nodes in document.body and wraps every occurrence of
 * lower_query (matched case-insensitively against the original text) in a
 * <span class="find-highlight">. Populates _find_matches with the new spans.
 * @param {string} lower_query - Already lower-cased search string.
 */
function _scan_and_highlight(lower_query) {
	const walker = document.createTreeWalker(
		document.body,
		NodeFilter.SHOW_TEXT,
		{
			acceptNode(node) {
				const parent = node.parentElement;
				if (!parent) return NodeFilter.FILTER_REJECT;
				const tag = parent.tagName.toLowerCase();
				// Skip containers that hold no user-visible text
				if (["script", "style", "input", "textarea", "canvas"].includes(tag)) {
					return NodeFilter.FILTER_REJECT;
				}
				// Skip the find bar and the hidden app modal to avoid self-referential matches
				if (parent.closest && (
					parent.closest("#find_bar") ||
					parent.closest("#app_modal")
				)) {
					return NodeFilter.FILTER_REJECT;
				}
				return NodeFilter.FILTER_ACCEPT;
			},
		}
	);

	// Collect nodes before mutating the DOM to avoid invalidating the walker
	const text_nodes = [];
	let node;
	while ((node = walker.nextNode())) text_nodes.push(node);

	const q_len = lower_query.length;

	text_nodes.forEach(text_node => {
		const text       = text_node.textContent;
		const lower_text = text.toLowerCase();
		if (!lower_text.includes(lower_query)) return;

		const fragment = document.createDocumentFragment();
		let   last_idx = 0;
		let   idx;

		while ((idx = lower_text.indexOf(lower_query, last_idx)) !== -1) {
			if (idx > last_idx) {
				fragment.appendChild(document.createTextNode(text.slice(last_idx, idx)));
			}
			const span      = document.createElement("span");
			span.className  = "find-highlight";
			span.textContent = text.slice(idx, idx + q_len);
			fragment.appendChild(span);
			_find_matches.push(span);
			last_idx = idx + q_len;
		}

		if (last_idx < text.length) {
			fragment.appendChild(document.createTextNode(text.slice(last_idx)));
		}

		text_node.parentNode.replaceChild(fragment, text_node);
	});
}

/**
 * Marks the span at idx as the active match: applies the current class and
 * scrolls it into view. Removes the current class from all others first.
 * @param {number} idx - Index into _find_matches.
 */
function _activate_match(idx) {
	_find_matches.forEach(m => m.classList.remove("find-highlight-current"));
	if (idx < 0 || idx >= _find_matches.length) return;
	const current = _find_matches[idx];
	// Guard: the span may have been removed if the table re-rendered since the scan
	if (!document.contains(current)) return;
	current.classList.add("find-highlight-current");
	current.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" });
}

/**
 * Updates the status text shown next to the navigation buttons.
 * @param {string}  text       - The string to display (e.g. "3 / 42" or "Introuvable").
 * @param {boolean} not_found  - Whether to apply the red "not found" color class.
 */
function _set_find_status(text, not_found) {
	const status = document.getElementById("find_status");
	if (!status) return;
	status.textContent = text;
	status.classList.toggle("find-not-found", not_found);
}

/**
 * Executes a forward or backward find, highlighting all matches and showing
 * "i\u202F/\u202Fn" in the status area. On first call (or after query change)
 * a full DOM scan runs; repeated calls with the same query only advance the index.
 * If the table re-rendered since the last scan the stale spans are detected and
 * a transparent re-scan fires before navigating.
 * @param {boolean} forward - true = find next, false = find previous.
 */
function find_in_page(forward) {
	const raw_query   = document.getElementById("find_input")?.value ?? "";
	const lower_query = raw_query.toLowerCase();

	if (!lower_query) {
		_clear_highlights();
		_find_matches = [];
		_find_index   = -1;
		_find_query   = "";
		_set_find_status("", false);
		return;
	}

	if (lower_query !== _find_query) {
		// Query changed: full DOM scan
		_clear_highlights();
		_find_matches = [];
		_find_query   = lower_query;
		_scan_and_highlight(lower_query);

		if (_find_matches.length === 0) {
			_find_index = -1;
			_set_find_status("Introuvable", true);
			return;
		}
		_find_index = forward ? 0 : _find_matches.length - 1;
	} else {
		// Same query: just advance the cursor
		if (_find_matches.length === 0) {
			_set_find_status("Introuvable", true);
			return;
		}
		// Detect stale spans (table re-rendered) and re-scan transparently
		if (_find_index >= 0 && !document.contains(_find_matches[_find_index])) {
			_clear_highlights();
			_find_matches = [];
			_scan_and_highlight(lower_query);
			if (_find_matches.length === 0) {
				_find_index = -1;
				_set_find_status("Introuvable", true);
				return;
			}
			_find_index = forward ? 0 : _find_matches.length - 1;
		} else {
			_find_index = forward
				? (_find_index + 1) % _find_matches.length
				: (_find_index - 1 + _find_matches.length) % _find_matches.length;
		}
	}

	_activate_match(_find_index);
	// \u202F = narrow no-break space for tighter "i / n" display
	_set_find_status(`${_find_index + 1}\u202F/\u202F${_find_matches.length}`, false);
}


// ==========================
// ==========================
// ======= 3/ DOM Init =====
// ==========================
// ==========================

document.addEventListener("DOMContentLoaded", () => {
	// Global keyboard shortcuts
	document.addEventListener("keydown", (e) => {
		// Cmd+F / Ctrl+F → open find bar (prevent default browser behavior)
		if ((e.metaKey || e.ctrlKey) && e.key === "f") {
			e.preventDefault();
			show_find_bar();
			return;
		}
		// Escape → close find bar first, then app modal if open
		if (e.key === "Escape") {
			const find_bar = document.getElementById("find_bar");
			if (find_bar && find_bar.style.display !== "none") {
				close_find_bar();
				return;
			}
			const modal = document.getElementById("app_modal");
			if (modal && modal.style.display !== "none") close_app_modal();
		}
	});

	// Find input: Enter = next, Shift+Enter = previous, Escape = close
	const find_input = document.getElementById("find_input");
	if (find_input) {
		find_input.addEventListener("keydown", (e) => {
			if (e.key === "Enter")  { e.preventDefault(); find_in_page(!e.shiftKey); }
			if (e.key === "Escape") { e.preventDefault(); close_find_bar(); }
		});
		// Live search: re-scan on every keystroke so results appear immediately
		find_input.addEventListener("input", () => {
			find_in_page(true);
		});
	}

	// Close the app filter modal when clicking outside the modal-content box
	const modal = document.getElementById("app_modal");
	if (modal) {
		modal.addEventListener("click", (e) => {
			if (e.target === modal) close_app_modal();
		});
	}
});
