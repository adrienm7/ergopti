// tools/build/import-xkb-layouts.cjs

/**
 * ==============================================================================
 * MODULE: XKB Layout Import
 * DESCRIPTION:
 * Re-encodes the Neo family (Neo 2, Bone, KOY, AdNW, Noted, Mine) and
 * Optimot 1.8.0 into the layout library of the layout analysis
 * (_shared/layouts/data/analysis/layout_library.json) from their official
 * files: xkeyboard-config's `symbols/de` (and the `latin`, `level3`,
 * `level5` and `shift` files the variants include), dl.neo-layout.org's
 * `mine_2.39` and XCompose, optimot.fr's Linux XKB and XCompose (in
 * Optimot_Linux_ISO_18.zip), the libX11 en_US.UTF-8 Compose table and
 * xorgproto's keysymdef.h, each pinned by its SHA-256.
 * USAGE: node tools/build/import-xkb-layouts.cjs <folder of the sources>
 *   [--check], the folder holding the files of SOURCE_FILES at their paths;
 *   then `node tools/lint/format.cjs --write` (the library) and
 *   `node tools/codegen/codegen-layout-analysis-data-js.cjs`. With --check it
 *   writes nothing and fails when the library differs from the files.
 *
 * FEATURES & RATIONALE:
 * 1. Every level: the seven levels a Neo key states (XKB levels 1 to 7:
 *    none, Shift, Mod3, Shift+Mod3, Mod4, Shift+Mod4, Mod3+Mod4) become the
 *    layout's own levels (docs/design/layout-analysis.md, « Levels »), the
 *    Mod3 and Mod4 keys read from the variant's includes (ISO_Level3_Shift,
 *    ISO_Level5_Shift), each held by the other hand when the board has it.
 *    Optimot keeps the four default levels (AltGr on AltRight); its fifth
 *    and sixth XKB levels are its Ctrl shortcuts, which no level measures.
 * 2. XKB as xkbcomp merges it: an include, then the keys over it, a
 *    NoSymbol level keeping the included one and VoidSymbol clearing it.
 * 3. Compose as xkbcommon builds it: the libX11 table first, then the
 *    layout's file over it (a user's ~/.XCompose that includes %L, as
 *    Optimot's first line does); a later sequence
 *    that passes through an earlier one's end replaces it, one that ends
 *    where a longer one passes is skipped. Sequences of any length that start
 *    with a dead key of the layout become its dead-key rules; a dead key or
 *    character in the middle enters a state of its own (« acute>circumflex »).
 * 4. Only what the layout types: a rule reads a character the layout has on
 *    a key, or one of its dead keys; a standard accent's rules that Unicode
 *    normalisation gives anyway are left to the codegen (composeAccent).
 * 5. Only the arrangement is kept, never a file (docs/memory/
 *    maintainer-decisions.md, « Layout library »).
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { shared } = require('../lib/paths.cjs');

const LIBRARY_PATH = shared('layouts', 'data', 'analysis', 'layout_library.json');
const FORMATS_PATH = shared('ui', 'layout_analysis', 'layout_formats.js');
const MODEL_PATH = shared('layouts', 'data', 'analysis', 'analysis_model.json');

// Each source file, at its path in the folder, and its SHA-256.
const SOURCE_FILES = {
	// xkeyboard-config f4d3ed8bb830e4b695408fe1df5b3cb038b97926, symbols/.
	'symbols/de': '6a67c83d10e13651d15028d5b64ff55af48d486ff0cca6bc92dccdd70f647d65',
	'symbols/level3': 'cdeddada22f8593f89cb8693d728dc02a24abef92d62cf0ce61c4f947b6d47d0',
	'symbols/level5': '8009418071d2bc55d0f5d38522fc9552a910af4e930945b261a7cdfc2ea7e750',
	'symbols/shift': 'f78597c70f29261bf49c2254e36e9d11718cc0c3665fb47bf0218d9761ed1605',
	// https://dl.neo-layout.org/mine_2.39 (its symbols file « mine »).
	'mine_2.39': '26fdffb463b375c01b9d128eb51cbc5a7eaaab82fd948d6604599ed6204f2641',
	// libX11 bf893321, nls/en_US.UTF-8/Compose.pre.
	'Compose.pre': 'cba1921a6b927218a9d4c2888454ec4970ce976842ba7a6a1dc018220bf55ac0',
	// https://dl.neo-layout.org/XCompose.
	XCompose: '445facbeb1b88dbea735f87673332b62cc5ab432c5819963cf0972a9228378a9',
	// xorgproto-2024.1, include/X11/keysymdef.h.
	'keysymdef.h': '4ba0724695c817a08b4ea3a79c5e8a52e0798cc8d5906281b10f89dc6225208d',
	'symbols/latin': '442253255e7aade71aab3caf325041cd2242d248ce856252e7eb364fef30b91b',
	// https://optimot.fr/downloads/Optimot_1.8/linux/Optimot_Linux_ISO_18.zip
	// (CC BY-NC-SA 4.0, Patrick Jamet: read, never redistributed).
	'optimot/Optimot_Linux_ISO_18 [ISO].xkb':
		'a6a395fc7d2e18d5b4112816a99f54fcdd7ce5ef19d0f0151bc85c42d26d03ef',
	'optimot/Optimot_Linux_ISO_18.XCompose':
		'e428fb9716e3f576842a143923f0191647505dd03e0059998e50ac625932b084'
};
// The XKB file each include name reads.
const SYMBOL_FILES = {
	de: 'symbols/de',
	level3: 'symbols/level3',
	level5: 'symbols/level5',
	shift: 'symbols/shift',
	latin: 'symbols/latin',
	mine: 'mine_2.39',
	optimot: 'optimot/Optimot_Linux_ISO_18 [ISO].xkb'
};
const NEO_COMPOSE = 'XCompose';
// The layouts re-encoded: library id, XKB file and variant, levels (SHAPES)
// and the Compose file over libX11's.
const LAYOUTS = [
	{ id: 'neo2_new', file: 'de', variant: 'neo', shape: 'neo', compose: NEO_COMPOSE },
	{ id: 'bone', file: 'de', variant: 'bone', shape: 'neo', compose: NEO_COMPOSE },
	{
		id: 'bone_eszett_home',
		file: 'de',
		variant: 'bone_eszett_home',
		shape: 'neo',
		compose: NEO_COMPOSE
	},
	{ id: 'koy', file: 'de', variant: 'koy', shape: 'neo', compose: NEO_COMPOSE },
	{ id: 'adnw', file: 'de', variant: 'adnw', shape: 'neo', compose: NEO_COMPOSE },
	{ id: 'noted', file: 'de', variant: 'noted', shape: 'neo', compose: NEO_COMPOSE },
	{ id: 'mine', file: 'mine', variant: 'mine', shape: 'neo', compose: NEO_COMPOSE },
	{
		id: 'optimot',
		file: 'optimot',
		variant: 'optimot_iso_18',
		shape: 'altgr',
		compose: 'optimot/Optimot_Linux_ISO_18.XCompose'
	}
];
// The Neo levels kept, XKB levels 1 to 7 (the eighth holds no character).
const NEO_LEVELS = [
	{ id: 'base' },
	{ id: 'shift', shift: true },
	{ id: 'mod3', hold: ['mod3'] },
	{ id: 'shift_mod3', shift: true, hold: ['mod3'] },
	{ id: 'mod4', hold: ['mod4'] },
	{ id: 'shift_mod4', shift: true, hold: ['mod4'] },
	{ id: 'mod3_mod4', hold: ['mod3', 'mod4'] }
];
const XKB_LEVELS = 8;
const DEFAULT_LEVELS = 4;
// Each shape: the levels it declares (none: the default four, AltGr on
// AltRight) and what the XKB levels after them hold.
const SHAPES = {
	// A character there is a level the import does not know: it fails.
	neo: { levels: NEO_LEVELS, beyond: null },
	// Optimot's « FOUR_LEVEL_CONTROL » types: its Ctrl shortcut letters.
	altgr: { levels: null, beyond: 'ctrl' }
};
// The keysym on a key that holds each modifier (xkeyboard-config's level3 and level5).
const MODIFIER_KEYSYMS = { ISO_Level3_Shift: 'mod3', ISO_Level5_Shift: 'mod4' };
const MODIFIER_LABELS = { mod3: 'Mod3', mod4: 'Mod4' };
// The XKB names of the held keys that are no typing key of the readers.
const HELD_XKB_KEYS = { CAPS: 'CapsLock', RALT: 'AltRight' };
// The keysym of a Unicode character is its code point plus this (keysymdef.h).
const UNICODE_KEYSYM = 0x01000000;
const DEAD = 'dead_';
const DEAD_TYPED = 'dead:';
// A derived state's name: its dead key's state, then each key after it.
const STATE_STEP = '>';

// ==========================
// ======= 1/ Sources =======
// ==========================

/**
 * Reads every source file, checked against its pin.
 * @param {string} dir - The folder of the sources.
 * @returns {Map<string, string>} Path → text.
 * @throws {Error} On a missing file or another hash.
 */
function readSources(dir) {
	const out = new Map();
	for (const [file, pin] of Object.entries(SOURCE_FILES)) {
		const at = path.join(dir, file);
		if (!fs.existsSync(at)) throw new Error(`import-xkb-layouts: ${at} is missing`);
		const bytes = fs.readFileSync(at);
		const hash = crypto.createHash('sha256').update(bytes).digest('hex');
		if (hash !== pin) throw new Error(`import-xkb-layouts: ${file} is ${hash}, pinned ${pin}`);
		out.set(file, bytes.toString('utf8'));
	}
	return out;
}

/**
 * Every keysym name of keysymdef.h: its value, and the character it types
 * (its U+ comment, or its value's: an alias states none, « deprecated alias
 * for guillemetright »), null for a function key or a control character.
 * @param {string} text - keysymdef.h.
 * @returns {Map<string, {value: number, char: string|null}>} Name (without XK_) → keysym.
 */
function keysymTable(text) {
	const define =
		/^#define XK_(\w+)\s+0x([0-9a-fA-F]+)\s*(?:\/\*\s*[<(]?\s*U\+([0-9A-Fa-f]{4,6}))?/gm;
	const values = new Map();
	const points = new Map();
	for (const match of text.matchAll(define)) {
		const value = parseInt(match[2], 16);
		values.set(match[1], value);
		if (match[3] && !points.has(value)) points.set(value, parseInt(match[3], 16));
	}
	const table = new Map();
	for (const [name, value] of values) {
		let point = points.has(value) ? points.get(value) : -1;
		// Latin-1 keysyms are their code point, Unicode ones UNICODE_KEYSYM above it.
		if (point < 0 && ((value >= 0x20 && value <= 0x7e) || (value >= 0xa0 && value <= 0xff)))
			point = value;
		if (point < 0 && value > UNICODE_KEYSYM) point = value - UNICODE_KEYSYM;
		// Tab, BackSpace, Return, Escape, Delete type control characters.
		table.set(name, {
			value,
			char: point >= 0x20 && point !== 0x7f ? String.fromCodePoint(point) : null
		});
	}
	return table;
}

/**
 * A keysym name read: its value (a Compose sequence matches a key by it) and
 * what it types.
 * @returns {{value: number|string, typed: string|null|{dead: string}}|null}
 *   typed is a character, null (none) or a dead key; null for a name
 *   keysymdef.h does not define.
 */
function keysymOf(sym, keysyms) {
	if (sym.startsWith(DEAD)) return { value: sym, typed: { dead: sym.slice(DEAD.length) } };
	const unicode = /^U([0-9A-Fa-f]{4,6})$/.exec(sym);
	if (unicode) {
		const point = parseInt(unicode[1], 16);
		return { value: UNICODE_KEYSYM + point, typed: String.fromCodePoint(point) };
	}
	const known = keysyms.get(sym);
	return known ? { value: known.value, typed: known.char } : null;
}

// ======================
// ======= 2/ XKB =======
// ======================

/** The text without its // and block comments. */
const withoutComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');

/**
 * The sections of an XKB symbols file: name → body, and the default one.
 * @param {string} text - The file.
 * @returns {{sections: Map<string, string>, first: string}}
 */
function symbolSections(text) {
	const clean = withoutComments(text);
	const sections = new Map();
	let first = null;
	let preferred = null;
	for (const head of clean.matchAll(/([\w\s]*)xkb_symbols\s+"([^"]+)"\s*\{/g)) {
		let depth = 1;
		let at = head.index + head[0].length;
		const start = at;
		while (depth > 0 && at < clean.length) {
			if (clean[at] === '{') depth++;
			else if (clean[at] === '}') depth--;
			at++;
		}
		sections.set(head[2], clean.slice(start, at - 1));
		if (first === null) first = head[2];
		if (preferred === null && /\bdefault\b/.test(head[1])) preferred = head[2];
	}
	// The section an include without one reads: the default, else the first.
	return { sections, first: preferred || first };
}

/**
 * The keysyms of a key statement's body: its first symbol list.
 * @param {string} body - Between the key's braces.
 * @returns {string[]|null}
 */
function keyLevels(body) {
	for (const bracket of body.matchAll(/\[([^\]]*)\]/g)) {
		const before = body.slice(0, bracket.index);
		if (/\w\s*$/.test(before)) continue;
		const statement = before.slice(before.lastIndexOf(',') + 1);
		if (/^\s*\{?\s*$/.test(statement) || /^\s*symbols\s*\[\s*group1\s*\]\s*=\s*$/i.test(statement))
			return bracket[1].split(',').map((sym) => sym.trim());
	}
	return null;
}

/**
 * The keys of a variant as xkbcomp merges them: each include, then each key
 * over what came before (a NoSymbol level keeps the earlier symbol).
 * @param {Map<string, string>} texts - The sources.
 * @param {string} file - An include file name (SYMBOL_FILES).
 * @param {string|null} variant - Its section, or null for its default.
 * @returns {Map<string, string[]>} XKB key name → keysyms by level.
 */
function resolveVariant(texts, file, variant) {
	if (!SYMBOL_FILES[file]) throw new Error(`import-xkb-layouts: no source for the include ${file}`);
	const { sections, first } = symbolSections(texts.get(SYMBOL_FILES[file]));
	const name = variant || first;
	if (!sections.has(name)) throw new Error(`import-xkb-layouts: ${file} has no section ${name}`);
	const keys = new Map();
	const merge = (key, syms) => {
		const before = keys.get(key) || [];
		const out = [];
		for (let i = 0; i < Math.max(before.length, syms.length); i++)
			out.push(syms[i] === undefined || syms[i] === 'NoSymbol' ? before[i] || 'NoSymbol' : syms[i]);
		keys.set(key, out);
	};
	const statement = /include\s+"([^"]+)"|key\s+<(\w+)>\s*\{([^}]*)\}/g;
	for (const match of sections.get(name).matchAll(statement)) {
		if (match[1] !== undefined) {
			for (const part of match[1].split(/[+|]/)) {
				const include = /^(\w+)(?:\((\w+)\))?$/.exec(part.trim());
				if (!include) throw new Error(`import-xkb-layouts: unreadable include ${part}`);
				for (const [key, syms] of resolveVariant(texts, include[1], include[2] || null))
					merge(key, syms);
			}
			continue;
		}
		const syms = keyLevels(match[3]);
		if (syms !== null) merge(match[2], syms);
	}
	return keys;
}

// ==========================
// ======= 3/ Compose =======
// ==========================

/**
 * Unescapes a Compose output string.
 * @throws {Error} On an escape this reader does not know.
 */
function composeString(raw) {
	return raw.replace(/\\(.)/g, (whole, char) => {
		if (char === '"' || char === '\\') return char;
		throw new Error(`import-xkb-layouts: unknown escape ${whole} in a Compose output`);
	});
}

/**
 * The Compose tree of the dead-key sequences, files in order (xkbcommon's
 * rules: a sequence through an earlier one's end replaces it, one ending
 * where a longer one passes is skipped).
 * @param {string[]} texts - The Compose files, the overriding one last.
 * @returns {Map<string, object>} First keysym → node {output?, next?: Map}.
 */
function composeTree(texts) {
	const root = new Map();
	const line = /^((?:\s*<[^>]+>)+)\s*:\s*"((?:[^"\\]|\\.)*)"/;
	for (const text of texts)
		for (const raw of text.split('\n')) {
			const match = line.exec(raw);
			if (!match) continue;
			const keys = Array.from(match[1].matchAll(/<([^>]+)>/g), (key) => key[1]);
			if (!keys[0].startsWith(DEAD)) continue;
			let level = root;
			for (let i = 0; i < keys.length - 1; i++) {
				let node = level.get(keys[i]);
				if (!node || node.output !== undefined) level.set(keys[i], (node = { next: new Map() }));
				level = node.next;
			}
			const last = keys[keys.length - 1];
			const node = level.get(last);
			if (!(node && node.next)) level.set(last, { output: composeString(match[2]) });
		}
	return root;
}

// ===========================
// ======= 4/ Encoding =======
// ===========================

/**
 * One layout of the Neo family in the library shape: rows of its seven
 * levels, its Mod3 and Mod4 keys, its dead keys and their rules.
 * @returns {object} {rows, levels, modifiers, dead_rules}.
 * @throws {Error} On an unknown keysym, a character on the eighth level, or
 *   a modifier that is not on one key of each hand.
 */
function encode(layout, ctx) {
	const shape = SHAPES[layout.shape];
	const width = shape.levels ? shape.levels.length : DEFAULT_LEVELS;
	const keys = resolveVariant(ctx.texts, layout.file, layout.variant);
	const rows = {};
	const holders = { mod3: [], mod4: [] };
	// The lowest level each keysym value is typed on (a Compose sequence reads keysyms).
	const lowest = new Map();
	for (const [xkb, syms] of keys) {
		const held = MODIFIER_KEYSYMS[syms[0]];
		const code = ctx.codes[xkb] || HELD_XKB_KEYS[xkb];
		if (held) {
			if (!code) throw new Error(`import-xkb-layouts: ${layout.id} holds ${held} on ${xkb}`);
			holders[held].push(code);
			continue;
		}
		if (!ctx.codes[xkb] || !ctx.typing.has(ctx.codes[xkb])) continue;
		const cells = [];
		for (let level = 0; level < XKB_LEVELS; level++) {
			const sym = syms[level];
			if (sym === undefined || sym === 'NoSymbol' || sym === 'VoidSymbol') {
				if (level < width) cells.push(null);
				continue;
			}
			if (level >= width && shape.beyond !== null) continue;
			const keysym = keysymOf(sym, ctx.keysyms);
			if (!keysym)
				throw new Error(`import-xkb-layouts: ${layout.id} ${xkb} has the unknown keysym ${sym}`);
			if (level >= width) {
				if (keysym.typed !== null)
					throw new Error(`import-xkb-layouts: ${layout.id} ${xkb} types on level ${level + 1}`);
				continue;
			}
			cells.push(keysym.typed);
			if (keysym.typed !== null && !(lowest.get(keysym.value) <= level))
				lowest.set(keysym.value, level);
		}
		if (cells.some((cell) => cell !== null)) rows[ctx.codes[xkb]] = cells;
	}
	const tree = ctx.tree(layout.compose);
	if (!shape.levels) {
		// The default levels: AltGr on the model's key, nothing on a Mod4 key.
		if (holders.mod4.length > 0 || holders.mod3.join() !== ctx.model.modifier_keys.altgr)
			throw new Error(`import-xkb-layouts: ${layout.id} holds its third level off AltGr`);
		return { rows, dead_rules: deadRules(rows, lowest, tree, ctx) };
	}
	const modifiers = {};
	for (const [name, codes] of Object.entries(holders)) {
		const left = codes.filter((code) => ctx.model.fingerings.standard[code].startsWith('l'));
		const right = codes.filter((code) => !ctx.model.fingerings.standard[code].startsWith('l'));
		if (left.length !== 1 || right.length !== 1)
			throw new Error(`import-xkb-layouts: ${layout.id} ${name} is not on one key of each hand`);
		// A key of the left hand holds the modifier with the right hand, then the left.
		modifiers[name] = {
			label: MODIFIER_LABELS[name],
			for_left_hand: [right[0], left[0]],
			for_right_hand: [left[0], right[0]]
		};
	}
	return { rows, levels: shape.levels, modifiers, dead_rules: deadRules(rows, lowest, tree, ctx) };
}

/**
 * The rules of a layout's dead keys from the Compose tree. A sequence reads
 * keysyms, so a typed key is a keysym of the layout; when two of them type
 * one character (plus and KP_Add), the one on the lower level decides, as
 * the engine keys a rule by the character. A sequence that goes on enters a
 * derived state. A standard accent's rule that Unicode normalisation gives
 * is left out (the codegen composes it).
 * @param {object} rows - The layout's rows.
 * @param {Map<number|string, number>} lowest - Keysym value → lowest level.
 * @param {Map<string, object>} tree - The layout's Compose tree (composeTree).
 * @param {object} ctx - The import context.
 * @returns {object} State → typed → output | {dead: state}.
 */
function deadRules(rows, lowest, tree, ctx) {
	const chars = new Set();
	const states = new Set();
	for (const row of Object.values(rows))
		for (const cell of row) {
			if (typeof cell === 'string' && Array.from(cell).length === 1) chars.add(cell);
			else if (cell && cell.dead) states.add(cell.dead);
		}
	const out = {};
	const walk = (state, node) => {
		const rules = {};
		const level = {};
		for (const [sym, child] of node.next) {
			const keysym = keysymOf(sym, ctx.keysyms);
			if (!keysym || keysym.typed === null || !lowest.has(keysym.value)) continue;
			const typed =
				typeof keysym.typed === 'string' ? keysym.typed : DEAD_TYPED + keysym.typed.dead;
			if (typeof keysym.typed === 'string' && !chars.has(typed)) continue;
			if (level[typed] <= lowest.get(keysym.value)) continue;
			let rule = child.output;
			if (rule === undefined) {
				const step = typed.startsWith(DEAD_TYPED) ? typed.slice(DEAD_TYPED.length) : typed;
				const next = `${state}${STATE_STEP}${step}`;
				rule = walk(next, child) ? { dead: next } : '';
			}
			if (rule === '') continue;
			rules[typed] = rule;
			level[typed] = lowest.get(keysym.value);
		}
		const kept =
			!state.includes(STATE_STEP) && ctx.accents[state]
				? normalised(state, rules, chars, ctx)
				: rules;
		if (Object.keys(kept).length === 0) return false;
		out[state] = kept;
		return true;
	};
	for (const state of [...states].sort()) {
		const node = tree.get(DEAD + state);
		if (node && node.next) walk(state, node);
	}
	return out;
}

/**
 * A standard accent's rules without those the codegen's composeAccent gives:
 * a character composed with the accent's mark by NFC, and its sign alone
 * after the space.
 */
function normalised(state, rules, chars, ctx) {
	const mark = ctx.accents[state];
	const kept = {};
	for (const [typed, output] of Object.entries(rules)) {
		if (typeof output === 'string' && chars.has(typed)) {
			const composed = (typed + mark).normalize('NFC');
			if (Array.from(composed).length === 1 && composed === output) continue;
		}
		if (typed === ' ' && output === ctx.alone(state)) continue;
		kept[typed] = output;
	}
	return kept;
}

// ======================
// ======= 5/ Main ======
// ======================

/**
 * What encode reads: the sources, the model, the readers' key names and
 * accents, the keysyms and each Compose tree.
 * @param {string} dir - The folder of the sources.
 * @returns {object} The import context.
 */
function importContext(dir) {
	const texts = readSources(dir);
	const sandbox = {};
	vm.createContext(sandbox);
	vm.runInContext(fs.readFileSync(FORMATS_PATH, 'utf8'), sandbox, { filename: FORMATS_PATH });
	const formats = vm.runInContext('LAYOUT_FORMATS', sandbox);
	const model = JSON.parse(fs.readFileSync(MODEL_PATH, 'utf8'));
	const trees = new Map();
	const ctx = {
		texts,
		model,
		codes: formats.XKB_KEYS,
		typing: new Set(Object.keys(model.fingerings.standard)),
		keysyms: keysymTable(texts.get('keysymdef.h')),
		// libX11's table, then the layout's file over it.
		tree: (file) => {
			if (!trees.has(file))
				trees.set(file, composeTree([texts.get('Compose.pre'), texts.get(file)]));
			return trees.get(file);
		},
		accents: formats.ACCENTS,
		// The sign a standard accent types after the space, as composeAccent writes it.
		alone: (accent) => formats.composeAccent({ rows: {}, dead: {} }, accent, accent)[' ']
	};
	return ctx;
}

/**
 * Re-encodes the layouts, or checks the library holds them.
 * @param {string} dir - The folder of the sources.
 * @param {boolean} check - Write nothing; fail on a difference.
 */
function main(dir, check) {
	if (!dir)
		throw new Error(
			'usage: node tools/build/import-xkb-layouts.cjs <folder of the sources> [--check]'
		);
	const ctx = importContext(dir);
	const library = JSON.parse(fs.readFileSync(LIBRARY_PATH, 'utf8'));
	const differing = [];
	for (const layout of LAYOUTS) {
		const entry = library.layouts.find((candidate) => candidate.id === layout.id);
		if (!entry) throw new Error(`import-xkb-layouts: the library has no ${layout.id}`);
		const fresh = encode(layout, ctx);
		const before = JSON.stringify([entry.rows, entry.levels, entry.modifiers, entry.dead_rules]);
		if (before !== JSON.stringify([fresh.rows, fresh.levels, fresh.modifiers, fresh.dead_rules]))
			differing.push(layout.id);
		for (const field of ['rows', 'levels', 'modifiers', 'dead_rules']) delete entry[field];
		Object.assign(entry, fresh);
	}
	if (check) {
		if (differing.length > 0)
			throw new Error(
				`import-xkb-layouts: the library differs from the files for ${differing.join(', ')}`
			);
		console.log(`import-xkb-layouts — ${LAYOUTS.length} layouts as their files`);
		return;
	}
	fs.writeFileSync(LIBRARY_PATH, `${JSON.stringify(library, null, '\t')}\n`);
	console.log(
		`import-xkb-layouts — ${LAYOUTS.length} layouts written (${differing.length} changed)`
	);
}

if (require.main === module) {
	const args = process.argv.slice(2);
	main(
		args.find((arg) => !arg.startsWith('--')),
		args.includes('--check')
	);
}

module.exports = { LAYOUTS, importContext, encode };
