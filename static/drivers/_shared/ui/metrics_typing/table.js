// ui/metrics_typing/table.js

/**
 * ==============================================================================
 * MODULE: Table Rendering
 * DESCRIPTION:
 * Manages all n-gram/word/shortcut table interactions: tab switching, sorting,
 * search, and row rendering.
 *
 * FEATURES & RATIONALE:
 * 1. KPI Bug Fix: render_current_tab() no longer overwrites the global WPM
 *    KPI card. The KPI is set exclusively by compute_manifest_metrics() in
 *    data.js, ensuring it always reflects the full manifest period regardless
 *    of which table section is active.
 * 2. Repetition Filter: Same-character sequences (e.g. "aaa") can be hidden
 *    via app_state.show_repetitions to declutter n-gram views.
 * 3. requestAnimationFrame Batching: render_table() defers DOM writes to the
 *    next animation frame to avoid blocking the main thread during live typing.
 * 4. Column Rename: "Vitesse Moy. (ms)" is now "Temps moyen (ms)" — ms is a
 *    duration unit, not a speed unit.
 * 5. Control-Char Filtering: ASCII control characters (codes 0–31, 127, BOM)
 *    are stripped from all text-based tabs so OS artifacts never appear in
 *    the table, totals, or column KPIs.
 * 9. Word Repetitions: for the words tab, consecutive identical words (separated
 *    by space, tab, or enter as normalised by merge_dict) are detected by looking
 *    up word+sep+word patterns directly in the word dict.
 * 6. Characters-Tab Expansion: The "c" tab decomposes multi-token keys into
 *    individual characters so that NBSP, NNBSP, and chars only found in combos
 *    (e.g. NBSP+?) are surfaced as standalone entries. Bracket markers such as
 *    [TAB] or [F1] count as single tokens and are shown with red chip styling.
 * 7. Rich Search: build_searchable_key() augments raw keys with human-readable
 *    aliases (nbsp, nnbsp, backspace, control-char names) so searching those
 *    terms finds the corresponding entries.
 * 8. Shift Modifier Inference: derive_modifier_usage() counts uppercase A–Z
 *    presses from the raw cache to surface Shift usage in the Modifiers tab
 *    even when case-insensitive mode folds them into lowercase.
 * ==============================================================================
 */


// ==================================
// ==================================
// ======= 1/ Tab Navigation =======
// ==================================
// ==================================

/**
 * Switches the active tab, resets sort/search state, and re-renders the table.
 * @param {string} tab_name - The tab key: c, bg, tg, qg, pg, hx, hp, w, sc, sc_bg, w_bg, mods, kc.
 */
function switch_tab(tab_name) {
	app_state.current_tab = tab_name;

	document.querySelectorAll(".tabs .tab-btn").forEach((btn) => btn.classList.remove("active"));
	const active_btn = document.querySelector(`.tab-btn[data-tab="${tab_name}"]`);
	if (active_btn) active_btn.classList.add("active");

	// Reset table state to "most frequent first" when switching sections
	app_state.sort_col    = "count";
	app_state.sort_asc    = false;
	app_state.search_query = "";

	const search_input = document.getElementById("search_input");
	if (search_input) search_input.value = "";

	render_current_tab();
}

/**
 * Updates the search query from the table header input and re-renders.
 */
function handle_search() {
	// Preserve original case — render_table() applies the case-sensitive toggle
	app_state.search_query = document.getElementById("search_input")?.value ?? "";
	render_table();
}

/**
 * Toggles or sets the sort column for the current table and re-renders.
 * @param {string} col_name - The sort key: key, count, freq, avg, wpm, acc.
 */
function handle_sort(col_name) {
	if (app_state.sort_col === col_name) {
		app_state.sort_asc = !app_state.sort_asc;
	} else {
		app_state.sort_col = col_name;
		// Alphabetical sort defaults to ascending; all others default to descending
		app_state.sort_asc = col_name === "key";
	}
	render_table();
}


// =========================================
// =========================================
// ======= 2/ Current Tab Processing =======
// =========================================
// =========================================

/**
 * Counts uppercase A–Z presses from the raw historical and live caches, applying
 * the current HS/LLM/manual source filters. This is called independently of the
 * case-sensitivity toggle so Shift usage is always visible in the Modifiers tab.
 * @returns {number} Total number of inferred Shift presses from character data.
 */
function count_uppercase_shift() {
	const { show_manual, show_hs, show_llm } = get_source_mode_flags();
	let total = 0;

	const add_from_c_dict = (c_dict) => {
		if (!c_dict || typeof c_dict !== "object") return;
		Object.entries(c_dict).forEach(([k, v]) => {
			if (k.length !== 1) return;
			const code = k.codePointAt(0);
			// Only unambiguous uppercase ASCII A–Z, which require Shift on every layout
			if (code < 65 || code > 90) return;
			const total_c  = v.c   || 0;
			const hs_c     = v.hs  || 0;
			const llm_c    = v.llm || 0;
			const other_c  = v.o   || 0;
			const manual_c = Math.max(0, total_c - hs_c - llm_c - other_c);
			// "other" chars always counted (no toggle for this source)
			total += other_c;
			if (show_manual) total += manual_c;
			if (show_hs)     total += hs_c;
			if (show_llm)    total += llm_c;
		});
	};

	// Historical cache is already filtered by date/app at fetch time
	add_from_c_dict(app_state.historical_cache?.c);

	// Today's live data is per-app; apply the app selection filter
	Object.entries(app_state.today_live_data || {}).forEach(([app_name, app_data]) => {
		if (app_name !== "Unknown" && !app_state.selected_apps.has(app_name)) return;
		add_from_c_dict(app_data?.c);
	});

	return total;
}

// Mapping from macOS virtual keycode string to canonical modifier name.
// These keycodes are emitted via flagsChanged events (tracked by log_manager).
const MODIFIER_KEYCODES = {
	"54": "cmd",   "55": "cmd",
	"56": "shift", "60": "shift",
	"58": "alt",   "61": "alt",
	"59": "ctrl",  "62": "ctrl",
	"57": "capslock",
	"63": "fn",
};

/**
 * Derives modifier usage from two sources:
 * 1. Raw kc dict: flagsChanged keycode presses (standalone modifier key taps).
 * 2. Shortcut sc dict: modifier+key combos aggregated by modifier pattern.
 * 3. Uppercase letter inference: Shift usage from capital letters typed.
 *
 * This ensures that pressing Option (kc 58/61) for a symbol layer is counted,
 * and that thumb keys (cmd-L=55, cmd-R=54, alt-L=58, etc.) appear correctly.
 * @param {Object} sc_dict - The processed shortcut dictionary from app_state.data.sc.
 * @returns {Object} A new dict keyed by canonical modifier name or combo.
 */
function derive_modifier_usage(sc_dict) {
	const result = {};

	// ── Source 1: raw flagsChanged kc presses ────────────────────────────────
	// Each entry in kc_dict where the keycode is a modifier contributes directly.
	const kc_dict = app_state.data.kc || {};
	Object.entries(kc_dict).forEach(([kc_str, kc_item]) => {
		const mod_name = MODIFIER_KEYCODES[kc_str];
		if (!mod_name) return;
		if (!result[mod_name]) {
			result[mod_name] = { count: 0, time: 0, errors: 0, synth_hs: 0, synth_llm: 0, synth_other: 0 };
		}
		result[mod_name].count += kc_item.count || 0;
	});

	// ── Source 2: Shift inferred from uppercase letter presses ───────────────
	const shift_count = count_uppercase_shift();
	if (shift_count > 0) {
		if (!result["shift"]) {
			result["shift"] = { count: 0, time: 0, errors: 0, synth_hs: 0, synth_llm: 0, synth_other: 0 };
		}
		// Add inferred shift presses on top of direct flagsChanged counts to get
		// the total number of shift activations (direct key tap + held for uppercase).
		result["shift"].count += shift_count;
	}

	// ── Source 3: modifier combos from shortcuts ──────────────────────────────
	Object.entries(sc_dict).forEach(([k, item]) => {
		const parts = String(k).toLowerCase().split("+").map(p => p.trim()).filter(p => p.length > 0);
		const mods  = parts.filter(p => MODIFIER_ORDER.includes(p));
		if (mods.length === 0) return;

		// Canonical sort so "shift+cmd" and "cmd+shift" collapse to the same key
		mods.sort((a, b) => MODIFIER_ORDER.indexOf(a) - MODIFIER_ORDER.indexOf(b));
		const mod_key = mods.join("+");

		if (!result[mod_key]) {
			result[mod_key] = { count: 0, time: 0, errors: 0, synth_hs: 0, synth_llm: 0, synth_other: 0 };
		}
		result[mod_key].count       += item.count       || 0;
		result[mod_key].time        += item.time        || 0;
		result[mod_key].errors      += item.errors      || 0;
		result[mod_key].synth_hs    += item.synth_hs    || 0;
		result[mod_key].synth_llm   += item.synth_llm   || 0;
		result[mod_key].synth_other += item.synth_other || 0;
	});

	return result;
}


/**
 * Returns true if a key string is a pure repetition (all code points identical).
 * Used to hide/show entries like "aaa" or "bb" via the repetitions toggle.
 * @param {string} key - The raw sequence key.
 * @returns {boolean} Whether all characters in the sequence are the same.
 */
function is_repetition(key) {
	// Normalize [BS] markers before the grapheme check
	const clean = key.replace(/\[BS\]/gi, "");
	const chars  = Array.from(clean);
	if (chars.length <= 1) return false;
	return chars.every((c) => c === chars[0]);
}

/**
 * Counts the effective number of key tokens in a raw key string.
 * Bracket markers such as [BS] or [LEFT] count as one token each;
 * every other Unicode code point counts as one token.
 * Used to validate that a key stored in the bigrams dict actually has 2
 * tokens, the trigrams dict has 3, etc.
 * @param {string} key - The raw key string (may contain bracket markers).
 * @returns {number} The number of effective tokens.
 */
function count_key_tokens(key) {
	const parts = key.split(/(\[[^\]]+\])/i).filter(p => p.length > 0);
	return parts.reduce((sum, part) => {
		if (/^\[[^\]]+\]$/i.test(part)) return sum + 1;
		return sum + Array.from(part).length;
	}, 0);
}

// Expected token count for each fixed-length n-gram tab
const NGRAM_EXPECTED_LEN = { bg: 2, tg: 3, qg: 4, pg: 5, hx: 6, hp: 7 };


// ===========================================
// ===========================================
// ======= 2.5/ Gradient Color Helpers =======
// ===========================================
// ===========================================

// Gradient stops: [value, r, g, b] — value is the threshold at which that color applies.
// Values between stops are linearly interpolated.
const PRECISION_GRADIENT = [
	[100, 52,  199, 89],   // #34c759 green
	[ 80, 255, 204,  0],   // #ffcc00 yellow
	[ 65, 255, 149,  0],   // #ff9500 orange
	[ 50, 255,  59, 48],   // #ff3b30 red
	[  0, 255,  59, 48],   // red — stays red below 50%
];

const WPM_GRADIENT = [
	[80, 52,  199, 89],    // #34c759 green  — fast typist
	[50, 140, 200, 50],    // yellow-green   — good
	[35, 255, 204,  0],    // #ffcc00 yellow — average
	[20, 255, 149,  0],    // #ff9500 orange — slow
	[ 0, 255,  59, 48],    // #ff3b30 red    — very slow
];

/**
 * Returns an rgb() CSS string interpolated along a gradient stop array.
 * @param {number}   value    - The metric value (e.g. 0–100 for precision, WPM for speed).
 * @param {number[][]} stops  - Array of [threshold, r, g, b] in descending threshold order.
 * @returns {string} A CSS rgb() color string.
 */
function gradient_color(value, stops) {
	if (value >= stops[0][0]) return `rgb(${stops[0][1]},${stops[0][2]},${stops[0][3]})`;
	for (let i = 0; i < stops.length - 1; i++) {
		const [hi, r1, g1, b1] = stops[i];
		const [lo, r2, g2, b2] = stops[i + 1];
		if (value >= lo) {
			const t = (value - lo) / (hi - lo);
			return `rgb(${Math.round(r1 * t + r2 * (1 - t))},${Math.round(g1 * t + g2 * (1 - t))},${Math.round(b1 * t + b2 * (1 - t))})`;
		}
	}
	const last = stops[stops.length - 1];
	return `rgb(${last[1]},${last[2]},${last[3]})`;
}



// ===================================
// ===================================
// ===== 2.1) Km Per Key Helpers =====
// ===================================

/**
 * Builds a map of lowercase key name → km of finger travel per single keystroke,
 * computed from KEY_POSITIONS geometry. Used to populate the km column in every
 * table section.
 * @returns {Object} Map of string key → km (number).
 */
function build_char_km_map() {
	const km_map     = {};
	const kc_name_map = (window.keycode_layout && Object.keys(window.keycode_layout).length > 0)
		? window.keycode_layout
		: KEYCODE_NAMES;

	Object.entries(KEY_POSITIONS).forEach(([kc_str, pos]) => {
		const finger = KEY_FINGER[kc_str];
		if (!finger) return;
		const home = FINGER_HOME[finger];
		if (!home) return;
		const dx = pos.x - home.x;
		const dy = pos.y - home.y;
		// Round-trip distance (home → key → home) in km
		const km = Math.sqrt(dx * dx + dy * dy) * 2 * KEY_UNIT_MM / 1_000_000;

		const char_name = kc_name_map[kc_str];
		if (!char_name) return;
		km_map[char_name.toLowerCase()] = km;
		// Also map the exact-case single character so "A" and "a" both resolve
		if (char_name.length === 1) km_map[char_name] = km;
	});

	// Bridge bracket markers ("[ bs]" → km of "backspace") using the canonical
	// name map so that accum_token-normalized keys like "[BS]" resolve correctly.
	const BRACKET_TO_NAME = {
		"[bs]": "backspace",  "[esc]":      "escape",     "[tab]":      "tab",
		"[enter]": "return",  "[return]":   "return",     "[space]":    "space",
		"[left]": "left",     "[right]":    "right",      "[up]":       "up",
		"[down]": "down",     "[delete]":   "delete",     "[home]":     "home",
		"[end]": "end",       "[pageup]":   "pageup",     "[pagedown]": "pagedown",
		"[caps]": "capslock",
		"[f1]":  "f1",  "[f2]":  "f2",  "[f3]":  "f3",  "[f4]":  "f4",
		"[f5]":  "f5",  "[f6]":  "f6",  "[f7]":  "f7",  "[f8]":  "f8",
		"[f9]":  "f9",  "[f10]": "f10", "[f11]": "f11", "[f12]": "f12",
	};
	Object.entries(BRACKET_TO_NAME).forEach(([bracket, name]) => {
		if (km_map[name] !== undefined) km_map[bracket] = km_map[name];
	});

	return km_map;
}

/**
 * Returns the km of finger travel per single occurrence of the given key sequence.
 * For n-gram / word / character tabs: tokenizes the key and sums per-character km.
 * For the shortcut tab: splits on "+" and looks up each key part separately.
 * For the keycode tab: looks up directly from KEY_POSITIONS geometry.
 * @param {string}  key          - The raw key string.
 * @param {Object}  char_km_map  - Map from build_char_km_map().
 * @param {boolean} is_kc_tab    - Whether the current tab is "kc".
 * @param {boolean} is_sc_tab    - Whether the current tab is "sc" or "mods".
 * @returns {number} Km per single occurrence.
 */
function compute_key_km_per_stroke(key, char_km_map, is_kc_tab, is_sc_tab) {
	if (is_kc_tab) {
		const pos    = KEY_POSITIONS[key];
		const finger = KEY_FINGER[key];
		if (!pos || !finger) return 0;
		const home = FINGER_HOME[finger];
		if (!home) return 0;
		const dx = pos.x - home.x;
		const dy = pos.y - home.y;
		return Math.sqrt(dx * dx + dy * dy) * 2 * KEY_UNIT_MM / 1_000_000;
	}

	// For shortcut / modifier tabs, split by "+" separator; each part is a key name
	const tokens = is_sc_tab
		? String(key).split("+").map(p => p.trim().toLowerCase()).filter(p => p.length > 0)
		: key.split(/(\[[^\]]+\])/i)
			.filter(p => p.length > 0)
			.flatMap(part => /^\[[^\]]+\]$/i.test(part) ? [part.toLowerCase()] : Array.from(part));

	return tokens.reduce((sum, t) => sum + (char_km_map[t.toLowerCase()] ?? char_km_map[t] ?? 0), 0);
}

/**
 * Converts the current tab's n-gram data into the rendered_list array and
 * updates the occurrence count in the table header.
 *
 * IMPORTANT: This function intentionally does NOT update the global WPM/CPM
 * KPI card. That responsibility belongs exclusively to compute_manifest_metrics()
 * in data.js. Keeping them separate ensures the KPI is always stable and
 * represents the full manifest period, not just the current tab's subset.
 */
function render_current_tab() {
	// "mods" draws from sc data and derives modifier patterns; "sc"/"sc_bg"/"w_bg" show as-is
	// New word-ngram and shortcut-ngram tabs fall back to empty if backend hasn't produced data yet
	const source_key      = app_state.current_tab === "mods" ? "sc" : app_state.current_tab;
	const source_dict_raw = app_state.data[source_key] || {};
	const source_dict     = app_state.current_tab === "mods"
		? derive_modifier_usage(source_dict_raw)
		: source_dict_raw;
	const pause_thresh = parseInt(document.getElementById("pause_threshold")?.value ?? "2000", 10) || 2000;

	let data_arr = [];
	let total_occ = 0;

	// Text-based tabs should never show OS control characters (RS, SOH, BOM…).
	// Shortcut and keycode tabs are exempt: raw keycodes and ctrl+key shortcuts
	// are legitimate there. sc_bg uses "→" separator — also exempt.
	const SC_TABS = ["sc", "sc_bg", "sc_tg", "sc_qg", "sc_pg", "mods"];
	const is_text_tab = ![...SC_TABS, "kc"].includes(app_state.current_tab);

	// ── Characters tab: expand multi-token keys into individual entries ───────
	// The keylogger sometimes records multi-char sequences (e.g. NBSP+?) in the
	// character dict. We decompose each multi-token key so that NBSP, NNBSP, and
	// every other char that only appeared in a combination is surfaced individually.
	// Bracket markers such as [TAB], [F1] count as one token and are kept as-is.
	// Single-token entries keep their full timing and error stats; synthesized ones
	// receive count and source breakdown only (inter-key timing does not apply
	// to individual characters derived from a bigram).
	let effective_source = source_dict;
	if (app_state.current_tab === "c") {
		const char_accum = {};

		const accum_token = (token, item, keep_timing) => {
			// Normalize bracket markers to uppercase ("[bs]" → "[BS]") so that the \x08
			// path through merge_dict (which yields "[BS]" after toLowerCase + replace) and
			// a literal "[BS]" stored lowercase by merge_dict collapse into the same
			// char_accum bucket, preventing duplicate rows for BackSpace and similar keys.
			if (/^\[[^\]]+\]$/i.test(token)) token = token.toUpperCase();

			// Bracket markers ([BS], [TAB], [ESC]…) are valid single-token representations;
			// their ASCII bracket chars must not trigger the control-character filter
			const is_bracket_marker = /^\[[^\]]+\]$/i.test(token);
			if (!is_bracket_marker) {
				// Control chars in plain text tokens are never meaningful character entries
				const has_ctrl = Array.from(token).some((ch) => {
					const cp = ch.codePointAt(0);
					return cp < 32 || cp === 127 || cp === 0xFEFF;
				});
				if (has_ctrl) return;
			}
			if (!char_accum[token]) {
				char_accum[token] = { count: 0, synth_hs: 0, synth_llm: 0, synth_other: 0, time: 0, errors: 0 };
			}
			char_accum[token].count       += item.count       || 0;
			char_accum[token].synth_hs    += item.synth_hs    || 0;
			char_accum[token].synth_llm   += item.synth_llm   || 0;
			char_accum[token].synth_other += item.synth_other || 0;
			if (keep_timing) {
				char_accum[token].time   += item.time   || 0;
				char_accum[token].errors += item.errors || 0;
			}
		};

		Object.entries(source_dict).forEach(([k, item]) => {
			// Skip keys containing raw ASCII control chars (e.g. literal \t, \x00)
			const has_ctrl = Array.from(k).some((ch) => {
				const cp = ch.codePointAt(0);
				return cp < 32 || cp === 127 || cp === 0xFEFF;
			});
			if (has_ctrl) return;

			// Tokenize: [BRACKET] markers → one token; everything else → per grapheme
			const tokens = k.split(/(\[[^\]]+\])/i)
				.filter(p => p.length > 0)
				.flatMap(part => /^\[[^\]]+\]$/i.test(part) ? [part] : Array.from(part));

			if (tokens.length === 1) {
				// Single token: preserve full stats including timing
				accum_token(k, item, true);
			} else {
				// Multi-token: propagate counts only; timing is not per-char here
				tokens.forEach(t => accum_token(t, item, false));
			}
		});

		// Pull standalone special keys from the sc dict into the characters tab.
		// Navigation keys (arrows, Esc, Tab, Enter, F1–F15…) are logged as shortcuts
		// (single key, no modifier) so they never appear in the raw "c" dict.
		// Merging them here surfaces them with the same chip style as [BS] and NBSP.
		// Keys that ARE in the c dict (Space, BackSpace, Tab, Enter, Escape) are
		// normalized to their canonical c-dict form (e.g. "space" → " ") so they
		// collapse into the existing char_accum bucket rather than creating a duplicate row.
		const sc_for_chars = app_state.data.sc || {};
		Object.entries(sc_for_chars).forEach(([sc_key, sc_item]) => {
			// Only standalone keys — no "+" means no modifier combination
			if (sc_key.includes("+")) return;
			const sc_lower = sc_key.toLowerCase();
			// Must be a known control/navigation key or a bracket marker
			if (!CONTROL_KEY_LABELS.has(sc_lower) && !/^\[[^\]]+\]$/i.test(sc_key)) return;
			// Normalize to canonical c-dict form (e.g. "backspace" → "[BS]", "space" → " ")
			const sc_canonical = SC_TO_CHAR_CANONICAL[sc_lower] ?? sc_key;
			// Skip if c dict already contributed this key — prevents double-counting for
			// keys like Space/BackSpace that are recorded in both dicts
			if (char_accum[sc_canonical]) return;
			accum_token(sc_canonical, sc_item, true);
		});

		// Fallback pull from the kc (keycode) dict for control keys missing from sc.
		// Some keylogger versions only populate kc for bare navigation/function keys,
		// never sc. Checking after sc ensures no double-counting.
		const kc_for_chars = app_state.data.kc || {};
		const kc_name_map  = window.keycode_layout && Object.keys(window.keycode_layout).length > 0
			? window.keycode_layout
			: KEYCODE_NAMES;
		Object.entries(kc_for_chars).forEach(([kc_str, kc_item]) => {
			const key_name = kc_name_map[kc_str] ?? KEYCODE_NAMES[kc_str];
			if (!key_name) return;
			const key_lower = key_name.toLowerCase();
			// Only navigation/control keys — skip regular printable keys
			if (!CONTROL_KEY_LABELS.has(key_lower)) return;
			// Normalize and skip if already present (c dict or sc dict is authoritative)
			const key_canonical = SC_TO_CHAR_CANONICAL[key_lower] ?? key_name;
			if (char_accum[key_canonical]) return;
			accum_token(key_canonical, kc_item, true);
		});

		effective_source = char_accum;
	}
	// ─────────────────────────────────────────────────────────────────────────

	Object.keys(effective_source).forEach((k) => {
		// Strip control chars for text tabs; for "c" tab, already handled above
		if (is_text_tab && app_state.current_tab !== "c") {
			const has_ctrl = Array.from(k).some((ch) => {
				const cp = ch.codePointAt(0);
				return cp < 32 || cp === 127 || cp === 0xFEFF;
			});
			if (has_ctrl) return;
		}

		// Characters tab: effective_source only has single-token keys; this guard
		// is purely defensive against any edge-case that slipped through.
		// Named control keys (e.g. "escape", "left") are also valid single entries.
		if (app_state.current_tab === "c") {
			const is_bracket   = /^\[[^\]]+\]$/i.test(k);
			const is_ctrl_name = CONTROL_KEY_LABELS.has(k.toLowerCase());
			if (!is_bracket && !is_ctrl_name && Array.from(k).length !== 1) return;
		}

		// Filter n-gram tabs to only entries with the expected effective token count.
		// Prevents trigramme keys that leaked into the bigrams dict from appearing, etc.
		const expected_tokens = NGRAM_EXPECTED_LEN[app_state.current_tab];
		if (expected_tokens !== undefined && count_key_tokens(k) !== expected_tokens) return;

		const item         = effective_source[k];
		const manual_count = Math.max(0, item.count - item.synth_hs - item.synth_llm - item.synth_other);
		const avg          = manual_count > 0 ? item.time / manual_count : 0;

		// Precision: [BS]-containing sequences are always 100%; others are 1 - error_rate
		const acc = k.includes("[BS]") || k.toLowerCase() === "backspace"
			? 100
			: item.count > 0 ? ((item.count - item.errors) / item.count) * 100 : 0;

		// Normalize any [BRACKET] marker to a single char before grapheme length computation.
		// Keycode tab keys are numeric strings ("49") representing a single physical key.
		const norm_key    = k.replace(/\[[^\]]+\]/gi, "B");
		const display_len = app_state.current_tab === "kc" ? 1 : Math.max(1, Array.from(norm_key).length);

		total_occ += item.count;

		data_arr.push({
			key:         k,
			count:       item.count,
			synth_hs:    item.synth_hs,
			synth_llm:   item.synth_llm,
			synth_other: item.synth_other,
			manual_count,
			// avg: mean delay between consecutive keystrokes (manual chars only)
			// avg only meaningful when >= MIN_PLAUSIBLE_AVG_MS (10ms) and <= pause_thresh
			// Below 10ms is physically impossible for human inter-key timing
			avg: (isNaN(avg) || avg < 10) ? 0 : avg,
			// wpm: estimated WPM if this sequence were typed continuously (avg must be plausible and below pause_thresh)
			wpm: (!["sc", "sc_bg", "sc_tg", "sc_qg", "sc_pg", "mods"].includes(app_state.current_tab) && !isNaN(avg) && avg >= 10 && avg <= pause_thresh)
				? display_len / 5 / (avg / 60000)
				: 0,
			acc:      Math.max(0, acc),
			freq:     0,
			// rep/rep_rate/rep_star/rep_manual: filled below from the next n-gram level (null = not computable)
			rep:        null,
			rep_rate:   0,
			rep_star:   null,
			rep_manual: null,
			// km: filled below from KEY_POSITIONS geometry (0 = home-row key or not mappable)
			km: 0,
		});
	});

	// Compute relative frequency after we know total_occ
	data_arr.forEach((i) => { i.freq = total_occ > 0 ? (i.count / total_occ) * 100 : 0; });

	// ── Repetition counts ─────────────────────────────────────────────────────
	// For a given n-gram X, its repetition count = how many times XX was typed
	// consecutively, which is the count of XX in the next n-gram level.
	// Characters → bigrams["aa"], Bigrams → quadrigrams["abab"], Trigrams → hexagrams["abcabc"].
	// Words: look up word+" "+word in the word-bigrams dict (w_bg stores consecutive
	//   word pairs with a space separator regardless of the actual inter-word key).
	// Shortcuts: look up "cmd+c→cmd+c" in the shortcut-bigrams dict (sc_bg), where
	//   → (U+2192) is the separator used when logging consecutive shortcut pairs.
	const rep_source_tab = { c: "bg", bg: "qg", tg: "hx" }[app_state.current_tab];
	if (rep_source_tab) {
		const rep_dict = app_state.data[rep_source_tab] || {};
		data_arr.forEach((item) => {
			const rep_key = item.key + item.key;
			// Lowercase fallback handles bracket markers stored with mixed case
			// (e.g. "[BS][BS]" vs "[bs][bs]" depending on raw data source path).
			const rep_entry = rep_dict[rep_key] ?? rep_dict[rep_key.toLowerCase()];
			if (rep_entry) {
				item.rep        = rep_entry.count      || 0;
				item.rep_star   = rep_entry.synth_hs   || 0;
				const rep_llm   = rep_entry.synth_llm  || 0;
				const rep_other = rep_entry.synth_other || 0;
				// Manual = total minus all synthetic sources
				item.rep_manual = Math.max(0, item.rep - item.rep_star - rep_llm - rep_other);
			} else {
				item.rep        = 0;
				item.rep_star   = 0;
				item.rep_manual = 0;
			}
			// Rate: fraction of total occurrences where this n-gram was immediately repeated.
			// E.g. 10 "abab" out of 100 "ab" → 10 % of "ab" occurrences were a direct repeat.
			item.rep_rate = item.count > 0 ? (item.rep / item.count) * 100 : 0;
		});
	} else if (app_state.current_tab === "w") {
		// For words, a repetition is the same word appearing twice consecutively.
		// Word bigrams are stored in w_bg with a space separator (the actual separator
		// key — space, tab, enter — is normalised away when the pair is logged).
		const wb_dict = app_state.data.w_bg || {};
		data_arr.forEach((item) => {
			const rep_key   = item.key + " " + item.key;
			const rep_entry = wb_dict[rep_key] ?? wb_dict[rep_key.toLowerCase()];
			const rep_total = rep_entry ? (rep_entry.count || 0) : 0;
			item.rep        = rep_total;
			item.rep_star   = 0;
			item.rep_manual = rep_total;
			item.rep_rate   = item.count > 0 ? (rep_total / item.count) * 100 : 0;
		});
	} else if (app_state.current_tab === "sc") {
		// For shortcuts, a repetition is the same shortcut used twice consecutively.
		// Consecutive shortcut pairs are stored in sc_bg with U+2192 (→) as separator:
		// "cmd+c→cmd+c" is the consecutive-repeat entry for cmd+c.
		const sc_bg_dict = app_state.data.sc_bg || {};
		data_arr.forEach((item) => {
			const rep_key   = item.key + "\u2192" + item.key;
			const rep_entry = sc_bg_dict[rep_key] ?? sc_bg_dict[rep_key.toLowerCase()];
			if (rep_entry) {
				item.rep        = rep_entry.count      || 0;
				item.rep_star   = rep_entry.synth_hs   || 0;
				const rep_llm   = rep_entry.synth_llm  || 0;
				const rep_other = rep_entry.synth_other || 0;
				item.rep_manual = Math.max(0, item.rep - item.rep_star - rep_llm - rep_other);
			} else {
				item.rep        = 0;
				item.rep_star   = 0;
				item.rep_manual = 0;
			}
			item.rep_rate = item.count > 0 ? (item.rep / item.count) * 100 : 0;
		});
	}
	// ─────────────────────────────────────────────────────────────────────────

	// ── Km per sequence ───────────────────────────────────────────────────────
	// Total finger travel per row = km_per_stroke × occurrence count.
	// "mods" and "sc_bg" tabs are skipped: "mods" keys represent modifier patterns,
	// "sc_bg" keys are two-shortcut sequences — per-keystroke geometry is ambiguous.
	if (app_state.current_tab !== "mods" && app_state.current_tab !== "sc_bg") {
		const char_km_map    = build_char_km_map();
		const is_kc_tab_flag = app_state.current_tab === "kc";
		const is_sc_tab_flag = app_state.current_tab === "sc";
		data_arr.forEach((item) => {
			const km_per_stroke = compute_key_km_per_stroke(item.key, char_km_map, is_kc_tab_flag, is_sc_tab_flag);
			item.km = km_per_stroke * item.count;
		});
	}
	// ─────────────────────────────────────────────────────────────────────────

	app_state.rendered_list = data_arr;

	// Update the occurrences subtitle in the table header (not the global KPI)
	const occ_elem = document.getElementById("total_occurrences");
	if (occ_elem) {
		// For the chars tab, append a small mode badge so users know whether the
		// total reflects raw keystrokes or output chars (controlled by the HS/LLM toggles).
		let mode_badge = "";
		if (app_state.current_tab === "c") {
			const { show_hs, show_llm } = get_source_mode_flags();
			// show_hs/show_llm=true means HS/LLM expansions are included (output view)
			const mode_label = (show_hs && show_llm) ? _t('ui_typing.table_mode_output')
				: (show_hs || show_llm) ? _t('ui_typing.table_mode_mixed')
				: _t('ui_typing.table_mode_raw');
			mode_badge = ` <span style="font-size:0.8em;opacity:0.7;">(${mode_label})</span>`;
		}
		occ_elem.innerHTML = format_number(total_occ) + mode_badge;
	}

	// Compute weighted global metrics for the column sub-headers
	let g_time = 0, g_man = 0, g_wpm = 0, g_wpm_n = 0, g_acc = 0, g_acc_n = 0;
	data_arr.forEach((item) => {
		if (item.manual_count > 0 && item.avg > 0) { g_time += item.avg * item.manual_count; g_man += item.manual_count; }
		if (item.wpm > 0)      { g_wpm += item.wpm; g_wpm_n++; }
		if (item.count > 0)    { g_acc += item.acc * item.count; g_acc_n += item.count; }
	});
	const g_avg_val = g_man   > 0 ? g_time / g_man   : 0;
	const g_wpm_val = g_wpm_n > 0 ? g_wpm  / g_wpm_n : 0;
	const g_acc_val = g_acc_n > 0 ? g_acc  / g_acc_n : 0;

	const set_col_stat = (id, val, suffix) => {
		const el = document.getElementById(id);
		if (el) el.innerHTML = val > 0 ? `~ ${format_number(Number(val.toFixed(1)))} ${suffix}` : "";
	};
	set_col_stat("col_global_avg", g_avg_val, "ms");
	set_col_stat("col_global_wpm", g_wpm_val, "MPM");
	set_col_stat("col_global_acc", g_acc_val, "%");

	const g_km_total = data_arr.reduce((s, i) => s + (i.km || 0), 0);
	const km_stat_el = document.getElementById("col_global_km");
	if (km_stat_el) {
		if (g_km_total > 0) {
			km_stat_el.innerHTML = `~ ${format_number(g_km_total.toFixed(2))} km`;
		} else {
			km_stat_el.innerHTML = "";
		}
	}

	// Always refresh the heatmap with current kc data regardless of active tab
	const kc_data_for_heatmap = app_state.data.kc
		? Object.entries(app_state.data.kc).map(([key, item]) => ({ key, count: item.count || 0 }))
		: [];
	render_kc_heatmap(kc_data_for_heatmap);

	render_table();
}


// =============================================
// =============================================
// ======= 2.2) Keyboard Heatmap Render =======
// =============================================

/**
 * Renders an SVG keyboard heatmap into #kc_heatmap_container.
 * The heatmap is always visible above the tab buttons and updates on every
 * filter change. Each key shows the user's actual layout label (from Lua
 * injection) and a full hover tooltip with frequency, counts, and bigram info.
 * @param {Array} kc_data_arr - Array of { key: kc_str, count } objects.
 */
function render_kc_heatmap(kc_data_arr) {
	const container = document.getElementById("kc_heatmap_container");
	if (!container) return;

	// Build lookup maps: kc_str → count and kc_str → full item for tooltip
	const count_map = {};
	const item_map  = {};
	let max_count   = 1;
	kc_data_arr.forEach(item => {
		const c = item.count || 0;
		count_map[item.key] = c;
		item_map[item.key]  = item;
		if (c > max_count) max_count = c;
	});

	// Also collect the full kc item from app_state for extra stats in tooltips
	const kc_full = app_state.data.kc || {};

	const kc_name_map = (window.keycode_layout && Object.keys(window.keycode_layout).length > 0)
		? window.keycode_layout
		: KEYCODE_NAMES;

	// ── SVG layout constants ──────────────────────────────────────────────────
	// 1 unit = U px; PAD adds breathing room so wide/edge keys aren't clipped
	const U     = 50;
	const GAP   = 4;
	const R     = 5;
	const KW    = U - GAP;
	const KH    = Math.round(U * 0.88 - GAP);
	const PAD   = 8; // padding around the full keyboard in px

	// Key y-coordinates span Y_BOT (thumb row) to Y_TOP (fn row)
	const Y_TOP  = 2.70;
	const Y_BOT  = -1.80;
	const Y_SPAN = Y_TOP - Y_BOT;

	// Widths of non-standard keys in key-units
	const WIDE_KEYS = {
		"36":  1.50, // return — top-row width on the QWERTY row (L-shape)
		"48":  1.50, // tab — left edge at x=0, flush against Q
		"51":  1.50, // backspace — 1.5u; right edge aligns with Return stem and r-shift (698 px)
		"56":  1.25, // l-shift (ISO) — 1.25u, left-anchored; 4 px gap before ISO extra key
		"57":  1.75, // capslock
		"60":  2.26, // r-shift (ISO) — 2.26u right-anchored; right edge aligns with Return (698 px), 4 px gap after /
		"49":  5.00, // space bar — fills cmd-L → cmd-R gap (exactly 5u wide)
		"63":  1.00, // fn — 1u; right-anchored so left edge aligns with Esc/Tab/Shift
		"59":  1.00, // ctrl-L
		"55":  1.25, // cmd-L — 1.25u; right-anchored so right edge aligns space bar left with V
		"54":  1.25, // cmd-R — 1.25u; left-anchored; same width as cmd-L
		"61":  1.00, // alt-R
		"62":  1.00, // ctrl-R
	};

	// Anchor side for each wide key — determines whether the key extends from its
	// pos.x toward the left, the right, or both sides of its declared centre.
	// "right": right edge butts against the next 1u key on the same row (GAP between).
	// "left":  left edge butts against the previous 1u key on the same row.
	// "centre": symmetric around pos.x (default for unspecified keys).
	// "stretch": fills the gap between two neighbours given as { left_kc, right_kc }.
	const WIDE_KEY_ANCHOR = {
		"48": "right",   // tab
		"57": "right",   // capslock
		"36": "right",   // return (L-shape uses anchor for the QWERTY-row top portion)
		"51": "left",    // backspace
		"56": "left",    // l-shift — left-anchored: left edge aligns with Esc/Tab/Shift/FN
		"63": "right",   // fn — right-anchored: left edge aligns with Esc/Tab/Shift
		"55": "right",   // cmd-L — right-anchored: right edge is adjacent to space
		"60": "right",   // r-shift — right-anchored: right edge aligns with Return
		"49": "stretch", // space — fills cmd-L → cmd-R
		"54": "left",    // cmd-R — left-anchored: left edge is adjacent to space, right edge adjacent to alt-R
	};
	const SPACE_LEFT_NEIGHBOUR  = "55"; // cmd-L
	const SPACE_RIGHT_NEIGHBOUR = "54"; // cmd-R

	/** Returns the visual sx (left edge, in raw px) for a key. Wide keys are anchored
	 * to their neighbour rather than centred on pos.x so that horizontal gaps stay
	 * uniform (= GAP px) regardless of key width. */
	const compute_sx = (kc_str, pos) => {
		const w_units = WIDE_KEYS[kc_str] ?? 1;
		const key_w   = Math.round(w_units * U - GAP);
		const anchor  = WIDE_KEY_ANCHOR[kc_str];
		if (anchor === "right") {
			// Right edge sits GAP px to the left of pos.x*U + KW/2 + GAP/2
			// (i.e. flush against the next 1u key whose centre is pos.x + 1).
			return Math.round((pos.x + 0.5) * U) - Math.round(GAP / 2) - key_w;
		}
		if (anchor === "left") {
			return Math.round((pos.x - 0.5) * U) + Math.round(GAP / 2);
		}
		if (anchor === "stretch") {
			const lp = KEY_POSITIONS[SPACE_LEFT_NEIGHBOUR];
			const rp = KEY_POSITIONS[SPACE_RIGHT_NEIGHBOUR];
			if (lp && rp) {
				return Math.round((lp.x + 0.5) * U) + Math.round(GAP / 2);
			}
		}
		// Default: centred on pos.x
		const extra_w = (w_units - 1) * U / 2;
		return Math.round(pos.x * U) - Math.round(KW / 2) - Math.round(extra_w);
	};

	/** Returns the visible width in px for a key, taking stretch into account. */
	const compute_kw = (kc_str, pos) => {
		const w_units = WIDE_KEYS[kc_str] ?? 1;
		if (WIDE_KEY_ANCHOR[kc_str] === "stretch") {
			const lp = KEY_POSITIONS[SPACE_LEFT_NEIGHBOUR];
			const rp = KEY_POSITIONS[SPACE_RIGHT_NEIGHBOUR];
			if (lp && rp) {
				const left  = Math.round((lp.x + 0.5) * U) + Math.round(GAP / 2);
				const right = Math.round((rp.x - 0.5) * U) - Math.round(GAP / 2);
				return Math.max(0, right - left);
			}
		}
		return Math.round(w_units * U - GAP);
	};

	// Compute pixel canvas size including padding
	let min_x_px = Infinity, max_x_px = -Infinity;
	let min_y_px = Infinity, max_y_px = -Infinity;
	const key_entries = Object.entries(KEY_POSITIONS);

	// First pass: determine canvas bounds.
	// The ISO Return key (kc 36) draws a wing that extends one full row above its
	// sy, so we must account for that extra vertical extent when computing the
	// SVG canvas height, otherwise the wing is clipped at the top.
	const ROW_PX = Math.round(U * 0.90); // vertical distance between rows (px)
	key_entries.forEach(([kc_str, pos]) => {
		const key_w   = compute_kw(kc_str, pos);
		const sx      = compute_sx(kc_str, pos);
		const sy      = Math.round((Y_TOP - pos.y) / Y_SPAN * (5.5 * U)) - Math.round(KH / 2);
		const top_ext = kc_str === "36" ? ROW_PX : 0; // Return: wing extends one row up
		min_x_px = Math.min(min_x_px, sx);
		max_x_px = Math.max(max_x_px, sx + key_w);
		min_y_px = Math.min(min_y_px, sy - top_ext);
		max_y_px = Math.max(max_y_px, sy + KH);
	});

	const SVG_W = max_x_px - min_x_px + PAD * 2;
	const SVG_H = max_y_px - min_y_px + PAD * 2;
	const off_x = -min_x_px + PAD;
	const off_y = -min_y_px + PAD;

	// Heat colour: dark blue (cold) → orange (mid) → bright red (hot)
	const heat_color = (count) => {
		if (count === 0) return "#1e1e2e";
		const t = Math.pow(count / max_count, 0.40);
		if (t < 0.5) {
			const tt = t * 2;
			const r  = Math.round(30  + tt * (220 - 30));
			const g  = Math.round(50  + tt * (130 - 50));
			const b  = Math.round(130 + tt * (20  - 130));
			return `rgb(${r},${g},${b})`;
		}
		const tt = (t - 0.5) * 2;
		const r  = Math.round(220 + tt * (255 - 220));
		const g  = Math.round(130 + tt * (20  - 130));
		const b  = Math.round(20  + tt * (0   - 20));
		return `rgb(${r},${g},${b})`;
	};

	// Compute total presses for frequency percentage
	const grand_total = kc_data_arr.reduce((s, i) => s + (i.count || 0), 0);

	// Aggregate kc_hold across all filtered apps so the tooltip can surface
	// a per-keycode tap / hold breakdown plus tap%-of-all-taps and
	// hold%-of-all-holds. _foreach_filtered_app is defined in data.js.
	const kc_hold_total = {}; // kc_str → { tap, hold, s, n, m }
	let total_taps = 0, total_holds = 0;
	if (typeof _foreach_filtered_app === "function") {
		_foreach_filtered_app(app => {
			const kh = app.kc_hold || {};
			Object.entries(kh).forEach(([kc_str, h]) => {
				const t = kc_hold_total[kc_str] || (kc_hold_total[kc_str] = { tap: 0, hold: 0, s: 0, n: 0, m: 0 });
				t.tap  += h.tap  || 0;
				t.hold += h.hold || 0;
				t.s    += h.s    || 0;
				t.n    += h.n    || 0;
				if ((h.m || 0) > t.m) t.m = h.m;
				total_taps  += h.tap  || 0;
				total_holds += h.hold || 0;
			});
		});
	}

	// Collect per-modifier combo counts for tooltip breakdown
	const sc_dict   = app_state.data.sc || {};
	// Build a map: kc_str → list of modifier combos that used this key
	const mod_by_kc = {};
	Object.entries(sc_dict).forEach(([sc_key, sc_item]) => {
		if (!sc_key.includes("+")) return;
		const parts = sc_key.toLowerCase().split("+").map(p => p.trim());
		const mods  = parts.filter(p => MODIFIER_ORDER.includes(p));
		const keys  = parts.filter(p => !MODIFIER_ORDER.includes(p));
		if (mods.length === 0 || keys.length === 0) return;
		keys.forEach(key_name => {
			// Try to resolve key_name back to a kc_str
			Object.entries(kc_name_map).forEach(([kc_str, kc_label]) => {
				if (kc_label.toLowerCase() === key_name) {
					if (!mod_by_kc[kc_str]) mod_by_kc[kc_str] = {};
					const mod_key = mods.join("+");
					mod_by_kc[kc_str][mod_key] = (mod_by_kc[kc_str][mod_key] || 0) + (sc_item.count || 0);
				}
			});
		});
	});

	// Build bigram following-key data from app_state.data.bg for tooltip
	// We'll build a map: char → top-3 following chars by frequency
	const bg_dict    = app_state.data.bg || {};
	const follow_map = {}; // char_lower → [{char, count}]
	const kc_chars   = {}; // kc_str → the char label it produces
	Object.entries(kc_name_map).forEach(([kc_str, label]) => {
		kc_chars[kc_str] = label;
	});
	Object.entries(bg_dict).forEach(([bg_key, bg_item]) => {
		const chars = Array.from(bg_key);
		if (chars.length !== 2) return;
		const first = chars[0];
		if (!follow_map[first]) follow_map[first] = {};
		follow_map[first][chars[1]] = (follow_map[first][chars[1]] || 0) + (bg_item.count || 0);
	});

	let rects  = "";
	let labels = "";
	let tooltips = ""; // foreignObject-based tooltip divs (CSS-positioned via JS)

	// Generate a unique id prefix for tooltip elements
	const uid = "hm_" + Date.now().toString(36);

	key_entries.forEach(([kc_str, pos]) => {
		const count    = count_map[kc_str] || 0;
		const fill     = heat_color(count);
		const key_w    = compute_kw(kc_str, pos);
		const sx       = compute_sx(kc_str, pos) + off_x;
		const base_sy  = Math.round((Y_TOP - pos.y) / Y_SPAN * (5.5 * U)) - Math.round(KH / 2) + off_y;

		// Half-height keys: up and down arrows share the same grid cell, stacked vertically
		const half_slot = HALF_HEIGHT_KEYS[kc_str];
		const key_h     = half_slot ? Math.round(KH / 2) - Math.round(GAP / 2) : KH;
		const sy        = half_slot === "bottom" ? base_sy + Math.round(KH / 2) + Math.round(GAP / 2) : base_sy;
		const cx        = sx + key_w / 2;
		const cy        = sy + key_h / 2;

		const text_color = count === 0 ? "#555" : "#fff";

		// Label: user's layout label, uppercase. Force a few well-known wide-key
		// short forms so they render clearly (Esc, Ret, Tab, Bksp, Caps, Shft).
		const label_raw  = kc_name_map[kc_str] ?? KEYCODE_NAMES[kc_str] ?? "";
		// MacBook-style symbols matching what is printed on the physical keycap
		const SHORT_LABELS_MAC = {
			"53":  "⎋",   // escape
			"36":  "⏎",   // return
			"48":  "⇥",   // tab
			"51":  "⌫",   // backspace / delete
			"56":  "⇧",   // left shift
			"60":  "⇧",   // right shift
			"57":  "⇪",   // caps lock
			"49":  "",    // spacebar — no label needed
			"59":  "⌃",   // left ctrl
			"55":  "⌘",   // left cmd
			"54":  "⌘",   // right cmd
			"58":  "⌥",   // left alt / option
			"61":  "⌥",   // right alt / option
			"63":  "Fn",
			"114": "?",
			"123": "←", "124": "→", "125": "↓", "126": "↑",
			"76":  "↵",
		};
		const SHORT_LABELS_WIN = {
			"53":  _t("ui_typing.key_esc"),
			"36":  _t("ui_typing.key_enter"),
			"48":  _t("ui_typing.key_tab"),
			"51":  "←",       // backspace arrow
			"56":  _t("ui_typing.key_shift"),
			"60":  _t("ui_typing.key_shift"),
			"57":  _t("ui_typing.key_caps"),
			"49":  "",
			// Windows thumb row: Ctrl(kc63) | Fn(kc59) | Win(kc58) | Alt(kc55) | Space | AltGr(kc54) | Menu(kc61)
			"63":  "Ctrl",
			"59":  "Fn",
			"58":  "Win",
			"55":  "Alt",
			"54":  "AltGr",
			"61":  "Menu",
			"114": "?",
			"123": "←", "124": "→", "125": "↓", "126": "↑",
			"76":  "↵",
		};
		const SHORT_LABELS = (window.driver_meta && window.driver_meta.os === "win")
			? SHORT_LABELS_WIN : SHORT_LABELS_MAC;
		// Truncate only when truly too long for the cell. Most names ≤ 6 chars fit
		// at font_size 9; longer ones get the ellipsis fallback.
		let label_disp;
		if (SHORT_LABELS[kc_str] !== undefined) {
			label_disp = SHORT_LABELS[kc_str];
		} else if (label_raw.length > 6) {
			label_disp = label_raw.slice(0, 5).toUpperCase() + "…";
		} else {
			label_disp = label_raw.toUpperCase();
		}

		// Emoji and Unicode symbols are single codepoints but wide — treat them as length 1
		const disp_len   = [...label_disp].length;
		const base_font  = disp_len > 7 ? 8 : disp_len > 4 ? 10 : disp_len > 2 ? 11 : 14;
		// Special keys (shift, ctrl, cmd, etc.) get 1.5× font to match their keycap symbols
		// Fn is text, not a symbol — use the same scale as alphabetic keys
		const is_special = SHORT_LABELS[kc_str] !== undefined && label_disp !== "" && label_disp !== "Fn";
		const font_size  = is_special ? Math.round(base_font * 1.5) : base_font;


		// Tooltip content assembled as a data attribute string; rendered by JS onmouseover
		const freq_pct  = grand_total > 0 ? ((count / grand_total) * 100).toFixed(2) : "0.00";
		let tip_lines   = [
			`<b>${escape_html(label_raw || kc_str)}</b> (kc ${kc_str})`,
		];
		// Tap / hold breakdown (only when the bridge or flagsChanged path
		// actually observed releases for this key — regular letters never
		// have hold data and fall back to a single-line "Presses" view).
		const kh = kc_hold_total[kc_str];
		if (kh && (kh.tap > 0 || kh.hold > 0)) {
			const tap_n  = kh.tap  || 0;
			const hold_n = kh.hold || 0;
			const tap_pct  = total_taps  > 0 ? ((tap_n  / total_taps)  * 100).toFixed(2) : "0.00";
			const hold_pct = total_holds > 0 ? ((hold_n / total_holds) * 100).toFixed(2) : "0.00";
			tip_lines.push(`Tap + hold : <b>${format_number(count)}</b>`);
			tip_lines.push(`&nbsp;&nbsp;Tap&nbsp;&nbsp;: <b>${format_number(tap_n)}</b> (${tap_pct}% des taps)`);
			tip_lines.push(`&nbsp;&nbsp;Hold : <b>${format_number(hold_n)}</b> (${hold_pct}% des holds)`);
			tip_lines.push(`Fréquence totale : <b>${freq_pct}%</b>`);
			if (kh.n > 0) {
				const mean = Math.round(kh.s / kh.n);
				tip_lines.push(`Durée moy. : <b>${mean} ms</b> (max ${kh.m})`);
			}
		} else {
			tip_lines.push(`Presses : <b>${format_number(count)}</b>`);
			tip_lines.push(`Fréquence : <b>${freq_pct}%</b>`);
		}

		// Modifier combos
		const mods = mod_by_kc[kc_str];
		if (mods) {
			const mod_sorted = Object.entries(mods).sort((a, b) => b[1] - a[1]).slice(0, 4);
			if (mod_sorted.length > 0) {
				tip_lines.push(`<hr style="border-color:#444;margin:3px 0">`);
				tip_lines.push(`Combos modificateurs :`);
				mod_sorted.forEach(([mod, mc]) => {
					tip_lines.push(`&nbsp;&nbsp;${escape_html(mod)} : <b>${format_number(mc)}</b>`);
				});
			}
		}

		// Top following characters (bigrams)
		if (label_raw && label_raw.length === 1) {
			const follows = follow_map[label_raw.toLowerCase()];
			if (follows) {
				const top3 = Object.entries(follows).sort((a, b) => b[1] - a[1]).slice(0, 3);
				if (top3.length > 0) {
					tip_lines.push(`<hr style="border-color:#444;margin:3px 0">`);
					tip_lines.push(`Top lettres suivantes :`);
					top3.forEach(([ch, n]) => {
						const disp = ch === " " ? "Espace" : ch === " " ? "NBSP" : escape_html(ch.toUpperCase());
						tip_lines.push(`&nbsp;&nbsp;${disp} : <b>${format_number(n)}</b>`);
					});
				}
			}
		}

		const tip_html  = tip_lines.join("<br>");
		const tip_id    = `${uid}_${kc_str}`;

		// ISO Return (kc 36) gets an L-shaped path spanning home + QWERTY rows.
		// For all other keys a standard rounded-rect is drawn.
		if (kc_str === "36") {
			// ISO Return: wing on QWERTY row, stem on home row.
			//   Wing left  = right edge of ] (kc 30, QWERTY row) + GAP
			//   Stem left  = left edge of r-shift (kc 60) — stem and r-shift share the same column
			//   Right edge = right edge of r-shift (kc 60) — aligns backspace, Return stem, and r-shift
			const pos_bracket   = KEY_POSITIONS["30"];  // ] — QWERTY row
			const pos_backslash = KEY_POSITIONS["42"];  // \ — home row ISO backslash
			const wing_lx = compute_sx("30", pos_bracket)   + off_x + compute_kw("30", pos_bracket)   + GAP;
			const stem_lx = compute_sx("42", pos_backslash) + off_x + compute_kw("42", pos_backslash) + GAP;
			const stem_w  = 34;  // ≈ 0.76u — Apple ISO Return stem is narrower than 1u
			const rx_ret  = stem_lx + stem_w;

			const sy_qwerty = Math.round((Y_TOP - 0.84) / Y_SPAN * (5.5 * U)) - Math.round(KH / 2) + off_y;
			const sy_home   = sy; // Return pos.y = 0 (home row), so sy is already the home-row sy
			const top_y     = sy_qwerty;         // top of wing (QWERTY row)
			const wing_bot  = sy_qwerty + KH;    // bottom of wing rect
			const bot_y     = sy_home   + KH;    // bottom of stem

			// Clockwise path. The inner concave corner (stem_lx, wing_bot) uses
			// sweep=0 (counter-clockwise arc) to produce the correct inward curve.
			const d = [
				`M ${wing_lx} ${top_y+R}`,
				`A ${R} ${R} 0 0 1 ${wing_lx+R} ${top_y}`,
				`L ${rx_ret-R} ${top_y}`,
				`A ${R} ${R} 0 0 1 ${rx_ret} ${top_y+R}`,
				`L ${rx_ret} ${bot_y-R}`,
				`A ${R} ${R} 0 0 1 ${rx_ret-R} ${bot_y}`,
				`L ${stem_lx+R} ${bot_y}`,
				`A ${R} ${R} 0 0 1 ${stem_lx} ${bot_y-R}`,
				`L ${stem_lx} ${wing_bot+R}`,
				`A ${R} ${R} 0 0 0 ${stem_lx-R} ${wing_bot}`,
				`L ${wing_lx+R} ${wing_bot}`,
				`A ${R} ${R} 0 0 1 ${wing_lx} ${wing_bot-R}`,
				`L ${wing_lx} ${top_y+R}`,
				"Z",
			].join(" ");
			rects += `<path d="${d}" fill="${fill}" stroke="#0d0d1a" stroke-width="1.5" paint-order="stroke fill"
				data-tip="${tip_id}" class="hm-key"
				onmouseenter="hm_show_tip('${tip_id}')" onmouseleave="hm_hide_tip('${tip_id}')"/>`;
			// Label centred in the wing portion (wider area, more legible than the narrow stem)
			const ret_font = 15;
			const ret_cx   = (wing_lx + rx_ret) / 2;
			const ret_cy   = sy_qwerty + KH / 2;
			labels += `<text x="${Math.round(ret_cx)}" y="${Math.round(ret_cy + ret_font * 0.38)}"
				text-anchor="middle" font-size="${ret_font}"
				font-family="monospace,sans-serif" fill="${text_color}"
				pointer-events="none">${escape_html(label_disp)}</text>`;

		} else {
			// Standard or half-height rounded rect
			rects += `<rect x="${sx}" y="${sy}" width="${key_w}" height="${key_h}" rx="${R}"
				fill="${fill}" stroke="#0d0d1a" stroke-width="1.5" paint-order="stroke fill"
				data-tip="${tip_id}" class="hm-key"
				onmouseenter="hm_show_tip('${tip_id}')" onmouseleave="hm_hide_tip('${tip_id}')"/>`;
		}

		// ISO Return renders its own label (centred in the wing); skip the generic one
		if (kc_str !== "36") {
			labels += `<text x="${Math.round(cx)}" y="${Math.round(cy + font_size * 0.38)}"
				text-anchor="middle" font-size="${font_size}"
				font-family="monospace,sans-serif" fill="${text_color}"
				pointer-events="none">${escape_html(label_disp)}</text>`;
		}

		// Tooltip div — absolutely positioned, hidden by default
		tooltips += `<div id="${tip_id}" class="hm-tooltip" style="display:none;position:fixed;z-index:9999;` +
			`background:#1a1a2e;border:1px solid #444;border-radius:6px;padding:7px 10px;` +
			`font-size:12px;line-height:1.5;color:#ddd;pointer-events:none;max-width:220px;white-space:nowrap;text-align:left;">` +
			tip_html + `</div>`;
	});

	container.innerHTML =
		`<div style="display:inline-block;position:relative;">` +
		`<div style="font-size:17px;font-weight:bold;color:#1e96ff;margin-bottom:6px;text-align:left;">` +
		`Heatmap de l'utilisation physique des touches</div>` +
		`<svg width="${SVG_W}" height="${SVG_H}" xmlns="http://www.w3.org/2000/svg" ` +
		`style="background:#12121e;border-radius:10px;display:block;"` +
		`onmousemove="hm_track_mouse(event)">` +
		rects + labels +
		`</svg>` +
		tooltips +
		`</div>`;
}

/**
 * Shows a heatmap tooltip positioned near the cursor.
 * @param {string} tip_id - The DOM id of the tooltip element.
 */
function hm_show_tip(tip_id) {
	const el = document.getElementById(tip_id);
	if (el) el.style.display = "block";
}

/**
 * Hides a heatmap tooltip.
 * @param {string} tip_id - The DOM id of the tooltip element.
 */
function hm_hide_tip(tip_id) {
	const el = document.getElementById(tip_id);
	if (el) el.style.display = "none";
}

/** Tracks mouse position and repositions any visible heatmap tooltip near the cursor. */
function hm_track_mouse(evt) {
	document.querySelectorAll(".hm-tooltip").forEach(el => {
		if (el.style.display === "none") return;
		const vw  = window.innerWidth;
		const vh  = window.innerHeight;
		const tw  = el.offsetWidth  || 200;
		const th  = el.offsetHeight || 80;
		let   lft = evt.clientX + 14;
		let   top = evt.clientY + 14;
		if (lft + tw > vw - 8) lft = evt.clientX - tw - 8;
		if (top + th > vh - 8) top = evt.clientY - th - 8;
		el.style.left = lft + "px";
		el.style.top  = top + "px";
	});
}


// ==================================================
// ==================================================
// ======= 2b/ SFB Heatmap (Same-Finger Bigrams) ======
// ==================================================
// ==================================================

/**
 * Renders the Same-Finger Bigram heatmap keyboard SVG into #sfb_heatmap_container.
 * Uses the same layout geometry as render_kc_heatmap() but with a green→red gradient
 * (cold = no SFBs, hot = many SFBs). Tooltip lists the top SFB pairs per key.
 * @param {Object} sfb_by_kc       - Map of kc_str → total SFB count for that key.
 * @param {Object} sfb_pairs_by_kc - Map of kc_str → [{partner_kc, pair_label, count}].
 * @param {Object} kc_raw          - Raw keycode data map (kc_str → {count, …}).
 */
function render_sfb_heatmap(sfb_by_kc, sfb_pairs_by_kc, kc_raw) {
	const container = document.getElementById("sfb_heatmap_container");
	if (!container) return;

	let max_count = 1;
	Object.values(sfb_by_kc).forEach(c => { if (c > max_count) max_count = c; });

	const kc_name_map = (window.keycode_layout && Object.keys(window.keycode_layout).length > 0)
		? window.keycode_layout
		: KEYCODE_NAMES;

	// ── SVG layout constants (same as kc heatmap) ──────────────────────────────
	const U    = 50;
	const GAP  = 4;
	const R    = 5;
	const KW   = U - GAP;
	const KH   = Math.round(U * 0.88 - GAP);
	const PAD  = 8;

	const Y_TOP  = 2.70;
	const Y_BOT  = -1.80;
	const Y_SPAN = Y_TOP - Y_BOT;

	const WIDE_KEYS = {
		"36":  1.50, "48":  1.50, "51":  1.50, "56":  1.25, "57":  1.75,
		"60":  2.26, "49":  5.00, "63":  1.00, "59":  1.00, "55":  1.25,
		"54":  1.25, "61":  1.00, "62":  1.00,
	};
	const WIDE_KEY_ANCHOR = {
		"48": "right", "57": "right", "36": "right", "51": "left",
		"56": "left",  "63": "right", "55": "right", "60": "right",
		"49": "stretch", "54": "left",
	};
	const SPACE_LEFT_NEIGHBOUR  = "55";
	const SPACE_RIGHT_NEIGHBOUR = "54";

	const compute_sx = (kc_str, pos) => {
		const w_units = WIDE_KEYS[kc_str] ?? 1;
		const key_w   = Math.round(w_units * U - GAP);
		const anchor  = WIDE_KEY_ANCHOR[kc_str];
		if (anchor === "right") return Math.round((pos.x + 0.5) * U) - Math.round(GAP / 2) - key_w;
		if (anchor === "left")  return Math.round((pos.x - 0.5) * U) + Math.round(GAP / 2);
		if (anchor === "stretch") {
			const lp = KEY_POSITIONS[SPACE_LEFT_NEIGHBOUR];
			const rp = KEY_POSITIONS[SPACE_RIGHT_NEIGHBOUR];
			if (lp && rp) return Math.round((lp.x + 0.5) * U) + Math.round(GAP / 2);
		}
		const extra_w = (w_units - 1) * U / 2;
		return Math.round(pos.x * U) - Math.round(KW / 2) - Math.round(extra_w);
	};
	const compute_kw = (kc_str, pos) => {
		if (WIDE_KEY_ANCHOR[kc_str] === "stretch") {
			const lp = KEY_POSITIONS[SPACE_LEFT_NEIGHBOUR];
			const rp = KEY_POSITIONS[SPACE_RIGHT_NEIGHBOUR];
			if (lp && rp) {
				const left  = Math.round((lp.x + 0.5) * U) + Math.round(GAP / 2);
				const right = Math.round((rp.x - 0.5) * U) - Math.round(GAP / 2);
				return Math.max(0, right - left);
			}
		}
		return Math.round((WIDE_KEYS[kc_str] ?? 1) * U - GAP);
	};

	// Determine canvas bounds
	let min_x_px = Infinity, max_x_px = -Infinity;
	let min_y_px = Infinity, max_y_px = -Infinity;
	const key_entries = Object.entries(KEY_POSITIONS);
	const ROW_PX = Math.round(U * 0.90);
	key_entries.forEach(([kc_str, pos]) => {
		const key_w   = compute_kw(kc_str, pos);
		const sx      = compute_sx(kc_str, pos);
		const sy      = Math.round((Y_TOP - pos.y) / Y_SPAN * (5.5 * U)) - Math.round(KH / 2);
		const top_ext = kc_str === "36" ? ROW_PX : 0;
		min_x_px = Math.min(min_x_px, sx);
		max_x_px = Math.max(max_x_px, sx + key_w);
		min_y_px = Math.min(min_y_px, sy - top_ext);
		max_y_px = Math.max(max_y_px, sy + KH);
	});

	const SVG_W = max_x_px - min_x_px + PAD * 2;
	const SVG_H = max_y_px - min_y_px + PAD * 2;
	const off_x = -min_x_px + PAD;
	const off_y = -min_y_px + PAD;

	// Green (cold, 0 SFBs) → red (hot, many SFBs)
	const heat_color = (count) => {
		if (count === 0) return "#1e2e1e";
		const t = Math.pow(count / max_count, 0.40);
		if (t < 0.5) {
			const tt = t * 2;
			const r  = Math.round(52  + tt * (220 - 52));
			const g  = Math.round(199 + tt * (140 - 199));
			const b  = Math.round(89  + tt * (20  - 89));
			return `rgb(${r},${g},${b})`;
		}
		const tt = (t - 0.5) * 2;
		const r  = Math.round(220 + tt * (255 - 220));
		const g  = Math.round(140 + tt * (59  - 140));
		const b  = Math.round(20  + tt * (48  - 20));
		return `rgb(${r},${g},${b})`;
	};

	const grand_total = Object.values(sfb_by_kc).reduce((s, c) => s + c, 0);
	const uid = "sfbhm_" + Date.now().toString(36);

	const SHORT_LABELS_MAC = {
		"53": "⎋", "36": "⏎", "48": "⇥", "51": "⌫", "56": "⇧", "60": "⇧",
		"57": "⇪", "49": "",  "59": "⌃", "55": "⌘", "54": "⌘", "58": "⌥",
		"61": "⌥", "63": "Fn",  "114": "?", "123": "←", "124": "→", "125": "↓",
		"126": "↑", "76": "⏎",
	};
	const SHORT_LABELS_WIN = {
		"53": _t("ui_typing.key_esc"), "36": _t("ui_typing.key_enter"), "48": _t("ui_typing.key_tab"), "51": "←",
		"56": _t("ui_typing.key_shift"), "60": _t("ui_typing.key_shift"), "57": _t("ui_typing.key_caps"), "49": "",
		"63": "Ctrl", "59": "Fn", "58": "Win", "55": "Alt", "54": "AltGr", "61": "Menu",
		"114": "?",
		"123": "←", "124": "→", "125": "↓", "126": "↑", "76": "⏎",
	};
	const SHORT_LABELS = (window.driver_meta && window.driver_meta.os === "win")
		? SHORT_LABELS_WIN : SHORT_LABELS_MAC;

	let rects    = "";
	let labels   = "";
	let tooltips = "";

	key_entries.forEach(([kc_str, pos]) => {
		const count    = sfb_by_kc[kc_str] || 0;
		const fill     = heat_color(count);
		const key_w    = compute_kw(kc_str, pos);
		const sx       = compute_sx(kc_str, pos) + off_x;
		const base_sy  = Math.round((Y_TOP - pos.y) / Y_SPAN * (5.5 * U)) - Math.round(KH / 2) + off_y;
		const half_slot = HALF_HEIGHT_KEYS[kc_str];
		const key_h     = half_slot ? Math.round(KH / 2) - Math.round(GAP / 2) : KH;
		const sy        = half_slot === "bottom" ? base_sy + Math.round(KH / 2) + Math.round(GAP / 2) : base_sy;
		const cx        = sx + key_w / 2;
		const cy        = sy + key_h / 2;
		const text_color = count === 0 ? "#555" : "#fff";
		const label_raw  = kc_name_map[kc_str] ?? KEYCODE_NAMES[kc_str] ?? "";
		let label_disp;
		if (SHORT_LABELS[kc_str] !== undefined) {
			label_disp = SHORT_LABELS[kc_str];
		} else if (label_raw.length > 6) {
			label_disp = label_raw.slice(0, 5).toUpperCase() + "…";
		} else {
			label_disp = label_raw.toUpperCase();
		}
		const disp_len   = [...label_disp].length;
		const base_font  = disp_len > 7 ? 8 : disp_len > 4 ? 10 : disp_len > 2 ? 12 : 14;
		// Fn is text, not a symbol — use the same scale as alphabetic keys
		const is_special = SHORT_LABELS[kc_str] !== undefined && label_disp !== "" && label_disp !== "Fn";
		const font_size  = is_special ? Math.round(base_font * 1.5) : base_font;

		// Build tooltip
		const key_occurrences = (kc_raw[kc_str] && kc_raw[kc_str].count) ? kc_raw[kc_str].count : 0;
		const sfb_key_count = count; // total SFBs for this key
		const sfb_key_rate  = key_occurrences > 0 ? ((sfb_key_count / key_occurrences) * 100).toFixed(1) : "0.0";

		const tip_lines = [
			`<b>${escape_html(label_raw || kc_str)}</b> <span style="color:#888;font-size:10px;">(kc ${kc_str})</span><br>`,
			`Occurrences : <b>${format_number(key_occurrences)}</b>`,
		];

		if (sfb_key_count > 0) {
			tip_lines.push(`<br>SFBs : ${format_number(sfb_key_count)} — taux : <b style="color:#f87171;">${sfb_key_rate}%</b>`);
		}

		// Build the full list of finger-mates for this key (from SFB_COLUMNS)
		// so we can show all possible pairs, including those with count = 0.
		const this_col = SFB_COLUMNS[kc_str];
		const finger_mates = this_col
			? Object.entries(SFB_COLUMNS)
				.filter(([k]) => k !== kc_str && SFB_COLUMNS[k] === this_col)
				.map(([k]) => k)
			: [];

		// Collect counts from sfb_pairs_by_kc; pairs are keyed by partner kc
		const pairs_map = {}; // partner_kc → count
		const raw_pairs = sfb_pairs_by_kc[kc_str] || [];
		raw_pairs.forEach(p => {
			pairs_map[p.partner_kc] = (pairs_map[p.partner_kc] || 0) + p.count;
		});

		// Self-doubling: partner_kc === kc_str (AA, BB…)
		const self_count = pairs_map[kc_str] || 0;

		// All possible partners: finger-mates + self (for doubling)
		const all_partner_kcs = [kc_str, ...finger_mates]; // self first, then others
		const all_rows = all_partner_kcs.map(pk => ({
			partner_kc: pk,
			count: pairs_map[pk] || 0,
		})).sort((a, b) => b.count - a.count); // sort by count descending

		const sfb_total_all = grand_total;

		if (all_rows.length > 0) {
			tip_lines.push(`<hr style="border-color:#555;margin:4px 0">`);
			// Table header
			tip_lines.push(
				`<table style="border-collapse:collapse;width:100%;font-size:11px;">` +
				`<tr style="color:#888;">` +
				`<td style="padding:1px 6px 1px 0;">Paire</td>` +
				`<td style="padding:1px 4px;text-align:right;">nb</td>` +
				`<td style="padding:1px 4px;text-align:right;" title="Part de ce SFB parmi les SFBs de la touche">% /SFBs touche</td>` +
				`<td style="padding:1px 4px;text-align:right;" title="Fréquence : nb SFB / nb occurrences de la touche">taux</td>` +
				`<td style="padding:1px 0 1px 4px;text-align:right;" title="Part de ce SFB parmi tous les SFBs">% SFBs tot.</td>` +
				`</tr>`
			);

			all_rows.forEach(({ partner_kc: pk, count: p_count }) => {
				// Always display as "current_key + partner_key" regardless of stored pair_label direction
				const partner_label = pk === kc_str
					? (label_raw || kc_str) // self-doubling: show key twice
					: (kc_name_map[pk] ?? KEYCODE_NAMES[pk] ?? pk);
				const pair_str = escape_html((label_raw || kc_str) + partner_label);
				const pct_of_key_sfb = sfb_key_count > 0 ? ((p_count / sfb_key_count) * 100).toFixed(0) : "0";
				const pct_key_use    = key_occurrences > 0 ? ((p_count / key_occurrences) * 100).toFixed(1) : "0.0";
				const pct_sfb_total  = sfb_total_all > 0 ? ((p_count / sfb_total_all) * 100).toFixed(2) : "0.00";
				const row_color = p_count === 0 ? "color:#555;" : "color:#ddd;";
				const val_color = p_count === 0 ? "color:#555;" : "color:#ddd;";
				tip_lines.push(
					`<tr>` +
					`<td style="padding:1px 6px 1px 0;${row_color}">${pair_str}</td>` +
					`<td style="padding:1px 4px;text-align:right;${val_color}"><b>${p_count > 0 ? format_number(p_count) : "—"}</b></td>` +
					`<td style="padding:1px 4px;text-align:right;color:#aaa;">${p_count > 0 ? pct_of_key_sfb + "%" : "—"}</td>` +
					`<td style="padding:1px 4px;text-align:right;color:#aaa;">${p_count > 0 ? pct_key_use + "%" : "—"}</td>` +
					`<td style="padding:1px 0 1px 4px;text-align:right;color:#aaa;">${p_count > 0 ? pct_sfb_total + "%" : "—"}</td>` +
					`</tr>`
				);
			});

			tip_lines.push(`</table>`);
		}

		const tip_html = tip_lines.join("");
		const tip_id   = `${uid}_${kc_str}`;

		if (kc_str === "36") {
			// ISO Return L-shape — identical geometry to kc heatmap
			const pos_bracket   = KEY_POSITIONS["30"];  // ] — QWERTY row
			const pos_backslash = KEY_POSITIONS["42"];  // \ — home row ISO backslash
			const wing_lx = compute_sx("30", pos_bracket)   + off_x + compute_kw("30", pos_bracket)   + GAP;
			const stem_lx = compute_sx("42", pos_backslash) + off_x + compute_kw("42", pos_backslash) + GAP;
			const stem_w  = 34;  // ≈ 0.76u — Apple ISO Return stem is narrower than 1u
			const rx_ret  = stem_lx + stem_w;
			const sy_qwerty = Math.round((Y_TOP - 0.84) / Y_SPAN * (5.5 * U)) - Math.round(KH / 2) + off_y;
			const sy_home   = sy;
			const top_y     = sy_qwerty;
			const wing_bot  = sy_qwerty + KH;
			const bot_y     = sy_home   + KH;
			const d = [
				`M ${wing_lx} ${top_y+R}`, `A ${R} ${R} 0 0 1 ${wing_lx+R} ${top_y}`,
				`L ${rx_ret-R} ${top_y}`,  `A ${R} ${R} 0 0 1 ${rx_ret} ${top_y+R}`,
				`L ${rx_ret} ${bot_y-R}`,  `A ${R} ${R} 0 0 1 ${rx_ret-R} ${bot_y}`,
				`L ${stem_lx+R} ${bot_y}`, `A ${R} ${R} 0 0 1 ${stem_lx} ${bot_y-R}`,
				`L ${stem_lx} ${wing_bot+R}`, `A ${R} ${R} 0 0 0 ${stem_lx-R} ${wing_bot}`,
				`L ${wing_lx+R} ${wing_bot}`,  `A ${R} ${R} 0 0 1 ${wing_lx} ${wing_bot-R}`,
				`L ${wing_lx} ${top_y+R}`, "Z",
			].join(" ");
			rects += `<path d="${d}" fill="${fill}" stroke="#0d1a0d" stroke-width="1.5" paint-order="stroke fill"
				data-tip="${tip_id}" class="hm-key"
				onmouseenter="hm_show_tip('${tip_id}')" onmouseleave="hm_hide_tip('${tip_id}')"/>`;
			const ret_font = 15;
			const ret_cx   = (wing_lx + rx_ret) / 2;
			const ret_cy   = sy_qwerty + KH / 2;
			labels += `<text x="${Math.round(ret_cx)}" y="${Math.round(ret_cy + ret_font * 0.38)}"
				text-anchor="middle" font-size="${ret_font}"
				font-family="monospace,sans-serif" fill="${text_color}"
				pointer-events="none">${escape_html(label_disp)}</text>`;
		} else {
			rects += `<rect x="${sx}" y="${sy}" width="${key_w}" height="${key_h}" rx="${R}"
				fill="${fill}" stroke="#0d1a0d" stroke-width="1.5" paint-order="stroke fill"
				data-tip="${tip_id}" class="hm-key"
				onmouseenter="hm_show_tip('${tip_id}')" onmouseleave="hm_hide_tip('${tip_id}')"/>`;
		}

		if (kc_str !== "36") {
			labels += `<text x="${Math.round(cx)}" y="${Math.round(cy + font_size * 0.38)}"
				text-anchor="middle" font-size="${font_size}"
				font-family="monospace,sans-serif" fill="${text_color}"
				pointer-events="none">${escape_html(label_disp)}</text>`;
		}

		tooltips += `<div id="${tip_id}" class="hm-tooltip" style="display:none;position:fixed;z-index:9999;` +
			`background:#1a2e1a;border:1px solid #444;border-radius:6px;padding:7px 10px;` +
			`font-size:12px;line-height:1.5;color:#ddd;pointer-events:none;max-width:280px;white-space:nowrap;text-align:left;">` +
			`<style scoped>.hm-tooltip hr{margin:4px 0;border-color:#555;}</style>` +
			tip_html + `</div>`;
	});

	container.innerHTML =
		`<div style="display:inline-block;position:relative;">` +
		`<div style="font-size:17px;font-weight:bold;color:#22c55e;margin-bottom:6px;text-align:left;">` +
		`Heatmap des SFBs par touche</div>` +
		`<svg width="${SVG_W}" height="${SVG_H}" xmlns="http://www.w3.org/2000/svg" ` +
		`style="background:#1e1608;border-radius:10px;display:block;"` +
		`onmousemove="hm_track_mouse(event)">` +
		rects + labels +
		`</svg>` +
		tooltips +
		`</div>`;
}


// ===================================
// ===================================
// ======= 3/ Table DOM Render =======
// ===================================
// ===================================

/**
 * Builds a searchable string for a key by augmenting the raw value with
 * human-readable aliases for special characters. This allows typing "nbsp",
 * "nnbsp", "backspace", or a control-char name (e.g. "rs") to match entries
 * whose raw key is an invisible Unicode code point.
 * @param {string} raw_key - The raw key string from the data dictionary.
 * @returns {string} Lowercase composite string including all aliases.
 */
function build_searchable_key(raw_key, case_sensitive) {
	let s = case_sensitive ? raw_key : raw_key.toLowerCase();
	// Space character variants
	if (raw_key.includes("\u00A0")) s += " nbsp";
	if (raw_key.includes("\u202F")) s += " nnbsp";
	// [BS] marker → backspace alias
	if (/\[bs\]/i.test(raw_key)) s += " backspace";
	// Single ASCII control characters → add their CONTROL_CHAR_NAMES abbreviation
	if (raw_key.length === 1) {
		const code = raw_key.charCodeAt(0);
		if (CONTROL_CHAR_NAMES[code]) {
			const name = CONTROL_CHAR_NAMES[code];
			s += " " + (case_sensitive ? name : name.toLowerCase());
		}
	}
	// Keycode tab → add the resolved human-readable name (custom layout > static map)
	if (app_state.current_tab === "kc") {
		const kc_resolved = (window.keycode_layout && window.keycode_layout[raw_key])
			|| KEYCODE_NAMES[raw_key];
		if (kc_resolved) s += " " + (case_sensitive ? kc_resolved : kc_resolved.toLowerCase());
	}
	// Add the text label for the exact key (lowercased for case-insensitive search)
	// so that typing "backspace", "left", "space", etc. finds the matching entries.
	const exact_sym = CONTROL_KEY_SYMBOLS[raw_key.toLowerCase()];
	if (exact_sym) {
		const candidate = case_sensitive ? exact_sym : exact_sym.toLowerCase();
		if (!s.includes(candidate)) s += " " + candidate;
	}
	// For sequences: also add labels for each embedded bracket marker (e.g. in bigrams)
	const bracket_matches = raw_key.match(/\[[^\]]+\]/gi) || [];
	bracket_matches.forEach(m => {
		const m_sym = CONTROL_KEY_SYMBOLS[m.toLowerCase()];
		if (m_sym) {
			const candidate = case_sensitive ? m_sym : m_sym.toLowerCase();
			if (!s.includes(candidate)) s += " " + candidate;
		}
	});
	return s;
}

/**
 * Renders the filtered and sorted row list into the table body via
 * requestAnimationFrame to keep the main thread responsive.
 */
function render_table() {
	if (app_state.render_timer) cancelAnimationFrame(app_state.render_timer);

	app_state.render_timer = requestAnimationFrame(() => {
		let arr = [...app_state.rendered_list];

		// Apply search filter using enriched searchable key so special characters
		// like NBSP, NNBSP, and [BS] can be found by typing their alias names.
		// Case sensitivity follows the dedicated toggle button — when active, "e"
		// must not match "Enter" and capitalised aliases are preserved verbatim.
		const case_sensitive_search = !!document.getElementById("btn_case_sensitive")?.classList.contains("active");
		const match_positions = new Map();
		if (app_state.search_query) {
			const q = app_state.search_query;
			arr = arr.filter((i) => {
				const haystack = build_searchable_key(i.key, case_sensitive_search);
				const idx = haystack.indexOf(q);
				if (idx === -1) return false;
				match_positions.set(i, idx);
				return true;
			});
		}

		// Sort. When a search is active, rows whose match position is further left
		// rank first — typing "e" should surface "e" itself before words containing
		// "e" further inside. Ties fall back to the regular column-based sort.
		arr.sort((a, b) => {
			if (app_state.search_query) {
				const pa = match_positions.get(a) ?? Infinity;
				const pb = match_positions.get(b) ?? Infinity;
				if (pa !== pb) return pa - pb;
			}
			const v_a = a[app_state.sort_col] ?? 0;
			const v_b = b[app_state.sort_col] ?? 0;
			if (typeof v_a === "string") {
				return app_state.sort_asc ? v_a.localeCompare(v_b) : v_b.localeCompare(v_a);
			}
			return app_state.sort_asc ? v_a - v_b : v_b - v_a;
		});

		// Reflect the visible row count in the Séquence column sub-header
		const rows_elem = document.getElementById("total_rows");
		if (rows_elem) {
			rows_elem.innerHTML = arr.length > 0
				? `${format_number(arr.length)} ligne${arr.length > 1 ? "s" : ""}`
				: "";
		}

		const tbody = document.getElementById("metrics_table_body");
		if (!tbody) return;

		const is_kc_tab       = app_state.current_tab === "kc";
		const is_shortcut_tab = ["sc", "sc_bg", "sc_tg", "sc_qg", "sc_pg", "mods"].includes(app_state.current_tab);
		// Repetition column is meaningful for chars, bigrams, trigrams, words, and shortcuts tabs
		const rep_available   = ["c", "bg", "tg", "w", "sc"].includes(app_state.current_tab);
		// Hide the repetition column for n-grams > 3 tokens and for all bigram/sequence pair tabs
		const NO_REP_TABS     = ["qg", "pg", "hx", "hp", "sc_bg", "sc_tg", "sc_qg", "sc_pg", "w_bg", "w_tg", "w_qg", "w_pg"];
		const show_rep_col    = !NO_REP_TABS.includes(app_state.current_tab);
		const table_el        = document.getElementById("metrics_table");
		if (table_el) table_el.classList.toggle("hide-rep", !show_rep_col);

		const html = arr.map((item, row_idx) => {
			const raw_lower = item.key.toLowerCase();

			// Detect standalone non-printable ASCII characters (e.g. RS = 0x1E logged by the keylogger)
			const single_code   = item.key.length === 1 ? item.key.charCodeAt(0) : -1;
			const is_nonprint   = single_code >= 0 && (single_code < 32 || single_code === 127);

			// Regular space (code 32) is printable but must still render as a "Space" chip so
			// the cell is not blank. CONTROL_KEY_LABELS includes " " for this reason.
			const is_ctrl_display = !is_shortcut_tab && !is_kc_tab &&
				(CONTROL_KEY_LABELS.has(raw_lower) || CONTROL_KEY_LABELS.has(item.key) || is_nonprint);

			let key_html;
			if (is_kc_tab) {
				// Prefer the custom layout injected by Lua (user's actual keyboard); fall back
				// to KEYCODE_NAMES for standard macOS keys (F1–F12, arrows, Escape…) which
				// are layout-independent and always have a known human name.
				const has_custom_layout = window.keycode_layout && Object.keys(window.keycode_layout).length > 0;
				const kc_name  = (has_custom_layout ? window.keycode_layout[item.key] : undefined)
					?? KEYCODE_NAMES[item.key];
				const kc_label = kc_name
					? `kc ${item.key}&nbsp;<span class="kc-name">(${escape_html(kc_name)})</span>`
					: `kc ${item.key}`;
				key_html = `<span class="mono-space kc-chip">${kc_label}</span>`;
			} else if (["sc_bg", "sc_tg", "sc_qg", "sc_pg"].includes(app_state.current_tab)) {
				// Keys are shortcut sequences joined by →; split and render each part
				const sc_parts = item.key.split("→");
				key_html = `<span class="shortcut-seq">` +
					sc_parts.map((p, i) =>
						(i > 0 ? ` <span style="color:var(--text-muted);">→</span> ` : "") +
						format_shortcut_key(p)
					).join("") +
					`</span>`;
			} else if (["w_bg", "w_tg", "w_qg", "w_pg"].includes(app_state.current_tab)) {
				// Keys are words joined by space; render as plain-text chips with arrows
				const w_parts = item.key.split(" ");
				key_html = `<span class="seq-chips">` +
					w_parts.map((p, i) =>
						(i > 0 ? ` <span style="color:var(--text-muted);">→</span> ` : "") +
						`<span class="mono-space">${escape_html(p)}</span>`
					).join("") +
					`</span>`;
				key_html = `<span class="shortcut-seq">${format_shortcut_key(item.key)}</span>`;
			} else if (is_ctrl_display) {
				// Resolve the best label: pretty symbol > ASCII abbreviation > uppercase name
				const label = CONTROL_KEY_SYMBOLS[raw_lower]
					?? (is_nonprint ? (CONTROL_CHAR_NAMES[single_code] ?? `\\x${single_code.toString(16).toUpperCase().padStart(2, "0")}`) : null)
					?? item.key.toUpperCase();
				key_html = `<span class="shortcut-chip shortcut-key-control">${escape_html(label)}</span>`;
			} else {
				// N-gram tabs always render one chip per token for visual consistency.
				// Characters/words/shortcuts stay as a single chip when there are no
				// special markers, which avoids needless per-grapheme splitting for prose.
				const is_ngram_tab = ["bg", "tg", "qg", "pg", "hx", "hp"].includes(app_state.current_tab);
				if (is_ngram_tab || /\[|\u00A0|\u202F/.test(item.key)) {
					key_html = `<span class="seq-chips">${format_seq_chips(item.key)}</span>`;
				} else {
					key_html = `<span class="mono-space">${format_display_key(item.key)}</span>`;
				}
			}

			const synth_parts = [];
			if (item.synth_hs  > 0) synth_parts.push(`${format_number(item.synth_hs)} HS`);
			if (item.synth_llm > 0) synth_parts.push(`${format_number(item.synth_llm)} IA`);
			const synth_str = synth_parts.length
				? `<br><span style="font-size:10px;color:var(--text-muted);">(dont ${synth_parts.join(", ")})</span>`
				: "";

			const avg_str = item.avg > 0
				? `${format_number(item.avg.toFixed(1))} ms`
				: "-";

			const wpm_color = item.wpm > 0 ? gradient_color(item.wpm, WPM_GRADIENT) : "inherit";
			const wpm_str   = item.wpm > 0 ? `${format_number(item.wpm.toFixed(1))} ${_t('ui_typing.unit_mpm')}` : "-";

			const acc_color = gradient_color(item.acc, PRECISION_GRADIENT);

			// Repetition cell: show count · rate% on one line, breakdown below when ★ involved.
			// null = tab type doesn't support rep (no next-level data); show "—".
			// 0   = computable but entry not found in dict; show "0" to distinguish from
			//       no-data tabs, so the user knows it was truly zero repetitions found.
			let rep_html;
			if (!rep_available || item.rep === null) {
				rep_html = `<span style="color:var(--text-muted);">—</span>`;
			} else if (item.rep === 0) {
				rep_html = `0`;
			} else {
				const rep_color = item.rep_rate >= 20 ? "#ff3b30" : (item.rep_rate >= 10 ? "#ffcc00" : "inherit");
				const rate_str  = format_number(item.rep_rate.toFixed(1)) + " %";
				rep_html = `<span style="color:${rep_color}">${format_number(item.rep)} (${rate_str})</span>`;
			}

			// Km cell: total finger distance for all occurrences of this sequence.
			// "—" for home-row keys and sequences whose geometry can't be resolved.
			let km_html;
			if (item.km <= 0) {
				km_html = `<span style="color:var(--text-muted);">—</span>`;
			} else {
				km_html = `${format_number(item.km.toFixed(4))} km`;
			}

			return `<tr>
				<td>
					<div class="cell-seq">
						<span class="row-num">${row_idx + 1}</span>
						<span class="row-divider"></span>
						${key_html}
					</div>
				</td>
				<td>${format_number(item.count)}${synth_str}</td>
				<td class="col-rep">${rep_html}</td>
				<td>${km_html}</td>
				<td>${format_number(item.freq.toFixed(2))} %</td>
				<td>${avg_str}</td>
				<td><strong style="color:${wpm_color}">${wpm_str}</strong></td>
				<td><strong style="color:${acc_color}">${format_number(item.acc.toFixed(1))} %</strong></td>
			</tr>`;
		}).join("");

		tbody.innerHTML = html ||
			`<tr><td colspan="8" style="text-align:center;">${_t('ui_typing.no_data')}</td></tr>`;
	});
}
