// _shared/ui/layout_analysis/layout_formats.js

/**
 * ==============================================================================
 * MODULE: Layout File Formats
 * DESCRIPTION:
 * Reads the layout files people already have into the one layout shape the
 * analysis engine and the Studio use (what each physical key types on the
 * base, Shift, AltGr and Shift+AltGr layers, and the dead keys), writes that
 * shape back as an Ergopti layout source, a Keyboard Layout Analyzer JSON or a
 * Kalamine TOML. Every reader returns what it could not map instead of
 * guessing it. The formats are described in docs/design/layout-analysis.md.
 *
 * FEATURES & RATIONALE:
 * 1. Formats read: Keyboard Layout Analyzer JSON (KLA, KLAnext and their
 *    forks), Kalamine TOML and JSON (Ergo-L and its family), XKB symbols,
 *    Windows KLC, Oxeylyzer DOF, cmini JSON and plain rows of characters. A
 *    macOS .keylayout goes through the layout composer's reader, which the
 *    editor already loads.
 * 2. Dead keys of the standard accents compose by Unicode normalisation (the
 *    accent's combining mark after the letter, NFC), the same table XKB's
 *    Compose and Kalamine's built-in dead keys hold for those accents; any
 *    other dead key keeps only the compositions its file states.
 * 3. Pure: no DOM, no fetch; a Kalamine TOML is passed already parsed, so the
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
	// XKB and Kalamine key names of the keys a layout defines.
	const XKB_KEYS = (() => {
		const out = { TLDE: 'Backquote', BKSL: 'Backslash', LSGT: 'IntlBackslash', SPCE: 'Space' };
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
		return { standard, european, ergodox };
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
		const name = json.label || 'KLA layout';
		const result = start('kla', slug(name), name);
		const cellOf = (value) => {
			if (value === undefined || value === null || value === -1 || value === '') return NONE;
			if (typeof value === 'string') return value;
			if (typeof value === 'number' && value >= 32) return String.fromCodePoint(value);
			return NONE;
		};
		json.keys.forEach((key, index) => {
			const cells = ['primary', 'shift', 'altGr', 'shiftAltGr'].map((field) => cellOf(key[field]));
			if (cells.every((cell) => cell === NONE)) return;
			const code = board[index];
			if (!code) {
				result.unmapped.push({ what: 'key', detail: String(index) });
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
			const levels = /\[([^\]]*)\]/.exec(key[2]);
			if (!levels) continue;
			if (!code) {
				result.unmapped.push({ what: 'key', detail: key[1] });
				continue;
			}
			levels[1]
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
					let char = unicode ? String.fromCodePoint(parseInt(unicode[1], 16)) : KEYSYMS[sym];
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
		const decode = (value) => {
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
					const cell = decode(value);
					if (cell !== NONE) put(result, code, layer, cell);
				});
			} else if (section === 'DEADKEY' && words.length >= 2) {
				const typed = String.fromCharCode(parseInt(words[0], 16));
				result.layout.dead[deadChar][typed] = String.fromCharCode(parseInt(words[1], 16));
			} else if (section === 'LIGATURE')
				result.unmapped.push({ what: 'ligature', detail: words[0] });
		}
		if (states.length === 0) fail('format_invalid', 'SHIFTSTATE');
		return result;
	}

	/**
	 * Reads three rows of base characters: an Oxeylyzer DOF, a cmini JSON or
	 * plain text (one row per line, characters separated by spaces or not).
	 * @param {object|string} input - The parsed JSON, or the text.
	 * @param {string} [name] - A name when the input has none.
	 * @returns {object} {format, layout, unmapped}.
	 */
	function fromRows(input, name) {
		let rows;
		let format = 'rows';
		let label = name || 'Layout';
		if (typeof input === 'string') rows = input.split('\n').filter((l) => l.trim() !== '');
		else if (input && input.layers && Array.isArray(input.layers.main)) {
			rows = input.layers.main;
			format = 'dof';
			label = input.name || label;
		} else if (input && input.keys && !Array.isArray(input.keys)) {
			format = 'cmini';
			label = input.name || label;
			rows = [[], [], []];
			for (const [char, pos] of Object.entries(input.keys)) {
				if (!rows[pos.row]) continue;
				rows[pos.row][pos.col] = char;
			}
		} else fail('format_invalid', 'rows');
		const result = start(format, slug(label), label);
		rows.slice(0, ROW_CODES.length).forEach((row, r) => {
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
		if (input && input.fingering === 'angle') result.layout.fingering = 'angle';
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

	/**
	 * Recognises a file and reads it.
	 * @param {string} name - The file name.
	 * @param {string} text - Its text.
	 * @param {object} tools - parseToml (the TOML codec), scancodes
	 *   (LAYOUT_ANALYSIS_DATA.scancodes), and for a .keylayout composer, table,
	 *   analysis and convention.
	 * @returns {object} {format, layout, unmapped}.
	 * @throws {Error} With code format_unknown when nothing matches.
	 */
	function read(name, text, tools) {
		const extension = (name.split('.').pop() || '').toLowerCase();
		if (extension === 'keylayout' || /<keyboard\s/.test(text))
			return fromKeylayout(text, name.replace(/\.[^.]+$/, ''), tools.convention || 'iso', tools);
		if (extension === 'klc' || /^KBD\s/m.test(text)) return fromKlc(text, tools.scancodes);
		if (/xkb_symbols\s+"/.test(text)) return fromXkb(text);
		if (extension === 'toml' || extension === 'yaml') {
			if (!tools.parseToml) fail('format_unknown', name);
			return fromKalamineToml(tools.parseToml(text));
		}
		if (extension === 'json' || extension === 'dof' || /^\s*\{/.test(text)) {
			const json = JSON.parse(text);
			if (Array.isArray(json.keys)) return fromKla(json);
			if (json.keymap) return fromKalamineJson(json);
			return fromRows(json, name.replace(/\.[^.]+$/, ''));
		}
		if (extension === 'txt') return fromRows(text, name.replace(/\.[^.]+$/, ''));
		return fail('format_unknown', name);
	}

	// ==========================
	// ======= 4/ Writers =======
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

	return {
		XKB_KEYS,
		KLA_KEYS,
		ACCENTS,
		fromKla,
		fromKalamineJson,
		fromKalamineToml,
		fromXkb,
		fromKlc,
		fromRows,
		fromKeylayout,
		read,
		toSource,
		toKla,
		toKalamineToml
	};
})();

// Node (tests, tools) reads the module through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_FORMATS;
