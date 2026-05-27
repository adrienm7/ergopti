// ui/metrics_typing/state.js

/**
 * ==============================================================================
 * MODULE: Application State
 * DESCRIPTION:
 * Central shared state object, chart instance references, and constants for
 * the typing metrics dashboard. All modules read from and write to these.
 *
 * FEATURES & RATIONALE:
 * 1. Single Source of Truth: All mutable UI state lives here to prevent drift.
 * 2. Constants Co-Located: Modifier config and control key sets are here so
 *    every rendering module shares the same definitions.
 * ==============================================================================
 */

window.metrics_manifest = window.metrics_manifest || {};
window.app_icons = window.app_icons || {};

// Shared i18n helper — defined here so every module loaded after state.js can call it.
// Reads from window._i18n_strings populated by the shared i18n loader (i18n.js).
function _t(key) {
	return (window._i18n_strings && window._i18n_strings[key]) || key;
}
window.keycode_layout = window.keycode_layout || {};
window._lua_request = null;

// ===================================
// ===================================
// ======= 1/ Mutable App State =======
// ===================================
// ===================================

const app_state = {
	historical_cache: null,
	today_live_data: null,
	data: {
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
		w_bg: {},
		kc: {}
	},
	time_series: {},
	hourly_series: {},
	minute5_series: {},
	available_apps: [],
	selected_apps: new Set(),
	did_apply_initial_reset: false,
	current_tab: 'c',
	sort_col: 'count',
	sort_asc: false,
	search_query: '',
	rendered_list: [],
	loading_data: false,
	manifest_dates_sorted: [],
	render_timer: null,
	live_update_timer: null,
	// Minimum hour (0–23) to display in hourly chart mode.
	// null = daily mode (multi-day range); 0 = today all-day; N = last-hour view (hours ≥ N).
	hour_cutoff: null
};

// Chart instance references — destroyed and recreated on each render cycle
let delegation_chart_instance = null;
let wpm_chart_instance = null;
let precision_chart_instance = null;
let hs_sparkline_instance = null;
let llm_sparkline_instance = null;
let auto_refresh_bound = false;

// =================================
// =================================
// ======= 2/ UI SVG Constants =======
// =================================
// =================================

const INFO_SVG =
	'<svg class="info-icon" xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg>';

// ============================================
// ============================================
// ======= 3/ Modifier & Key Definitions =======
// ============================================
// ============================================

// Canonical modifier display order: Ctrl → Cmd → Option → Shift → Fn
const MODIFIER_ORDER = ['ctrl', 'cmd', 'alt', 'shift', 'fn'];

// Per-modifier color class mapping
const MODIFIER_CONFIG = {
	cmd: { label: '⌘', color_class: 'shortcut-mod-cmd' },
	ctrl: { label: '⌃', color_class: 'shortcut-mod-ctrl' },
	alt: { label: '⌥', color_class: 'shortcut-mod-alt' },
	shift: { label: '⇧', color_class: 'shortcut-mod-shift' },
	fn: { label: 'fn', color_class: 'shortcut-mod-fn' }
};

// Keys rendered in red in both the table and shortcut chips.
// "space" and " " are included so that the bare space-bar press is styled
// consistently with other control keys in the Characters tab.
const CONTROL_KEY_LABELS = new Set([
	'escape',
	'capslock',
	'left',
	'right',
	'up',
	'down',
	'backspace',
	'delete',
	'return',
	'enter',
	'tab',
	'home',
	'end',
	'pageup',
	'pagedown',
	'space',
	' ',
	// French typographic spaces — always synthetic (hotstring output); styled as control keys
	// so they are never rendered as a blank cell in the characters tab.
	'\u00A0',
	'\u202F',
	'f1',
	'f2',
	'f3',
	'f4',
	'f5',
	'f6',
	'f7',
	'f8',
	'f9',
	'f10',
	'f11',
	'f12',
	'f13',
	'f14',
	'f15',
	// Bracketed markers logged by the keylogger for navigation/control keys
	'[bs]',
	'[esc]',
	'[left]',
	'[right]',
	'[up]',
	'[down]',
	'[caps]',
	'[tab]',
	'[enter]',
	'[return]',
	'[space]',
	'[delete]',
	'[home]',
	'[end]',
	'[pageup]',
	'[pagedown]',
	'[f1]',
	'[f2]',
	'[f3]',
	'[f4]',
	'[f5]',
	'[f6]',
	'[f7]',
	'[f8]',
	'[f9]',
	'[f10]',
	'[f11]',
	'[f12]',
	'[f13]',
	'[f14]',
	'[f15]'
]);

// Text labels for named control keys when rendered as standalone chips.
// Text names are used instead of Unicode symbols so that the label cannot be
// confused with a dead-key character the user actually typed (e.g. ⌫ could be
// a dead key output, "BackSpace" is unambiguous).
const CONTROL_KEY_SYMBOLS = {
	'[bs]': 'BackSpace',
	backspace: 'BackSpace',
	escape: 'Escape',
	'[esc]': 'Escape',
	return: 'Return',
	enter: 'Enter',
	'[enter]': 'Enter',
	'[return]': 'Return',
	tab: 'Tab',
	'[tab]': 'Tab',
	delete: 'Delete',
	'[delete]': 'Delete',
	left: 'Left',
	'[left]': 'Left',
	right: 'Right',
	'[right]': 'Right',
	up: 'Up',
	'[up]': 'Up',
	down: 'Down',
	'[down]': 'Down',
	home: 'Home',
	'[home]': 'Home',
	end: 'End',
	'[end]': 'End',
	pageup: 'PageUp',
	'[pageup]': 'PageUp',
	pagedown: 'PageDown',
	'[pagedown]': 'PageDown',
	capslock: 'CapsLock',
	'[caps]': 'CapsLock',
	space: 'Space',
	' ': 'Space',
	'[space]': 'Space',
	'\u00A0': 'NBSP',
	'\u202F': 'NNBSP',
	'[f1]': 'F1',
	'[f2]': 'F2',
	'[f3]': 'F3',
	'[f4]': 'F4',
	'[f5]': 'F5',
	'[f6]': 'F6',
	'[f7]': 'F7',
	'[f8]': 'F8',
	'[f9]': 'F9',
	'[f10]': 'F10',
	'[f11]': 'F11',
	'[f12]': 'F12',
	'[f13]': 'F13',
	'[f14]': 'F14',
	'[f15]': 'F15',
	// Bare named forms (without brackets) — used when keylogger emits the key name directly
	f1: 'F1',
	f2: 'F2',
	f3: 'F3',
	f4: 'F4',
	f5: 'F5',
	f6: 'F6',
	f7: 'F7',
	f8: 'F8',
	f9: 'F9',
	f10: 'F10',
	f11: 'F11',
	f12: 'F12',
	f13: 'F13',
	f14: 'F14',
	f15: 'F15'
};

// ================================================
// ================================================
// ======= 4/ Physical Keyboard Layout Map =======
// ================================================
// ================================================

// Standard ANSI keyboard physical key positions in key-unit coordinates.
// Origin: number-row left edge. x increases rightward, y increases upward.
// 1 unit ≈ KEY_UNIT_MM millimetres (standard keycap centre-to-centre spacing).
// Row stagger: QWERTY row +0.50, Home row +0.75, Bottom row +1.25 vs. number row.
// Vertical pitch: 0.90 units per row (keys are slightly taller than wide).
const KEY_UNIT_MM = 19.05;

const KEY_POSITIONS = {
	// Home row (y = 0.12) — shifted up by half the inter-row reduction to tighten letter-row spacing
	0: { x: 1.75, y: 0.12 }, // a — left pinky home
	1: { x: 2.75, y: 0.12 }, // s — left ring home
	2: { x: 3.75, y: 0.12 }, // d — left middle home
	3: { x: 4.75, y: 0.12 }, // f — left index home (bump)
	5: { x: 5.75, y: 0.12 }, // g — left index stretch
	4: { x: 6.75, y: 0.12 }, // h — right index stretch
	38: { x: 7.75, y: 0.12 }, // j — right index home (bump)
	40: { x: 8.75, y: 0.12 }, // k — right middle home
	37: { x: 9.75, y: 0.12 }, // l — right ring home
	41: { x: 10.75, y: 0.12 }, // ;  — right pinky home
	39: { x: 11.75, y: 0.12 }, // '  — right pinky reach
	36: { x: 13.5, y: 0.12 }, // return — right-anchored; wing right edge aligns with r-shift/backspace (698 px)
	57: { x: 0.75, y: 0.12 }, // capslock — 1.75u wide, anchored so right edge has normal gap with A

	// QWERTY row (y = 0.84)
	48: { x: 0.5, y: 0.84 }, // tab — 1.5u wide, anchored so right edge has normal gap with Q
	12: { x: 1.5, y: 0.84 }, // q
	13: { x: 2.5, y: 0.84 }, // w
	14: { x: 3.5, y: 0.84 }, // e
	15: { x: 4.5, y: 0.84 }, // r
	17: { x: 5.5, y: 0.84 }, // t
	16: { x: 6.5, y: 0.84 }, // y
	32: { x: 7.5, y: 0.84 }, // u
	34: { x: 8.5, y: 0.84 }, // i
	31: { x: 9.5, y: 0.84 }, // o
	35: { x: 10.5, y: 0.84 }, // p
	33: { x: 11.5, y: 0.84 }, // [
	30: { x: 12.5, y: 0.84 }, // ]
	42: { x: 12.75, y: 0.12 }, // \ — ISO backslash is on the home row, between ' and Return

	// Number row (y = 1.80)
	// Apple ISO keyboard quirk: the OS-reported keycode for the backtick key (left of 1)
	// is kc 10, and the ISO extra key (< >, right of left-shift) is kc 50.
	// kc 10 is placed here (number row) so the ` label sits at the correct position.
	10: { x: 0, y: 1.8 }, // ` (number row, left of 1) — Apple ISO: kc10 is physically the ` key
	18: { x: 1, y: 1.8 }, // 1
	19: { x: 2, y: 1.8 }, // 2
	20: { x: 3, y: 1.8 }, // 3
	21: { x: 4, y: 1.8 }, // 4
	23: { x: 5, y: 1.8 }, // 5
	22: { x: 6, y: 1.8 }, // 6
	26: { x: 7, y: 1.8 }, // 7
	28: { x: 8, y: 1.8 }, // 8
	25: { x: 9, y: 1.8 }, // 9
	29: { x: 10, y: 1.8 }, // 0
	27: { x: 11, y: 1.8 }, // -
	24: { x: 12, y: 1.8 }, // =
	51: { x: 13.0, y: 1.8 }, // backspace — left anchor; right edge aligns with Return stem

	// Bottom row (y = -0.60) — ISO layout; shifted up by 0.24 to halve inter-row gap vs home
	// Left Shift is 0.75u on ISO (narrow); ISO extra key (kc 50) fills the gap to Z.
	// Letter keys shifted -0.50u on x so B (x=6.25) sits exactly between G (5.75) and H (6.75).
	56: { x: 0.0, y: -0.6 }, // shift (L) — 0.75u, left-anchored from left edge
	50: { x: 1.25, y: -0.6 }, // ISO extra key (< > on AZERTY)
	6: { x: 2.25, y: -0.6 }, // z
	7: { x: 3.25, y: -0.6 }, // x
	8: { x: 4.25, y: -0.6 }, // c
	9: { x: 5.25, y: -0.6 }, // v
	11: { x: 6.25, y: -0.6 }, // b — exactly between G (5.75) and H (6.75)
	45: { x: 7.25, y: -0.6 }, // n
	46: { x: 8.25, y: -0.6 }, // m
	43: { x: 9.25, y: -0.6 }, // ,
	47: { x: 10.25, y: -0.6 }, // .
	44: { x: 11.25, y: -0.6 }, // /
	60: { x: 13.5, y: -0.6 }, // shift (R) — right-anchored; right edge aligns with Return (rx_ret ≈ 698 px)

	// Thumb row (y = -1.32) — fn, ctrl-L, alt-L, cmd-L | space | cmd-R, alt-R
	// ctrl-R removed; arrow cluster sits immediately after alt-R (4 px gap)
	63: { x: 0.0, y: -1.32 }, // fn — 1u wide, right-anchored; left edge aligns with Esc/Tab/Shift
	59: { x: 1.0, y: -1.32 }, // ctrl (L)
	58: { x: 2.0, y: -1.32 }, // alt / option (L)
	55: { x: 3.25, y: -1.32 }, // cmd (L) — 1.25u, right-anchored; 4 px gap after alt-L, space left = C.left
	49: { x: 6.5, y: -1.32 }, // space
	54: { x: 9.25, y: -1.32 }, // cmd (R) — 1.25u, left-anchored; space = exactly 5u wide
	61: { x: 10.5, y: -1.32 }, // alt / option (R) — 1 normal gap after cmd-R
	// Arrow cluster: left-arrow left edge sits 4 px after alt-R right edge
	// right-arrow right edge aligns with Return and right-shift (≈ 698 px)
	123: { x: 11.5, y: -1.32 }, // left arrow  — 4 px gap after alt-R
	126: { x: 12.5, y: -1.32 }, // up arrow   — top half
	125: { x: 12.5, y: -1.32 }, // down arrow — bottom half (same x; renderer offsets y)
	124: { x: 13.5, y: -1.32 }, // right arrow — right edge aligns with Return (rx_ret ≈ 698 px)

	// Function row (y = 2.70): Esc + F1-F12
	53: { x: 0, y: 2.7 }, // escape
	122: { x: 1.0, y: 2.7 }, // f1
	120: { x: 2.0, y: 2.7 }, // f2
	99: { x: 3.0, y: 2.7 }, // f3
	118: { x: 4.0, y: 2.7 }, // f4
	96: { x: 5.0, y: 2.7 }, // f5
	97: { x: 6.0, y: 2.7 }, // f6
	98: { x: 7.0, y: 2.7 }, // f7
	100: { x: 8.0, y: 2.7 }, // f8
	101: { x: 9.0, y: 2.7 }, // f9
	109: { x: 10.0, y: 2.7 }, // f10
	103: { x: 11.0, y: 2.7 }, // f11
	111: { x: 12.0, y: 2.7 } // f12
};

// Keys rendered at half the standard key height (KH / 2).
// "top" = upper half, "bottom" = lower half of the cell.
// Two keys sharing the same KEY_POSITIONS entry are stacked vertically.
const HALF_HEIGHT_KEYS = {
	126: 'top', // up arrow — upper half
	125: 'bottom' // down arrow — lower half
};

// =================================================================================
// Single source of truth for keycode → finger / hand / home assignments.
// Mirrors `static/ergopti_plus/shared/data/keycodes/azerty.json` — both files must
// stay in sync. The variante-en-A convention applies: the right hand types the
// physical left columns and vice-versa (so kc 0, the QWERTY 'a' key on the
// physical left, is assigned to r_pinky here). The `home: true` flag marks the
// rest position of each finger.
// =================================================================================
const KEYCODE_DATA = [
	{ kc: 0, finger: 'r_pinky', home: true },
	{ kc: 1, finger: 'r_ring', home: true },
	{ kc: 2, finger: 'r_mid', home: true },
	{ kc: 3, finger: 'r_idx', home: true },
	{ kc: 4, finger: 'l_idx' },
	{ kc: 5, finger: 'r_idx' },
	{ kc: 6, finger: 'r_ring' },
	{ kc: 7, finger: 'r_mid' },
	{ kc: 8, finger: 'r_idx' },
	{ kc: 9, finger: 'r_idx' },
	{ kc: 10, finger: 'r_pinky' },
	{ kc: 11, finger: 'r_idx' },
	{ kc: 12, finger: 'r_pinky' },
	{ kc: 13, finger: 'r_ring' },
	{ kc: 14, finger: 'r_mid' },
	{ kc: 15, finger: 'r_idx' },
	{ kc: 16, finger: 'l_idx' },
	{ kc: 17, finger: 'r_idx' },
	{ kc: 18, finger: 'r_pinky' },
	{ kc: 19, finger: 'r_ring' },
	{ kc: 20, finger: 'r_mid' },
	{ kc: 21, finger: 'r_idx' },
	{ kc: 22, finger: 'l_idx' },
	{ kc: 23, finger: 'r_idx' },
	{ kc: 24, finger: 'l_pinky' },
	{ kc: 25, finger: 'l_ring' },
	{ kc: 26, finger: 'l_idx' },
	{ kc: 27, finger: 'l_pinky' },
	{ kc: 28, finger: 'l_mid' },
	{ kc: 29, finger: 'l_pinky' },
	{ kc: 30, finger: 'l_pinky' },
	{ kc: 31, finger: 'l_ring' },
	{ kc: 32, finger: 'l_idx' },
	{ kc: 33, finger: 'l_pinky' },
	{ kc: 34, finger: 'l_mid' },
	{ kc: 35, finger: 'l_pinky' },
	{ kc: 36, finger: 'l_pinky' },
	{ kc: 37, finger: 'l_ring', home: true },
	{ kc: 38, finger: 'l_idx', home: true },
	{ kc: 39, finger: 'l_pinky' },
	{ kc: 40, finger: 'l_mid', home: true },
	{ kc: 41, finger: 'l_pinky', home: true },
	{ kc: 42, finger: 'l_pinky' },
	{ kc: 43, finger: 'l_mid' },
	{ kc: 44, finger: 'l_pinky' },
	{ kc: 45, finger: 'l_idx' },
	{ kc: 46, finger: 'l_idx' },
	{ kc: 47, finger: 'l_ring' },
	{ kc: 49, finger: 'l_thumb', home: true },
	{ kc: 50, finger: 'r_pinky' },
	{ kc: 51, finger: 'l_pinky' },
	{ kc: 53, finger: 'r_pinky' },
	{ kc: 54, finger: 'r_thumb', home: true },
	{ kc: 55, finger: 'l_thumb' },
	{ kc: 56, finger: 'r_pinky' },
	{ kc: 57, finger: 'r_pinky' },
	{ kc: 58, finger: 'l_thumb' },
	{ kc: 59, finger: 'l_pinky' },
	{ kc: 60, finger: 'l_pinky' },
	{ kc: 61, finger: 'r_thumb' },
	{ kc: 63, finger: 'r_pinky' },
	{ kc: 96, finger: 'r_idx' },
	{ kc: 97, finger: 'l_idx' },
	{ kc: 98, finger: 'l_idx' },
	{ kc: 99, finger: 'r_mid' },
	{ kc: 100, finger: 'l_mid' },
	{ kc: 101, finger: 'l_ring' },
	{ kc: 103, finger: 'l_pinky' },
	{ kc: 109, finger: 'l_pinky' },
	{ kc: 111, finger: 'l_pinky' },
	{ kc: 118, finger: 'r_idx' },
	{ kc: 120, finger: 'r_ring' },
	{ kc: 122, finger: 'r_pinky' },
	{ kc: 123, finger: 'l_ring' },
	{ kc: 124, finger: 'l_pinky' },
	{ kc: 125, finger: 'l_mid' },
	{ kc: 126, finger: 'l_ring' }
];

// Fingers excluded from SFB analysis: thumbs press only space/modifiers (no content),
// and are anatomically free to alternate, so they cannot produce a same-finger bigram.
const SFB_EXCLUDED_FINGERS = new Set(['l_thumb', 'r_thumb']);
// Modifier/function-only keys excluded from SFB even though their finger is a content
// finger — pressing Shift/Ctrl/Tab etc. does not type a character, so they cannot
// participate in a content bigram.
const SFB_EXCLUDED_KCS = new Set([
	'48',
	'57',
	'56',
	'59',
	'55',
	'58',
	'61',
	'62',
	'63',
	'51',
	'36',
	'60'
]);

// Derived: kc_str → finger column (used for SFB pair detection).
const SFB_COLUMNS = (() => {
	const map = {};
	KEYCODE_DATA.forEach(({ kc, finger }) => {
		const kc_str = String(kc);
		if (SFB_EXCLUDED_FINGERS.has(finger)) return;
		if (SFB_EXCLUDED_KCS.has(kc_str)) return;
		map[kc_str] = finger;
	});
	return map;
})();

// Derived: kc_str → finger that types it (used by the distance metric).
const KEY_FINGER = (() => {
	const map = {};
	KEYCODE_DATA.forEach(({ kc, finger }) => {
		map[String(kc)] = finger;
	});
	return map;
})();

// Derived: finger → rest position { x, y } in KEY_POSITIONS coordinate units.
// Each finger's home key is the entry tagged `home: true` in KEYCODE_DATA;
// its physical position comes from KEY_POSITIONS.
const FINGER_HOME = (() => {
	const map = {};
	KEYCODE_DATA.forEach(({ kc, finger, home }) => {
		if (!home) return;
		const pos = KEY_POSITIONS[String(kc)];
		if (pos) map[finger] = { x: pos.x, y: pos.y };
	});
	return map;
})();

// Localised display labels for each finger identifier, resolved at render time
// from the active locale via window._i18n_strings.
// In "variante-en-A" the right hand types the physical left columns and vice-versa,
// so the display label swaps G/D vs. the logical finger name to match physical key position.
function _finger_label(key) {
	return (window._i18n_strings && window._i18n_strings['ui_typing.finger.' + key]) || key;
}

const FINGER_LABELS_FR = {
	get l_pinky() { return _finger_label('l_pinky'); },
	get l_ring()  { return _finger_label('l_ring'); },
	get l_mid()   { return _finger_label('l_mid'); },
	get l_idx()   { return _finger_label('l_idx'); },
	get l_thumb() { return _finger_label('l_thumb'); },
	get r_idx()   { return _finger_label('r_idx'); },
	get r_mid()   { return _finger_label('r_mid'); },
	get r_ring()  { return _finger_label('r_ring'); },
	get r_pinky() { return _finger_label('r_pinky'); },
	get r_thumb() { return _finger_label('r_thumb'); }
};

// Pause-threshold buckets emitted by the keylogger as cumulative cache fields.
// MUST stay in sync with UI_PAUSE_BUCKETS_MS in modules/keylogger/log_manager.lua
// — the JS side reads the bucket whose key matches the user-selected pause
// threshold. Adding a new value here requires also adding it to the Lua list
// and re-deploying so the buckets are populated for new data.
const UI_PAUSE_BUCKETS_MS = [1000, 2000, 3000, 5000, 10000, 20000, 30000, 60000];

/**
 * Returns the string-keyed bucket name that exactly matches `pause_thresh`.
 * If the user value is not one of the pre-aggregated thresholds (e.g. they
 * picked "sans filtrage" = 99999999), falls back to the largest bucket so
 * the cache still gives a useful answer.
 * @param {number} pause_thresh - User-selected pause threshold in ms.
 * @returns {string} The bucket key (e.g. "5000") used to index the cache maps.
 */
function pause_thresh_to_bucket_key(pause_thresh) {
	if (UI_PAUSE_BUCKETS_MS.includes(pause_thresh)) return String(pause_thresh);
	let chosen = UI_PAUSE_BUCKETS_MS[UI_PAUSE_BUCKETS_MS.length - 1];
	for (const t of UI_PAUSE_BUCKETS_MS) {
		if (t <= pause_thresh) chosen = t;
	}
	return String(chosen);
}

// Centralised tooltip text for the finger-travel distance metric. Reused by
// every UI surface that exposes "km parcourus" so the explanation stays
// consistent and updates in a single place.
const FINGER_DISTANCE_TOOLTIP_HTML = (() => {
	const NBSP = String.fromCharCode(160);
	return (
		`<strong>Calcul de la distance${NBSP}:</strong><br>` +
		`&nbsp;&nbsp;Pour chaque touche frappée, on calcule la distance euclidienne (en unités de touche, 1${NBSP}u${NBSP}=${NBSP}19,05${NBSP}mm) entre le centre de la touche et la position de repos du doigt qui l'a tapée${NBSP}: F${NBSP}/${NBSP}J pour les index, A${NBSP}S${NBSP}D et K${NBSP}L${NBSP};${NBSP}pour les autres, espace pour le pouce gauche, cmd droite pour le pouce droit. ` +
		`On compte un aller-retour (×${NBSP}2) puisque le doigt revient au repos.<br><br>` +
		`<strong>Cas particuliers${NBSP}:</strong><br>` +
		`&nbsp;&nbsp;• Si la touche frappée est la touche de repos elle-même (espace pour le pouce gauche par exemple), la distance est de 0.<br>` +
		`&nbsp;&nbsp;• Le décalage horizontal entre rangées d'un clavier ISO n'est pas pris en compte${NBSP}: on traite le clavier comme une grille orthogonale, ce qui simplifie le calcul et reste valide pour les claviers ortholinéaires.<br>` +
		`&nbsp;&nbsp;• Frapper deux fois la même touche ne compte pas deux allers-retours complets : la distance est sommée par-dessus le compteur de la touche, ce qui sous-estime légèrement les répétitions mais reflète bien la fatigue cumulée.<br><br>` +
		`<strong>Effet des toggles${NBSP}:</strong> diminue significativement quand les hotstrings ou l'IA génèrent des caractères à votre place — vos doigts ne se déplacent plus pour ces caractères-là.`
	);
})();

// Standard 2–3-letter abbreviations for ASCII non-printable characters (codes 0–31 and 127).
// These appear in the n-gram data when control characters are captured by the keylogger.
const CONTROL_CHAR_NAMES = {
	0: 'NUL',
	1: 'SOH',
	2: 'STX',
	3: 'ETX',
	4: 'EOT',
	5: 'ENQ',
	6: 'ACK',
	7: 'BEL',
	8: 'BS',
	9: 'HT',
	10: 'LF',
	11: 'VT',
	12: 'FF',
	13: 'CR',
	14: 'SO',
	15: 'SI',
	16: 'DLE',
	17: 'DC1',
	18: 'DC2',
	19: 'DC3',
	20: 'DC4',
	21: 'NAK',
	22: 'SYN',
	23: 'ETB',
	24: 'CAN',
	25: 'EM',
	26: 'SUB',
	27: 'ESC',
	28: 'FS',
	29: 'GS',
	30: 'RS',
	31: 'US',
	127: 'DEL'
};

// =====================================================
// =====================================================
// ======= 5/ Control-Key Canonicalization Map =======
// =====================================================
// =====================================================

// Maps sc/kc key names (lowercase) to the canonical form produced by merge_dict
// for the same key in the c dict. merge_dict converts raw control chars as follows:
//   \x08 → "[BS]",  \x09 → "[TAB]",  \x0A/\x0D → "[ENTER]",  \x1B → "[ESC]",  \x1E → " "
// Any sc/kc entry whose lowercase name maps here will be merged into the same
// char_accum bucket as the c-dict entry, preventing duplicate rows in the
// characters tab for Space, BackSpace, Tab, Enter, Escape, and nav keys.
const SC_TO_CHAR_CANONICAL = {
	backspace: '[BS]',
	space: ' ',
	tab: '[TAB]',
	enter: '[ENTER]',
	return: '[ENTER]',
	escape: '[ESC]',
	// Navigation keys: sc dict may have bare "left"/"home"/etc. from older builds;
	// map them to the same bracket-marker keys logged by the c-dict path.
	left: '[LEFT]',
	right: '[RIGHT]',
	up: '[UP]',
	down: '[DOWN]',
	delete: '[DELETE]',
	home: '[HOME]',
	end: '[END]',
	pageup: '[PAGEUP]',
	pagedown: '[PAGEDOWN]',
	'[bs]': '[BS]',
	'[space]': ' ',
	'[tab]': '[TAB]',
	'[enter]': '[ENTER]',
	'[return]': '[ENTER]',
	'[esc]': '[ESC]',
	'[left]': '[LEFT]',
	'[right]': '[RIGHT]',
	'[up]': '[UP]',
	'[down]': '[DOWN]',
	'[delete]': '[DELETE]',
	'[home]': '[HOME]',
	'[end]': '[END]',
	'[pageup]': '[PAGEUP]',
	'[pagedown]': '[PAGEDOWN]',
	// F-keys: kc-fallback emits bare names ("f1") while c-dict logs bracket markers ("[F1]");
	// both must collapse into the same row in the Characters tab.
	f1: '[F1]',
	f2: '[F2]',
	f3: '[F3]',
	f4: '[F4]',
	f5: '[F5]',
	f6: '[F6]',
	f7: '[F7]',
	f8: '[F8]',
	f9: '[F9]',
	f10: '[F10]',
	f11: '[F11]',
	f12: '[F12]',
	f13: '[F13]',
	f14: '[F14]',
	f15: '[F15]',
	'[f1]': '[F1]',
	'[f2]': '[F2]',
	'[f3]': '[F3]',
	'[f4]': '[F4]',
	'[f5]': '[F5]',
	'[f6]': '[F6]',
	'[f7]': '[F7]',
	'[f8]': '[F8]',
	'[f9]': '[F9]',
	'[f10]': '[F10]',
	'[f11]': '[F11]',
	'[f12]': '[F12]',
	'[f13]': '[F13]',
	'[f14]': '[F14]',
	'[f15]': '[F15]',
	// CapsLock: same deduplication need between c-dict "[CAPS]" and kc-fallback "capslock"
	capslock: '[CAPS]',
	'[caps]': '[CAPS]'
};

// macOS virtual keycode → human-readable key name.
// Used by the Keycodes tab to display readable labels instead of raw integers.
// Source: HIToolbox/Events.h (kVK_* constants), macOS Carbon reference.
const KEYCODE_NAMES = {
	0: 'a',
	1: 's',
	2: 'd',
	3: 'f',
	4: 'h',
	5: 'g',
	6: 'z',
	7: 'x',
	8: 'c',
	9: 'v',
	10: '< >',
	11: 'b',
	12: 'q',
	13: 'w',
	14: 'e',
	15: 'r',
	16: 'y',
	17: 't',
	18: '1',
	19: '2',
	20: '3',
	21: '4',
	22: '6',
	23: '5',
	24: '=',
	25: '9',
	26: '7',
	27: '-',
	28: '8',
	29: '0',
	30: ']',
	31: 'o',
	32: 'u',
	33: '[',
	34: 'i',
	35: 'p',
	36: 'return',
	37: 'l',
	38: 'j',
	39: "'",
	40: 'k',
	41: ';',
	42: '\\',
	43: ',',
	44: '/',
	45: 'n',
	46: 'm',
	47: '.',
	48: 'tab',
	49: 'space',
	50: '`',
	51: 'backspace',
	53: 'escape',
	54: 'r-cmd',
	55: 'cmd',
	56: 'shift',
	57: 'capslock',
	58: 'alt',
	59: 'ctrl',
	60: 'r-shift',
	61: 'r-alt',
	62: 'r-ctrl',
	63: 'fn',
	76: 'enter',
	96: 'f5',
	97: 'f6',
	98: 'f7',
	99: 'f3',
	100: 'f8',
	101: 'f9',
	103: 'f11',
	105: 'f13',
	107: 'f14',
	109: 'f10',
	111: 'f12',
	113: 'f15',
	114: 'help',
	115: 'home',
	116: 'pageup',
	117: 'delete',
	118: 'f4',
	119: 'end',
	120: 'f2',
	121: 'pagedown',
	122: 'f1',
	123: 'left',
	124: 'right',
	125: 'down',
	126: 'up'
};
