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

window.metrics_manifest  = window.metrics_manifest  || {};
window.app_icons         = window.app_icons         || {};
window.keycode_layout    = window.keycode_layout    || {};
window._lua_request      = null;


// ===================================
// ===================================
// ======= 1/ Mutable App State =======
// ===================================
// ===================================

const app_state = {
	historical_cache:        null,
	today_live_data:         null,
	data:                    { c: {}, bg: {}, tg: {}, qg: {}, pg: {}, hx: {}, hp: {}, w: {}, sc: {}, sc_bg: {}, w_bg: {}, kc: {} },
	time_series:             {},
	hourly_series:           {},
	minute5_series:          {},
	available_apps:          [],
	selected_apps:           new Set(),
	did_apply_initial_reset: false,
	current_tab:             "c",
	sort_col:                "count",
	sort_asc:                false,
	search_query:            "",
	rendered_list:           [],
	loading_data:            false,
	manifest_dates_sorted:   [],
	render_timer:            null,
	live_update_timer:       null,
	// Minimum hour (0–23) to display in hourly chart mode.
	// null = daily mode (multi-day range); 0 = today all-day; N = last-hour view (hours ≥ N).
	hour_cutoff:             null,
};

// Chart instance references — destroyed and recreated on each render cycle
let delegation_chart_instance = null;
let wpm_chart_instance        = null;
let precision_chart_instance  = null;
let hs_sparkline_instance     = null;
let llm_sparkline_instance    = null;
let auto_refresh_bound        = false;


// =================================
// =================================
// ======= 2/ UI SVG Constants =======
// =================================
// =================================

const INFO_SVG = "<svg class=\"info-icon\" xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"10\"></circle><line x1=\"12\" y1=\"16\" x2=\"12\" y2=\"12\"></line><line x1=\"12\" y1=\"8\" x2=\"12.01\" y2=\"8\"></line></svg>";


// ============================================
// ============================================
// ======= 3/ Modifier & Key Definitions =======
// ============================================
// ============================================

// Canonical modifier display order: Ctrl → Cmd → Option → Shift → Fn
const MODIFIER_ORDER = ["ctrl", "cmd", "alt", "shift", "fn"];

// Per-modifier color class mapping
const MODIFIER_CONFIG = {
	cmd:   { label: "⌘",  color_class: "shortcut-mod-cmd"   },
	ctrl:  { label: "⌃",  color_class: "shortcut-mod-ctrl"  },
	alt:   { label: "⌥",  color_class: "shortcut-mod-alt"   },
	shift: { label: "⇧",  color_class: "shortcut-mod-shift" },
	fn:    { label: "fn", color_class: "shortcut-mod-fn"    },
};

// Keys rendered in red in both the table and shortcut chips.
// "space" and " " are included so that the bare space-bar press is styled
// consistently with other control keys in the Characters tab.
const CONTROL_KEY_LABELS = new Set([
	"escape", "capslock", "left", "right", "up", "down",
	"backspace", "delete", "return", "enter", "tab",
	"home", "end", "pageup", "pagedown",
	"space", " ",
	// French typographic spaces — always synthetic (hotstring output); styled as control keys
	// so they are never rendered as a blank cell in the characters tab.
	"\u00A0", "\u202F",
	"f1",  "f2",  "f3",  "f4",  "f5",  "f6",
	"f7",  "f8",  "f9",  "f10", "f11", "f12",
	"f13", "f14", "f15",
	// Bracketed markers logged by the keylogger for navigation/control keys
	"[bs]", "[esc]", "[left]", "[right]", "[up]", "[down]", "[caps]",
	"[tab]", "[enter]", "[return]", "[space]",
	"[delete]", "[home]", "[end]", "[pageup]", "[pagedown]",
	"[f1]",  "[f2]",  "[f3]",  "[f4]",  "[f5]",  "[f6]",
	"[f7]",  "[f8]",  "[f9]",  "[f10]", "[f11]", "[f12]",
	"[f13]", "[f14]", "[f15]",
]);

// Text labels for named control keys when rendered as standalone chips.
// Text names are used instead of Unicode symbols so that the label cannot be
// confused with a dead-key character the user actually typed (e.g. ⌫ could be
// a dead key output, "BackSpace" is unambiguous).
const CONTROL_KEY_SYMBOLS = {
	"[bs]": "BackSpace",      "backspace": "BackSpace",
	"escape": "Escape",       "[esc]": "Escape",
	"return": "Return",       "enter": "Enter",
	"[enter]": "Enter",       "[return]": "Return",
	"tab": "Tab",             "[tab]": "Tab",
	"delete": "Delete",       "[delete]": "Delete",
	"left": "Left",           "[left]": "Left",
	"right": "Right",         "[right]": "Right",
	"up": "Up",               "[up]": "Up",
	"down": "Down",           "[down]": "Down",
	"home": "Home",           "[home]": "Home",
	"end": "End",             "[end]": "End",
	"pageup": "PageUp",       "[pageup]": "PageUp",
	"pagedown": "PageDown",   "[pagedown]": "PageDown",
	"capslock": "CapsLock",   "[caps]": "CapsLock",
	"space": "Space",         " ": "Space",              "[space]": "Space",
	"\u00A0": "NBSP",         "\u202F": "NNBSP",
	"[f1]": "F1",   "[f2]": "F2",   "[f3]": "F3",   "[f4]": "F4",
	"[f5]": "F5",   "[f6]": "F6",   "[f7]": "F7",   "[f8]": "F8",
	"[f9]": "F9",   "[f10]": "F10", "[f11]": "F11", "[f12]": "F12",
	"[f13]": "F13", "[f14]": "F14", "[f15]": "F15",
	// Bare named forms (without brackets) — used when keylogger emits the key name directly
	"f1":  "F1",  "f2":  "F2",  "f3":  "F3",  "f4":  "F4",
	"f5":  "F5",  "f6":  "F6",  "f7":  "F7",  "f8":  "F8",
	"f9":  "F9",  "f10": "F10", "f11": "F11", "f12": "F12",
	"f13": "F13", "f14": "F14", "f15": "F15",
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
	// Home row (y = 0)
	"0":   { x: 1.75,  y: 0     }, // a — left pinky home
	"1":   { x: 2.75,  y: 0     }, // s — left ring home
	"2":   { x: 3.75,  y: 0     }, // d — left middle home
	"3":   { x: 4.75,  y: 0     }, // f — left index home (bump)
	"5":   { x: 5.75,  y: 0     }, // g — left index stretch
	"4":   { x: 6.75,  y: 0     }, // h — right index stretch
	"38":  { x: 7.75,  y: 0     }, // j — right index home (bump)
	"40":  { x: 8.75,  y: 0     }, // k — right middle home
	"37":  { x: 9.75,  y: 0     }, // l — right ring home
	"41":  { x: 10.75, y: 0     }, // ;  — right pinky home
	"39":  { x: 11.75, y: 0     }, // '  — right pinky reach
	"36":  { x: 14.0,  y: 0     }, // return
	"57":  { x: 0.875, y: 0     }, // capslock — 1.75u wide, left-aligned at x=0

	// QWERTY row (y = 0.90)
	"48":  { x: 0.75,  y: 0.90  }, // tab — 1.5u wide, left-aligned at x=0
	"12":  { x: 1.5,   y: 0.90  }, // q
	"13":  { x: 2.5,   y: 0.90  }, // w
	"14":  { x: 3.5,   y: 0.90  }, // e
	"15":  { x: 4.5,   y: 0.90  }, // r
	"17":  { x: 5.5,   y: 0.90  }, // t
	"16":  { x: 6.5,   y: 0.90  }, // y
	"32":  { x: 7.5,   y: 0.90  }, // u
	"34":  { x: 8.5,   y: 0.90  }, // i
	"31":  { x: 9.5,   y: 0.90  }, // o
	"35":  { x: 10.5,  y: 0.90  }, // p
	"33":  { x: 11.5,  y: 0.90  }, // [
	"30":  { x: 12.5,  y: 0.90  }, // ]
	"42":  { x: 12.75, y: 0     }, // \ — ISO backslash is on the home row, between ' and Return

	// Number row (y = 1.80)
	// Apple ISO keyboard quirk: the kc to the left of "1" is reported as 10
	// (normally the ISO < > key) and the kc right of left-shift is reported
	// as 50 (normally `). The visual layout swaps them so the labels match
	// what the user actually sees on their physical keyboard.
	"10":  { x: 0,     y: 1.80  }, // ` (left of 1) — Apple ISO swap
	"18":  { x: 1,     y: 1.80  }, // 1
	"19":  { x: 2,     y: 1.80  }, // 2
	"20":  { x: 3,     y: 1.80  }, // 3
	"21":  { x: 4,     y: 1.80  }, // 4
	"23":  { x: 5,     y: 1.80  }, // 5
	"22":  { x: 6,     y: 1.80  }, // 6
	"26":  { x: 7,     y: 1.80  }, // 7
	"28":  { x: 8,     y: 1.80  }, // 8
	"25":  { x: 9,     y: 1.80  }, // 9
	"29":  { x: 10,    y: 1.80  }, // 0
	"27":  { x: 11,    y: 1.80  }, // -
	"24":  { x: 12,    y: 1.80  }, // =
	"51":  { x: 13.5,  y: 1.80  }, // backspace

	// Bottom row (y = -0.90) — ISO layout
	// Left Shift is 1.25u on ISO (vs 2.25u ANSI); ISO extra key (kc 10) fills the gap.
	// Z and every key after it sit at the same x as ANSI because 1.25u + 1u = 2.25u total offset.
	"56":  { x: 0.625, y: -0.90 }, // shift (L) — 1.25u ISO key, centre at 0.625
	"50":  { x: 1.75,  y: -0.90 }, // ISO extra key (< > on AZERTY, § on UK) — Apple ISO swap
	"6":   { x: 2.75,  y: -0.90 }, // z
	"7":   { x: 3.75,  y: -0.90 }, // x
	"8":   { x: 4.75,  y: -0.90 }, // c
	"9":   { x: 5.75,  y: -0.90 }, // v
	"11":  { x: 6.75,  y: -0.90 }, // b
	"45":  { x: 7.75,  y: -0.90 }, // n
	"46":  { x: 8.75,  y: -0.90 }, // m
	"43":  { x: 9.75,  y: -0.90 }, // ,
	"47":  { x: 10.75, y: -0.90 }, // .
	"44":  { x: 11.75, y: -0.90 }, // /
	"60":  { x: 12.875,y: -0.90 }, // shift (R) — 1.75u ISO right shift

	// Thumb row (y = -1.80)
	"59":  { x: 0.5,   y: -1.80 }, // ctrl (L) — left pinky (standard touch-typing)
	"63":  { x: 1.5,   y: -1.80 }, // fn
	"58":  { x: 2.5,   y: -1.80 }, // alt / option (L)
	"55":  { x: 3.5,   y: -1.80 }, // cmd (L)
	"49":  { x: 6.5,   y: -1.80 }, // space — left thumb rest position
	"54":  { x: 9.5,   y: -1.80 }, // cmd (R) — right thumb rest position
	"61":  { x: 10.5,  y: -1.80 }, // alt / option (R)
	"62":  { x: 11.5,  y: -1.80 }, // ctrl (R)

	// Function row (y = 2.70)
	"53":  { x: 0,     y: 2.70  }, // escape
	"122": { x: 2.0,   y: 2.70  }, // f1  (gap between Esc and F1–F4)
	"120": { x: 3.0,   y: 2.70  }, // f2
	"99":  { x: 4.0,   y: 2.70  }, // f3
	"118": { x: 5.0,   y: 2.70  }, // f4
	"96":  { x: 6.0,   y: 2.70  }, // f5
	"97":  { x: 7.0,   y: 2.70  }, // f6
	"98":  { x: 8.0,   y: 2.70  }, // f7
	"100": { x: 9.0,   y: 2.70  }, // f8
	"101": { x: 10.0,  y: 2.70  }, // f9
	"109": { x: 11.0,  y: 2.70  }, // f10
	"103": { x: 12.0,  y: 2.70  }, // f11
	"111": { x: 13.0,  y: 2.70  }, // f12

	// Navigation cluster (right of main keyboard) — strict 2-column grid at x=15/16,
	// vertically aligned with each main row. F13/F14/F15 live on the function row;
	// kc 114 ("help" — vestigial, not present on most Apple ISO keyboards) is
	// pushed to the far edge so it never overlaps F13/F14.
	"105": { x: 15.0,  y: 2.70  }, // f13 (above home)
	"107": { x: 16.0,  y: 2.70  }, // f14 (above page up)
	"113": { x: 17.0,  y: 2.70  }, // f15
	"114": { x: 18.0,  y: 2.70  }, // help / insert — isolated, rarely used on ISO
	"117": { x: 15.0,  y: 1.80  }, // forward delete (number-row line)
	"115": { x: 16.0,  y: 1.80  }, // home
	"116": { x: 16.0,  y: 0.90  }, // page up
	"119": { x: 16.0,  y: 0     }, // end
	"121": { x: 17.0,  y: 0     }, // page down (rightmost column to avoid overcrowding)

	// Arrow cluster — inverted-T layout (matches physical keyboard):
	//   row 1 (y = -0.90): UP alone, centred above DOWN
	//   row 2 (y = -1.80): LEFT, DOWN, RIGHT aligned side by side
	"126": { x: 15.5,  y: -0.90 }, // up — isolated above down
	"123": { x: 14.5,  y: -1.80 }, // left
	"125": { x: 15.5,  y: -1.80 }, // down
	"124": { x: 16.5,  y: -1.80 }, // right

	// Numpad enter
	"76":  { x: 18.0,  y: -1.80 }, // enter (numpad)
};

// Maps each macOS virtual keycode to the finger that types it (standard touch typing).
const KEY_FINGER = {
	// Home row
	"0": "l_pinky", "1": "l_ring",  "2": "l_mid",   "3": "l_idx",
	"5": "l_idx",   "4": "r_idx",   "38": "r_idx",  "40": "r_mid",
	"37": "r_ring", "41": "r_pinky","39": "r_pinky","36": "r_pinky",
	"57": "l_pinky",
	// QWERTY row
	"48": "l_pinky","12": "l_pinky","13": "l_ring", "14": "l_mid",
	"15": "l_idx",  "17": "l_idx",  "16": "r_idx",  "32": "r_idx",
	"34": "r_mid",  "31": "r_ring", "35": "r_pinky","33": "r_pinky",
	"30": "r_pinky","42": "r_pinky",
	// Number row
	"50": "l_pinky","18": "l_pinky","19": "l_ring", "20": "l_mid",
	"21": "l_idx",  "23": "l_idx",  "22": "r_idx",  "26": "r_idx",
	"28": "r_mid",  "25": "r_ring", "29": "r_pinky","27": "r_pinky",
	"24": "r_pinky","51": "r_pinky",
	// Bottom row
	"56": "l_pinky","10": "l_pinky","6":  "l_pinky","7":  "l_ring", "8":  "l_mid",
	"9":  "l_idx",  "11": "l_idx",  "45": "r_idx",  "46": "r_idx",
	"43": "r_mid",  "47": "r_ring", "44": "r_pinky","60": "r_pinky",
	// Thumb row (ctrl-L is typed with the left pinky in standard touch typing)
	"59": "l_pinky","63": "l_thumb","58": "l_thumb","55": "l_thumb",
	"49": "l_thumb","54": "r_thumb","61": "r_thumb","62": "r_thumb",
	// Function row
	"53": "l_pinky","122":"l_pinky","120":"l_ring", "99": "l_mid",
	"118":"l_idx",  "96": "l_idx",  "97": "r_idx",  "98": "r_idx",
	"100":"r_mid",  "101":"r_ring", "109":"r_pinky","103":"r_pinky",
	"111":"r_pinky",
	// Navigation cluster
	"114":"r_pinky","105":"r_pinky","107":"r_pinky","113":"r_pinky",
	"117":"r_pinky","115":"r_pinky","116":"r_pinky","119":"r_pinky",
	"121":"r_pinky",
	// Arrows
	"123":"r_ring", "124":"r_pinky","125":"r_mid",  "126":"r_ring",
	"76": "r_pinky",
};

// Rest position for each finger (in KEY_POSITIONS coordinate units).
const FINGER_HOME = {
	l_pinky: { x: 1.75,  y: 0     }, // rests on a
	l_ring:  { x: 2.75,  y: 0     }, // rests on s
	l_mid:   { x: 3.75,  y: 0     }, // rests on d
	l_idx:   { x: 4.75,  y: 0     }, // rests on f (bump)
	l_thumb: { x: 6.5,   y: -1.80 }, // rests on the space bar
	r_idx:   { x: 7.75,  y: 0     }, // rests on j (bump)
	r_mid:   { x: 8.75,  y: 0     }, // rests on k
	r_ring:  { x: 9.75,  y: 0     }, // rests on l
	r_pinky: { x: 10.75, y: 0     }, // rests on ;
	r_thumb: { x: 9.5,   y: -1.80 }, // rests on cmd (R), adjacent to space
};

// French display labels for each finger identifier.
const FINGER_LABELS_FR = {
	l_pinky: "Auriculaire G", l_ring: "Annulaire G",
	l_mid:   "Majeur G",      l_idx:  "Index G",
	l_thumb: "Pouce G",       r_idx:  "Index D",
	r_mid:   "Majeur D",      r_ring: "Annulaire D",
	r_pinky: "Auriculaire D", r_thumb:"Pouce D",
};


// Standard 2–3-letter abbreviations for ASCII non-printable characters (codes 0–31 and 127).
// These appear in the n-gram data when control characters are captured by the keylogger.
const CONTROL_CHAR_NAMES = {
	0: "NUL", 1: "SOH", 2: "STX", 3: "ETX", 4: "EOT", 5: "ENQ", 6: "ACK", 7: "BEL",
	8: "BS",  9: "HT",  10: "LF", 11: "VT",  12: "FF", 13: "CR", 14: "SO", 15: "SI",
	16: "DLE", 17: "DC1", 18: "DC2", 19: "DC3", 20: "DC4",
	21: "NAK", 22: "SYN", 23: "ETB", 24: "CAN", 25: "EM", 26: "SUB",
	27: "ESC", 28: "FS",  29: "GS",  30: "RS",  31: "US", 127: "DEL",
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
	"backspace": "[BS]",       "space":     " ",
	"tab":       "[TAB]",      "enter":     "[ENTER]",
	"return":    "[ENTER]",    "escape":    "[ESC]",
	// Navigation keys: sc dict may have bare "left"/"home"/etc. from older builds;
	// map them to the same bracket-marker keys logged by the c-dict path.
	"left":      "[LEFT]",     "right":     "[RIGHT]",
	"up":        "[UP]",       "down":      "[DOWN]",
	"delete":    "[DELETE]",   "home":      "[HOME]",
	"end":       "[END]",      "pageup":    "[PAGEUP]",
	"pagedown":  "[PAGEDOWN]",
	"[bs]":      "[BS]",       "[space]":   " ",
	"[tab]":     "[TAB]",      "[enter]":   "[ENTER]",
	"[return]":  "[ENTER]",    "[esc]":     "[ESC]",
	"[left]":    "[LEFT]",     "[right]":   "[RIGHT]",
	"[up]":      "[UP]",       "[down]":    "[DOWN]",
	"[delete]":  "[DELETE]",   "[home]":    "[HOME]",
	"[end]":     "[END]",      "[pageup]":  "[PAGEUP]",
	"[pagedown]": "[PAGEDOWN]",
	// F-keys: kc-fallback emits bare names ("f1") while c-dict logs bracket markers ("[F1]");
	// both must collapse into the same row in the Characters tab.
	"f1":  "[F1]",  "f2":  "[F2]",  "f3":  "[F3]",  "f4":  "[F4]",  "f5":  "[F5]",
	"f6":  "[F6]",  "f7":  "[F7]",  "f8":  "[F8]",  "f9":  "[F9]",  "f10": "[F10]",
	"f11": "[F11]", "f12": "[F12]", "f13": "[F13]", "f14": "[F14]", "f15": "[F15]",
	"[f1]":  "[F1]",  "[f2]":  "[F2]",  "[f3]":  "[F3]",  "[f4]":  "[F4]",  "[f5]":  "[F5]",
	"[f6]":  "[F6]",  "[f7]":  "[F7]",  "[f8]":  "[F8]",  "[f9]":  "[F9]",  "[f10]": "[F10]",
	"[f11]": "[F11]", "[f12]": "[F12]", "[f13]": "[F13]", "[f14]": "[F14]", "[f15]": "[F15]",
	// CapsLock: same deduplication need between c-dict "[CAPS]" and kc-fallback "capslock"
	"capslock": "[CAPS]", "[caps]": "[CAPS]",
};


// macOS virtual keycode → human-readable key name.
// Used by the Keycodes tab to display readable labels instead of raw integers.
// Source: HIToolbox/Events.h (kVK_* constants), macOS Carbon reference.
const KEYCODE_NAMES = {
	"0": "a",        "1": "s",        "2": "d",        "3": "f",
	"4": "h",        "5": "g",        "6": "z",        "7": "x",
	"8": "c",        "9": "v",        "10": "< >",     "11": "b",       "12": "q",
	"13": "w",       "14": "e",       "15": "r",       "16": "y",
	"17": "t",       "18": "1",       "19": "2",       "20": "3",
	"21": "4",       "22": "6",       "23": "5",       "24": "=",
	"25": "9",       "26": "7",       "27": "-",       "28": "8",
	"29": "0",       "30": "]",       "31": "o",       "32": "u",
	"33": "[",       "34": "i",       "35": "p",       "36": "return",
	"37": "l",       "38": "j",       "39": "'",       "40": "k",
	"41": ";",       "42": "\\",      "43": ",",       "44": "/",
	"45": "n",       "46": "m",       "47": ".",       "48": "tab",
	"49": "space",   "50": "`",       "51": "backspace","53": "escape",
	"54": "r-cmd",   "55": "cmd",     "56": "shift",   "57": "capslock",
	"58": "alt",     "59": "ctrl",    "60": "r-shift",
	"61": "r-alt",   "62": "r-ctrl",  "63": "fn",
	"76": "enter",
	"96": "f5",      "97": "f6",      "98": "f7",      "99": "f3",
	"100": "f8",     "101": "f9",     "103": "f11",    "105": "f13",
	"107": "f14",    "109": "f10",    "111": "f12",    "113": "f15",
	"114": "help",   "115": "home",   "116": "pageup", "117": "delete",
	"118": "f4",     "119": "end",    "120": "f2",     "121": "pagedown",
	"122": "f1",     "123": "left",   "124": "right",  "125": "down",
	"126": "up",
};
