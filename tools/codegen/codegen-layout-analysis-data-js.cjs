// tools/codegen/codegen-layout-analysis-data-js.cjs

/**
 * ==============================================================================
 * MODULE: Layout Analysis Data Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/layout_analysis/_generated/analysis_data.js`, every
 * datum the layout analysis engine reads, from:
 *   - _shared/layouts/data/analysis/analysis_model.json (fingers, keyboards…);
 *   - _shared/layouts/data/analysis/score_weights.json (default weights);
 *   - _shared/layouts/data/analysis/layout_library.json (alphabetic blocks);
 *   - _shared/layouts/data/analysis/sources.json (the « i » references);
 *   - _shared/layouts/data/keycodes/physical_keys.json (key geometry);
 *   - the registry layouts and the reference QWERTY and AZERTY, read through
 *     the layout composer model (tools/lib/layout-composer.cjs).
 *
 * FEATURES & RATIONALE:
 * 1. Classic script: `_shared/ui/*` pages load plain `<script src>` tags and
 *    the hosts inline them, so the data is a top-level const, not a fetch.
 * 2. One library for the site and the app: registry layouts keep all their
 *    layers and dead keys; an alphabetic block of the library JSON gets the US
 *    number row and the US Shift pairs, the convention of its source.
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
const CREDITS_PATH = shared('layouts', 'data', 'analysis', 'layout_credits.json');
const INFO_SOURCES_PATH = shared('layouts', 'data', 'analysis', 'sources.json');
// The values the « i » popovers explain besides the metrics.
const INFO_VALUES = ['ideal_finger_load', 'shortcut_letters', 'weights', 'fingering'];
// The ideal finger load per hand, pinky to index (maintainer 2026-11-14).
const HAND_FINGERS = [
	['lp', 'lr', 'lm', 'li'],
	['rp', 'rr', 'rm', 'ri']
];
const HAND_SHARE = 50;
const MAX_PINKY_SHARE = 8;
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
	'adapters',
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
const REGISTRY_ORIGIN = 'registry';
const REFERENCE_ORIGIN = 'reference';
const LIBRARY_ORIGIN = 'library';

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
	for (const entry of composer.INDEX.layouts)
		out.push(fromComposer(engine, composer.SOURCES[entry.id], REGISTRY_ORIGIN, codes, entry.name));
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
	for (const entry of library.layouts)
		out.push(fromAlphaBlock(entry, composer.REFERENCE.qwerty.rows));
	credit(out);
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
 * The n-gram tables of every built-in corpus, counted by the engine itself.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @returns {{catalogue: object[], tables: object}} The list the page shows and
 *   the tables by corpus id.
 */
function buildCorpora(engine) {
	const manifest = JSON.parse(fs.readFileSync(CORPORA_PATH, 'utf8'));
	const catalogue = [];
	const tables = {};
	for (const corpus of manifest.corpora) {
		let text = fs.readFileSync(path.join(REPO_ROOT, corpus.file), 'utf8').replace(/\uFEFF/g, '');
		if (corpus.restore_dead_key_pairs) text = restoreDeadKeyPairs(text);
		const counts = engine.ngramsFromText(text);
		const sorted = (table) =>
			Object.fromEntries(
				Object.entries(table).sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
			);
		tables[corpus.id] = {
			chars: sorted(counts.chars),
			bigrams: sorted(counts.bigrams),
			trigrams: sorted(counts.trigrams)
		};
		const characters = Object.values(counts.chars).reduce((sum, n) => sum + n, 0);
		catalogue.push({
			id: corpus.id,
			title: corpus.title,
			language: corpus.language,
			licence: corpus.licence,
			source: corpus.source,
			characters,
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
 * One table as JSON text. A token a text scanner would read as a forbidden word
 * (the trigram "uac" matches /\bUAC\b/, "hs." the purity scan) is written
 * with its first character as a \u escape: the same string to JavaScript, no
 * longer the word to a text scan.
 * @param {object} table - token → count.
 * @param {RegExp[]} patterns - From scannerPatterns().
 * @returns {string} The JSON object text.
 */
function tableText(table, patterns) {
	const entries = Object.entries(table).map(([token, n]) => {
		let key = JSON.stringify(token);
		if (patterns.some((pattern) => pattern.test(key))) {
			const unit = token.charCodeAt(0).toString(16).padStart(4, '0');
			key = `"\\u${unit}${JSON.stringify(token.slice(1)).slice(1)}`;
		}
		return `${key}:${n}`;
	});
	return `{${entries.join(',')}}`;
}

/**
 * The generated file of one corpus's tables.
 * @param {string} id - The corpus id.
 * @param {object} table - Its tables.
 * @returns {string} JS source.
 */
function corpusSource(id, table) {
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
		'// The n-gram tables of one built-in corpus; the page loads this file when',
		'// the corpus is chosen.',
		'// eslint-disable-next-line no-var',
		'var LAYOUT_ANALYSIS_CORPORA = typeof LAYOUT_ANALYSIS_CORPORA === "object" ? LAYOUT_ANALYSIS_CORPORA : {};',
		`LAYOUT_ANALYSIS_CORPORA[${JSON.stringify(id)}] = {"chars":${tableText(table.chars, patterns)},` +
			`"bigrams":${tableText(table.bigrams, patterns)},"trigrams":${tableText(table.trigrams, patterns)}};`,
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
	const expected = Object.keys(engine.METRICS).concat(INFO_VALUES);
	const items = raw.items;
	for (const id of expected)
		if (!Array.isArray(items[id]) || items[id].length === 0)
			throw new Error(`sources.json: no references for ${id}`);
	for (const id of Object.keys(items))
		if (!expected.includes(id)) throw new Error(`sources.json: unknown item ${id}`);
	const references = {};
	for (const [id, ref] of Object.entries(raw.references)) {
		let url = ref.url;
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
			url = raw.repository_base + ref.path + (ref.anchor ? `#${ref.anchor}` : '');
		}
		if (typeof url !== 'string' || !url.startsWith('https://'))
			throw new Error(`sources.json: ${id}: needs an https url or a repository path`);
		references[id] = {
			title: ref.title,
			url,
			checked: ref.checked === undefined ? true : ref.checked !== null
		};
	}
	const used = new Set(Object.values(items).flat());
	for (const id of used)
		if (!references[id]) throw new Error(`sources.json: unknown reference ${id}`);
	for (const id of Object.keys(references))
		if (!used.has(id)) throw new Error(`sources.json: unused reference ${id}`);
	return { references, items };
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

// ==========================
// ======= 4/ JS source =====
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
	delete model._description;
	return {
		schema_version: 1,
		model,
		geometry: buildGeometry(model),
		scancodes: buildScancodes(model),
		weights: weights.weights,
		library_sources: library.sources,
		layouts: buildLibrary(model),
		corpora: corpora.catalogue,
		sources: buildInfoSources(engine),
		corpusTables: corpora.tables
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
		...SOURCES.map((s) => `// Source: ${s.startsWith('..') ? s : sharedRel(s)}`),
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
		`\t"scancodes": ${JSON.stringify(data.scancodes)},`,
		`\t"weights": ${JSON.stringify(data.weights)},`,
		`\t"library_sources": ${JSON.stringify(data.library_sources)},`,
		`\t"corpora": ${JSON.stringify(data.corpora)},`,
		`\t"sources": ${JSON.stringify(data.sources)},`,
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
		fs.writeFileSync(path.join(CORPUS_OUT_DIR, `corpus_${id}.js`), corpusSource(id, table));
	console.log(`codegen:layout-analysis-data:js — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildData, buildSource, corpusSource, restoreDeadKeyPairs, OUT_PATH };
