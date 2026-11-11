// tools/lib/kbd-dll/constants.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL Constants
 * DESCRIPTION:
 * The numeric vocabulary of a Windows keyboard layout DLL, written from
 * Microsoft's public documentation of the kbd.h tables (WDK « Keyboard layout
 * samples », the Virtual-Key Codes reference and the Keyboard Input overview):
 * virtual-key codes, the shift-state bits, the per-key attributes, the locale
 * flags, the scan-code flag bits and the standard 101/102-key scan-code to
 * virtual-key tables every layout starts from.
 *
 * FEATURES & RATIONALE:
 * 1. One owner: the KLC reader, the model checks and the C emitter take every
 *    number from here; the independent DLL reader keeps its own copy on purpose
 *    so a wrong value here cannot agree with itself.
 * 2. The default scan-code tables are the standard PC/AT set 1 assignment a
 *    layout keeps unless its LAYOUT section moves a character key.
 * ==============================================================================
 */

'use strict';

// =================================
// ======= 1/ Virtual keys =========
// =================================

const VK = Object.freeze({
	CANCEL: 0x03,
	BACK: 0x08,
	TAB: 0x09,
	CLEAR: 0x0c,
	RETURN: 0x0d,
	SHIFT: 0x10,
	CONTROL: 0x11,
	MENU: 0x12,
	PAUSE: 0x13,
	CAPITAL: 0x14,
	KANA: 0x15,
	IME_ON: 0x16,
	JUNJA: 0x17,
	FINAL: 0x18,
	KANJI: 0x19,
	IME_OFF: 0x1a,
	ESCAPE: 0x1b,
	CONVERT: 0x1c,
	NONCONVERT: 0x1d,
	ACCEPT: 0x1e,
	MODECHANGE: 0x1f,
	SPACE: 0x20,
	PRIOR: 0x21,
	NEXT: 0x22,
	END: 0x23,
	HOME: 0x24,
	LEFT: 0x25,
	UP: 0x26,
	RIGHT: 0x27,
	DOWN: 0x28,
	SELECT: 0x29,
	PRINT: 0x2a,
	EXECUTE: 0x2b,
	SNAPSHOT: 0x2c,
	INSERT: 0x2d,
	DELETE: 0x2e,
	HELP: 0x2f,
	...Object.fromEntries([...'0123456789'].map((d, i) => [d, 0x30 + i])),
	...Object.fromEntries([...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'].map((c, i) => [c, 0x41 + i])),
	LWIN: 0x5b,
	RWIN: 0x5c,
	APPS: 0x5d,
	SLEEP: 0x5f,
	...Object.fromEntries(Array.from({ length: 10 }, (_, i) => [`NUMPAD${i}`, 0x60 + i])),
	MULTIPLY: 0x6a,
	ADD: 0x6b,
	SEPARATOR: 0x6c,
	SUBTRACT: 0x6d,
	DECIMAL: 0x6e,
	DIVIDE: 0x6f,
	...Object.fromEntries(Array.from({ length: 24 }, (_, i) => [`F${i + 1}`, 0x70 + i])),
	NUMLOCK: 0x90,
	SCROLL: 0x91,
	OEM_NEC_EQUAL: 0x92,
	OEM_FJ_MASSHOU: 0x93,
	OEM_FJ_TOUROKU: 0x94,
	OEM_FJ_LOYA: 0x95,
	OEM_FJ_ROYA: 0x96,
	LSHIFT: 0xa0,
	RSHIFT: 0xa1,
	LCONTROL: 0xa2,
	RCONTROL: 0xa3,
	LMENU: 0xa4,
	RMENU: 0xa5,
	BROWSER_BACK: 0xa6,
	BROWSER_FORWARD: 0xa7,
	BROWSER_REFRESH: 0xa8,
	BROWSER_STOP: 0xa9,
	BROWSER_SEARCH: 0xaa,
	BROWSER_FAVORITES: 0xab,
	BROWSER_HOME: 0xac,
	VOLUME_MUTE: 0xad,
	VOLUME_DOWN: 0xae,
	VOLUME_UP: 0xaf,
	MEDIA_NEXT_TRACK: 0xb0,
	MEDIA_PREV_TRACK: 0xb1,
	MEDIA_STOP: 0xb2,
	MEDIA_PLAY_PAUSE: 0xb3,
	LAUNCH_MAIL: 0xb4,
	LAUNCH_MEDIA_SELECT: 0xb5,
	LAUNCH_APP1: 0xb6,
	LAUNCH_APP2: 0xb7,
	OEM_1: 0xba,
	OEM_PLUS: 0xbb,
	OEM_COMMA: 0xbc,
	OEM_MINUS: 0xbd,
	OEM_PERIOD: 0xbe,
	OEM_2: 0xbf,
	OEM_3: 0xc0,
	ABNT_C1: 0xc1,
	ABNT_C2: 0xc2,
	OEM_4: 0xdb,
	OEM_5: 0xdc,
	OEM_6: 0xdd,
	OEM_7: 0xde,
	OEM_8: 0xdf,
	OEM_AX: 0xe1,
	OEM_102: 0xe2,
	ICO_HELP: 0xe3,
	ICO_00: 0xe4,
	PROCESSKEY: 0xe5,
	ICO_CLEAR: 0xe6,
	PACKET: 0xe7,
	OEM_RESET: 0xe9,
	OEM_JUMP: 0xea,
	OEM_PA1: 0xeb,
	OEM_PA2: 0xec,
	OEM_PA3: 0xed,
	OEM_WSCTRL: 0xee,
	OEM_CUSEL: 0xef,
	OEM_ATTN: 0xf0,
	OEM_FINISH: 0xf1,
	OEM_COPY: 0xf2,
	OEM_AUTO: 0xf3,
	OEM_ENLW: 0xf4,
	OEM_BACKTAB: 0xf5,
	ATTN: 0xf6,
	CRSEL: 0xf7,
	EXSEL: 0xf8,
	EREOF: 0xf9,
	PLAY: 0xfa,
	ZOOM: 0xfb,
	NONAME: 0xfc,
	PA1: 0xfd,
	OEM_CLEAR: 0xfe
});

// The marker rows of a VK_TO_WCHARS table: the dead-character row after a key
// with a dead cell, and the Caps Lock row after an SGCAPS key.
const VK_FOLLOW_ROW = 0xff;

// =====================================
// ======= 2/ Shift states, flags ======
// =====================================

// Modifier bits a column is selected by (KBDSHIFT ... KBDLOYA).
const MOD_BITS = Object.freeze({
	shift: 0x01,
	ctrl: 0x02,
	alt: 0x04,
	kana: 0x08,
	roya: 0x10,
	loya: 0x20
});
// The virtual key each modifier bit is read from (VK_TO_BIT).
const MOD_VK = Object.freeze({
	shift: VK.SHIFT,
	ctrl: VK.CONTROL,
	alt: VK.MENU,
	kana: VK.KANA,
	roya: VK.OEM_FJ_ROYA,
	loya: VK.OEM_FJ_LOYA
});
// A modifier combination with no column (SHFT_INVALID).
const SHFT_INVALID = 0x0f;
// Per-key attributes (VK_TO_WCHARS Attributes).
const ATTRIBUTES = Object.freeze({ caplok: 0x01, sgcaps: 0x02, caplokaltgr: 0x04, kanalok: 0x08 });
// Special cell values (WCH_NONE, WCH_DEAD, WCH_LGTR).
const WCH = Object.freeze({ NONE: 0xf000, DEAD: 0xf001, LGTR: 0xf002 });
// A dead-key transition that enters another dead key (DKF_DEAD).
const DKF_DEAD = 0x0001;
// fLocaleFlags low word; the high word is KBD_VERSION.
const LOCALE_FLAGS = Object.freeze({ altgr: 0x0001, shiftlock: 0x0002, lrm_rlm: 0x0004 });
const KBD_VERSION = 1;
// Scan-code to virtual-key flags (high byte of each pusVSCtoVK entry).
const SC_FLAGS = Object.freeze({ EXT: 0x0100, MULTIVK: 0x0200, SPECIAL: 0x0400, NUMPAD: 0x0800 });
// The keyboard type of a standard 101/102-key PC keyboard (dwType = 4).
const KEYBOARD_TYPE = 4;
// The string resource holding the layout's display name (Layout Display Name).
const DISPLAY_NAME_RESOURCE = 1000;

// =========================================
// ======= 3/ Standard scan-code tables ====
// =========================================

const { EXT, MULTIVK, SPECIAL, NUMPAD } = SC_FLAGS;
const NONE = 0xff;

/** The set 1 scan codes 0x00-0x7f of a 101/102-key keyboard and their virtual keys. */
const DEFAULT_SCANCODES = Object.freeze([
	NONE,
	VK.ESCAPE,
	VK['1'],
	VK['2'],
	VK['3'],
	VK['4'],
	VK['5'],
	VK['6'],
	VK['7'],
	VK['8'],
	VK['9'],
	VK['0'],
	VK.OEM_MINUS,
	VK.OEM_PLUS,
	VK.BACK,
	VK.TAB,
	VK.Q,
	VK.W,
	VK.E,
	VK.R,
	VK.T,
	VK.Y,
	VK.U,
	VK.I,
	VK.O,
	VK.P,
	VK.OEM_4,
	VK.OEM_6,
	VK.RETURN,
	VK.LCONTROL,
	VK.A,
	VK.S,
	VK.D,
	VK.F,
	VK.G,
	VK.H,
	VK.J,
	VK.K,
	VK.L,
	VK.OEM_1,
	VK.OEM_7,
	VK.OEM_3,
	VK.LSHIFT,
	VK.OEM_5,
	VK.Z,
	VK.X,
	VK.C,
	VK.V,
	VK.B,
	VK.N,
	VK.M,
	VK.OEM_COMMA,
	VK.OEM_PERIOD,
	VK.OEM_2,
	VK.RSHIFT | EXT,
	VK.MULTIPLY | MULTIVK,
	VK.LMENU,
	VK.SPACE,
	VK.CAPITAL,
	VK.F1,
	VK.F2,
	VK.F3,
	VK.F4,
	VK.F5,
	VK.F6,
	VK.F7,
	VK.F8,
	VK.F9,
	VK.F10,
	VK.NUMLOCK | EXT | MULTIVK,
	VK.SCROLL | MULTIVK,
	VK.HOME | SPECIAL | NUMPAD,
	VK.UP | SPECIAL | NUMPAD,
	VK.PRIOR | SPECIAL | NUMPAD,
	VK.SUBTRACT,
	VK.LEFT | SPECIAL | NUMPAD,
	VK.CLEAR | SPECIAL | NUMPAD,
	VK.RIGHT | SPECIAL | NUMPAD,
	VK.ADD,
	VK.END | SPECIAL | NUMPAD,
	VK.DOWN | SPECIAL | NUMPAD,
	VK.NEXT | SPECIAL | NUMPAD,
	VK.INSERT | SPECIAL | NUMPAD,
	VK.DELETE | SPECIAL | NUMPAD,
	VK.SNAPSHOT,
	NONE,
	VK.OEM_102,
	VK.F11,
	VK.F12,
	VK.CLEAR,
	VK.OEM_WSCTRL,
	VK.OEM_FINISH,
	VK.OEM_JUMP,
	VK.EREOF,
	VK.OEM_BACKTAB,
	VK.OEM_AUTO,
	NONE,
	NONE,
	VK.ZOOM,
	VK.HELP,
	VK.F13,
	VK.F14,
	VK.F15,
	VK.F16,
	VK.F17,
	VK.F18,
	VK.F19,
	VK.F20,
	VK.F21,
	VK.F22,
	VK.F23,
	VK.OEM_PA3,
	NONE,
	VK.OEM_RESET,
	NONE,
	VK.ABNT_C1,
	NONE,
	NONE,
	VK.F24,
	NONE,
	NONE,
	NONE,
	NONE,
	VK.OEM_PA1,
	VK.TAB,
	NONE,
	VK.ABNT_C2,
	VK.OEM_PA2
]);

/** The scan codes behind the E0 prefix and their virtual keys, all extended. */
const DEFAULT_E0 = Object.freeze([
	[0x10, VK.MEDIA_PREV_TRACK],
	[0x19, VK.MEDIA_NEXT_TRACK],
	[0x1d, VK.RCONTROL],
	[0x20, VK.VOLUME_MUTE],
	[0x21, VK.LAUNCH_APP2],
	[0x22, VK.MEDIA_PLAY_PAUSE],
	[0x24, VK.MEDIA_STOP],
	[0x2e, VK.VOLUME_DOWN],
	[0x30, VK.VOLUME_UP],
	[0x32, VK.BROWSER_HOME],
	[0x35, VK.DIVIDE],
	[0x37, VK.SNAPSHOT],
	[0x38, VK.RMENU],
	[0x47, VK.HOME],
	[0x48, VK.UP],
	[0x49, VK.PRIOR],
	[0x4b, VK.LEFT],
	[0x4d, VK.RIGHT],
	[0x4f, VK.END],
	[0x50, VK.DOWN],
	[0x51, VK.NEXT],
	[0x52, VK.INSERT],
	[0x53, VK.DELETE],
	[0x5b, VK.LWIN],
	[0x5c, VK.RWIN],
	[0x5d, VK.APPS],
	[0x5f, VK.SLEEP],
	[0x65, VK.BROWSER_SEARCH],
	[0x66, VK.BROWSER_FAVORITES],
	[0x67, VK.BROWSER_REFRESH],
	[0x68, VK.BROWSER_STOP],
	[0x69, VK.BROWSER_FORWARD],
	[0x6a, VK.BROWSER_BACK],
	[0x6b, VK.LAUNCH_APP1],
	[0x6c, VK.LAUNCH_MAIL],
	[0x6d, VK.LAUNCH_MEDIA_SELECT],
	[0x1c, VK.RETURN],
	[0x46, VK.CANCEL]
]);

/** The scan code behind the E1 prefix: Pause. */
const DEFAULT_E1 = Object.freeze([[0x1d, VK.PAUSE]]);

/**
 * The characters every layout's control and keypad keys type, as Windows'
 * own layouts declare them; a layout's LAYOUT section may replace any of them.
 * Each lists the character per modifier name: base, shift, ctrl.
 */
const SYSTEM_KEYS = Object.freeze([
	{ vk: 'TAB', cells: { base: 0x09, shift: 0x09 } },
	{ vk: 'ADD', cells: { base: 0x2b, shift: 0x2b } },
	{ vk: 'DIVIDE', cells: { base: 0x2f, shift: 0x2f } },
	{ vk: 'MULTIPLY', cells: { base: 0x2a, shift: 0x2a } },
	{ vk: 'SUBTRACT', cells: { base: 0x2d, shift: 0x2d } },
	{ vk: 'BACK', cells: { base: 0x08, shift: 0x08, ctrl: 0x7f } },
	{ vk: 'CANCEL', cells: { base: 0x03, shift: 0x03, ctrl: 0x03 } },
	{ vk: 'ESCAPE', cells: { base: 0x1b, shift: 0x1b, ctrl: 0x1b } },
	{ vk: 'RETURN', cells: { base: 0x0d, shift: 0x0d, ctrl: 0x0a } },
	{ vk: 'SPACE', cells: { base: 0x20, shift: 0x20, ctrl: 0x20 } }
]);

/** The keypad digits: one column, in their own last table (VkKeyScan looks there last). */
const NUMPAD_KEYS = Object.freeze(
	Array.from({ length: 10 }, (_, i) => ({ vk: `NUMPAD${i}`, char: 0x30 + i }))
);

module.exports = {
	VK,
	VK_FOLLOW_ROW,
	MOD_BITS,
	MOD_VK,
	SHFT_INVALID,
	ATTRIBUTES,
	WCH,
	DKF_DEAD,
	LOCALE_FLAGS,
	KBD_VERSION,
	SC_FLAGS,
	KEYBOARD_TYPE,
	DISPLAY_NAME_RESOURCE,
	DEFAULT_SCANCODES,
	DEFAULT_E0,
	DEFAULT_E1,
	SYSTEM_KEYS,
	NUMPAD_KEYS
};
