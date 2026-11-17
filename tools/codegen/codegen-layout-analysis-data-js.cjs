// tools/codegen/codegen-layout-analysis-data-js.cjs

/**
 * ==============================================================================
 * MODULE: Layout Analysis Data Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/layout_analysis/_generated/analysis_data.js`, every
 * datum the layout analysis engine reads, from:
 *   - _shared/layouts/data/analysis/analysis_model.json (fingers, keyboards…);
 *   - _shared/layouts/data/analysis/score_weights.json (default weights);
 *   - _shared/layouts/data/analysis/layout_library.json (alphabetic blocks
 *     and whole layouts);
 *   - _shared/layouts/data/analysis/sources.json (the « i » references);
 *   - _shared/layouts/data/analysis/corpora.json and static/corpus/register.json
 *     (the built-in corpora and the licence of every corpus text);
 *   - _shared/layouts/data/analysis/analyser_models.json (the constants of the
 *     scorers that reproduce other analysers, analyser_scores.js);
 *   - _shared/layouts/data/keycodes/physical_keys.json (key geometry);
 *   - the registry layouts and the reference QWERTY and AZERTY, read through
 *     the layout composer model (tools/lib/layout-composer.cjs).
 *
 * FEATURES & RATIONALE:
 * 1. Classic script: `_shared/ui/*` pages load plain `<script src>` tags and
 *    the hosts inline them, so the data is a top-level const, not a fetch.
 * 2. One library for the site and the app: registry layouts keep all their
 *    layers and dead keys; an alphabetic block of the library JSON gets the US
 *    number row and the US Shift pairs, the convention of its source; a whole
 *    layout of the library JSON (KLA's) is taken as it is.
 * 3. Deterministic: no timestamp, keys in a fixed order.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { REPO_ROOT, shared, sharedRel } = require('../lib/paths.cjs');
const { loadComposer, REGISTRY_DIR } = require('../lib/layout-composer.cjs');
const { parse: parseToml } = require('smol-toml');

const OUT_PATH = shared('ui', 'layout_analysis', '_generated', 'analysis_data.js');
const MODEL_PATH = shared('layouts', 'data', 'analysis', 'analysis_model.json');
const WEIGHTS_PATH = shared('layouts', 'data', 'analysis', 'score_weights.json');
const LIBRARY_PATH = shared('layouts', 'data', 'analysis', 'layout_library.json');
const CORPORA_PATH = shared('layouts', 'data', 'analysis', 'corpora.json');
// The licence register of every text under static/corpus/original.
const CORPUS_DIR = path.join(REPO_ROOT, 'static', 'corpus');
const CORPUS_REGISTER_PATH = path.join(CORPUS_DIR, 'register.json');
const SHIP_STATUS = 'ship';
const REGISTER_STATUSES = ['ship', 'hold', 'refused'];
// The folders of static/corpus the register covers: texts, and word frequency lists.
const CORPUS_FOLDERS = ['original', 'frequency'];
const CORPUS_FORMATS = ['text', 'word_frequencies', 'tsv', 'count_table'];
// How a count table was counted: as running text, or by the word-list rule.
const COUNTED_AS = ['text', 'word_list'];
// The count-table file (static/corpus/frequency/<source>/<id>.json) a large corpus
// ships instead of its text: tools/build/import-count-tables.cjs writes it.
const COUNT_TABLE_FORMAT = 'ergopti-count-table';
// Version 2 adds the word table (words): its most frequent words.
const COUNT_TABLE_VERSION = 2;
// The most words a count table's word table keeps: the engine's WORD_TABLE_SIZE
// (tools/test/test-corpus-count-tables.cjs checks they agree).
const COUNT_TABLE_MAX_WORDS = 1000;
// A word of a word table, as the engine's countWords keeps it: two or more
// letters or combining marks, folded to lower case.
const COUNT_TABLE_WORD = /^[\p{L}\p{M}]{2,}$/u;
// The i18n key family of a corpus's localized name (corpora.json title_key).
const CORPUS_TITLE_KEY_PREFIX = 'layout_analysis.corpus.name.';
const CREDITS_PATH = shared('layouts', 'data', 'analysis', 'layout_credits.json');
const INFO_SOURCES_PATH = shared('layouts', 'data', 'analysis', 'sources.json');
// The repository and the host a repository document is linked on (one source each).
const REPOSITORY_DEFAULTS_PATH = shared('updater', 'data', 'defaults.json');
const IDENTIFIERS_PATH = shared('core', 'text', 'data', 'identifiers.json');
const BOARDS_PATH = shared('layouts', 'data', 'analysis', 'board_geometries.json');
// The values the « i » popovers explain besides the metrics.
const INFO_VALUES = ['ideal_finger_load', 'shortcut_letters', 'weights', 'fingering'];
// The ideal finger load per hand, pinky to index (maintainer 2026-11-14).
const HAND_FINGERS = [
	['lp', 'lr', 'lm', 'li'],
	['rp', 'rr', 'rm', 'ri']
];
const HAND_SHARE = 50;
const MAX_PINKY_SHARE = 8;
const ANALYSERS_PATH = shared('layouts', 'data', 'analysis', 'analyser_models.json');
// The text patterns the Windows antivirus-surface gate refuses in the shipped
// bundle (tools/ci/windows-exe-av-surface.cjs reads the same file).
const AV_POLICY_PATH = path.join(REPO_ROOT, 'tools', 'ci', 'windows-exe-av-surface.json');
// The Windows suite's shared-purity scanner, which refuses OS calls such as
// `hs.` in _shared JS; its pattern list is read from the test itself.
// Floor: a parse that lost the list must not read as « nothing forbidden ».
const MIN_PURITY_PATTERNS = 5;
const PURITY_TEST_PATH = path.join(
	REPO_ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'tests',
	'meta',
	'platform',
	'system',
	'test_port_adapter_coverage.ahk'
);
const CORPUS_OUT_DIR = shared('ui', 'layout_analysis', '_generated');
const ENGINE_PATH = shared('ui', 'layout_analysis', 'analysis_engine.js');
const PHYSICAL_KEYS_PATH = shared('layouts', 'data', 'keycodes', 'physical_keys.json');
const SOURCES = [
	'layouts/data/analysis/analysis_model.json',
	'layouts/data/analysis/score_weights.json',
	'layouts/data/analysis/layout_library.json',
	'layouts/data/analysis/corpora.json',
	'layouts/data/analysis/layout_credits.json',
	'layouts/data/analysis/sources.json',
	'layouts/data/analysis/board_geometries.json',
	'static/corpus/register.json',
	'layouts/data/analysis/analyser_models.json',
	'layouts/data/keycodes/physical_keys.json',
	'../../layouts/registry (through layout_composer)'
];

// The Shift character of an unshifted US symbol, the convention of the
// alphabetic blocks the library imports.
const US_SHIFT = {
	',': '<',
	'.': '>',
	'/': '?',
	';': ':',
	"'": '"',
	'[': '{',
	']': '}',
	'\\': '|',
	'-': '_',
	'=': '+',
	'`': '~'
};
const NUMBER_ROW = [
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
// The keys an alphabetic block leaves to QWERTY, in the order the characters
// it displaced take their free cells.
const OUTER_KEYS = ['Quote', 'BracketLeft', 'BracketRight', 'Backslash', 'IntlBackslash'];
const REGISTRY_ORIGIN = 'registry';
const REFERENCE_ORIGIN = 'reference';
const LIBRARY_ORIGIN = 'library';
// The levels of a whole layout's row: base, Shift, AltGr, Shift+AltGr.
const LIBRARY_LEVELS = 4;

// ======================
// ======= 1/ Keys ======
// ======================

/**
 * The centre of each finger-assigned key on the ISO and ANSI boards.
 * @param {object} model - analysis_model.json.
 * @returns {object} code → {iso: {x, y, col, width}, ansi: {...}}.
 * @throws {Error} When a key has no geometry.
 */
function buildGeometry(model) {
	const physical = JSON.parse(fs.readFileSync(PHYSICAL_KEYS_PATH, 'utf8')).keys;
	const out = {};
	for (const code of Object.keys(model.fingerings.standard)) {
		const record = physical[code];
		if (!record || !record.geometry)
			throw new Error(`${code} has no geometry in physical_keys.json`);
		out[code] = {};
		for (const form of ['iso', 'ansi']) {
			const g = record.geometry[form];
			if (!g) continue;
			out[code][form] = { row: g.row, col: g.col, width: g.width };
		}
	}
	return out;
}

/**
 * The physical key of each Windows scan code (KLC files number keys by it),
 * for the keys the engine measures.
 * @param {object} model - analysis_model.json.
 * @returns {object} lower-case hex scan code → KeyboardEvent.code.
 */
function buildScancodes(model) {
	const physical = JSON.parse(fs.readFileSync(PHYSICAL_KEYS_PATH, 'utf8')).keys;
	const out = {};
	for (const code of Object.keys(model.fingerings.standard)) {
		const match = /^SC([0-9A-F]{3})$/.exec(physical[code].ahk);
		if (!match) throw new Error(`${code} has no scan code in physical_keys.json`);
		out[parseInt(match[1], 16).toString(16).padStart(2, '0')] = code;
	}
	return out;
}

// =========================
// ======= 2/ Layouts ======
// =========================

/**
 * The analysis engine, loaded as the classic script a page loads; only its
 * data-free converter is used here, so no data is defined yet.
 * @returns {object} LAYOUT_ANALYSIS.
 */
function loadEngine() {
	const sandbox = {};
	vm.createContext(sandbox);
	vm.runInContext(fs.readFileSync(ENGINE_PATH, 'utf8'), sandbox, { filename: ENGINE_PATH });
	return vm.runInContext('LAYOUT_ANALYSIS', sandbox);
}

/**
 * A registry or reference layout, with all its layers and dead keys, through
 * the engine's own converter.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @param {object} source - The composer source.
 * @param {string} origin - REGISTRY_ORIGIN or REFERENCE_ORIGIN.
 * @param {string[]} codes - The measured codes.
 * @param {string} name - The display name.
 * @returns {object} The library entry.
 */
function fromComposer(engine, source, origin, codes, name) {
	const layout = engine.layoutFromComposerSource(source, codes);
	return {
		id: layout.id,
		name,
		language: 'fr',
		origin,
		rows: layout.rows,
		command: layout.command,
		dead: layout.dead
	};
}

/**
 * An alphabetic block of the library JSON, completed with the US number row
 * and US Shift pairs.
 * @param {object} entry - One layout_library.json entry.
 * @param {object} qwerty - The reference QWERTY rows.
 * @returns {object} The library entry.
 */
function fromAlphaBlock(entry, qwerty) {
	const rows = {};
	const used = new Set(Object.values(entry.keys));
	for (const code of NUMBER_ROW) {
		const [base, shift] = qwerty[code];
		// A symbol the block moved to the letters leaves the number row.
		rows[code] = [used.has(base) ? null : base, used.has(shift) ? null : shift, null, null];
	}
	rows.Space = [' ', ' ', null, null];
	for (const [code, base] of Object.entries(entry.keys)) {
		const upper = base.toUpperCase();
		const shift = upper !== base ? upper : US_SHIFT[base] || null;
		rows[code] = [base, shift, null, null];
	}
	// The keys outside the block keep QWERTY's characters the block did not
	// place, then take the QWERTY characters the block displaced and placed
	// nowhere (Dvorak's / and ?), so a 30-key layout types what QWERTY types.
	const placed = new Set(
		Object.values(rows)
			.flat()
			.filter((cell) => cell !== null)
	);
	const outer = OUTER_KEYS.filter((code) => !rows[code] && qwerty[code]);
	for (const code of outer) {
		const [base, shift] = qwerty[code];
		rows[code] = [placed.has(base) ? null : base, placed.has(shift) ? null : shift, null, null];
		rows[code].forEach((cell) => cell !== null && placed.add(cell));
	}
	const missing = Object.values(qwerty)
		.flatMap((row) => row.slice(0, 2))
		.filter((cell) => typeof cell === 'string' && !placed.has(cell));
	// Free cells: the outer keys first, then the number-row cells the block
	// emptied, then the Shift cells the block left empty (Engram's " key).
	for (const code of outer.concat(NUMBER_ROW, Object.keys(entry.keys)))
		for (const level of [0, 1])
			if (rows[code][level] === null && missing.length > 0) rows[code][level] = missing.shift();
	// What finds no free cell stays out: the unsupported metric shows it.
	return {
		id: entry.id,
		name: entry.name,
		language: entry.language,
		origin: LIBRARY_ORIGIN,
		fingering: entry.fingering,
		source: entry.source,
		rows,
		command: {},
		dead: {}
	};
}

/**
 * A whole layout of the library JSON (every key and level its source states),
 * taken as it is: nothing is completed.
 * @param {object} entry - One layout_library.json entry with rows.
 * @param {string[]} codes - The measured codes.
 * @returns {object} The library entry.
 * @throws {Error} On a key the engine does not measure or a malformed row.
 */
function fromWholeRows(entry, codes) {
	const measured = new Set(codes);
	const rows = {};
	for (const [code, row] of Object.entries(entry.rows)) {
		if (!measured.has(code)) throw new Error(`${entry.id}: ${code} is not a measured key`);
		if (
			!Array.isArray(row) ||
			row.length !== LIBRARY_LEVELS ||
			!row.every((cell) => cell === null || (typeof cell === 'string' && cell !== ''))
		)
			throw new Error(`${entry.id}: ${code} is not ${LIBRARY_LEVELS} characters or null`);
		rows[code] = row.slice();
	}
	return {
		id: entry.id,
		name: entry.name,
		language: entry.language,
		origin: LIBRARY_ORIGIN,
		fingering: entry.fingering,
		source: entry.source,
		rows,
		command: {},
		dead: {}
	};
}

/**
 * Checks the files a collection import left out: each names its source and
 * reason, and a duplicate names a layout the library holds.
 * @param {object} library - layout_library.json.
 * @param {Set<string>} ids - The library ids.
 * @throws {Error} On a malformed entry or an unknown layout.
 */
function checkNotImported(library, ids) {
	for (const entry of library.not_imported || []) {
		if (!library.sources[entry.source] || !entry.source_path || !entry.reason)
			throw new Error(
				`not_imported: ${JSON.stringify(entry)} needs a known source, a path and a reason`
			);
		if (entry.same_as !== undefined && !ids.has(entry.same_as))
			throw new Error(
				`not_imported: ${entry.source_path} names ${entry.same_as}, not in the library`
			);
	}
}

/**
 * The whole library, registry layouts first.
 * @param {object} model - analysis_model.json.
 * @returns {object[]} The library entries.
 * @throws {Error} On a duplicate id.
 */
function buildLibrary(model) {
	const engine = loadEngine();
	const codes = engine.typingCodes(model);
	const composer = loadComposer();
	const out = [];
	for (const entry of composer.INDEX.layouts) {
		const layout = fromComposer(
			engine,
			composer.SOURCES[entry.id],
			REGISTRY_ORIGIN,
			codes,
			entry.name
		);
		// The board a registry layout is made for, and its family: the Comparer
		// ticks by default the variant of the chosen keyboard's geometry.
		layout.family = entry.family;
		if (entry.geometry) layout.geometry = entry.geometry;
		out.push(layout);
	}
	for (const id of Object.keys(composer.REFERENCE)) {
		const layout = fromComposer(
			engine,
			composer.SOURCES[id],
			REFERENCE_ORIGIN,
			codes,
			composer.REFERENCE[id].name
		);
		layout.language = id === 'qwerty' ? 'en' : 'fr';
		out.push(layout);
	}
	const library = JSON.parse(fs.readFileSync(LIBRARY_PATH, 'utf8'));
	for (const entry of library.layouts) {
		if ((entry.keys === undefined) === (entry.rows === undefined))
			throw new Error(`${entry.id}: a library entry has either keys or rows`);
		out.push(
			entry.rows
				? fromWholeRows(entry, codes)
				: fromAlphaBlock(entry, composer.REFERENCE.qwerty.rows)
		);
	}
	credit(out);
	checkNotImported(library, new Set(out.map((layout) => layout.id)));
	const seen = new Set();
	for (const layout of out) {
		if (seen.has(layout.id)) throw new Error(`duplicate layout id ${layout.id}`);
		seen.add(layout.id);
		if (!layout.fingering) layout.fingering = 'standard';
	}
	return out;
}

/**
 * Credits each layout: a registry layout from its meta.toml, another from
 * layout_credits.json, else the collection it was taken from.
 * @param {object[]} layouts - The library entries, completed in place.
 * @throws {Error} On a credit for a layout the library does not hold.
 */
function credit(layouts) {
	const credits = JSON.parse(fs.readFileSync(CREDITS_PATH, 'utf8')).credits;
	const ids = new Set(layouts.map((layout) => layout.id));
	for (const id of Object.keys(credits))
		if (!ids.has(id))
			throw new Error(`layout_credits.json credits ${id}, which the library does not hold`);
	for (const layout of layouts) {
		// A registry or reference layout comes from this repository.
		if (!layout.source) layout.source = layout.origin;
		if (layout.origin === REGISTRY_ORIGIN) {
			const meta = parseToml(
				fs.readFileSync(path.join(REGISTRY_DIR, layout.id, 'meta.toml'), 'utf8')
			);
			layout.authors = [meta.author];
			if (meta.homepage) layout.url = meta.homepage;
			if (meta.licence) layout.licence = meta.licence;
			layout.credit_basis = 'source';
			continue;
		}
		const entry = credits[layout.id];
		layout.authors = entry ? entry.authors : [];
		if (entry && entry.year) layout.year = entry.year;
		if (entry && entry.url) layout.url = entry.url;
		if (entry) layout.credit_basis = entry.basis;
	}
}

// =========================
// ======= 3/ Corpora ======
// =========================

const ACCENTS = {
	'^': { a: 'â', e: 'ê', i: 'î', o: 'ô', u: 'û', A: 'Â', E: 'Ê', I: 'Î', O: 'Ô', U: 'Û' },
	'¨': { a: 'ä', e: 'ë', i: 'ï', o: 'ö', u: 'ü', y: 'ÿ', A: 'Ä', E: 'Ë', I: 'Ï', O: 'Ö', U: 'Ü' }
};

/**
 * Turns the two-character spellings of the old KLA conversion (^e, ¨i) back
 * into the accented letter they stand for.
 * @param {string} text - The corpus.
 * @returns {string} The text with its accented letters.
 */
function restoreDeadKeyPairs(text) {
	return text.replace(/([\^¨])([A-Za-z])/g, (pair, mark, letter) => ACCENTS[mark][letter] || pair);
}

/**
 * The licence register, checked against the texts on disk.
 * @returns {object} relative path → entry.
 * @throws {Error} On a text with no entry, an entry with no text, an unknown
 *   status, or a shippable entry without licence or attribution.
 */
function corpusRegister() {
	const register = JSON.parse(fs.readFileSync(CORPUS_REGISTER_PATH, 'utf8')).files;
	const onDisk = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) walk(full);
			else onDisk.push(path.relative(CORPUS_DIR, full).split(path.sep).join('/'));
		}
	};
	for (const folder of CORPUS_FOLDERS) walk(path.join(CORPUS_DIR, folder));
	for (const file of onDisk)
		if (!register[file])
			throw new Error(
				`static/corpus/register.json: no entry for ${file} (record its source and licence)`
			);
	for (const [file, entry] of Object.entries(register)) {
		if (!onDisk.includes(file))
			throw new Error(`static/corpus/register.json: ${file} does not exist`);
		if (!REGISTER_STATUSES.includes(entry.status))
			throw new Error(`static/corpus/register.json: ${file} has status ${entry.status}`);
		if (entry.status === SHIP_STATUS && (!entry.licence || !entry.attribution || !entry.source))
			throw new Error(
				`static/corpus/register.json: ${file} ships without licence, attribution or source`
			);
	}
	return register;
}

/**
 * The n-gram counts of a word frequency list (« word count » per line): each
 * word counts its letters and one space, and its bigrams and trigrams with a
 * space on either side, as often as the list says.
 * @param {string} text - The list.
 * @param {string} id - The corpus id, for errors.
 * @returns {{chars: object, bigrams: object, trigrams: object}} Counts.
 * @throws {Error} On a line that is not a word and a positive count.
 */
function wordListCounts(text, id) {
	const chars = {};
	const bigrams = {};
	const trigrams = {};
	const add = (table, key, n) => {
		table[key] = (table[key] || 0) + n;
	};
	text.split('\n').forEach((line, index) => {
		if (line.trim() === '') return;
		const match = /^(\S+) ([1-9][0-9]*)$/.exec(line);
		if (!match) throw new Error(`corpora.json: ${id} line ${index + 1} is not « word count »`);
		const n = Number(match[2]);
		const cells = Array.from(` ${match[1]} `);
		// The leading space stands for the one the previous word ended with.
		for (let i = 1; i < cells.length; i++) add(chars, cells[i], n);
		for (let i = 0; i + 1 < cells.length; i++) add(bigrams, cells[i] + cells[i + 1], n);
		for (let i = 0; i + 2 < cells.length; i++)
			add(trigrams, cells[i] + cells[i + 1] + cells[i + 2], n);
	});
	return { chars, bigrams, trigrams };
}

/**
 * The words of a word-frequency list (« word count » lines, wordListCounts
 * checked them), each counted as often as the list says, by the engine's word
 * rule (countWords).
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @param {string} text - The list.
 * @param {object} [into] - The count to add to; a new one when absent.
 * @returns {object} word → count, unbounded.
 */
function wordListWords(engine, text, into) {
	const counts = into || {};
	for (const line of text.split('\n')) {
		const match = /^(\S+) ([1-9][0-9]*)$/.exec(line);
		if (match) engine.countWords(match[1], Number(match[2]), counts);
	}
	return counts;
}

/**
 * The tables of a count-table file, checked: each of chars, bigrams and trigrams
 * maps a string of exactly 1, 2 or 3 characters to a positive integer count,
 * pruned_below gives, per table, the smallest count it kept, and words maps at
 * most COUNT_TABLE_MAX_WORDS words to their counts, the most frequent first.
 * @param {string} text - The file.
 * @param {string} id - The corpus id, for errors.
 * @returns {{chars: object, bigrams: object, trigrams: object, words: object,
 *   countedAs: string}} Counts.
 * @throws {Error} On another format or version, an unknown key, or a bad entry.
 */
function countTableCounts(text, id) {
	const table = JSON.parse(text);
	if (table.format !== COUNT_TABLE_FORMAT || table.version !== COUNT_TABLE_VERSION)
		throw new Error(`corpora.json: ${id} is not a ${COUNT_TABLE_FORMAT} v${COUNT_TABLE_VERSION}`);
	const lengths = { chars: 1, bigrams: 2, trigrams: 3 };
	for (const key of Object.keys(table))
		if (
			![
				'format',
				'version',
				'counted_as',
				'pruned_below',
				'prune_check',
				...Object.keys(lengths),
				'words'
			].includes(key)
		)
			throw new Error(`corpora.json: ${id} count table has an unknown field ${key}`);
	// A word list's n-grams stay inside words: the page says so (word_list).
	if (!COUNTED_AS.includes(table.counted_as))
		throw new Error(`corpora.json: ${id} count table has no valid counted_as`);
	// The counts each table was kept from (tools/build/import-count-tables.cjs prune).
	const pruned = table.pruned_below;
	if (
		!pruned ||
		Object.keys(pruned).join() !== Object.keys(lengths).join() ||
		!Object.values(pruned).every((n) => Number.isSafeInteger(n) && n >= 1)
	)
		throw new Error(`corpora.json: ${id} count table has no valid pruned_below`);
	// What pruning changed in the analysis (import-count-tables.cjs pruneDeviation).
	const check = table.prune_check;
	if (
		!check ||
		Object.keys(check).join() !== 'layouts,max_metric_change,at' ||
		!Array.isArray(check.layouts) ||
		check.layouts.length === 0 ||
		!check.layouts.every((layout) => typeof layout === 'string') ||
		!(Number.isFinite(check.max_metric_change) && check.max_metric_change >= 0) ||
		typeof check.at !== 'string'
	)
		throw new Error(`corpora.json: ${id} count table has no valid prune_check`);
	for (const [name, length] of Object.entries(lengths)) {
		const counts = table[name];
		if (!counts || typeof counts !== 'object' || Array.isArray(counts))
			throw new Error(`corpora.json: ${id} count table has no ${name}`);
		for (const [gram, n] of Object.entries(counts))
			if (Array.from(gram).length !== length || !Number.isSafeInteger(n) || n < pruned[name])
				throw new Error(`corpora.json: ${id} ${name} entry ${JSON.stringify(gram)} is invalid`);
	}
	// The word table: the engine's word rule, its most frequent words first.
	const words = table.words;
	if (!words || typeof words !== 'object' || Array.isArray(words))
		throw new Error(`corpora.json: ${id} count table has no words`);
	const wordEntries = Object.entries(words);
	if (wordEntries.length === 0 || wordEntries.length > COUNT_TABLE_MAX_WORDS)
		throw new Error(`corpora.json: ${id} count table has ${wordEntries.length} words`);
	wordEntries.forEach(([word, n], index) => {
		if (
			!COUNT_TABLE_WORD.test(word) ||
			word !== word.toLowerCase() ||
			!Number.isSafeInteger(n) ||
			n < 1 ||
			(index > 0 && n > wordEntries[index - 1][1])
		)
			throw new Error(`corpora.json: ${id} words entry ${JSON.stringify(word)} is invalid`);
	});
	return {
		chars: table.chars,
		bigrams: table.bigrams,
		trigrams: table.trigrams,
		words,
		countedAs: table.counted_as
	};
}

/**
 * The n-gram tables of every built-in corpus, counted by the engine itself.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @returns {{catalogue: object[], tables: object}} The list the page shows and
 *   the tables by corpus id.
 */
function buildCorpora(engine) {
	const manifest = JSON.parse(fs.readFileSync(CORPORA_PATH, 'utf8'));
	const register = corpusRegister();
	const catalogue = [];
	const tables = {};
	for (const corpus of manifest.corpora) {
		const entry = register[path.posix.relative('static/corpus', corpus.file)];
		if (!entry || entry.status !== SHIP_STATUS)
			throw new Error(
				`corpora.json: ${corpus.id} is not cleared to ship in static/corpus/register.json`
			);
		let text = fs.readFileSync(path.join(REPO_ROOT, corpus.file), 'utf8').replace(/\uFEFF/g, '');
		if (corpus.restore_dead_key_pairs) text = restoreDeadKeyPairs(text);
		// A Leipzig sentence file numbers its lines: « 12<TAB>sentence ».
		if (corpus.strip_sentence_numbers) text = text.replace(/^\d+\t/gm, '');
		const format = corpus.format || 'text';
		if (!CORPUS_FORMATS.includes(format))
			throw new Error(`corpora.json: ${corpus.id} has format ${format}`);
		// A tab-separated file (Tatoeba): one sentence per line, in one column.
		if (format === 'tsv') {
			if (!Number.isInteger(corpus.tsv_text_column))
				throw new Error(`corpora.json: ${corpus.id} needs tsv_text_column`);
			text = text
				.split('\n')
				.filter((line) => line !== '')
				.map((line) => {
					const cell = line.split('\t')[corpus.tsv_text_column];
					if (cell === undefined) throw new Error(`corpora.json: ${corpus.id} has a short line`);
					return cell;
				})
				.join('\n');
		}
		const counts =
			format === 'word_frequencies'
				? wordListCounts(text, corpus.id)
				: format === 'count_table'
					? countTableCounts(text, corpus.id)
					: engine.ngramsFromText(text);
		// Its most frequent words, counted from the same text by the engine's rule;
		// a count table brings its own, counted by the importer from its source.
		const words =
			format === 'word_frequencies'
				? engine.wordTable(wordListWords(engine, text))
				: format === 'count_table'
					? counts.words
					: engine.wordsFromText(text);
		const sorted = (table) =>
			Object.fromEntries(
				Object.entries(table).sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
			);
		tables[corpus.id] = {
			chars: sorted(counts.chars),
			bigrams: sorted(counts.bigrams),
			trigrams: sorted(counts.trigrams)
		};
		if (words) tables[corpus.id].words = words;
		const characters = Object.values(counts.chars).reduce((sum, n) => sum + n, 0);
		// A localized name, for a title that describes rather than names a work.
		if (
			corpus.title_key !== undefined &&
			!(
				typeof corpus.title_key === 'string' &&
				corpus.title_key.startsWith(CORPUS_TITLE_KEY_PREFIX) &&
				corpus.title_key.length > CORPUS_TITLE_KEY_PREFIX.length
			)
		)
			throw new Error(
				`corpora.json: ${corpus.id} title_key must start with ${CORPUS_TITLE_KEY_PREFIX}`
			);
		catalogue.push({
			id: corpus.id,
			title: corpus.title,
			...(corpus.title_key ? { title_key: corpus.title_key } : {}),
			language: corpus.language,
			format,
			// Its n-grams stay inside words (layout_analysis.corpus.word_list).
			word_list:
				format === 'word_frequencies' ||
				(format === 'count_table' && counts.countedAs === 'word_list'),
			licence: entry.licence,
			attribution: entry.attribution,
			source: entry.source,
			url: entry.url || '',
			characters,
			// How many words its word table keeps (0: none).
			words: words ? Object.keys(words).length : 0,
			script: `_generated/corpus_${corpus.id}.js`
		});
	}
	return { catalogue, tables };
}

/**
 * The patterns of the text scanners the shipped JS must not trip: the
 * antivirus-surface policy's bundle section (case-insensitive) and the shared
 * purity scanner's list (case-sensitive, as AutoHotkey matches it).
 * @returns {RegExp[]} The patterns.
 * @throws {Error} When the purity scanner's list cannot be found.
 */
function scannerPatterns() {
	const bundle = JSON.parse(fs.readFileSync(AV_POLICY_PATH, 'utf8')).bundle;
	const av = Object.values(bundle.forbidden)
		.concat(Object.values(bundle.ceilings).map((ceiling) => ceiling.pattern))
		.map((pattern) => new RegExp(pattern, 'i'));
	// The list ends the line; its patterns hold brackets of their own.
	const match = /ForbiddenPatterns := \[(.*)\]\s*$/m.exec(
		fs.readFileSync(PURITY_TEST_PATH, 'utf8')
	);
	if (!match) throw new Error(`no ForbiddenPatterns list in ${PURITY_TEST_PATH}`);
	const purity = Array.from(match[1].matchAll(/"([^"]+)"/g), (m) => new RegExp(m[1]));
	if (purity.length < MIN_PURITY_PATTERNS)
		throw new Error(`only ${purity.length} purity patterns read from ${PURITY_TEST_PATH}`);
	return av.concat(purity);
}

/**
 * One token as a JSON string key. A token a text scanner would read as a
 * forbidden word (the trigram "uac" matches /\bUAC\b/, "hs." the purity scan,
 * the Rust word "completepowershell" the bundle's powershell ceiling) has the
 * character where each match starts written as a \u escape: the same string to
 * JavaScript, no longer the word to a text scan. Escaping only the first
 * character missed a word inside a longer token.
 * @param {string} token - The table token.
 * @param {RegExp[]} patterns - From scannerPatterns().
 * @returns {string} The JSON string text.
 * @throws {Error} When escaping cannot hide a match.
 */
function keyText(token, patterns) {
	const escaped = new Set();
	for (let round = 0; round <= token.length; round++) {
		// Each code unit's rendering and where it starts in the key text.
		const pieces = [];
		let text = '"';
		for (let i = 0; i < token.length; i++) {
			const piece = escaped.has(i)
				? `\\u${token.charCodeAt(i).toString(16).padStart(4, '0')}`
				: JSON.stringify(token[i]).slice(1, -1);
			pieces.push(text.length);
			text += piece;
		}
		text += '"';
		const match = patterns.map((pattern) => pattern.exec(text)).find(Boolean);
		if (!match) return text;
		// The code unit whose rendering holds the start of the match (a match
		// starting on the opening quote starts at the first code unit).
		let unit = 0;
		while (unit + 1 < pieces.length && pieces[unit + 1] <= match.index) unit++;
		if (escaped.has(unit))
			throw new Error(`the escaped token ${JSON.stringify(token)} still matches ${match[0]}`);
		escaped.add(unit);
	}
	throw new Error(`no escaping hides the token ${JSON.stringify(token)} from the scanners`);
}

/**
 * One table as JSON text, each key written by keyText().
 * @param {object} table - token → count.
 * @param {RegExp[]} patterns - From scannerPatterns().
 * @returns {string} The JSON object text.
 */
function tableText(table, patterns) {
	const entries = Object.entries(table).map(([token, n]) => `${keyText(token, patterns)}:${n}`);
	return `{${entries.join(',')}}`;
}

/**
 * The generated file of one corpus's tables.
 * @param {string} id - The corpus id.
 * @param {object} table - Its tables.
 * @returns {string} JS source.
 */
function corpusSource(id, table, licence) {
	const patterns = scannerPatterns();
	return [
		`// _shared/ui/layout_analysis/_generated/corpus_${id}.js`,
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		`// Source: ${sharedRel('layouts/data/analysis/corpora.json')}`,
		'// Run: npm run codegen:layout-analysis-data:js',
		'// ==========================================',
		'',
		'// The n-gram tables of one built-in corpus, and the most frequent words of',
		'// its text when it has one; the page loads this file when the corpus is chosen.',
		`// Licence of these tables: ${licence.licence}. Attribution: ${licence.attribution}.`,
		'// eslint-disable-next-line no-var',
		'var LAYOUT_ANALYSIS_CORPORA = typeof LAYOUT_ANALYSIS_CORPORA === "object" ? LAYOUT_ANALYSIS_CORPORA : {};',
		`LAYOUT_ANALYSIS_CORPORA[${JSON.stringify(id)}] = {"chars":${tableText(table.chars, patterns)},` +
			`"bigrams":${tableText(table.bigrams, patterns)},"trigrams":${tableText(table.trigrams, patterns)}` +
			(table.words ? `,"words":${tableText(table.words, patterns)}` : '') +
			'};',
		''
	].join('\n');
}

/**
 * GitHub's anchor of a Markdown heading: lower case, punctuation dropped,
 * spaces to hyphens.
 * @param {string} heading - Heading text without the leading #.
 * @returns {string} The anchor.
 */
function headingAnchor(heading) {
	return heading
		.trim()
		.toLowerCase()
		.replace(/[^\p{L}\p{N}\s_-]/gu, '')
		.replace(/\s/g, '-');
}

/**
 * The references of the « i » popovers, each with its link resolved.
 * @param {object} engine - The engine (its METRICS list every metric).
 * @returns {{references: object, items: object}} References and items.
 * @throws {Error} On a metric or value without an item, an unknown or unused
 *   reference, a missing repository file or anchor, or a non-https URL.
 */
function buildInfoSources(engine) {
	const raw = JSON.parse(fs.readFileSync(INFO_SOURCES_PATH, 'utf8'));
	// Each analyser of analyser_scores.js has its « i » item, analyser.<id>.
	const analyserItems = Object.keys(
		JSON.parse(fs.readFileSync(ANALYSERS_PATH, 'utf8')).analysers
	).map((id) => `analyser.${id}`);
	const expected = Object.keys(engine.METRICS).concat(INFO_VALUES, analyserItems);
	const items = raw.items;
	for (const id of expected)
		if (!Array.isArray(items[id]) || items[id].length === 0)
			throw new Error(`sources.json: no references for ${id}`);
	for (const id of Object.keys(items))
		if (!expected.includes(id)) throw new Error(`sources.json: unknown item ${id}`);
	const { owner, repo } = JSON.parse(fs.readFileSync(REPOSITORY_DEFAULTS_PATH, 'utf8')).github;
	const host = JSON.parse(fs.readFileSync(IDENTIFIERS_PATH, 'utf8')).hosts.github;
	if (!owner || !repo || !host || !raw.repository_branch)
		throw new Error('sources.json: the repository owner, name, host or branch is missing');
	// Parts, not a typed URL: the page composes the link (repository URL single source).
	const repository = { host, owner, repo, branch: raw.repository_branch };
	const references = {};
	for (const [id, ref] of Object.entries(raw.references)) {
		if (ref.path !== undefined) {
			const file = path.join(REPO_ROOT, ref.path);
			if (!fs.existsSync(file)) throw new Error(`sources.json: ${id}: no ${ref.path}`);
			if (ref.anchor !== undefined) {
				const anchors = Array.from(fs.readFileSync(file, 'utf8').matchAll(/^#+ (.+)$/gm), (m) =>
					headingAnchor(m[1])
				);
				if (!anchors.includes(ref.anchor))
					throw new Error(`sources.json: ${id}: no heading #${ref.anchor} in ${ref.path}`);
			}
			references[id] = {
				title: ref.title,
				path: ref.path,
				anchor: ref.anchor || '',
				checked: true
			};
			continue;
		}
		if (typeof ref.url !== 'string' || !ref.url.startsWith('https://'))
			throw new Error(`sources.json: ${id}: needs an https url or a repository path`);
		references[id] = { title: ref.title, url: ref.url, checked: ref.checked !== null };
	}
	const used = new Set(Object.values(items).flat());
	for (const id of used)
		if (!references[id]) throw new Error(`sources.json: unknown reference ${id}`);
	for (const id of Object.keys(references))
		if (!used.has(id)) throw new Error(`sources.json: unused reference ${id}`);
	return { repository, references, items };
}

/**
 * The split, ortholinear and column-staggered boards, checked against the
 * model: every key has a position, a row and a known finger; every finger has
 * its home key on the board; the held modifiers exist.
 * @param {object} model - analysis_model.json.
 * @returns {object} board id → {name, source, keys, fingers, home_keys}.
 * @throws {Error} On a board the engine could not measure.
 */
function buildBoards(model) {
	const boards = JSON.parse(fs.readFileSync(BOARDS_PATH, 'utf8')).boards;
	for (const [id, spec] of Object.entries(model.keyboards))
		if (spec.board && !boards[spec.board])
			throw new Error(`keyboard ${id}: no board ${spec.board}`);
	for (const [id, board] of Object.entries(boards)) {
		for (const [code, key] of Object.entries(board.keys)) {
			if (![key.x, key.y, key.row, key.w].every(Number.isFinite))
				throw new Error(`board ${id}: ${code} has no position`);
			if (!model.fingers.includes(board.fingers[code]))
				throw new Error(`board ${id}: ${code} has no finger`);
		}
		for (const finger of model.fingers)
			if (!board.keys[board.home_keys[finger]])
				throw new Error(`board ${id}: no home key for ${finger}`);
		for (const code of Object.values(model.modifier_keys))
			if (!board.keys[code]) throw new Error(`board ${id}: no ${code}`);
	}
	return boards;
}

/**
 * Rejects keyboard formats the editor and the Comparer could not show: each
 * block names physical keys, each format hides known blocks, the ids are
 * unique, the default is one of them, and the full-size format hides nothing.
 * @param {object} model - analysis_model.json.
 * @throws {Error} On a broken format.
 */
function checkKeyboardFormats(model) {
	const physical = JSON.parse(fs.readFileSync(PHYSICAL_KEYS_PATH, 'utf8')).keys;
	const known = new Set(Object.keys(physical));
	for (const [block, codes] of Object.entries(model.keyboard_blocks || {})) {
		if (!Array.isArray(codes) || codes.length === 0)
			throw new Error(`keyboard_blocks.${block}: no keys`);
		for (const code of codes)
			if (!known.has(code)) throw new Error(`keyboard_blocks.${block}: unknown key ${code}`);
	}
	const formats = model.keyboard_formats;
	if (!Array.isArray(formats) || formats.length === 0) throw new Error('keyboard_formats: none');
	const ids = new Set();
	for (const format of formats) {
		if (typeof format.id !== 'string' || ids.has(format.id))
			throw new Error(`keyboard_formats: missing or repeated id ${format.id}`);
		ids.add(format.id);
		for (const block of format.hides)
			if (!model.keyboard_blocks[block])
				throw new Error(`keyboard_formats.${format.id}: unknown block ${block}`);
	}
	if (formats[0].hides.length !== 0)
		throw new Error('keyboard_formats: the first must hide nothing');
	if (!ids.has(model.default_keyboard_format))
		throw new Error(`default_keyboard_format ${model.default_keyboard_format} is not a format`);
}

/**
 * Rejects an ideal finger load that breaks the maintainer's rule: each hand
 * sums to half, index ≥ middle ≥ ring ≥ pinky, pinkies under 8 %.
 * @param {object} load - finger → %.
 * @throws {Error} On a broken rule.
 */
function checkIdealLoad(load) {
	for (const hand of HAND_FINGERS) {
		const shares = hand.map((f) => load[f]);
		if (!shares.every(Number.isFinite))
			throw new Error(`ideal_finger_load: ${hand.join(', ')} needed`);
		const sum = shares.reduce((a, b) => a + b, 0);
		if (Math.abs(sum - HAND_SHARE) > 1e-9)
			throw new Error(`ideal_finger_load: ${hand.join(', ')} sum to ${sum}, not ${HAND_SHARE}`);
		for (let i = 1; i < shares.length; i++)
			if (shares[i] < shares[i - 1])
				throw new Error(`ideal_finger_load: ${hand[i]} is below ${hand[i - 1]}`);
		if (shares[0] >= MAX_PINKY_SHARE)
			throw new Error(`ideal_finger_load: ${hand[0]} is not under ${MAX_PINKY_SHARE} %`);
	}
}

// ============================
// ======= 4/ Analysers =======
// ============================

// The fields every analyser entry of analyser_models.json carries.
const ANALYSER_FIELDS = [
	'name',
	'url',
	'revision',
	'licence',
	'fidelity',
	'better',
	'unit',
	'model'
];
const FIDELITIES = new Set(['exact', 'close', 'approximate']);
const DIRECTIONS = new Set(['higher', 'lower', 'none']);

/**
 * The constants of the analyser scorers, checked.
 * @returns {object} analyser id → entry.
 * @throws {Error} On a missing field, an unknown fidelity or direction.
 */
function buildAnalysers() {
	const analysers = JSON.parse(fs.readFileSync(ANALYSERS_PATH, 'utf8')).analysers;
	for (const [id, entry] of Object.entries(analysers)) {
		for (const field of ANALYSER_FIELDS)
			if (entry[field] === undefined)
				throw new Error(`analyser_models.json: ${id} has no ${field}`);
		if (!FIDELITIES.has(entry.fidelity))
			throw new Error(`analyser_models.json: ${id} fidelity ${entry.fidelity}`);
		if (!DIRECTIONS.has(entry.better))
			throw new Error(`analyser_models.json: ${id} better ${entry.better}`);
	}
	return analysers;
}

// ==========================
// ======= 5/ JS source =====
// ==========================

/**
 * Builds the data object.
 * @returns {object} The data the engine reads.
 */
function buildData() {
	const model = JSON.parse(fs.readFileSync(MODEL_PATH, 'utf8'));
	const weights = JSON.parse(fs.readFileSync(WEIGHTS_PATH, 'utf8'));
	const library = JSON.parse(fs.readFileSync(LIBRARY_PATH, 'utf8'));
	const engine = loadEngine();
	const corpora = buildCorpora(engine);
	checkIdealLoad(model.ideal_finger_load);
	// The engine keeps an edited load in the same order (analysis_engine.js idealLoad).
	model.ideal_finger_load_hands = HAND_FINGERS;
	checkKeyboardFormats(model);
	delete model._description;
	return {
		schema_version: 1,
		model,
		geometry: buildGeometry(model),
		boards: buildBoards(model),
		scancodes: buildScancodes(model),
		weights: weights.weights,
		library_sources: library.sources,
		layouts: buildLibrary(model),
		corpora: corpora.catalogue,
		sources: buildInfoSources(engine),
		corpusTables: corpora.tables,
		analysers: buildAnalysers()
	};
}

/**
 * Builds the complete generated file.
 * @param {object} data - buildData() output.
 * @returns {string} JS source with LF line ends and a final newline.
 */
function buildSource(data) {
	const layoutLines = data.layouts.map((layout) => `\t\t${JSON.stringify(layout)}`).join(',\n');
	const lines = [
		'// _shared/ui/layout_analysis/_generated/analysis_data.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		...SOURCES.map(
			(s) => `// Source: ${s.startsWith('..') || s.startsWith('static/') ? s : sharedRel(s)}`
		),
		'// Run: npm run codegen:layout-analysis-data:js',
		'// ==========================================',
		'',
		'// The fingers, keyboards, default weights and layout library of the layout',
		'// analysis engine. Loaded by a <script> tag before analysis_engine.js.',
		'// eslint-disable-next-line no-unused-vars',
		'var LAYOUT_ANALYSIS_DATA = {',
		`\t"schema_version": ${data.schema_version},`,
		`\t"model": ${JSON.stringify(data.model)},`,
		`\t"geometry": ${JSON.stringify(data.geometry)},`,
		`\t"boards": ${JSON.stringify(data.boards)},`,
		`\t"scancodes": ${JSON.stringify(data.scancodes)},`,
		`\t"weights": ${JSON.stringify(data.weights)},`,
		`\t"library_sources": ${JSON.stringify(data.library_sources)},`,
		`\t"corpora": ${JSON.stringify(data.corpora)},`,
		`\t"sources": ${JSON.stringify(data.sources)},`,
		`\t"analysers": ${JSON.stringify(data.analysers)},`,
		'\t"layouts": [',
		layoutLines,
		'\t]',
		'};',
		''
	];
	return lines.join('\n');
}

/**
 * Writes the generated file.
 */
function main() {
	console.log('codegen:layout-analysis-data:js — generating the layout analysis data…');
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	const data = buildData();
	fs.writeFileSync(OUT_PATH, buildSource(data));
	for (const [id, table] of Object.entries(data.corpusTables))
		fs.writeFileSync(
			path.join(CORPUS_OUT_DIR, `corpus_${id}.js`),
			corpusSource(
				id,
				table,
				data.corpora.find((corpus) => corpus.id === id)
			)
		);
	console.log(`codegen:layout-analysis-data:js — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = {
	ENGINE_PATH,
	COUNTED_AS,
	countTableCounts,
	loadEngine,
	COUNT_TABLE_FORMAT,
	COUNT_TABLE_VERSION,
	COUNT_TABLE_MAX_WORDS,
	CORPUS_TITLE_KEY_PREFIX,
	wordListWords,
	buildData,
	buildSource,
	corpusSource,
	restoreDeadKeyPairs,
	wordListCounts,
	OUT_PATH
};
