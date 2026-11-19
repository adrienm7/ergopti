// tools/test/test-analyser-scores.cjs

/**
 * ==============================================================================
 * MODULE: Analyser Scores Gate
 * DESCRIPTION:
 * _shared/ui/layout_analysis/analyser_scores.js gives a layout's score as
 * each major public analyser computes it. This gate holds every scorer to the
 * reference vectors of
 * _shared/tests/corpus/layout_analysis/analyser_vectors.json: values printed
 * by the analyser's own code on the same input, published by its author, or
 * computed by hand from the formula of docs/design/analyser-scores.md.
 *
 * WHAT IS CHECKED:
 * 1. Vectors: each scorer gives its reference value and parts within the
 *    vector's tolerance, and every analyser has at least one vector.
 * 2. Description: every analyser names its source, revision, licence,
 *    fidelity and direction; an unknown analyser throws.
 * 3. Whole library: every library layout gets a finite value (or, for an
 *    analyser without a score, finite parts) from every analyser on a
 *    built-in corpus, at a cost of at most SCORES_WALKS_BOUND reference walks
 *    of the corpus table per layout (tools/test/lib/table-walk-speed.cjs),
 *    timed in the same process.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { shared } = require('../lib/paths.cjs');
const { relativeSpeed, tableWalk } = require('./lib/table-walk-speed.cjs');

const DIR = shared('ui', 'layout_analysis');
const VECTORS_DIR = shared('tests', 'corpus', 'layout_analysis');
const VECTORS_PATH = path.join(VECTORS_DIR, 'analyser_vectors.json');
const SCRIPTS = [
	path.join(DIR, '_generated', 'analysis_data.js'),
	path.join(DIR, 'analysis_engine.js'),
	path.join(DIR, 'analyser_scores.js'),
	path.join(DIR, 'layout_formats.js'),
	path.join(DIR, '_generated', 'corpus_fr_don_quichotte.js')
];
// Floors: an empty vector file or analyser list must not read as a pass.
const MIN_VECTORS = 20;
const MIN_ANALYSERS = 11;
// Scoring a layout with every analyser, both fingerings, inside a vm context
// (global lookups go through the context), costs 1400 to 2100 reference walks
// of the corpus table with every core of a Windows PC busy (2026-11-19). The
// engine's library ratio was 1.6 times higher on a quieter PC, about 3400
// here. The bound sits above that and below five times the lowest ratio:
// scorers five times slower fail (four more passes of every scorer read
// 11300).
const SCORES_WALKS_BOUND = 5000;
// Walks of the table per layout in the reference: one walk takes a quarter of
// a millisecond, too short to time after the scorers have filled the caches.
const REFERENCE_WALKS = 20;
// The sample is scored up to this many rounds, one layout per timed chunk.
const SPEED_ROUNDS = 3;
const LIBRARY_SAMPLE = 30;
const LETTERS_TEXT = 'Thequickbrownfoxjumpsoverthelazydog';
const DIGITS_TEXT = '2024 or 1999, 35 and 46';

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};

const sandbox = {};
vm.createContext(sandbox);
for (const file of SCRIPTS)
	vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const S = vm.runInContext('LAYOUT_ANALYSER_SCORES', sandbox);
const F = vm.runInContext('LAYOUT_FORMATS', sandbox);
const library = new Map(E.libraryLayouts().map((layout) => [layout.id, layout]));

/**
 * Character counts of a text with its line breaks kept (KLA types each as
 * Enter), unlike ngramsFromText, which cuts the text at them.
 */
function countsWithLineBreaks(text) {
	const chars = {};
	const bigrams = {};
	const trigrams = {};
	const c = Array.from(text.replace(/\r\n?/g, '\n'));
	for (let i = 0; i < c.length; i++) {
		chars[c[i]] = (chars[c[i]] || 0) + 1;
		if (i + 1 < c.length) bigrams[c[i] + c[i + 1]] = (bigrams[c[i] + c[i + 1]] || 0) + 1;
		if (i + 2 < c.length) {
			const t = c[i] + c[i + 1] + c[i + 2];
			trigrams[t] = (trigrams[t] || 0) + 1;
		}
	}
	return { chars, bigrams, trigrams };
}

/** The input tables of one vector. */
function tablesOf(vector) {
	if (vector.tables) return vector.tables;
	if (vector.ergol_corpus) {
		const corpus = JSON.parse(fs.readFileSync(path.join(VECTORS_DIR, vector.ergol_corpus), 'utf8'));
		return { chars: corpus.symbols, bigrams: corpus.digrams, trigrams: corpus.trigrams };
	}
	const text =
		vector.text !== undefined
			? vector.text
			: fs.readFileSync(path.join(VECTORS_DIR, vector.file), 'utf8');
	return vector.keep_line_breaks ? countsWithLineBreaks(text) : E.ngramsFromText(text);
}

/** The layout of one vector: a library layout or a Kalamine JSON file. */
function layoutOf(vector) {
	if (vector.kalamine) {
		const json = JSON.parse(fs.readFileSync(path.join(VECTORS_DIR, vector.kalamine), 'utf8'));
		return F.fromKalamineJson(json).layout;
	}
	const layout = library.get(vector.layout);
	if (!layout) throw new Error(`no library layout ${vector.layout}`);
	return layout;
}

const near = (got, expected, tolerance) =>
	typeof got === 'number' && Number.isFinite(got) && Math.abs(got - expected) <= tolerance;

// ===========================
// ======= 1/ Vectors ========
// ===========================

const vectors = JSON.parse(fs.readFileSync(VECTORS_PATH, 'utf8')).vectors;
check(vectors.length >= MIN_VECTORS, `only ${vectors.length} analyser vectors`);
const covered = new Set();
let compared = 0;
for (const [i, vector] of vectors.entries()) {
	const name = `${vector.analyser} #${i} (${vector.basis})`;
	const result = S.score(vector.analyser, layoutOf(vector), tablesOf(vector), {
		keyboard: vector.keyboard
	});
	covered.add(vector.analyser);
	if (vector.value !== undefined) {
		check(
			near(result.value, vector.value, vector.tolerance),
			`${name}: ${result.value}, expected ${vector.value} ± ${vector.tolerance}`
		);
		compared++;
	}
	for (const [part, expected] of Object.entries(vector.parts || {})) {
		check(part in result.parts, `${name}: no part ${part}`);
		check(
			near(result.parts[part], expected, vector.parts_tolerance),
			`${name}: ${part} = ${result.parts[part]}, expected ${expected} ± ${vector.parts_tolerance}`
		);
		compared++;
	}
}

// =============================
// ======= 2/ Description ======
// =============================

const analysers = S.analysers();
check(analysers.length >= MIN_ANALYSERS, `only ${analysers.length} analysers`);
for (const a of analysers) {
	check(covered.has(a.id), `${a.id}: no reference vector`);
	for (const field of ['name', 'url', 'revision', 'licence'])
		check(typeof a[field] === 'string' && a[field] !== '', `${a.id}: no ${field}`);
	check(['exact', 'close', 'approximate'].includes(a.fidelity), `${a.id}: fidelity ${a.fidelity}`);
	check(['higher', 'lower', 'none'].includes(a.better), `${a.id}: direction ${a.better}`);
	if (a.better === 'none')
		check(a.headline.length > 0, `${a.id}: a score-less analyser needs headline parts`);
}
// Ergo-L follows a dead key typed after a dead key, in the engine's « dead:<state> »
// form as in Kalamine's « ** » form: ë = 1dk, 1dk, d.
for (const self of ['dead:1dk', '**']) {
	const chained = E.layoutFromRows({
		id: `chain_${self}`,
		rows: { KeyO: [{ dead: '1dk' }, null, null, null], KeyD: ['d', null, null, null] },
		dead: { '1dk': { [self]: { dead: 'diaeresis' } }, diaeresis: { d: 'ë' } }
	});
	const parts = S.score(
		'ergol',
		chained,
		{ chars: { ë: 1, d: 1 }, bigrams: {}, trigrams: {} },
		{}
	).parts;
	check(
		parts.unsupported === 0,
		`ergol: ë not typed through « ${self} » (${parts.unsupported} % unsupported)`
	);
}
// The break tables of ngramsFromText (the Enter and Tab presses KLA and
// KLAnext type): hand-counted on a short text, and with the main tables
// they count every n-gram of the text, as read with its line breaks kept.
{
	const counted = E.ngramsFromText('ab\r\n\nc\td');
	const same = (got, expected, what) =>
		check(
			JSON.stringify(Object.entries(got).sort()) ===
				JSON.stringify(Object.entries(expected).sort()),
			`ngramsFromText breaks ${what}: ${JSON.stringify(got)}, expected ${JSON.stringify(expected)}`
		);
	same(counted.breaks.chars, { '\n': 2, '\t': 1 }, 'chars');
	same(counted.breaks.bigrams, { 'b\n': 1, '\n\n': 1, '\nc': 1, 'c\t': 1, '\td': 1 }, 'bigrams');
	same(
		counted.breaks.trigrams,
		{ 'ab\n': 1, 'b\n\n': 1, '\n\nc': 1, '\nc\t': 1, 'c\td': 1 },
		'trigrams'
	);
	const text = fs.readFileSync(path.join(VECTORS_DIR, 'analysers', 'kla_alice_ch1.txt'), 'utf8');
	const cut = E.ngramsFromText(text + '\t\tx\n');
	const whole = countsWithLineBreaks(text + '\t\tx\n');
	for (const key of ['chars', 'bigrams', 'trigrams']) {
		const merged = Object.assign({}, cut[key]);
		for (const [gram, n] of Object.entries(cut.breaks[key])) merged[gram] = (merged[gram] || 0) + n;
		same(merged, whole[key], `with the main ${key}`);
	}
}
// Two fingerings side by side: on a text without spaces or digits, where
// carpalx, keygen, genkey and Oxeylyzer finger QWERTY as the default model
// does, the two numbers are equal; Keyboard Layout Optimizer fingers the
// number row one key over, so on digits its two numbers differ.
{
	const qwerty = library.get('qwerty');
	const letters = S.scoreAll(qwerty, E.ngramsFromText(LETTERS_TEXT), { keyboard: 'iso' });
	for (const id of ['carpalx', 'keygen', 'genkey', 'oxeylyzer'])
		check(
			letters[id].official.value === letters[id].custom.value,
			`${id}: official and custom differ on QWERTY letters`
		);
	const digits = S.scoreAll(qwerty, E.ngramsFromText(DIGITS_TEXT), { keyboard: 'iso' });
	check(
		digits.dariogoetz.official.value !== digits.dariogoetz.custom.value,
		'dariogoetz: the custom finger model is not used'
	);
	let refused = false;
	try {
		S.score('kla', library.get('qwerty'), E.ngramsFromText('the'), { fingering: 'other' });
	} catch {
		refused = true;
	}
	check(refused, 'an unknown fingering does not throw');
}
let threw = false;
try {
	S.score('no_such_analyser', library.get('qwerty'), E.ngramsFromText('the'), {});
} catch {
	threw = true;
}
check(threw, 'an unknown analyser does not throw');

// ===============================
// ======= 3/ Whole library ======
// ===============================

const corpus = E.prepareNgrams(
	vm.runInContext('LAYOUT_ANALYSIS_CORPORA', sandbox).fr_don_quichotte
);
const sample = Array.from(library.values()).slice(0, LIBRARY_SAMPLE);
for (const layout of sample) {
	const both = S.scoreAll(layout, corpus, { keyboard: 'iso' });
	const all = Object.fromEntries(Object.entries(both).map(([id, r]) => [id, r.official]));
	for (const a of analysers) {
		const r = all[a.id];
		if (a.better === 'none') {
			check(r.value === null, `${layout.id} ${a.id}: a score-less analyser gave a value`);
			for (const part of a.headline)
				check(Number.isFinite(r.parts[part]), `${layout.id} ${a.id}: ${part} is not finite`);
		} else check(Number.isFinite(r.value), `${layout.id} ${a.id}: ${r.value} is not finite`);
	}
}
// A copy of each layout: the engine keeps its key n-grams per layout object,
// so every round scores from the start.
const walk = tableWalk(corpus);
const speed = relativeSpeed({
	items: sample,
	chunk: 1,
	reference: (layouts) => {
		for (let pass = 0; pass < REFERENCE_WALKS; pass++) walk(layouts);
	},
	subject: ([layout]) => S.scoreAll({ ...layout }, corpus, { keyboard: 'iso' }),
	bound: SCORES_WALKS_BOUND / REFERENCE_WALKS,
	maxRounds: SPEED_ROUNDS
});
const walks = speed.ratio * REFERENCE_WALKS;
check(
	walks <= SCORES_WALKS_BOUND,
	`every analyser costs ${walks.toFixed(0)} reference walks of the corpus per layout ` +
		`(bound ${SCORES_WALKS_BOUND}): ${speed.subjectMs.toFixed(0)} ms against ` +
		`${speed.referenceMs.toFixed(0)} ms on ${sample.length} layouts, fastest of ${speed.rounds} rounds`
);

if (errors.length > 0) {
	console.error(`test-analyser-scores: ${errors.length} error(s)`);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}
console.log(
	`test-analyser-scores: OK (${analysers.length} analysers, ${vectors.length} vectors, ${compared} values, ` +
		`${sample.length} layouts at ${(speed.subjectMs / sample.length).toFixed(0)} ms each, ` +
		`${walks.toFixed(0)} table walks)`
);
