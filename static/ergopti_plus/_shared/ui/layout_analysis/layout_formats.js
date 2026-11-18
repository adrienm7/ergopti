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
 *    forks, on the standard, european, ErgoDox and KLAnext matrix boards),
 *    Kalamine TOML and JSON (Ergo-L and its family), XKB symbols, Windows
 *    KLC, Oxeylyzer DOF (libdof's boards, anchors and layers), genkey
 *    layouts, cmini JSON and plain rows of characters. A macOS .keylayout
 *    goes through the layout composer's reader, which the editor already
 *    loads. A KbdEdit .kbe is recognised and refused: its body is encrypted
 *    (KBE_SIGNATURE).
 * 2. Dead keys of the standard accents compose by Unicode normalisation (the
 *    accent's combining mark after the letter, NFC), the same table XKB's
 *    Compose and Kalamine's built-in dead keys hold for those accents; any
 *    other dead key keeps only the compositions its file states.
 * 3. Every refusal and loss has a stable code that refusalMessage and
 *    lossMessage turn into a locale key, so the Studio and the Comparer word
 *    them the same way in every language.
 * 4. Pure: no DOM, no fetch; a Kalamine TOML is passed already parsed, so the
 *    page's TOML codec (vendor/smol-toml.js) and Node's are the same one.
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
		'txt'
	];
	// The refusals and losses a page words in the user's language
	// (layout_analysis.formats.refused.* and .loss.* in every locale).
	const REFUSALS = [
		'format_unknown',
		'format_invalid',
		'format_unsupported_board',
		'format_kbe_encrypted'
	];
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
		return { standard, european, ergodox, matrix };
	})();
	// The KLA finger number of each engine finger (1 left pinky … 10 right pinky).
	const KLA_FINGERS = { lp: 1, lr: 2, lm: 3, li: 4, lt: 5, rt: 6, ri: 7, rm: 8, rr: 9, rp: 10 };
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

	/** A rejection with a stable code the caller can show. */
	function fail(code, detail) {
		const error = new Error(`${code}: ${detail}`);
		error.code = code;
		error.detail = detail;
		throw error;
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
		placed.forEach((key, index) => {
			const cells = ['primary', 'shift', 'altGr', 'shiftAltGr'].map((field) => cellOf(key[field]));
			if (cells.every((cell) => cell === NONE)) return;
			const code = board[index];
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
		if (typeof input === 'string') rows = input.split('\n').filter((l) => l.trim() !== '');
		else if (input && input.layers) return fromDof(input);
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
		rows.slice(0, ROW_CODES.length).forEach((row, r) => {
			if (!Array.isArray(row) && typeof row !== 'string') fail('format_invalid', `rows[${r}]`);
			const chars = Array.isArray(row)
				? row
				: row.includes(' ')
					? row.trim().split(/\s+/)
					: Array.from(row.trim());
			chars.forEach((char, c) => {
				if (char === undefined || char === '' || char === '~' || char === '*') return;
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
		const result = recognise(name, text, tools);
		const typing = Object.entries(result.layout.rows).some(
			([code, row]) => code !== 'Space' && row.some((cell) => cell !== NONE)
		);
		if (!typing) fail('format_invalid', 'no key');
		return result;
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
			let doc;
			try {
				doc = tools.parseToml(text);
			} catch (error) {
				fail('format_invalid', `toml ${error.message}`);
			}
			return fromKalamineToml(doc);
		}
		if (extension === 'json' || extension === 'dof' || /^\s*\{/.test(text)) {
			let json;
			try {
				json = JSON.parse(text);
			} catch (error) {
				fail('format_invalid', `json ${error.message}`);
			}
			if (!json || typeof json !== 'object') fail('format_invalid', 'json');
			if (Array.isArray(json.keys)) return fromKla(json);
			if (json.keymap) return fromKalamineJson(json);
			return fromRows(json, name.replace(/\.[^.]+$/, ''));
		}
		if ((extension === 'txt' || extension === '') && isGenkey(text)) return fromGenkey(text);
		if (extension === 'txt') return fromRows(text, name.replace(/\.[^.]+$/, ''));
		return fail('format_unknown', name);
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
				values: { detail: String(error.detail) }
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
	 * (ISO) board, with the engine's standard fingering.
	 * @param {object} layout - The layout (library shape).
	 * @param {object} fingering - code → finger id (LAYOUT_ANALYSIS_DATA.model.fingerings.standard).
	 * @returns {object} The JSON object; dead keys cannot be written (KLA has none).
	 */
	function toKla(layout, fingering) {
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

	return {
		EXTENSIONS,
		XKB_KEYS,
		KLA_KEYS,
		ACCENTS,
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
		decode,
		read,
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
