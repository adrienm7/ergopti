// _shared/ui/layout_analysis/layout_formats.js

/**
 * ==============================================================================
 * MODULE: Layout File Formats
 * DESCRIPTION:
 * Reads the layout files people already have into the one layout shape the
 * analysis engine and the Studio use (what each physical key types on the
 * base, Shift, AltGr and Shift+AltGr layers, and the dead keys), writes that
 * shape back as an Ergopti layout source, a Keyboard Layout Analyzer JSON, a
 * Kalamine TOML, an Oxeylyzer DOF, a genkey layout or a cmini JSON. Every
 * reader and writer returns what it could not map instead of guessing it. The
 * formats are described in docs/design/layout-analysis.md.
 *
 * FEATURES & RATIONALE:
 * 1. Formats read: Keyboard Layout Analyzer JSON (KLA, KLAnext and their
 *    forks, on the standard, european, ErgoDox and KLAnext matrix, janiso and
 *    ergolinear boards, the thumb keys of the ErgoDox and matrix included),
 *    Kalamine TOML and JSON (Ergo-L and its family), XKB symbols, Windows
 *    KLC, Oxeylyzer DOF (libdof's boards, anchors and layers), genkey
 *    layouts, cmini JSON and plain rows of characters. A macOS .keylayout
 *    goes through the layout composer's reader, which the editor already
 *    loads. A KbdEdit .kbe is recognised and refused: its body is encrypted
 *    (KBE_SIGNATURE). A cyanophage playground link or string, and
 *    Oxeylyzer's legacy .kb rows, are read too.
 * 1b. Pasted or dropped text: detect names the format from the content
 *    alone, readText reads it with that format's reader. Every refusal is
 *    strict and says where: a JSON or TOML error by line and column, a
 *    character on two keys by both places, a cyanophage string of the wrong
 *    length by its count.
 * 2. Dead keys of the standard accents compose by Unicode normalisation (the
 *    accent's combining mark after the letter, NFC), the same table XKB's
 *    Compose and Kalamine's built-in dead keys hold for those accents; any
 *    other dead key keeps only the compositions its file states.
 * 3. Every refusal and loss has a stable code that refusalMessage and
 *    lossMessage turn into a locale key, so the Studio and the Comparer word
 *    them the same way in every language.
 * 4. Pure: no DOM, no fetch; a Kalamine TOML is passed already parsed, so the
 *    page's TOML codec (vendor/smol-toml.js) and Node's are the same one.
 * 5. Share links: the Comparer's « Copy the link » carries the visitor's own
 *    layouts in the URL fragment (toLink), which never reaches a server:
 *    versioned (l=<version>.<data>), compact (the layouts' keys as JSON,
 *    deflated, base64url) and read back strictly (fromLink): a fragment that
 *    is cut, from a newer version, too large or holding a layout the engine
 *    refuses is refused with its own code, never half read.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
// eslint-disable-next-line no-unused-vars
var LAYOUT_FORMATS = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const LAYERS = 4;
	const NONE = null;
	const MAX_CODE_POINT = 0x10ffff;
	// A UTF-16 code unit as a KLC writes it.
	const HEX4 = /^[0-9a-fA-F]{4}$/;
	// KbdEdit's .kbe header, read from the samples it exports
	// (static/layouts/registry/bepo/kbdedit, static/ergopti/windows): a UInt16
	// length and the ASCII signature, a UInt32 format version, a UInt32 field
	// (0x40, 0x7c or 0x7f), then a UInt16 length of the rest of the file. The
	// rest has the byte statistics of random data, and two layouts that differ by
	// a few keys share no 8-byte run: it is encrypted, and only KbdEdit holds the
	// key, so a .kbe is recognised and refused with that reason.
	const KBE_SIGNATURE = 'KbdEdit export file';
	const KBE_HEADER_SIZE = 2 + KBE_SIGNATURE.length + 4 + 4 + 2;
	// The file types the Studio opens, for the pages' file pickers; the app's
	// native panel reads the same list from the layout defaults
	// (source.pick_extensions, held equal by tools/test/test-layout-formats.cjs).
	const EXTENSIONS = [
		'toml',
		'keylayout',
		'json',
		'klc',
		'kbe',
		'xkb',
		'xkb_symbols',
		'yaml',
		'dof',
		'txt',
		// Oxeylyzer's legacy layout files: three rows of keys, as plain text.
		'kb'
	];
	// The refusals and losses a page words in the user's language
	// (layout_analysis.formats.refused.* and .loss.* in every locale).
	const REFUSALS = [
		'format_unknown',
		'format_invalid',
		'format_unsupported_board',
		'format_kbe_encrypted',
		// The strict reading of a file or a pasted text: where it is wrong, and how to fix it.
		'format_syntax',
		'format_duplicate',
		'format_length',
		'format_unrecognised',
		'link_version',
		'link_damaged',
		'link_too_large',
		'link_invalid',
		'link_unsupported'
	];
	// The formats a reader names in its result, each worded in every locale
	// (layout_analysis.formats.name.<format>): what the Studio says it detected.
	const FORMAT_NAMES = [
		'kla',
		'kalamine_json',
		'kalamine_toml',
		'xkb',
		'klc',
		'keylayout',
		'dof',
		'genkey',
		'cmini',
		'rows',
		'cyanophage',
		// Recognised to be named, not read here: a KbdEdit export is refused
		// (encrypted), an Ergopti source is the editor's own (LayoutSourceIO).
		'kbe',
		'ergopti'
	];
	// A cyanophage playground layout (its keyboard_svg.js, importLayout and
	// exportLayout): its « layout » parameter holds 34 characters, three rows of
	// 11 then the thumb key. Index 10 is the top row's 11th key, 21 the home
	// row's, 32 the bottom row's key left of Z (row 2, column 0 of its rcdata),
	// 33 the left thumb (the model's left thumb rest key), 34 (a 35-character
	// string) a key of its own boards with no place here. « ^ » marks the Shift key, which types no character,
	// and « $ » stands for « = ». A 30-character string is the three rows of
	// 10, as its import box takes it.
	const CYANOPHAGE_LENGTHS = [30, 33, 34, 35];
	const CYANOPHAGE_THUMB = 33;
	const CYANOPHAGE_SHIFT = '^';
	const CYANOPHAGE_ALIASES = { $: '=' };
	// Its link: any URL or query with a layout= parameter.
	const CYANOPHAGE_LINK = /(?:^|[?&#])layout=([^&#\s]*)/;
	// A share link's fragment part (#l=1.<data>): its version, and the caps it is
	// read under (its text, its unpacked JSON, its layouts, a name and a cell).
	const LINK_PARAM = 'l';
	const LINK_VERSION = 1;
	const LINK_PART = /^l=(\d+)\.([A-Za-z0-9_-]+)$/;
	const LINK_MAX_TEXT = 262144;
	const LINK_MAX_JSON = 1048576;
	const LINK_MAX_LAYOUTS = 16;
	const LINK_MAX_NAME = 80;
	const LINK_MAX_CELL = 64;
	// A link longer than this may be cut by a chat or mail client: the Comparer says so.
	const LINK_LONG = 8192;
	const LOSSES = [
		'key',
		'keysym',
		'include',
		'ligature',
		'dead_key_rules',
		'dead_key',
		'multi_character',
		'layer',
		'rule',
		'special',
		'character'
	];
	// XKB and Kalamine key names of the keys a layout defines.
	const XKB_KEYS = (() => {
		const out = { TLDE: 'Backquote', BKSL: 'Backslash', LSGT: 'IntlBackslash', SPCE: 'Space' };
		// The JIS and ABNT keys (xkeyboard-config keycodes/evdev): Yen, Ro or ABNT C1,
		// and the keypad comma (KPPT, its Brazilian keypad point alias, and I129).
		Object.assign(out, {
			AE13: 'IntlYen',
			AB11: 'IntlRo',
			KPPT: 'NumpadComma',
			I129: 'NumpadComma'
		});
		const rows = [
			[
				'AE',
				[
					'Digit1',
					'Digit2',
					'Digit3',
					'Digit4',
					'Digit5',
					'Digit6',
					'Digit7',
					'Digit8',
					'Digit9',
					'Digit0',
					'Minus',
					'Equal'
				]
			],
			[
				'AD',
				[
					'KeyQ',
					'KeyW',
					'KeyE',
					'KeyR',
					'KeyT',
					'KeyY',
					'KeyU',
					'KeyI',
					'KeyO',
					'KeyP',
					'BracketLeft',
					'BracketRight'
				]
			],
			[
				'AC',
				[
					'KeyA',
					'KeyS',
					'KeyD',
					'KeyF',
					'KeyG',
					'KeyH',
					'KeyJ',
					'KeyK',
					'KeyL',
					'Semicolon',
					'Quote',
					'Backslash'
				]
			],
			['AB', ['KeyZ', 'KeyX', 'KeyC', 'KeyV', 'KeyB', 'KeyN', 'KeyM', 'Comma', 'Period', 'Slash']]
		];
		for (const [prefix, codes] of rows)
			codes.forEach((code, i) => {
				out[`${prefix}${String(i + 1).padStart(2, '0')}`] = code;
			});
		return out;
	})();
	// The keys of a one-line layout (three rows of 10), read as its three rows.
	const ROWS_LINE = 30;
	// Rows of a 3-row character block (DOF, cmini, plain text), by column.
	const ROW_CODES = [
		[
			'KeyQ',
			'KeyW',
			'KeyE',
			'KeyR',
			'KeyT',
			'KeyY',
			'KeyU',
			'KeyI',
			'KeyO',
			'KeyP',
			'BracketLeft',
			'BracketRight'
		],
		[
			'KeyA',
			'KeyS',
			'KeyD',
			'KeyF',
			'KeyG',
			'KeyH',
			'KeyJ',
			'KeyK',
			'KeyL',
			'Semicolon',
			'Quote',
			'Backslash'
		],
		['KeyZ', 'KeyX', 'KeyC', 'KeyV', 'KeyB', 'KeyN', 'KeyM', 'Comma', 'Period', 'Slash']
	];
	// The boards of libdof (src/keyboard.rs, PhysicalKeyboard from FormFactor):
	// each row's keys from the left, null for a key without a character (Tab,
	// Caps, Shift, Enter, Backspace, the modifiers, ortho thumbs), the default
	// anchor (dofinitions.rs, FormFactor::anchor) and, for the staggered ones,
	// how many keys each row holds (a custom relative board of that shape is
	// that board). On ISO, a 3x10 block's bottom row starts on the ISO key.
	const DOF_BOARDS = (() => {
		const number = [
			'Backquote',
			'Digit1',
			'Digit2',
			'Digit3',
			'Digit4',
			'Digit5',
			'Digit6',
			'Digit7',
			'Digit8',
			'Digit9',
			'Digit0',
			'Minus',
			'Equal',
			null
		];
		const thumbs = [null, null, null, 'Space', null, null, null, null];
		const letters = ROW_CODES.map((row) => row.slice(0, 10));
		const ortho = { rows: [...letters, [null, null, null, null, null, null]], anchor: [0, 0] };
		return {
			ansi: {
				rows: [
					number,
					[null, ...ROW_CODES[0], 'Backslash'],
					[null, ...ROW_CODES[1].slice(0, 11), null],
					[null, ...ROW_CODES[2], null],
					thumbs
				],
				anchor: [1, 1],
				shape: [14, 14, 13, 12, 8]
			},
			iso: {
				rows: [
					number,
					[null, ...ROW_CODES[0], null],
					[null, ...ROW_CODES[1]],
					[null, 'IntlBackslash', ...ROW_CODES[2], null],
					thumbs
				],
				anchor: [1, 1],
				shape: [14, 14, 13, 13, 8]
			},
			ortho,
			colstag: ortho
		};
	})();
	// The DOF layers the four levels hold; `shift_altgr` is the name the
	// writer gives the fourth (libdof reserves only main and shift).
	const DOF_LEVELS = { main: 0, shift: 1, altgr: 2, shift_altgr: 3 };
	// libdof's special keys (dofinitions.rs, Key::from), by every name it accepts.
	const DOF_SPECIALS = (() => {
		const out = {};
		const names = {
			esc: 'esc',
			repeat: 'repeat rpt',
			space: 'space spc',
			tab: 'tab tb',
			enter: 'enter return ret ent rt',
			shift: 'shift shft sft st',
			caps: 'caps cps cp',
			ctrl: 'ctrl ctl ct',
			alt: 'alt lalt ralt lt',
			meta: 'meta mta met mt super sup sp',
			menu: 'menu mnu mn',
			fn: 'fn',
			backspace: 'backspace bksp bcsp bsp',
			del: 'del'
		};
		for (const [kind, list] of Object.entries(names))
			for (const name of list.split(' ')) out[name] = kind;
		return out;
	})();
	// The Shift character libdof gives a main-layer character when the file has
	// no Shift layer (dofinitions.rs, Key::shifted); any other character takes
	// its upper case. Its table has no entry for 8, which stays 8.
	const DOF_SHIFTED = {
		'`': '~',
		1: '!',
		2: '@',
		3: '#',
		4: '$',
		5: '%',
		6: '^',
		7: '*',
		9: '(',
		0: ')',
		'[': '{',
		']': '}',
		'<': '>',
		"'": '"',
		',': '<',
		'.': '>',
		';': ':',
		'/': '?',
		'=': '+',
		'-': '_',
		'\\': '|'
	};
	// genkey's finger numbers (0 left pinky … 7 right pinky) for its three rows:
	// the standard ones, and the bottom row the angle fingering types.
	const GENKEY_FINGERS = ['0', '1', '2', '3', '3', '4', '4', '5', '6', '7', '7', '7'];
	const GENKEY_ANGLE_BOTTOM = ['1', '2', '3', '3', '3', '4', '4', '5', '6', '7'];
	// cmini's finger names, by column of the three letter rows.
	const CMINI_FINGERS = ['LP', 'LR', 'LM', 'LI', 'LI', 'RI', 'RI', 'RM', 'RR', 'RP', 'RP', 'RP'];
	const CMINI_ANGLE_BOTTOM = ['LR', 'LM', 'LI', 'LI', 'LI', 'RI', 'RI', 'RM', 'RR', 'RP'];
	// Keyboard Layout Analyzer key index → physical key, per keyboardType, from
	// the QWERTY key sets of its source (common/pat/keyboard/js/kb.js).
	const KLA_KEYS = (() => {
		const top = [
			'Backquote',
			'Digit1',
			'Digit2',
			'Digit3',
			'Digit4',
			'Digit5',
			'Digit6',
			'Digit7',
			'Digit8',
			'Digit9',
			'Digit0',
			'Minus',
			'Equal'
		];
		const tab = [
			'KeyQ',
			'KeyW',
			'KeyE',
			'KeyR',
			'KeyT',
			'KeyY',
			'KeyU',
			'KeyI',
			'KeyO',
			'KeyP',
			'BracketLeft',
			'BracketRight'
		];
		const home = [
			'KeyA',
			'KeyS',
			'KeyD',
			'KeyF',
			'KeyG',
			'KeyH',
			'KeyJ',
			'KeyK',
			'KeyL',
			'Semicolon',
			'Quote'
		];
		const bottom = [
			'KeyZ',
			'KeyX',
			'KeyC',
			'KeyV',
			'KeyB',
			'KeyN',
			'KeyM',
			'Comma',
			'Period',
			'Slash'
		];
		const at = (start, codes, map) => codes.forEach((code, i) => (map[start + i] = code));
		const standard = {};
		at(0, top, standard);
		at(15, tab, standard);
		standard[27] = 'Backslash';
		at(29, home, standard);
		at(42, bottom, standard);
		standard[56] = 'Space';
		const european = {};
		at(0, top, european);
		at(15, tab, european);
		at(29, home, european);
		european[40] = 'Backslash';
		european[42] = 'IntlBackslash';
		at(43, bottom, european);
		european[57] = 'Space';
		const ergodox = {};
		at(1, top.slice(1, 6), ergodox);
		ergodox[6] = 'Minus';
		ergodox[7] = 'Equal';
		at(8, top.slice(6, 11), ergodox);
		at(15, tab.slice(0, 5), ergodox);
		at(22, tab.slice(5, 10), ergodox);
		ergodox[27] = 'Backslash';
		at(29, home.slice(0, 10), ergodox);
		at(41, bottom.slice(0, 5), ergodox);
		at(48, bottom.slice(5, 10), ergodox);
		ergodox[58] = 'Backquote';
		ergodox[60] = 'BracketLeft';
		ergodox[61] = 'BracketRight';
		ergodox[62] = 'Quote';
		ergodox[66] = 'Space';
		ergodox[74] = 'Space';
		// KLAnext's split matrix (its kb.js, KB.keyMap.matrix: rows of 12, 12,
		// 12, 14 and 16 keys, each row's left half then its right half, then a
		// 29-key centre block at 66-94), read from KLAnext's own QWERTY on it
		// (layouts/qwerty.en.matrix.json): each index takes the key its QWERTY
		// character has on an ANSI board. Its Tab, Shift, Ctrl, Alt, AltGr,
		// Enter, Backspace, page and arrow keys and the centre block have no
		// character key here, so a character placed there is reported.
		const matrix = {};
		at(0, top.slice(0, 6), matrix);
		at(6, top.slice(6, 11), matrix);
		matrix[11] = 'Backslash';
		at(13, tab.slice(0, 5), matrix);
		at(18, tab.slice(5, 10), matrix);
		matrix[23] = 'Equal';
		at(25, home.slice(0, 5), matrix);
		at(30, home.slice(5, 11), matrix);
		at(37, bottom.slice(0, 5), matrix);
		at(44, bottom.slice(5, 10), matrix);
		matrix[52] = 'BracketLeft';
		matrix[53] = 'Minus';
		matrix[54] = 'BracketRight';
		matrix[56] = 'Space';
		// KLAnext's janiso board (its kb.js, KB.keyMap.janiso: four unstaggered
		// split rows of 14 keys, then 11 bottom keys; no JIS key, despite the
		// name), read like the matrix from KLAnext's own QWERTY on it
		// (layouts/qwerty.za.janiso.json): its two outer columns hold the
		// punctuation the standard board has right of P, L and the slash, and
		// each index takes the key its QWERTY character has on an ANSI board.
		// The outermost columns and the other bottom keys have no character key.
		const janiso = {};
		at(2, top.slice(1, 11), janiso);
		janiso[12] = 'Equal';
		janiso[15] = 'BracketLeft';
		at(16, tab.slice(0, 10), janiso);
		janiso[26] = 'BracketRight';
		janiso[29] = 'Backslash';
		at(30, home.slice(0, 10), janiso);
		janiso[40] = 'Minus';
		janiso[43] = 'Backquote';
		at(44, bottom, janiso);
		janiso[54] = 'Quote';
		janiso[61] = 'Space';
		// KLAnext's ergolinear board (KB.keyMap.ergolinear: no number row, three
		// split rows of 12 keys, then 16 bottom keys). KLAnext has no layout on
		// it to read a QWERTY from, so its keys are placed by position, as the
		// Corne's: the three letter rows' ten middle keys, the key right of the
		// home row's tenth (Quote) and the right thumb's first key (the space
		// bar of Hands Down's ortho files, the only ones on this board).
		const ergolinear = {};
		at(1, tab.slice(0, 10), ergolinear);
		at(13, home, ergolinear);
		at(25, bottom, ergolinear);
		ergolinear[44] = 'Space';
		return { standard, european, ergodox, matrix, janiso, ergolinear };
	})();
	// The KLA finger number of each engine finger (1 left pinky … 10 right pinky).
	const KLA_FINGERS = { lp: 1, lr: 2, lm: 3, li: 4, lt: 5, rt: 6, ri: 7, rm: 8, rr: 9, rp: 10 };
	// The thumb keys of the analysis model (analysis_model.json thumb_keys), by
	// thumb, in the order a thumb-letter file's keys take them: the first of
	// each thumb is the one it rests on (thumb_rest_keys).
	const KLA_THUMB_CODES = { left: ['NonConvert'], right: ['Convert', 'KanaMode'] };
	const KLA_THUMB_HANDS = { 5: 'left', 6: 'right' };
	// What a thumb key types to be read as one: a letter, a digit, a punctuation
	// mark or the space, not an action sign (⌦, ⇞, ⌘) that types nothing.
	const KLA_THUMB_TYPED = /^[\p{L}\p{M}\p{N}\p{P} ]+$/u;
	const typedCell = (cell) => cell !== NONE && KLA_THUMB_TYPED.test(cell);
	// The boards with thumb clusters, and their big thumb keys (ErgoDox's
	// 2-unit keys, KLA's index; KLAnext's matrix and ergolinear draw none
	// bigger). Hands Down's Alt-ex, -nx and -tx ortho files put their thumb
	// letter on ergolinear's key 41, the left thumb's.
	const KLA_THUMB_BOARDS = {
		ergodox: { big: [66, 67, 74, 75] },
		matrix: { big: [] },
		ergolinear: { big: [] }
	};
	// KLA's ErgoDox board for the writer: its size, the keys without a
	// character (their primary and finger, from KLAnext's layouts/qwerty.en.ergodox.json),
	// the thumb key each thumb code is written on (the ErgoDox inner 2-unit
	// keys, where Hands Down's files put their thumb letter and space; KanaMode
	// on the right cluster's lower small key) and the start key of each finger.
	const KLA_ERGODOX = {
		size: 76,
		specials: {
			14: [-95, 1],
			28: [8, 1],
			39: [13, 10],
			40: [16, 1],
			53: [-16, 10],
			54: [-18, 1],
			64: [20, 5],
			67: [8, 5],
			70: [18, 6],
			71: [27, 6],
			74: [9, 6],
			75: [13, 6]
		},
		thumbs: { NonConvert: 67, Convert: 74, KanaMode: 73 },
		space: 66,
		fingerStart: { 1: 29, 2: 30, 3: 31, 4: 32, 5: 66, 6: 74, 7: 35, 8: 36, 9: 37, 10: 38 }
	};
	// The non-character keys of KLA's european board, by index: their primary.
	const KLA_EUROPEAN_SPECIALS = {
		13: 8,
		14: 9,
		27: 13,
		28: 20,
		41: 16,
		53: -16,
		54: 17,
		55: -91,
		56: 18,
		58: -18,
		59: -91,
		60: -93,
		61: 17
	};
	const KLA_EUROPEAN_SIZE = 62;
	// The standard accents: dead-key name → combining mark, shared by the XKB
	// keysyms (dead_<name>) and Kalamine's dead keys.
	const ACCENTS = {
		grave: '̀',
		acute: '́',
		circumflex: '̂',
		tilde: '̃',
		macron: '̄',
		breve: '̆',
		abovedot: '̇',
		diaeresis: '̈',
		abovering: '̊',
		doubleacute: '̋',
		caron: '̌',
		doublegrave: '̏',
		invertedbreve: '̑',
		belowdot: '̣',
		belowcomma: '̦',
		cedilla: '̧',
		ogonek: '̨'
	};
	// The character each accent types alone (after a space).
	const ACCENT_ALONE = {
		grave: '`',
		acute: '´',
		circumflex: '^',
		tilde: '~',
		macron: '¯',
		breve: '˘',
		abovedot: '˙',
		diaeresis: '¨',
		abovering: '˚',
		doubleacute: '˝',
		caron: 'ˇ',
		cedilla: '¸',
		ogonek: '˛'
	};
	// Kalamine's dead-key characters (its data/dead_keys.yaml ids) → names.
	const KALAMINE_DEAD = {
		'**': 'odk',
		'*`': 'grave',
		'*‟': 'doublegrave',
		'*´': 'acute',
		'*”': 'doubleacute',
		'*^': 'circumflex',
		'*ˇ': 'caron',
		'*˘': 'breve',
		'*⁻': 'invertedbreve',
		'*~': 'tilde',
		'*¯': 'macron',
		'*¨': 'diaeresis',
		'*˚': 'abovering',
		'*¸': 'cedilla',
		'*,': 'belowcomma',
		'*˛': 'ogonek',
		'*/': 'stroke',
		'*˙': 'abovedot',
		'*.': 'belowdot',
		'*µ': 'greek',
		'*¤': 'currency'
	};
	// Kalamine's ASCII-art geometry: key names per template row, first key column.
	const KALAMINE_ROWS = {
		ISO: [
			[
				2,
				[
					'TLDE',
					'AE01',
					'AE02',
					'AE03',
					'AE04',
					'AE05',
					'AE06',
					'AE07',
					'AE08',
					'AE09',
					'AE10',
					'AE11',
					'AE12'
				]
			],
			[
				11,
				[
					'AD01',
					'AD02',
					'AD03',
					'AD04',
					'AD05',
					'AD06',
					'AD07',
					'AD08',
					'AD09',
					'AD10',
					'AD11',
					'AD12'
				]
			],
			[
				12,
				[
					'AC01',
					'AC02',
					'AC03',
					'AC04',
					'AC05',
					'AC06',
					'AC07',
					'AC08',
					'AC09',
					'AC10',
					'AC11',
					'BKSL'
				]
			],
			[9, ['LSGT', 'AB01', 'AB02', 'AB03', 'AB04', 'AB05', 'AB06', 'AB07', 'AB08', 'AB09', 'AB10']]
		],
		ANSI: [
			[
				2,
				[
					'TLDE',
					'AE01',
					'AE02',
					'AE03',
					'AE04',
					'AE05',
					'AE06',
					'AE07',
					'AE08',
					'AE09',
					'AE10',
					'AE11',
					'AE12'
				]
			],
			[
				11,
				[
					'AD01',
					'AD02',
					'AD03',
					'AD04',
					'AD05',
					'AD06',
					'AD07',
					'AD08',
					'AD09',
					'AD10',
					'AD11',
					'AD12',
					'BKSL'
				]
			],
			[
				12,
				['AC01', 'AC02', 'AC03', 'AC04', 'AC05', 'AC06', 'AC07', 'AC08', 'AC09', 'AC10', 'AC11']
			],
			[15, ['AB01', 'AB02', 'AB03', 'AB04', 'AB05', 'AB06', 'AB07', 'AB08', 'AB09', 'AB10']]
		],
		ERGO: [
			[
				2,
				[
					'TLDE',
					'AE01',
					'AE02',
					'AE03',
					'AE04',
					'AE05',
					'AE06',
					'AE07',
					'AE08',
					'AE09',
					'AE10',
					'AE11',
					'AE12'
				]
			],
			[
				8,
				[
					'AD01',
					'AD02',
					'AD03',
					'AD04',
					'AD05',
					'AD06',
					'AD07',
					'AD08',
					'AD09',
					'AD10',
					'AD11',
					'AD12'
				]
			],
			[
				8,
				[
					'AC01',
					'AC02',
					'AC03',
					'AC04',
					'AC05',
					'AC06',
					'AC07',
					'AC08',
					'AC09',
					'AC10',
					'AC11',
					'BKSL'
				]
			],
			[2, ['LSGT', 'AB01', 'AB02', 'AB03', 'AB04', 'AB05', 'AB06', 'AB07', 'AB08', 'AB09', 'AB10']]
		]
	};
	// Kalamine's ISO drawing, the frame its `full` block is written in.
	const KALAMINE_ISO_TEMPLATE = [
		'┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┲━━━━━━━━━━┓',
		'│     │     │     │     │     │     │     │     │     │     │     │     │     ┃          ┃',
		'│     │     │     │     │     │     │     │     │     │     │     │     │     ┃ ⌫        ┃',
		'┢━━━━━┷━━┱──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┺━━┳━━━━━━━┫',
		'┃        ┃     │     │     │     │     │     │     │     │     │     │     │     ┃       ┃',
		'┃ ↹      ┃     │     │     │     │     │     │     │     │     │     │     │     ┃       ┃',
		'┣━━━━━━━━┻┱────┴┬────┴┬────┴┬────┴┬────┴┬────┴┬────┴┬────┴┬────┴┬────┴┬────┴┬────┺┓  ⏎   ┃',
		'┃         ┃     │     │     │     │     │     │     │     │     │     │     │     ┃      ┃',
		'┃ ⇬       ┃     │     │     │     │     │     │     │     │     │     │     │     ┃      ┃',
		'┣━━━━━━┳━━┹──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┲━━┷━━━━━┻━━━━━━┫',
		'┃      ┃     │     │     │     │     │     │     │     │     │     │     ┃               ┃',
		'┃ ⇧    ┃     │     │     │     │     │     │     │     │     │     │     ┃ ⇧             ┃',
		'┣━━━━━━┻┳━━━━┷━━┳━━┷━━━━┱┴─────┴─────┴─────┴─────┴─────┴─┲━━━┷━━━┳━┷━━━━━╋━━━━━━━┳━━━━━━━┫',
		'┃       ┃       ┃       ┃                                ┃       ┃       ┃       ┃       ┃',
		'┃ Ctrl  ┃ super ┃ Alt   ┃ ␣                              ┃ AltGr ┃ super ┃ menu  ┃ Ctrl  ┃',
		'┗━━━━━━━┻━━━━━━━┻━━━━━━━┹────────────────────────────────┺━━━━━━━┻━━━━━━━┻━━━━━━━┻━━━━━━━┛'
	];
	const KALAMINE_KEY_STEP = 6;
	const KALAMINE_LINES_PER_ROW = 3;
	// The XKB keysyms of the Latin-1 range, in code-point order from U+00A0;
	// a Latin-1 keysym's value is its code point.
	const LATIN1 = (
		'nobreakspace exclamdown cent sterling currency yen brokenbar section diaeresis copyright ' +
		'ordfeminine guillemotleft notsign hyphen registered macron degree plusminus twosuperior ' +
		'threesuperior acute mu paragraph periodcentered cedilla onesuperior masculine guillemotright ' +
		'onequarter onehalf threequarters questiondown Agrave Aacute Acircumflex Atilde Adiaeresis ' +
		'Aring AE Ccedilla Egrave Eacute Ecircumflex Ediaeresis Igrave Iacute Icircumflex Idiaeresis ' +
		'ETH Ntilde Ograve Oacute Ocircumflex Otilde Odiaeresis multiply Oslash Ugrave Uacute ' +
		'Ucircumflex Udiaeresis Yacute THORN ssharp agrave aacute acircumflex atilde adiaeresis aring ' +
		'ae ccedilla egrave eacute ecircumflex ediaeresis igrave iacute icircumflex idiaeresis eth ' +
		'ntilde ograve oacute ocircumflex otilde odiaeresis division oslash ugrave uacute ucircumflex ' +
		'udiaeresis yacute thorn ydiaeresis'
	).split(' ');
	const ASCII_NAMES = (
		'space exclam quotedbl numbersign dollar percent ampersand apostrophe parenleft parenright ' +
		'asterisk plus comma minus period slash'
	).split(' ');
	const ASCII_NAMES_2 = 'colon semicolon less equal greater question at'.split(' ');
	const ASCII_NAMES_3 = 'bracketleft backslash bracketright asciicircum underscore grave'.split(
		' '
	);
	const ASCII_NAMES_4 = 'braceleft bar braceright asciitilde'.split(' ');
	const KEYSYMS = (() => {
		const out = {};
		ASCII_NAMES.forEach((name, i) => (out[name] = String.fromCharCode(0x20 + i)));
		ASCII_NAMES_2.forEach((name, i) => (out[name] = String.fromCharCode(0x3a + i)));
		ASCII_NAMES_3.forEach((name, i) => (out[name] = String.fromCharCode(0x5b + i)));
		ASCII_NAMES_4.forEach((name, i) => (out[name] = String.fromCharCode(0x7b + i)));
		LATIN1.forEach((name, i) => (out[name] = String.fromCharCode(0xa0 + i)));
		Object.assign(out, {
			Ooblique: 'Ø',
			ooblique: 'ø',
			oe: 'œ',
			OE: 'Œ',
			EuroSign: '€',
			ellipsis: '…',
			emdash: '—',
			endash: '–',
			leftsinglequotemark: '‘',
			rightsinglequotemark: '’',
			leftdoublequotemark: '“',
			rightdoublequotemark: '”',
			singlelowquotemark: '‚',
			doublelowquotemark: '„',
			dagger: '†',
			doubledagger: '‡',
			trademark: '™',
			permille: '‰',
			enfilledcircbullet: '•',
			leftarrow: '←',
			uparrow: '↑',
			rightarrow: '→',
			downarrow: '↓',
			notequal: '≠',
			lessthanequal: '≤',
			greaterthanequal: '≥',
			infinity: '∞',
			Greek_alpha: 'α',
			Greek_beta: 'β',
			Greek_pi: 'π',
			Greek_mu: 'μ'
		});
		return out;
	})();

	// ==========================
	// ======= 2/ Helpers =======
	// ==========================

	/**
	 * A rejection with a stable code the caller can show.
	 * @param {string} code - One of REFUSALS (or an internal code).
	 * @param {string} detail - What was wrong, for the message and the logs.
	 * @param {object} [values] - More placeholders of the refusal's words (a
	 *   line and a column, a key, a count).
	 */
	function fail(code, detail, values) {
		const error = new Error(`${code}: ${detail}`);
		error.code = code;
		error.detail = detail;
		if (values) error.values = values;
		throw error;
	}

	/** The line and column (from 1) of an offset of a text. */
	function lineColumn(text, offset) {
		const before = text.slice(0, Math.max(0, Math.min(offset, text.length))).split('\n');
		return { line: before.length, column: before[before.length - 1].length + 1 };
	}

	/**
	 * Parses a JSON text, or refuses it with the line and column of its first
	 * error (V8 and SpiderMonkey name an offset or a line and a column).
	 */
	function parseJson(text) {
		try {
			return JSON.parse(text);
		} catch (error) {
			const message = String(error && error.message);
			const lineCol = /line (\d+) column (\d+)/.exec(message);
			const offset = /position (\d+)/.exec(message);
			const where = lineCol
				? { line: Number(lineCol[1]), column: Number(lineCol[2]) }
				: lineColumn(text, offset ? Number(offset[1]) : jsonErrorOffset(text));
			return fail('format_syntax', `json ${message}`, Object.assign({ format: 'JSON' }, where));
		}
	}

	/**
	 * Where a JSON text breaks when the engine's message names no place
	 * (V8's « Unexpected token »): every prefix before the error only ends too
	 * soon, so the shortest prefix that fails otherwise ends on the error.
	 */
	function jsonErrorOffset(text) {
		const broken = (end) => {
			try {
				JSON.parse(text.slice(0, end));
				return false;
			} catch (error) {
				return !/end of (JSON|data)|Unterminated/i.test(String(error && error.message));
			}
		};
		let low = 0;
		let high = text.length;
		while (low < high) {
			const middle = Math.floor((low + high) / 2);
			if (broken(middle + 1)) high = middle;
			else low = middle + 1;
		}
		return low;
	}

	/** Parses a TOML text with the page's codec, or refuses it with the line and column of its error. */
	function parseTomlText(text, parseToml) {
		try {
			return parseToml(text);
		} catch (error) {
			const where =
				Number.isInteger(error && error.line) && Number.isInteger(error.column)
					? { line: error.line, column: error.column }
					: lineColumn(text, text.length);
			const first = String((error && error.message) || error).split('\n')[0];
			return fail('format_syntax', `toml ${first}`, Object.assign({ format: 'TOML' }, where));
		}
	}

	/**
	 * Refuses a character placed on two keys: a layout types it from one key,
	 * so the user is told both places to choose from.
	 * @param {Map<string, {row: number, column: number}>} seen - Character → its first place.
	 * @param {string} char - The character.
	 * @param {{row: number, column: number}} place - Its place now (from 1).
	 */
	function once(seen, char, place) {
		const first = seen.get(char);
		if (first)
			fail(
				'format_duplicate',
				`${char} ${first.row}:${first.column} ${place.row}:${place.column}`,
				{
					char,
					row1: first.row,
					column1: first.column,
					row2: place.row,
					column2: place.column
				}
			);
		seen.set(char, place);
	}

	/** A fresh result: the layout being built and what could not be mapped. */
	function start(format, id, name) {
		return {
			format,
			layout: { id, name, rows: {}, dead: {}, command: {}, fingering: 'standard' },
			unmapped: []
		};
	}

	/** Puts a cell on a key's layer. */
	function put(result, code, layer, cell) {
		if (!result.layout.rows[code]) result.layout.rows[code] = [NONE, NONE, NONE, NONE];
		result.layout.rows[code][layer] = cell;
	}

	/** An identifier the Ergopti source accepts, from any name. */
	function slug(text) {
		const id = String(text)
			.toLowerCase()
			.normalize('NFD')
			.replace(/[̀-ͯ]/g, '')
			.replace(/[^a-z0-9]+/g, '_')
			.replace(/^_+|_+$/g, '');
		return /^[a-z]/.test(id) ? id : `layout_${id}`;
	}

	/**
	 * Fills a standard accent's compositions for every character the layout
	 * types on a key: the letter with the accent's combining mark, when that
	 * normalises to one character.
	 */
	function composeAccent(layout, state, accent) {
		const mark = ACCENTS[accent];
		const rules = layout.dead[state] || (layout.dead[state] = {});
		if (!mark) return rules;
		for (const row of Object.values(layout.rows))
			for (const cell of row) {
				if (typeof cell !== 'string' || Array.from(cell).length !== 1 || rules[cell] !== undefined)
					continue;
				const composed = (cell + mark).normalize('NFC');
				if (Array.from(composed).length === 1) rules[cell] = composed;
			}
		if (rules[' '] === undefined && ACCENT_ALONE[accent]) rules[' '] = ACCENT_ALONE[accent];
		return rules;
	}

	/**
	 * The level list of an XKB key statement: the first bracket that is a
	 * list of keysyms (bare, or `symbols[Group1] =`), never an index such as
	 * `type[Group1]` or another statement's list such as `actions[Group1] =`.
	 * @param {string} body - The text between the key statement's braces.
	 * @returns {string|null} The keysyms between the brackets, or null.
	 */
	function xkbLevels(body) {
		for (const bracket of body.matchAll(/\[([^\]]*)\]/g)) {
			const before = body.slice(0, bracket.index);
			// An index ([Group1]) follows a name.
			if (/\w\s*$/.test(before)) continue;
			const statement = before.slice(before.lastIndexOf(',') + 1);
			if (/^\s*$/.test(statement) || /^\s*symbols\s*\[\s*group1\s*\]\s*=\s*$/i.test(statement))
				return bracket[1];
		}
		return null;
	}

	/**
	 * The character of an XKB keysym named letter then accent (scircumflex,
	 * Ubreve, Iabovedot), composed by Unicode normalisation; undefined for any
	 * other name.
	 */
	function accentedKeysym(sym) {
		const match = /^([A-Za-z])([a-z]+)$/.exec(sym);
		if (!match || !ACCENTS[match[2]]) return undefined;
		const composed = (match[1] + ACCENTS[match[2]]).normalize('NFC');
		return Array.from(composed).length === 1 ? composed : undefined;
	}

	/** Completes the standard accents once every key is known. */
	function finishAccents(result, accents) {
		for (const [state, accent] of accents) {
			const stated = result.layout.dead[state] && Object.keys(result.layout.dead[state]).length > 0;
			if (!ACCENTS[accent] && !stated)
				result.unmapped.push({ what: 'dead_key_rules', detail: accent });
			composeAccent(result.layout, state, accent);
		}
	}

	// ==========================
	// ======= 3/ Readers =======
	// ==========================

	/**
	 * The thumb keys of a KLA file on a board with thumb clusters (ErgoDox,
	 * KLAnext's matrix and ergolinear), when one of them types a letter, a digit or a
	 * punctuation mark (KLA_THUMB_TYPED; a key drawing only an action sign,
	 * « ⌦ » or « ⇞ », stays unread): each thumb's keys that type one of them
	 * or the space, by the file's own finger (5 left, 6 right), take that
	 * thumb's codes (KLA_THUMB_CODES), the big keys first, then by index; the
	 * shared space bar (Space) is not used, so the space goes to the thumb the
	 * file gives it. A key holding only the capitals of another key's letters on
	 * the same thumb (Hands Down's « T » beside « t ») becomes that key's
	 * Shift. A thumb key beyond its thumb's codes stays unmapped (null code),
	 * reported. Otherwise (the space alone on the thumbs) nothing changes.
	 * @param {string} type - The file's keyboardType.
	 * @param {Map<number, object>} placed - Index → key.
	 * @param {function(object): Array} cellsOf - A key's four cells.
	 * @returns {{codes: Map<number, string|null>, cells: Map<number, Array>}}
	 */
	function klaThumbCodes(type, placed, cellsOf) {
		const none = { codes: new Map(), cells: new Map() };
		const spec = KLA_THUMB_BOARDS[type];
		if (!spec) return none;
		const board = KLA_KEYS[type];
		const thumbs = [];
		placed.forEach((key, index) => {
			const hand = KLA_THUMB_HANDS[key.finger];
			if (hand === undefined || (board[index] && board[index] !== 'Space')) return;
			const cells = cellsOf(key);
			if (cells.some(typedCell)) thumbs.push({ index, hand, cells });
		});
		if (!thumbs.some((thumb) => thumb.cells.some((cell) => typedCell(cell) && cell !== ' ')))
			return none;
		const out = { codes: new Map(), cells: new Map() };
		// The space bar's indexes take no action sign: such a key stays unread.
		placed.forEach((key, index) => {
			if (board[index] === 'Space') out.codes.set(index, null);
		});
		for (const hand of Object.keys(KLA_THUMB_CODES)) {
			const own = thumbs
				.filter((thumb) => thumb.hand === hand)
				.sort(
					(a, b) => spec.big.includes(b.index) - spec.big.includes(a.index) || a.index - b.index
				);
			// The capitals' key: its base and AltGr cells the capitals of another
			// key's (Silver's « N Ñ » beside « n ñ »), whose Shift levels are empty.
			const capitalOf = (cell, lower) =>
				cell === NONE || (lower !== NONE && cell !== lower && cell === lower.toUpperCase());
			const kept = own.filter((thumb) => {
				const cells = thumb.cells;
				if (cells[0] === NONE || cells[1] !== NONE || cells[3] !== NONE) return true;
				const lower = own.find(
					(other) =>
						other !== thumb &&
						other.cells[1] === NONE &&
						other.cells[3] === NONE &&
						capitalOf(cells[0], other.cells[0]) &&
						capitalOf(cells[2], other.cells[2])
				);
				if (!lower) return true;
				lower.cells = [lower.cells[0], cells[0], lower.cells[2], cells[2]];
				out.codes.set(thumb.index, null);
				out.cells.set(thumb.index, [NONE, NONE, NONE, NONE]);
				return false;
			});
			kept.forEach((thumb, i) => {
				out.codes.set(thumb.index, KLA_THUMB_CODES[hand][i] || null);
				out.cells.set(thumb.index, thumb.cells);
			});
		}
		return out;
	}

	/**
	 * Reads a Keyboard Layout Analyzer JSON (KLA, KLAnext, their forks).
	 * @param {object} json - The parsed file.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromKla(json) {
		if (!json || !Array.isArray(json.keys)) fail('format_invalid', 'keys');
		const board = KLA_KEYS[json.keyboardType];
		if (!board) fail('format_unsupported_board', String(json.keyboardType));
		const name = typeof json.label === 'string' && json.label !== '' ? json.label : 'KLA layout';
		const result = start('kla', slug(name), name);
		const cellOf = (value) => {
			if (value === undefined || value === null || value === -1 || value === '') return NONE;
			if (typeof value === 'string') return value;
			if (Number.isInteger(value) && value >= 32 && value <= MAX_CODE_POINT)
				return String.fromCodePoint(value);
			return NONE;
		};
		// A key sits at its « id » when it has one (KLAnext's fixKeys orders the
		// keys by id, a later key replacing an earlier one at the same id), else
		// at its place in the list (KLA's own files).
		const placed = new Map();
		json.keys.forEach((key, index) => {
			if (!key || typeof key !== 'object') fail('format_invalid', `keys[${index}]`);
			placed.set(Number.isInteger(key.id) && key.id >= 0 ? key.id : index, key);
		});
		const cellsOf = (key) =>
			['primary', 'shift', 'altGr', 'shiftAltGr'].map((field) => cellOf(key[field]));
		const thumbCodes = klaThumbCodes(json.keyboardType, placed, cellsOf);
		placed.forEach((key, index) => {
			const cells = thumbCodes.cells.get(index) || cellsOf(key);
			if (cells.every((cell) => cell === NONE)) return;
			const code = thumbCodes.codes.has(index) ? thumbCodes.codes.get(index) : board[index];
			if (!code) {
				// A key the ISO board has no place for (an ErgoDox thumb or outer
				// column): its characters are named so the user sees what is left out.
				const typed = cells.filter((cell) => cell !== NONE).join(' ');
				result.unmapped.push({ what: 'key', detail: `${index} (${typed})` });
				return;
			}
			cells.forEach((cell, layer) => {
				if (cell !== NONE) put(result, code, layer, cell);
			});
		});
		return result;
	}

	/**
	 * Reads a Kalamine JSON (x-keyboard): keymap code → [base, shift, altgr,
	 * shift_altgr], dead keys written *^ and the custom one **.
	 * @param {object} json - The parsed file.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromKalamineJson(json) {
		if (!json || typeof json.keymap !== 'object') fail('format_invalid', 'keymap');
		const name = json.name || 'Kalamine layout';
		const result = start('kalamine_json', slug(name), name);
		const accents = new Map();
		const deadState = (id) => {
			const accent = KALAMINE_DEAD[id] || `dead_${Array.from(id).slice(1).join('')}`;
			const state = slug(accent);
			if (!accents.has(state)) accents.set(state, accent);
			return state;
		};
		for (const [code, levels] of Object.entries(json.keymap)) {
			if (!Array.isArray(levels)) continue;
			levels.slice(0, LAYERS).forEach((value, layer) => {
				if (typeof value !== 'string' || value === '') return;
				put(
					result,
					code,
					layer,
					value.length > 1 && value[0] === '*' ? { dead: deadState(value) } : value
				);
			});
		}
		for (const [id, table] of Object.entries(json.deadkeys || {})) {
			const state = deadState(id);
			const rules = result.layout.dead[state] || (result.layout.dead[state] = {});
			if (!table || typeof table !== 'object') fail('format_invalid', `deadkeys ${id}`);
			for (const [typed, made] of Object.entries(table)) {
				if (typeof made !== 'string') continue;
				// A dead key typed in a dead state (Ergo-L's ** then **) is « dead:<state> ».
				const key = typed.length > 1 && typed[0] === '*' ? `dead:${deadState(typed)}` : typed;
				rules[key] = made.length > 1 && made[0] === '*' ? { dead: deadState(made) } : made;
			}
		}
		finishAccents(result, Array.from(accents));
		return result;
	}

	/**
	 * Reads a parsed Kalamine TOML: its ASCII-art blocks (full, or base and
	 * altgr), the 1dk column and the [spacebar] table.
	 * @param {object} doc - The parsed TOML.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromKalamineToml(doc) {
		const geometry = String(doc.geometry || 'ISO').toUpperCase();
		const rows = KALAMINE_ROWS[geometry];
		if (!rows) fail('format_unsupported_board', geometry);
		const name = doc.name || 'Kalamine layout';
		const result = start('kalamine_toml', slug(name), name);
		const accents = new Map();
		const odk = {};
		const cell = (line, at) => {
			const ch = line[at];
			if (ch === undefined || ch === ' ') return NONE;
			if (line[at - 1] === '*') {
				const id = `*${ch}`;
				const accent = KALAMINE_DEAD[id] || `dead_${ch}`;
				const state = slug(accent);
				accents.set(state, accent);
				return { dead: state };
			}
			return ch;
		};
		/** Reads one block: left column into `left` layers, right column into `right`. */
		const read = (block, left, right) => {
			const lines = String(block).replace(/^\n/, '').split('\n');
			rows.forEach(([offset, keys], r) => {
				const upper = lines[1 + KALAMINE_LINES_PER_ROW * r] || '';
				const lower = lines[2 + KALAMINE_LINES_PER_ROW * r] || '';
				keys.forEach((xkb, k) => {
					const at = offset + KALAMINE_KEY_STEP * k;
					const code = XKB_KEYS[xkb];
					const values = [
						cell(lower, at),
						cell(upper, at),
						cell(lower, at + 2),
						cell(upper, at + 2)
					];
					// A blank base takes the lower case of its Shift character (Kalamine's rule).
					if (values[0] === NONE && typeof values[1] === 'string')
						values[0] = values[1].toLowerCase();
					// A blank right-column Shift level takes the upper case of the level below.
					if (
						values[3] === NONE &&
						typeof values[2] === 'string' &&
						values[2].toUpperCase() !== values[2]
					)
						values[3] = values[2].toUpperCase();
					if (left) {
						if (values[0] !== NONE) put(result, code, left[0], values[0]);
						if (values[1] !== NONE) put(result, code, left[1], values[1]);
					}
					if (right === 'odk') {
						const plain = [values[0], values[1]];
						[values[2], values[3]].forEach((made, i) => {
							if (made !== NONE && typeof plain[i] === 'string') odk[plain[i]] = made;
						});
					} else if (right) {
						if (values[2] !== NONE) put(result, code, right[0], values[2]);
						if (values[3] !== NONE) put(result, code, right[1], values[3]);
					}
				});
			});
		};
		if (doc.full !== undefined) read(doc.full, [0, 1], [2, 3]);
		else {
			if (doc.base !== undefined) read(doc.base, [0, 1], 'odk');
			if (doc.altgr !== undefined) read(doc.altgr, null, [2, 3]);
		}
		put(result, 'Space', 0, ' ');
		const space = doc.spacebar || {};
		if (typeof space.shift === 'string') put(result, 'Space', 1, space.shift);
		if (typeof space.altgr === 'string') put(result, 'Space', 2, space.altgr);
		if (typeof space.altgr_shift === 'string') put(result, 'Space', 3, space.altgr_shift);
		if (Object.keys(odk).length > 0 || accents.has('odk')) {
			const rules = result.layout.dead.odk || (result.layout.dead.odk = {});
			Object.assign(rules, odk);
			rules[' '] = typeof space['1dk'] === 'string' ? space['1dk'] : "'";
			accents.delete('odk');
		}
		finishAccents(result, Array.from(accents));
		return result;
	}

	/**
	 * Reads XKB symbols: the first xkb_symbols block, or the named one.
	 * @param {string} text - The symbols file.
	 * @param {string} [variant] - The block's name.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromXkb(text, variant) {
		const blocks = Array.from(text.matchAll(/xkb_symbols\s+"([^"]+)"\s*\{([\s\S]*?)\n\s*\}\s*;/g));
		if (blocks.length === 0) fail('format_invalid', 'xkb_symbols');
		const block = variant ? blocks.find((b) => b[1] === variant) : blocks[0];
		if (!block) fail('format_invalid', `xkb_symbols ${variant}`);
		const nameMatch = /name\[Group1\]\s*=\s*"([^"]*)"/.exec(block[2]);
		const name = nameMatch ? nameMatch[1] : block[1];
		const result = start('xkb', slug(block[1]), name);
		const accents = new Map();
		for (const include of block[2].matchAll(/include\s+"([^"]+)"/g))
			result.unmapped.push({ what: 'include', detail: include[1] });
		for (const key of block[2].matchAll(/key\s+<([A-Z0-9]+)>\s*\{([^}]*)\}/g)) {
			const code = XKB_KEYS[key[1]];
			const levels = xkbLevels(key[2]);
			if (levels === null) continue;
			if (!code) {
				result.unmapped.push({ what: 'key', detail: key[1] });
				continue;
			}
			levels
				.split(',')
				.map((s) => s.trim())
				.slice(0, LAYERS)
				.forEach((sym, layer) => {
					if (sym === '' || sym === 'NoSymbol' || sym === 'VoidSymbol') return;
					if (sym.startsWith('dead_')) {
						const accent = sym.slice('dead_'.length);
						accents.set(accent, accent);
						put(result, code, layer, { dead: accent });
						return;
					}
					const unicode = /^U([0-9A-Fa-f]{4,6})$/.exec(sym);
					const point = unicode ? parseInt(unicode[1], 16) : -1;
					let char =
						point >= 0 && point <= MAX_CODE_POINT ? String.fromCodePoint(point) : KEYSYMS[sym];
					if (char === undefined) char = accentedKeysym(sym);
					if (char === undefined && Array.from(sym).length === 1) char = sym;
					if (char === undefined && /^[0-9]$/.test(sym)) char = sym;
					if (char === undefined)
						result.unmapped.push({ what: 'keysym', detail: `${key[1]}:${sym}` });
					else put(result, code, layer, char);
				});
		}
		finishAccents(result, Array.from(accents));
		return result;
	}

	/**
	 * Reads a Windows KLC: its SHIFTSTATE columns, LAYOUT rows and DEADKEY tables.
	 * @param {string} text - The KLC (already decoded from UTF-16).
	 * @param {object} scancodes - Hex scan code → physical key (LAYOUT_ANALYSIS_DATA.scancodes).
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromKlc(text, scancodes) {
		const lines = text.replace(/\r/g, '').split('\n');
		const nameMatch = /^KBD\s+\S+\s+"([^"]*)"/m.exec(text);
		const name = nameMatch ? nameMatch[1] : 'KLC layout';
		const result = start('klc', slug(name), name);
		// Shift states → engine layer: 0 base, 1 Shift, 6 AltGr, 7 Shift+AltGr.
		const LAYER_OF_STATE = { 0: 0, 1: 1, 6: 2, 7: 3 };
		const states = [];
		let section = '';
		let deadChar = null;
		const deadName = (hex) => `dead_${hex.toLowerCase()}`;
		const klcCell = (value) => {
			if (value === '-1' || value === '%%') return NONE;
			const dead = value.endsWith('@');
			const raw = dead ? value.slice(0, -1) : value;
			const char = /^[0-9a-fA-F]{4}$/.test(raw) ? String.fromCharCode(parseInt(raw, 16)) : raw;
			return dead ? { dead: deadName(char.charCodeAt(0).toString(16).padStart(4, '0')) } : char;
		};
		for (const raw of lines) {
			const line = raw.replace(/\/\/.*$/, '').trim();
			if (line === '') continue;
			const words = line.split(/\s+/);
			const keyword = words[0].toUpperCase();
			if (
				[
					'SHIFTSTATE',
					'LAYOUT',
					'DEADKEY',
					'KEYNAME',
					'KEYNAME_EXT',
					'KEYNAME_DEAD',
					'LIGATURE',
					'DESCRIPTIONS',
					'LANGUAGENAMES',
					'ENDKBD'
				].includes(keyword)
			) {
				section = keyword;
				if (keyword === 'DEADKEY') {
					if (!HEX4.test(words[1] || '')) fail('format_invalid', `DEADKEY ${words[1]}`);
					deadChar = deadName(words[1]);
					result.layout.dead[deadChar] = result.layout.dead[deadChar] || {};
				}
				continue;
			}
			if (section === 'SHIFTSTATE') states.push(Number(words[0]));
			else if (section === 'LAYOUT') {
				const code = scancodes[words[0].toLowerCase()];
				if (!code) continue;
				words.slice(3, 3 + states.length).forEach((value, column) => {
					const layer = LAYER_OF_STATE[states[column]];
					if (layer === undefined) return;
					const cell = klcCell(value);
					if (cell !== NONE) put(result, code, layer, cell);
				});
			} else if (section === 'DEADKEY' && words.length >= 2) {
				// The result ends with @ when it chains to another dead key.
				const chained = words[1].endsWith('@');
				const made = chained ? words[1].slice(0, -1) : words[1];
				if (!HEX4.test(words[0]) || !HEX4.test(made)) fail('format_invalid', `DEADKEY ${line}`);
				const typed = String.fromCharCode(parseInt(words[0], 16));
				result.layout.dead[deadChar][typed] = chained
					? { dead: deadName(made) }
					: String.fromCharCode(parseInt(made, 16));
			} else if (section === 'LIGATURE')
				result.unmapped.push({ what: 'ligature', detail: words[0] });
		}
		if (states.length === 0) fail('format_invalid', 'SHIFTSTATE');
		return result;
	}

	/**
	 * Reads three rows of base characters: a cmini JSON or plain text (one row
	 * per line, characters separated by spaces or not); an Oxeylyzer DOF goes
	 * to fromDof.
	 * @param {object|string} input - The parsed JSON, or the text.
	 * @param {string} [name] - A name when the input has none.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromRows(input, name) {
		let rows;
		let format = 'rows';
		let label = name || 'Layout';
		const outside = [];
		if (typeof input === 'string') {
			rows = input
				.replace(/\r/g, '')
				.split('\n')
				.filter((l) => l.trim() !== '');
			// One line of the 30 keys (a one-line export): three rows of 10.
			const one = rows.length === 1 ? Array.from(rows[0].replace(/\s+/g, '')) : [];
			if (one.length === ROWS_LINE)
				rows = [0, 1, 2].map((r) => one.slice(r * 10, r * 10 + 10).join(''));
		} else if (input && input.layers) return fromDof(input);
		else if (input && input.keys && !Array.isArray(input.keys)) {
			format = 'cmini';
			label = typeof input.name === 'string' && input.name !== '' ? input.name : label;
			rows = [[], [], []];
			for (const [char, pos] of Object.entries(input.keys)) {
				if (!pos || typeof pos !== 'object') fail('format_invalid', `keys ${char}`);
				if (!Number.isInteger(pos.row) || !Number.isInteger(pos.col) || pos.row < 0 || pos.col < 0)
					fail('format_invalid', `keys ${char}`);
				// cmini's thumb row (3) has no key here: say what it types.
				if (!rows[pos.row])
					outside.push({ what: 'key', detail: `${pos.row}:${pos.col} (${char})` });
				else rows[pos.row][pos.col] = char;
			}
		} else fail('format_invalid', 'rows');
		const result = start(format, slug(label), label);
		result.unmapped.push(...outside);
		rows.slice(ROW_CODES.length).forEach((row, r) =>
			result.unmapped.push({
				what: 'key',
				detail: `${ROW_CODES.length + r}:* (${String(row).trim()})`
			})
		);
		const seen = new Map();
		rows.slice(0, ROW_CODES.length).forEach((row, r) => {
			if (!Array.isArray(row) && typeof row !== 'string') fail('format_invalid', `rows[${r}]`);
			const chars = Array.isArray(row)
				? row
				: row.includes(' ')
					? row.trim().split(/\s+/)
					: Array.from(row.trim());
			chars.forEach((char, c) => {
				if (char === undefined || char === '' || char === '~' || char === '*') return;
				once(seen, char, { row: r + 1, column: c + 1 });
				const code = ROW_CODES[r][c];
				if (!code) {
					result.unmapped.push({ what: 'key', detail: `${r}:${c}` });
					return;
				}
				put(result, code, 0, char);
				const upper = char.toUpperCase();
				if (upper !== char && Array.from(upper).length === 1) put(result, code, 1, upper);
			});
		});
		put(result, 'Space', 0, ' ');
		if (input && input.board === 'angle') result.layout.fingering = 'angle';
		return result;
	}

	/** One DOF key, as libdof reads it (its Key::from): a character, a word, or what it does. */
	function dofKey(token) {
		if (token === '~') return { empty: true };
		if (token === '*') return { transparent: true };
		if (Array.from(token).length === 1) return { text: token };
		const lower = token.toLowerCase();
		if (lower === '\\~') return { text: '~' };
		if (lower === '\\*') return { text: '*' };
		if (DOF_SPECIALS[lower]) return { special: DOF_SPECIALS[lower], token };
		if (token[0] === '@') return { layer: token.slice(1), token };
		if (token[0] === '&') return { magic: token.slice(1), token };
		if (/^(#|\\[#@&])/.test(token)) return { text: token.slice(1) };
		return { text: token };
	}

	/** The physical grid a DOF board's rows and anchor place keys on. */
	function dofGrid(json) {
		const board = json.board;
		if (typeof board === 'string') {
			const named = DOF_BOARDS[board.toLowerCase()];
			if (!named) fail('format_unsupported_board', board);
			return named;
		}
		if (!Array.isArray(board)) fail('format_invalid', 'board');
		// A relative board (« k 2k 1.5k », a bare number is a gap) whose rows
		// hold as many keys as the ANSI or ISO preset is that keyboard; any
		// other shape has no keys here to place its characters on.
		const shape = board.map((row) =>
			typeof row === 'string'
				? row
						.trim()
						.split(/\s+/)
						.filter((w) => /k$/.test(w)).length
				: -1
		);
		// A custom board anchors at its top left key unless the file says otherwise.
		for (const named of Object.values(DOF_BOARDS))
			if (named.shape && JSON.stringify(named.shape) === JSON.stringify(shape))
				return { rows: named.rows, anchor: [0, 0] };
		return fail('format_unsupported_board', 'custom');
	}

	/**
	 * Reads an Oxeylyzer DOF (libdof's format): the `main`, `shift`, `altgr`
	 * and `shift_altgr` layers placed on the board from its anchor, a missing
	 * Shift layer made as libdof makes it (QWERTY's shifted symbols, letters
	 * upper case), word keys as several characters. Other layers, magic keys
	 * and combos are reported, as are characters off the board's keys.
	 * @param {object} json - The parsed file.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromDof(json) {
		if (!json || typeof json.layers !== 'object' || json.layers === null)
			fail('format_invalid', 'layers');
		if (!Array.isArray(json.layers.main)) fail('format_invalid', 'layers.main');
		const grid = dofGrid(json);
		const anchor = json.anchor === undefined ? grid.anchor : json.anchor;
		if (
			!Array.isArray(anchor) ||
			anchor.length !== 2 ||
			!anchor.every((n) => Number.isInteger(n) && n >= 0)
		)
			fail('format_invalid', 'anchor');
		const name = typeof json.name === 'string' && json.name !== '' ? json.name : 'DOF layout';
		const result = start('dof', slug(name), name);
		const tokens = (layer, id) =>
			layer.map((row, r) => {
				if (typeof row !== 'string') fail('format_invalid', `layers.${id}[${r}]`);
				return row.trim() === '' ? [] : row.trim().split(/\s+/);
			});
		const main = tokens(json.layers.main, 'main');
		const reported = new Set();
		const lose = (what, detail) => {
			if (reported.has(`${what} ${detail}`)) return;
			reported.add(`${what} ${detail}`);
			result.unmapped.push({ what, detail });
		};
		/**
		 * Places one layer. A transparent key (*) types what the main layer types
		 * without the layer held, which the main layer already says: it adds no
		 * character to this level.
		 */
		const place = (rows, level) =>
			rows.forEach((row, r) =>
				row.forEach((token, c) => {
					const key = dofKey(token);
					if (key.empty || key.transparent) return;
					const code = (grid.rows[r + anchor[1]] || [])[c + anchor[0]];
					if (key.magic !== undefined) return lose('rule', `&${key.magic}`);
					if (key.special === 'space' && code) return put(result, code, level, ' ');
					// A modifier, Tab, Enter or a layer key types no character: it belongs
					// on a key without one, and is left out where a character would be.
					if (key.special || key.layer !== undefined)
						return code ? lose('special', `${code}: ${key.token}`) : undefined;
					if (!code) return lose('key', `${r}:${c} (${key.text})`);
					put(result, code, level, key.text);
				})
			);
		place(main, 0);
		for (const [id, layer] of Object.entries(json.layers)) {
			if (id === 'main') continue;
			if (!Array.isArray(layer)) fail('format_invalid', `layers.${id}`);
			const level = DOF_LEVELS[id];
			if (level === undefined) lose('layer', id);
			else place(tokens(layer, id), level);
		}
		// libdof makes the Shift layer when the file has none (generate_shift_layer).
		if (json.layers.shift === undefined)
			main.forEach((row, r) =>
				row.forEach((token, c) => {
					const key = dofKey(token);
					const code = (grid.rows[r + anchor[1]] || [])[c + anchor[0]];
					if (!code || key.text === undefined) return;
					put(result, code, 1, DOF_SHIFTED[key.text] || key.text.toUpperCase());
				})
			);
		for (const kind of ['combos', 'magic'])
			if (json[kind] && typeof json[kind] === 'object')
				for (const [id, rules] of Object.entries(json[kind]))
					if (rules && typeof rules === 'object')
						Object.keys(rules).forEach((rule) => lose('rule', kind === 'magic' ? `&${id}` : rule));
		if (!result.layout.rows.Space || result.layout.rows.Space[0] === NONE)
			put(result, 'Space', 0, ' ');
		if (json.fingering === 'angle') result.layout.fingering = 'angle';
		return result;
	}

	/** Whether a text is a genkey layout: a name, three rows of keys, three rows of fingers. */
	function isGenkey(text) {
		const lines = text.replace(/\r/g, '').split('\n');
		if (lines.length < 7 || lines[0].trim() === '') return false;
		const words = (line) =>
			line
				.trim()
				.split(/\s+/)
				.filter((w) => w !== '');
		return (
			lines.slice(1, 4).every((line) => words(line).length > 0) &&
			lines
				.slice(4, 7)
				.every((line) => words(line).length > 0 && words(line).every((w) => /^[0-9]$/.test(w)))
		);
	}

	/**
	 * Reads a genkey layout (semilin/genkey, layout.go LoadLayout): its name,
	 * three rows of keys (the first character of each word, lower case, as
	 * genkey takes it) and three rows of finger numbers. The keys are the base
	 * layer of the three letter rows, upper case on Shift; a bottom row typed
	 * with the angle fingering (fingers 1 2 3 3 3) keeps it.
	 * @param {string} text - The file.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromGenkey(text) {
		if (!isGenkey(text)) fail('format_invalid', 'genkey');
		const lines = text.replace(/\r/g, '').split('\n');
		const name = lines[0].trim();
		const result = start('genkey', slug(name), name);
		const words = (line) =>
			line
				.trim()
				.split(/\s+/)
				.filter((w) => w !== '');
		lines.slice(1, 4).forEach((line, r) =>
			words(line).forEach((word, c) => {
				const char = Array.from(word)[0].toLowerCase();
				if (char === '~' || char === '*') return;
				const code = ROW_CODES[r][c];
				if (!code) return result.unmapped.push({ what: 'key', detail: `${r}:${c} (${char})` });
				put(result, code, 0, char);
				const upper = char.toUpperCase();
				if (upper !== char && Array.from(upper).length === 1) put(result, code, 1, upper);
			})
		);
		put(result, 'Space', 0, ' ');
		if (words(lines[6]).slice(0, 5).join(' ') === GENKEY_ANGLE_BOTTOM.slice(0, 5).join(' '))
			result.layout.fingering = 'angle';
		return result;
	}

	/**
	 * Reads a macOS .keylayout through the layout composer's reader (the page
	 * loads layout_composer/composer_data.js and composer_model.js).
	 * @param {string} text - The .keylayout.
	 * @param {string} id - Its id.
	 * @param {'iso'|'ansi'} convention - Its keycode numbering.
	 * @param {object} tools - {composer: LayoutComposer, table: LAYOUT_COMPOSER_DATA, analysis: LAYOUT_ANALYSIS}.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromKeylayout(text, id, convention, tools) {
		if (!tools.composer || !tools.table || !tools.analysis) fail('format_unknown', 'keylayout');
		let source;
		try {
			source = tools.composer.parseSource(slug(id), text, convention, tools.table);
		} catch (error) {
			// The reader's own refusal (an undefined action, an unknown state…).
			fail('format_invalid', `${error.code || 'keylayout'} ${error.message}`);
		}
		const codes = Object.keys(XKB_KEYS).map((name) => XKB_KEYS[name]);
		const layout = tools.analysis.layoutFromComposerSource(source, Array.from(new Set(codes)));
		const result = start('keylayout', layout.id, source.name || id);
		Object.assign(result.layout, { rows: layout.rows, dead: layout.dead, command: layout.command });
		return result;
	}

	/** Whether bytes or text start with KbdEdit's .kbe signature. */
	function isKbe(data) {
		const head =
			typeof data === 'string'
				? data.slice(2, 2 + KBE_SIGNATURE.length)
				: String.fromCharCode(...Array.from(data.subarray(2, 2 + KBE_SIGNATURE.length)));
		return head === KBE_SIGNATURE;
	}

	/**
	 * Reads a KbdEdit .kbe: checks its header, then refuses it, since its body
	 * is encrypted with a key only KbdEdit holds (see KBE_SIGNATURE).
	 * @param {Uint8Array|string} data - The file's bytes, or its text when only
	 *   the text is at hand (the header's ASCII survives any decoding).
	 * @throws {Error} format_invalid for a damaged header, else format_kbe_encrypted.
	 */
	function fromKbe(data) {
		if (!isKbe(data)) fail('format_invalid', 'kbe signature');
		if (typeof data === 'string') fail('format_kbe_encrypted', 'kbe');
		if (data.length < KBE_HEADER_SIZE) fail('format_invalid', 'kbe header');
		const at = 2 + KBE_SIGNATURE.length;
		const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
		const version = view.getUint32(at, true);
		const rest = view.getUint16(at + 8, true);
		if (rest !== data.length - KBE_HEADER_SIZE) fail('format_invalid', 'kbe length');
		return fail('format_kbe_encrypted', `kbe version ${version}`);
	}

	/**
	 * A layout file's text: UTF-16 with its byte-order mark (a KLC), else UTF-8
	 * without its mark.
	 * @param {Uint8Array} bytes - The file.
	 * @returns {string} Its text.
	 */
	function decode(bytes) {
		if (bytes[0] === 0xff && bytes[1] === 0xfe)
			return new TextDecoder('utf-16le').decode(bytes.subarray(2));
		if (bytes[0] === 0xfe && bytes[1] === 0xff)
			return new TextDecoder('utf-16be').decode(bytes.subarray(2));
		return new TextDecoder().decode(bytes).replace(/^﻿/, '');
	}

	/**
	 * Recognises a file and reads it.
	 * @param {string} name - The file name.
	 * @param {string} text - Its text.
	 * @param {object} tools - parseToml (the TOML codec), scancodes
	 *   (LAYOUT_ANALYSIS_DATA.scancodes), and for a .keylayout composer, table,
	 *   analysis and convention.
	 * @returns {object} {format, layout, unmapped}.
	 * @throws {Error} With code format_unknown when nothing matches, format_invalid
	 *   when the file is damaged or places no character on any key.
	 */
	function read(name, text, tools) {
		return checked(recognise(name, text, tools));
	}

	/** The reader of a file's format, by extension and content. */
	function recognise(name, text, tools) {
		// A genkey layout is a file without an extension (genkey's layouts folder).
		const extension = name.includes('.') ? name.split('.').pop().toLowerCase() : '';
		if (extension === 'kbe' || isKbe(text)) return fromKbe(text);
		if (extension === 'keylayout' || /<keyboard\s/.test(text))
			return fromKeylayout(text, name.replace(/\.[^.]+$/, ''), tools.convention || 'iso', tools);
		if (extension === 'klc' || /^KBD\s/m.test(text)) return fromKlc(text, tools.scancodes);
		if (/xkb_symbols\s+"/.test(text)) return fromXkb(text);
		if (extension === 'toml' || extension === 'yaml') {
			if (!tools.parseToml) fail('format_unknown', name);
			return fromKalamineToml(parseTomlText(text, tools.parseToml));
		}
		if (extension === 'json' || extension === 'dof' || /^\s*\{/.test(text)) {
			const json = parseJson(text);
			if (!json || typeof json !== 'object') fail('format_invalid', 'json');
			if (Array.isArray(json.keys)) return fromKla(json);
			if (json.keymap) return fromKalamineJson(json);
			return fromRows(json, name.replace(/\.[^.]+$/, ''));
		}
		if ((extension === 'txt' || extension === '') && isGenkey(text)) return fromGenkey(text);
		if (extension === 'txt' || extension === 'kb')
			return fromRows(text, name.replace(/\.[^.]+$/, ''));
		return fail('format_unknown', name);
	}

	/**
	 * Reads a cyanophage playground layout: its link (or any text holding its
	 * layout= parameter) or the string its import box takes (CYANOPHAGE_LENGTHS).
	 * @param {string} text - The link or the string.
	 * @returns {object} {format, layout, unmapped}.
	 * @throws {Error} format_length for a string of another length,
	 *   format_duplicate for a character on two keys, format_invalid for a
	 *   damaged link.
	 */
	function fromCyanophage(text) {
		const link = CYANOPHAGE_LINK.exec(String(text).trim());
		let value = link ? link[1] : String(text);
		if (link)
			try {
				value = decodeURIComponent(value.replace(/\+/g, ' '));
			} catch {
				fail('format_invalid', 'cyanophage layout= is not URL-encoded');
			}
		const chars = Array.from(value.replace(/\s+/g, ''));
		if (!CYANOPHAGE_LENGTHS.includes(chars.length))
			fail('format_length', `cyanophage ${chars.length}`, {
				count: chars.length,
				expected: CYANOPHAGE_LENGTHS.join(', ')
			});
		const result = start('cyanophage', 'cyanophage', 'Cyanophage layout');
		const ten = [0, 1, 2].flatMap((r) => ROW_CODES[r].slice(0, 10));
		// The key of each index: the three rows of 10, or of 11 with their 11th
		// keys (BracketLeft, Quote, the key left of Z) after each row.
		const columns = chars.length === ROWS_LINE ? 10 : 11;
		const codes =
			columns === 10
				? ten
				: ten
						.slice(0, 10)
						.concat(['BracketLeft'], ten.slice(10, 20), ['Quote'], ten.slice(20, 30), [
							'IntlBackslash'
						]);
		const seen = new Map();
		chars.forEach((raw, i) => {
			if (raw === CYANOPHAGE_SHIFT) return;
			const char = CYANOPHAGE_ALIASES[raw] || raw;
			once(seen, char, { row: Math.floor(i / columns) + 1, column: (i % columns) + 1 });
			// A character on its thumb key goes on the left thumb's rest key, as a
			// KLA thumb letter does (KLA_THUMB_CODES).
			const code =
				i < CYANOPHAGE_THUMB ? codes[i] : i === CYANOPHAGE_THUMB ? KLA_THUMB_CODES.left[0] : null;
			if (!code) {
				// The 35th key: no key of this keyboard holds it.
				result.unmapped.push({ what: 'key', detail: `${i + 1} (${char})` });
				return;
			}
			put(result, code, 0, char);
			const upper = char.toUpperCase();
			if (upper !== char && Array.from(upper).length === 1) put(result, code, 1, upper);
		});
		put(result, 'Space', 0, ' ');
		return result;
	}

	/**
	 * The format a pasted text is in, from its content alone (no file name):
	 * the reader readText would use, or null when none matches.
	 * @param {string} text - The pasted text.
	 * @returns {string|null} A FORMAT_NAMES id, 'kbe', or null.
	 */
	function detect(text) {
		const s = String(text)
			.replace(/^\uFEFF/, '')
			.trim();
		if (s === '') return null;
		if (isKbe(s)) return 'kbe';
		if (/^\s*format\s*=\s*"ergopti-layout"/m.test(s)) return 'ergopti';
		if (/<keyboard\s/.test(s)) return 'keylayout';
		if (/^KBD\s/m.test(s)) return 'klc';
		if (/xkb_symbols\s+"/.test(s)) return 'xkb';
		if (s[0] === '{') {
			let json = null;
			try {
				json = JSON.parse(s);
			} catch {
				// A damaged JSON is still JSON: its reader says where it breaks.
				return 'kla';
			}
			if (!json || typeof json !== 'object') return null;
			if (Array.isArray(json.keys)) return 'kla';
			if (json.keymap) return 'kalamine_json';
			if (json.layers) return 'dof';
			if (json.keys) return 'cmini';
			return null;
		}
		if (CYANOPHAGE_LINK.test(s)) return 'cyanophage';
		if (isGenkey(s)) return 'genkey';
		if (/^\s*(name|base|full|altgr|geometry)\s*=/m.test(s)) return 'kalamine_toml';
		const lines = s.split(/\r?\n/).filter((line) => line.trim() !== '');
		if (lines.length === 1) {
			const count = Array.from(lines[0].replace(/\s+/g, '')).length;
			if (CYANOPHAGE_LENGTHS.includes(count) && count !== ROWS_LINE) return 'cyanophage';
			// One row of keys apart (a key a word), or the 30 keys at once.
			const words = lines[0].trim().split(/\s+/).length;
			return words >= ROW_CODES[2].length || count === ROWS_LINE ? 'rows' : null;
		}
		return lines.length <= 4 ? 'rows' : null;
	}

	/**
	 * Reads a pasted text (or a dropped one) by its content: the format detect
	 * names, through that format's reader, as strictly as a file.
	 * @param {string} text - The text.
	 * @param {object} tools - As read.
	 * @returns {object} {format, layout, unmapped}.
	 * @throws {Error} format_unrecognised when no format matches, else as the reader.
	 */
	function readText(text, tools) {
		const clean = String(text).replace(/^\uFEFF/, '');
		const format = detect(clean);
		if (!format) fail('format_unrecognised', `${clean.split('\n').length} lines`);
		if (format === 'cyanophage') return checked(fromCyanophage(clean));
		// The editor opens its own sources before it calls readText; the Comparer cannot.
		if (format === 'ergopti') fail('format_unknown', 'ergopti-layout');
		const names = {
			kbe: 'pasted.kbe',
			keylayout: 'pasted.keylayout',
			klc: 'pasted.klc',
			xkb: 'pasted.xkb',
			kla: 'pasted.json',
			kalamine_json: 'pasted.json',
			dof: 'pasted.dof',
			cmini: 'pasted.json',
			genkey: 'pasted',
			kalamine_toml: 'pasted.toml',
			rows: 'pasted.txt'
		};
		return read(names[format], clean.trim(), tools);
	}

	/** A result that types something, or the refusal of a layout without a character. */
	function checked(result) {
		const typing = Object.entries(result.layout.rows).some(
			([code, row]) => code !== 'Space' && row.some((cell) => cell !== NONE)
		);
		if (!typing) fail('format_invalid', 'no key');
		return result;
	}

	/**
	 * The locale key of a format's name, as a page shows what it detected.
	 * @param {string} format - A reader's result format.
	 * @returns {string} The key.
	 */
	function formatNameKey(format) {
		if (!FORMAT_NAMES.includes(format)) fail('format_name_unknown', String(format));
		return `layout_analysis.formats.name.${format}`;
	}

	/**
	 * Reads a picked file from its bytes: a .kbe by its header, any other format
	 * from its decoded text.
	 * @param {string} name - The file name.
	 * @param {Uint8Array} bytes - Its content.
	 * @param {object} tools - As read.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function readBytes(name, bytes, tools) {
		if (/\.kbe$/i.test(name) || isKbe(bytes)) return fromKbe(bytes);
		return read(name, decode(bytes), tools);
	}

	// ===========================
	// ======= 4/ Messages =======
	// ===========================

	/**
	 * The locale key and values that word a reader's refusal; an error that is
	 * not a reader's (a failed save…) keeps the generic words with its reason.
	 * @param {Error} error - What a reader or writer threw.
	 * @returns {{key: string, values: object}}
	 */
	function refusalMessage(error) {
		if (error && REFUSALS.includes(error.code))
			return {
				key: `layout_analysis.formats.refused.${error.code}`,
				values: Object.assign({ detail: String(error.detail) }, error.values || {})
			};
		const reason = (error && (error.code || error.message)) || String(error);
		return { key: 'layout_analysis.layouts.import_failed', values: { reason } };
	}

	/**
	 * The locale key and values that word one item a reader or writer could not carry.
	 * @param {{what: string, detail: string}} entry - One unmapped item.
	 * @returns {{key: string, values: object}}
	 */
	function lossMessage(entry) {
		if (!LOSSES.includes(entry.what)) fail('format_loss_unknown', String(entry.what));
		return { key: `layout_analysis.formats.loss.${entry.what}`, values: { detail: entry.detail } };
	}

	// ==========================
	// ======= 5/ Writers =======
	// ==========================

	/**
	 * Writes a layout as an Ergopti layout source document (the TOML model of
	 * docs/design/layout-source-format.md, before TOML encoding).
	 * @param {object} layout - The layout (library shape).
	 * @returns {object} The source document.
	 */
	function toSource(layout) {
		const ids = new Map();
		const idOf = (state) => {
			if (!ids.has(state)) {
				let id = slug(state);
				if (id.startsWith('layout_')) id = `dead_${id.slice('layout_'.length)}`;
				for (let n = 2; Array.from(ids.values()).includes(id); n++) id = `${slug(state)}_${n}`;
				ids.set(state, id);
			}
			return ids.get(state);
		};
		const layerSpecs = [
			{ id: 'base', required: [] },
			{ id: 'shift', required: ['shift'] },
			{ id: 'altgr', required: ['alt_right'] },
			{ id: 'shift_altgr', required: ['alt_right', 'shift'] }
		];
		const layers = layerSpecs.map((spec, index) => {
			const keys = {};
			for (const [code, row] of Object.entries(layout.rows)) {
				const cell = row[index];
				if (cell === NONE) continue;
				keys[code] = typeof cell === 'string' ? { text: cell } : { dead_key: idOf(cell.dead) };
			}
			return { id: spec.id, required: spec.required, optional: [], keys };
		});
		// The Ctrl/Cmd letters of keys whose shortcut differs from their base
		// character (the optimizer's kept QWERTY shortcuts): the editor's
		// « command » layer, which the macOS and Linux exports compile.
		const commandKeys = {};
		for (const [code, letter] of Object.entries(layout.command || {}))
			commandKeys[code] = { text: letter };
		if (Object.keys(commandKeys).length > 0)
			layers.push({ id: 'command', required: ['meta'], optional: [], keys: commandKeys });
		const deadKeys = Object.keys(layout.dead).map((state) => {
			const rules = [];
			for (const [typed, made] of Object.entries(layout.dead[state])) {
				if (typed === ' ') continue;
				rules.push(
					typeof made === 'string'
						? { input: typed, text: made }
						: { input: typed, next: idOf(made.dead) }
				);
			}
			const terminator = typeof layout.dead[state][' '] === 'string' ? layout.dead[state][' '] : '';
			return { id: idOf(state), terminator, rules };
		});
		// Every dead key a cell names must be declared, even without rules.
		for (const state of ids.keys())
			if (!layout.dead[state]) deadKeys.push({ id: idOf(state), terminator: '', rules: [] });
		return {
			format: 'ergopti-layout',
			version: 1,
			layout: { id: slug(layout.id), name: layout.name || layout.id },
			physical: { base: 'iso' },
			layers: layers.filter((layer) => Object.keys(layer.keys).length > 0 || layer.id === 'base'),
			dead_keys: deadKeys
		};
	}

	/**
	 * Writes a layout as a Keyboard Layout Analyzer JSON on its european
	 * (ISO) board, with the engine's standard fingering; a layout with
	 * characters on thumb keys goes on its ErgoDox board (toKlaErgodox), which
	 * KLA and KLAnext both read.
	 * @param {object} layout - The layout (library shape).
	 * @param {object} fingering - code → finger id (LAYOUT_ANALYSIS_DATA.model.fingerings.standard).
	 * @returns {object} The JSON object; dead keys cannot be written (KLA has none).
	 */
	function toKla(layout, fingering) {
		const thumbCodes = [].concat(...Object.values(KLA_THUMB_CODES));
		if (thumbCodes.some((code) => layout.rows[code])) return toKlaErgodox(layout, fingering);
		const byCode = {};
		for (const [index, code] of Object.entries(KLA_KEYS.european)) byCode[code] = Number(index);
		const keys = [];
		for (let id = 0; id < KLA_EUROPEAN_SIZE; id++) {
			const key = { id, primary: -1, shift: -1, altGr: -1, shiftAltGr: -1, finger: 1 };
			if (KLA_EUROPEAN_SPECIALS[id] !== undefined) key.primary = KLA_EUROPEAN_SPECIALS[id];
			keys.push(key);
		}
		for (const [code, row] of Object.entries(layout.rows)) {
			const index = byCode[code];
			if (index === undefined) continue;
			['primary', 'shift', 'altGr', 'shiftAltGr'].forEach((field, layer) => {
				const cell = row[layer];
				if (typeof cell === 'string' && Array.from(cell).length === 1)
					keys[index][field] = cell.codePointAt(0);
			});
			keys[index].finger = KLA_FINGERS[fingering[code]];
		}
		return {
			label: layout.name || layout.id,
			author: '',
			fingerStart: { 1: 29, 2: 30, 3: 31, 4: 32, 5: 57, 6: 57, 7: 35, 8: 36, 9: 37, 10: 38 },
			keyboardType: 'european',
			keys
		};
	}

	/**
	 * Writes a layout with characters on its thumb keys (NonConvert, Convert,
	 * KanaMode) as a KLA JSON on its ErgoDox board, the one KLA and KLAnext
	 * draw thumb clusters on: each thumb code on its ErgoDox thumb key
	 * (KLA_ERGODOX.thumbs) with its thumb's finger, the space bar on the left
	 * thumb's outer key, the other keys where fromKla reads them back.
	 * @param {object} layout - The layout (library shape).
	 * @param {object} fingering - code → finger id (the standard fingering).
	 * @returns {object} The JSON object.
	 */
	function toKlaErgodox(layout, fingering) {
		const byCode = { Space: KLA_ERGODOX.space };
		for (const [index, code] of Object.entries(KLA_KEYS.ergodox))
			if (byCode[code] === undefined) byCode[code] = Number(index);
		const fingerOf = {};
		for (const [code, index] of Object.entries(KLA_ERGODOX.thumbs)) {
			byCode[code] = index;
			fingerOf[code] = KLA_THUMB_CODES.left.includes(code) ? 5 : 6;
		}
		fingerOf.Space = 5;
		const keys = [];
		for (let id = 0; id < KLA_ERGODOX.size; id++) {
			const special = KLA_ERGODOX.specials[id];
			keys.push({
				id,
				primary: special ? special[0] : -1,
				shift: -1,
				altGr: -1,
				shiftAltGr: -1,
				finger: special ? special[1] : 1
			});
		}
		for (const [code, row] of Object.entries(layout.rows)) {
			const index = byCode[code];
			if (index === undefined) continue;
			['primary', 'shift', 'altGr', 'shiftAltGr'].forEach((field, layer) => {
				const cell = row[layer];
				keys[index][field] =
					typeof cell === 'string' && Array.from(cell).length === 1 ? cell.codePointAt(0) : -1;
			});
			keys[index].finger = fingerOf[code] || KLA_FINGERS[fingering[code]] || 1;
		}
		return {
			label: layout.name || layout.id,
			author: '',
			fingerStart: KLA_ERGODOX.fingerStart,
			keyboardType: 'ergodox',
			keys
		};
	}

	/**
	 * Writes a layout as a Kalamine TOML (ISO geometry, one `full` block);
	 * dead keys outside Kalamine's own set cannot be written and are reported.
	 * @param {object} layout - The layout (library shape).
	 * @returns {{text: string, unmapped: object[]}} The TOML text and the losses.
	 */
	function toKalamineToml(layout) {
		const unmapped = [];
		const kalamineChar = {};
		for (const [char, accent] of Object.entries(KALAMINE_DEAD))
			kalamineChar[slug(accent)] = char[1];
		const lines = KALAMINE_ISO_TEMPLATE.map((line) => Array.from(line));
		const write = (line, at, cell) => {
			if (cell === NONE) return;
			if (typeof cell === 'string') {
				if (Array.from(cell).length !== 1) {
					unmapped.push({ what: 'multi_character', detail: cell });
					return;
				}
				lines[line][at] = cell;
				return;
			}
			const ch = kalamineChar[cell.dead];
			if (!ch) {
				unmapped.push({ what: 'dead_key', detail: cell.dead });
				return;
			}
			lines[line][at - 1] = '*';
			lines[line][at] = ch;
		};
		KALAMINE_ROWS.ISO.forEach(([offset, keys], r) => {
			keys.forEach((xkb, k) => {
				const row = layout.rows[XKB_KEYS[xkb]];
				if (!row) return;
				const at = offset + KALAMINE_KEY_STEP * k;
				write(2 + KALAMINE_LINES_PER_ROW * r, at, row[0]);
				write(1 + KALAMINE_LINES_PER_ROW * r, at, row[1]);
				write(2 + KALAMINE_LINES_PER_ROW * r, at + 2, row[2]);
				write(1 + KALAMINE_LINES_PER_ROW * r, at + 2, row[3]);
			});
		});
		const art = lines.map((line) => line.join('')).join('\n');
		const quote = (s) => JSON.stringify(s);
		const text = [
			`name = ${quote(layout.name || layout.id)}`,
			'geometry = "ISO"',
			'',
			"full = '''",
			art,
			"'''",
			''
		].join('\n');
		return { text, unmapped };
	}

	/**
	 * Writes a layout as an Oxeylyzer DOF on libdof's ISO board, anchored at
	 * its top left key so the number row and the ISO key are written: the
	 * base layer as `main`, then `shift`, `altgr` and `shift_altgr` (each
	 * written in full, so nothing depends on libdof's generated Shift). DOF has
	 * no dead keys, and a character libdof splits words on (a space other than
	 * the space bar's) cannot be written; both are reported.
	 * @param {object} layout - The layout (library shape).
	 * @returns {{text: string, unmapped: object[]}} The JSON text and the losses.
	 */
	function toDof(layout) {
		const unmapped = [];
		const reported = new Set();
		const lose = (what, detail) => {
			if (!reported.has(`${what} ${detail}`)) unmapped.push({ what, detail });
			reported.add(`${what} ${detail}`);
		};
		// The keys without a character, at the start and the end of each row.
		const first = ['', 'tb', 'cps', 'shft', '~'];
		const last = ['bsp', 'ret', '', 'shft', '~'];
		const token = (code, level, r, c) => {
			if (code === null) return c === 0 ? first[r] : last[r];
			const cell = (layout.rows[code] || [])[level];
			if (cell === NONE || cell === undefined) return '~';
			if (typeof cell !== 'string') {
				lose('dead_key', cell.dead);
				return '~';
			}
			if (cell === ' ') return 'spc';
			if (/\s/.test(cell)) {
				lose(
					'character',
					`${code}: U+${cell.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`
				);
				return '~';
			}
			if (cell === '~' || cell === '*') return `\\${cell}`;
			if (Array.from(cell).length === 1) return cell;
			// A word libdof would read as something else keeps its text behind a « # ».
			const lower = cell.toLowerCase();
			if (DOF_SPECIALS[lower] || /^[#@&]/.test(cell) || /^\\[~*#@&]/.test(cell)) return `#${cell}`;
			return cell;
		};
		const board = DOF_BOARDS.iso;
		const layer = (level) =>
			board.rows.map((row, r) => row.map((code, c) => token(code, level, r, c)).join(' '));
		const used = (level) =>
			Object.values(layout.rows).some((row) => row[level] !== NONE && row[level] !== undefined);
		// A key the ISO board lacks (a JIS or ABNT key) is named with what it types.
		const placed = new Set(board.rows.flat());
		for (const [code, row] of Object.entries(layout.rows))
			if (!placed.has(code) && row.some((cell) => typeof cell === 'string'))
				lose('key', `${code} (${row.filter((cell) => typeof cell === 'string').join(' ')})`);
		const layers = { main: layer(0), shift: layer(1) };
		if (used(2)) layers.altgr = layer(2);
		if (used(3)) layers.shift_altgr = layer(3);
		const json = {
			name: layout.name || layout.id,
			board: 'iso',
			anchor: [0, 0],
			layers,
			fingering: layout.fingering === 'angle' ? 'angle' : 'traditional'
		};
		return { text: `${JSON.stringify(json, null, 4)}\n`, unmapped };
	}

	/**
	 * The base characters of the three letter rows for a letter-block format
	 * (genkey, cmini), and what such a format leaves out: a dead key, several
	 * characters on a key, a character typed twice, and the layers above the
	 * base when they hold more than its upper case.
	 */
	function letterBlock(layout, unmapped) {
		const seen = new Set();
		const rows = ROW_CODES.map((codes) =>
			codes.map((code) => {
				const cell = (layout.rows[code] || [])[0];
				if (cell === NONE || cell === undefined) return NONE;
				if (typeof cell !== 'string') {
					unmapped.push({ what: 'dead_key', detail: cell.dead });
					return NONE;
				}
				if (Array.from(cell).length !== 1) {
					unmapped.push({ what: 'multi_character', detail: cell });
					return NONE;
				}
				if (/\s/.test(cell) || seen.has(cell)) {
					unmapped.push({ what: 'character', detail: `${code}: ${cell}` });
					return NONE;
				}
				seen.add(cell);
				return cell;
			})
		);
		const lost = new Set();
		ROW_CODES.flat().forEach((code) => {
			const row = layout.rows[code] || [];
			const base = row[0];
			if (typeof row[1] === 'string' && (typeof base !== 'string' || row[1] !== base.toUpperCase()))
				lost.add('Shift');
			if (row[2] !== NONE && row[2] !== undefined) lost.add('AltGr');
			if (row[3] !== NONE && row[3] !== undefined) lost.add('Shift+AltGr');
		});
		lost.forEach((level) => unmapped.push({ what: 'layer', detail: level }));
		return rows;
	}

	/**
	 * Writes a layout as a genkey layout: its name, the base characters of
	 * the three letter rows (~ where a key has none) and genkey's finger rows,
	 * the bottom one angled when the layout uses the angle fingering. genkey
	 * reads every key lower case.
	 * @param {object} layout - The layout (library shape).
	 * @returns {{text: string, unmapped: object[]}} The text and the losses.
	 */
	function toGenkey(layout) {
		const unmapped = [];
		const rows = letterBlock(layout, unmapped);
		const keys = rows.map((row) => {
			const out = row.map((cell) => {
				// genkey reads a key lower case, and the reader takes ~ and * for no key.
				if (cell !== NONE && (cell !== cell.toLowerCase() || cell === '~' || cell === '*')) {
					unmapped.push({ what: 'character', detail: cell });
					return '~';
				}
				return cell === NONE ? '~' : cell;
			});
			// genkey's rows hold ten keys; a key beyond is kept only when it types something.
			while (out.length > 10 && out[out.length - 1] === '~') out.pop();
			return out;
		});
		const fingers = keys.map((row, r) =>
			(r === 2 && layout.fingering === 'angle' ? GENKEY_ANGLE_BOTTOM : GENKEY_FINGERS).slice(
				0,
				row.length
			)
		);
		const name = String(layout.name || layout.id).replace(/\s+/g, ' ');
		const text = [
			name,
			...keys.map((row) => row.join(' ')),
			...fingers.map((row) => row.join(' ')),
			''
		];
		return { text: text.join('\n'), unmapped };
	}

	/**
	 * Writes a layout as a cmini JSON: each base character of the three
	 * letter rows with its row, column and finger, on cmini's « angle » board
	 * when the layout uses the angle fingering, else « stagger ».
	 * @param {object} layout - The layout (library shape).
	 * @returns {{text: string, unmapped: object[]}} The JSON text and the losses.
	 */
	function toCmini(layout) {
		const unmapped = [];
		const angle = layout.fingering === 'angle';
		const keys = {};
		letterBlock(layout, unmapped).forEach((row, r) =>
			row.forEach((cell, col) => {
				if (cell === NONE) return;
				const finger = (r === 2 && angle ? CMINI_ANGLE_BOTTOM : CMINI_FINGERS)[col];
				keys[cell] = { row: r, col, finger };
			})
		);
		const json = {
			name: layout.name || layout.id,
			user: 0,
			board: angle ? 'angle' : 'stagger',
			keys
		};
		return { text: `${JSON.stringify(json, null, 4)}\n`, unmapped };
	}

	// ===============================
	// ======= 6/ Share links ========
	// ===============================

	/** Base64url of bytes, without padding. */
	function toBase64Url(bytes) {
		let binary = '';
		for (const byte of bytes) binary += String.fromCharCode(byte);
		return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
	}

	/** The bytes of a base64url text; a text that is not one is a damaged link. */
	function fromBase64Url(text) {
		const padded = text.replace(/-/g, '+').replace(/_/g, '/');
		let binary;
		try {
			binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4));
		} catch {
			fail('link_damaged', 'base64');
		}
		return Uint8Array.from(binary, (ch) => ch.charCodeAt(0));
	}

	/** Bytes through a CompressionStream or DecompressionStream, stopped past a cap. */
	async function pipeBytes(bytes, stream, cap) {
		const reader = new Blob([bytes]).stream().pipeThrough(stream).getReader();
		const chunks = [];
		let size = 0;
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			size += value.length;
			if (size > cap) {
				await reader.cancel();
				fail('link_too_large', String(size));
			}
			chunks.push(value);
		}
		const out = new Uint8Array(size);
		let at = 0;
		for (const chunk of chunks) {
			out.set(chunk, at);
			at += chunk.length;
		}
		return out;
	}

	/** Whether a value is a plain object (not an array, not null). */
	const isPlain = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

	/**
	 * The fragment part that carries layouts in a share link.
	 * @param {Array<{name: string, rows: object, dead?: object, command?: object}>} layouts
	 *   The layouts (library shape).
	 * @returns {Promise<string>} « l=1.<data> », to put after the link's « # ».
	 * @throws {Error} link_unsupported when the browser cannot deflate;
	 *   link_too_large past the caps fromLink reads.
	 */
	async function toLink(layouts) {
		if (typeof CompressionStream !== 'function') fail('link_unsupported', 'CompressionStream');
		if (layouts.length === 0 || layouts.length > LINK_MAX_LAYOUTS)
			fail('link_too_large', `${layouts.length} layouts`);
		const compact = layouts.map((layout) => {
			const entry = { n: String(layout.name || layout.id).slice(0, LINK_MAX_NAME), r: layout.rows };
			if (layout.dead && Object.keys(layout.dead).length > 0) entry.d = layout.dead;
			if (layout.command && Object.keys(layout.command).length > 0) entry.c = layout.command;
			return entry;
		});
		const json = new TextEncoder().encode(JSON.stringify(compact));
		if (json.length > LINK_MAX_JSON) fail('link_too_large', String(json.length));
		const packed = await pipeBytes(json, new CompressionStream('deflate-raw'), LINK_MAX_TEXT);
		const part = `${LINK_PARAM}=${LINK_VERSION}.${toBase64Url(packed)}`;
		if (part.length > LINK_MAX_TEXT) fail('link_too_large', String(part.length));
		return part;
	}

	/** One cell of a linked layout: null, a text, or a dead key's state. */
	function linkCell(cell) {
		if (cell === null) return true;
		if (typeof cell === 'string') return cell.length > 0 && cell.length <= LINK_MAX_CELL;
		return (
			isPlain(cell) &&
			Object.keys(cell).length === 1 &&
			typeof cell.dead === 'string' &&
			cell.dead.length > 0 &&
			cell.dead.length <= LINK_MAX_CELL
		);
	}

	/**
	 * Checks one layout of a link against the shape toLink writes, every key a
	 * key the engine types on, every cell a text or a dead key.
	 * @returns {object} The layout in the library shape.
	 * @throws {Error} link_invalid, naming what is wrong.
	 */
	function linkLayout(entry, index, analysis, codes) {
		const where = `layout ${index + 1}`;
		if (!isPlain(entry)) fail('link_invalid', where);
		for (const key of Object.keys(entry))
			if (!['n', 'r', 'd', 'c'].includes(key)) fail('link_invalid', `${where}: ${key}`);
		const name = typeof entry.n === 'string' ? entry.n.trim() : '';
		if (name === '' || name.length > LINK_MAX_NAME) fail('link_invalid', `${where}: name`);
		if (!isPlain(entry.r) || Object.keys(entry.r).length === 0)
			fail('link_invalid', `${where}: keys`);
		for (const [code, row] of Object.entries(entry.r)) {
			if (!codes.has(code)) fail('link_invalid', `${where}: ${code}`);
			if (!Array.isArray(row) || row.length !== LAYERS || !row.every(linkCell))
				fail('link_invalid', `${where}: ${code}`);
		}
		const dead = entry.d === undefined ? {} : entry.d;
		if (!isPlain(dead)) fail('link_invalid', `${where}: dead keys`);
		for (const [state, rules] of Object.entries(dead)) {
			if (!isPlain(rules)) fail('link_invalid', `${where}: ${state}`);
			for (const [typed, result] of Object.entries(rules))
				if (typed.length > LINK_MAX_CELL || result === null || !linkCell(result))
					fail('link_invalid', `${where}: ${state}`);
		}
		const command = entry.c === undefined ? {} : entry.c;
		if (!isPlain(command)) fail('link_invalid', `${where}: shortcuts`);
		for (const [code, letter] of Object.entries(command))
			if (!codes.has(code) || typeof letter !== 'string' || !linkCell(letter))
				fail('link_invalid', `${where}: ${code}`);
		try {
			return analysis.layoutFromRows({
				id: `link_${index + 1}`,
				name,
				rows: entry.r,
				dead,
				command,
				origin: 'user'
			});
		} catch (error) {
			fail('link_invalid', `${where}: ${error.message}`);
		}
	}

	/**
	 * The layouts a share link's fragment carries.
	 * @param {string} hash - The address's fragment (location.hash, with or without « # »).
	 * @param {object} analysis - The analysis engine (LAYOUT_ANALYSIS).
	 * @returns {Promise<object[]>} The layouts (ids link_1, link_2…, origin user),
	 *   none when the fragment carries none.
	 * @throws {Error} link_version, link_damaged, link_too_large, link_invalid or
	 *   link_unsupported: the whole fragment is refused.
	 */
	async function fromLink(hash, analysis) {
		const text = String(hash || '').replace(/^#/, '');
		const parts = text === '' ? [] : text.split('&');
		const linked = parts.filter((part) => part.startsWith(`${LINK_PARAM}=`));
		if (linked.length === 0) return [];
		if (linked.length > 1) fail('link_damaged', 'parts');
		if (linked[0].length > LINK_MAX_TEXT) fail('link_too_large', String(linked[0].length));
		const match = LINK_PART.exec(linked[0]);
		if (!match) fail('link_damaged', 'form');
		if (Number(match[1]) !== LINK_VERSION) fail('link_version', match[1]);
		if (typeof DecompressionStream !== 'function') fail('link_unsupported', 'DecompressionStream');
		let json;
		try {
			json = await pipeBytes(
				fromBase64Url(match[2]),
				new DecompressionStream('deflate-raw'),
				LINK_MAX_JSON
			);
		} catch (error) {
			if (REFUSALS.includes(error && error.code)) throw error;
			fail('link_damaged', 'deflate');
		}
		let value;
		try {
			value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(json));
		} catch {
			fail('link_damaged', 'json');
		}
		if (!Array.isArray(value) || value.length === 0) fail('link_invalid', 'layouts');
		if (value.length > LINK_MAX_LAYOUTS) fail('link_too_large', `${value.length} layouts`);
		const codes = new Set(analysis.typingCodes());
		return value.map((entry, index) => linkLayout(entry, index, analysis, codes));
	}

	return {
		EXTENSIONS,
		LINK_LONG,
		toLink,
		fromLink,
		XKB_KEYS,
		KLA_KEYS,
		ACCENTS,
		composeAccent,
		fromKla,
		fromKalamineJson,
		fromKalamineToml,
		fromXkb,
		fromKlc,
		fromRows,
		fromDof,
		fromGenkey,
		fromKeylayout,
		fromKbe,
		fromCyanophage,
		FORMAT_NAMES,
		formatNameKey,
		detect,
		decode,
		read,
		readText,
		readBytes,
		refusalMessage,
		lossMessage,
		toSource,
		toKla,
		toKalamineToml,
		toDof,
		toGenkey,
		toCmini
	};
})();

// Node (tests, tools) reads the module through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_FORMATS;
