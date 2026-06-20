// ui/metrics_typing/heatmap_win.js

/**
 * ==============================================================================
 * MODULE: Windows scancode → HS keycode bridge
 * DESCRIPTION:
 * The dashboard's heatmap geometry (KEY_POSITIONS, KEYCODE_DATA, SFB_COLUMNS)
 * is keyed by Hammerspoon keycodes — the macOS driver's native identifier.
 * The AHK driver captures hardware scancodes (set 1) instead. Rather than
 * forking the entire layout for Windows, we translate each scancode to its
 * equivalent HS keycode at the data ingestion layer so the renderer keeps
 * working unchanged.
 *
 * FEATURES & RATIONALE:
 * 1. Single physical-key map: SC_TO_KC covers every key the heatmap can
 *    colour. Modifier identities differ (Ctrl/Alt/Win vs ⌃/⌥/⌘) but the
 *    PHYSICAL position is identical, so the same KEY_POSITIONS entry is
 *    reused with a relabel via WIN_KEYCODE_LABELS.
 * 2. No cross-driver leakage: the translator only kicks in when the
 *    incoming prefetch carries `driver_meta.os === "win"`. Mac payloads
 *    fall through untouched.
 * 3. Defensive: unknown scancodes (rare extended-key edge cases) are
 *    dropped instead of crashing the render pipeline.
 * ==============================================================================
 */

// =============================================
// =============================================
// ======= 1/ Scancode → HS keycode map =======
// =============================================
// =============================================

// Windows scancode set 1 → Hammerspoon keycode. Matches each physical key
// against the position the dashboard already knows about. Modifier and
// arrow keys included so heatmap colouring lights up the same cell as on
// macOS.
const SC_TO_KC = {
	// Function row
	1: 53, // Esc
	59: 122,
	60: 120,
	61: 99,
	62: 118, // F1-F4
	63: 96,
	64: 97,
	65: 98,
	66: 100, // F5-F8
	67: 101,
	68: 109,
	87: 103,
	88: 111, // F9-F12

	// Number row
	2: 18,
	3: 19,
	4: 20,
	5: 21,
	6: 23, // 1-5
	7: 22,
	8: 26,
	9: 28,
	10: 25,
	11: 29, // 6-0
	12: 27,
	13: 24,
	14: 51, // - = backspace
	41: 10, // ` (left of 1)

	// QWERTY row
	15: 48, // tab
	16: 12,
	17: 13,
	18: 14,
	19: 15,
	20: 17, // q w e r t
	21: 16,
	22: 32,
	23: 34,
	24: 31,
	25: 35, // y u i o p
	26: 33,
	27: 30,
	43: 42, // [ ] backslash

	// Home row
	58: 57, // capslock
	30: 0,
	31: 1,
	32: 2,
	33: 3,
	34: 5, // a s d f g
	35: 4,
	36: 38,
	37: 40,
	38: 37,
	39: 41, // h j k l ;
	40: 39,
	28: 36, // ' enter

	// Bottom row (ISO)
	42: 56,
	86: 50, // shift_l, ISO < >
	44: 6,
	45: 7,
	46: 8,
	47: 9,
	48: 11, // z x c v b
	49: 45,
	50: 46,
	51: 43,
	52: 47,
	53: 44, // n m , . /
	54: 60, // shift_r

	// Thumb row + modifiers.
	// Windows physical order (left→right): Ctrl | Fn | Win | Alt | Space | AltGr | (Menu) | Ctrl
	// KEY_POSITIONS reuse: kc63=x0 (fn slot) kc59=x1 kc58=x2 kc55=x3.25 | space | kc54=x9.25 kc61=x10.5
	// We map each SC to the kc whose x-position matches the physical Windows position.
	29: 63, // ctrl_l  → fn slot (x=0), leftmost key on Windows
	91: 58, // lwin    → x=2 slot, between Fn and Alt
	56: 55, // alt_l   → x=3.25 slot, right of Win
	57: 49, // space
	312: 54, // altgr (right-alt, SC 56 + 256 = 312) → x=9.25, first key right of space
	92: 61, // rwin / app menu → x=10.5
	93: 61, // app/menu key → same slot

	// Arrows (AHK extended scancodes 0xE048..0xE0CB usually surface as
	// raw codes; cover both the bare and high-byte forms).
	75: 123,
	203: 123, // left
	72: 126,
	200: 126, // up
	77: 124,
	205: 124, // right
	80: 125,
	208: 125 // down
};

// ==============================================
// ==============================================
// ======= 2/ Windows-style key labels =======
// ==============================================
// ==============================================

// Override macOS modifier glyphs with Windows names. Keys NOT listed fall
// back to KEYCODE_NAMES (which already covers letters / digits / punct).
const WIN_KEYCODE_LABELS = {
	49: 'Espace',
	36: 'Entrée',
	48: 'Tab',
	51: 'Retour arr.',
	53: 'Échap',
	56: 'Maj',
	60: 'Maj',
	57: 'Verr. Maj',
	// Windows thumb row (left→right): Ctrl | Fn | Win | Alt | Space | AltGr | (Menu)
	// kc63=x0 → Ctrl (leftmost), kc59=x1 → Fn, kc58=x2 → Win, kc55=x3.25 → Alt
	// kc54=x9.25 → AltGr (first key right of Space), kc61=x10.5 → Menu
	63: 'Ctrl',
	59: 'Fn',
	58: 'Win',
	55: 'Alt',
	54: 'AltGr',
	61: 'Menu',
	123: '←',
	126: '↑',
	124: '→',
	125: '↓'
};

// ==============================================
// ==============================================
// ======= 3/ Public translation API =======
// ==============================================
// ==============================================

/**
 * Translate a per-app today payload from Windows scancode-keyed n-grams
 * into the macOS keycode-keyed shape the renderer expects. Mutates a
 * shallow copy of the bucket and leaves the original untouched.
 *
 * @param {Object} app_bucket - One entry of `today_live_data` (per app).
 * @returns {Object} A new bucket with `kc` populated from `sc_kb`.
 */
function translate_win_bucket(app_bucket) {
	if (!app_bucket || !app_bucket.sc_kb) return app_bucket;
	const sc_kb = app_bucket.sc_kb;
	const kc_out = { ...(app_bucket.kc || {}) };
	Object.entries(sc_kb).forEach(([sc_str, item]) => {
		const sc_num = Number(sc_str);
		const kc_num = SC_TO_KC[sc_num];
		if (kc_num === undefined) return;
		const kc_key = String(kc_num);
		// Sum into any existing kc entry — defensive in case both fields
		// happen to be populated for the same physical key.
		const prev = kc_out[kc_key];
		if (!prev) {
			kc_out[kc_key] = { ...item };
		} else {
			kc_out[kc_key] = {
				c: (prev.c || 0) + (item.c || 0),
				t: (prev.t || 0) + (item.t || 0),
				e: (prev.e || 0) + (item.e || 0),
				hs: (prev.hs || 0) + (item.hs || 0),
				llm: (prev.llm || 0) + (item.llm || 0),
				o: (prev.o || 0) + (item.o || 0)
			};
		}
	});
	return { ...app_bucket, kc: kc_out };
}

/**
 * Walk the entire `today` payload and apply `translate_win_bucket` to
 * every app. Idempotent — calling it on already-translated data is a
 * no-op because the kc field is the merge target.
 *
 * @param {Object} today - `_prefetch_data.today` from the live blob.
 * @returns {Object} A new today object with kc fields populated.
 */
function translate_win_today(today) {
	if (!today || typeof today !== 'object') return today;
	const out = {};
	Object.entries(today).forEach(([app, bucket]) => {
		out[app] = translate_win_bucket(bucket);
	});
	return out;
}

/**
 * Build the keycode_layout map (kc_str → display label) appropriate for
 * the active driver.
 *
 *   macOS payloads return KEYCODE_NAMES untouched.
 *   Windows payloads merge three layers, in increasing priority:
 *     1. KEYCODE_NAMES                     — static QWERTY fallback
 *     2. AHK-provided sc → char (translated via SC_TO_KC) — reflects
 *        the user's active Windows layout (AZERTY, QWERTY-US, …).
 *     3. WIN_KEYCODE_LABELS                — explicit Win modifier names.
 *
 * @param {Object} driver_meta - Optional `{ os, heatmap_id }` from blob.
 * @param {Object} ahk_layout - Optional `{ sc_str: char }` from blob.
 * @returns {Object} Map of `kc_str` → display label string.
 */
function build_keycode_layout_for_driver(driver_meta, ahk_layout) {
	const base = typeof KEYCODE_NAMES === 'object' && KEYCODE_NAMES ? KEYCODE_NAMES : {};
	if (!driver_meta || driver_meta.os !== 'win') return { ...base };
	const out = { ...base };
	if (ahk_layout && typeof ahk_layout === 'object') {
		Object.entries(ahk_layout).forEach(([sc_str, ch]) => {
			const kc = SC_TO_KC[Number(sc_str)];
			if (kc === undefined) return;
			out[String(kc)] = ch;
		});
	}
	Object.entries(WIN_KEYCODE_LABELS).forEach(([k, v]) => {
		out[k] = v;
	});
	return out;
}

window.translate_win_today = translate_win_today;
window.build_keycode_layout_for_driver = build_keycode_layout_for_driver;
