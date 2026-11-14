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
 *    built-in corpus, within a time budget.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { shared } = require('../lib/paths.cjs');

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
// Budget per library layout for every analyser, inside a vm context (slower
// than a page: global lookups go through the context). Measured about 85 ms.
const BUDGET_MS_PER_LAYOUT = 400;
const LIBRARY_SAMPLE = 30;

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
const started = Date.now();
for (const layout of sample) {
	const all = S.scoreAll(layout, corpus, { keyboard: 'iso' });
	for (const a of analysers) {
		const r = all[a.id];
		if (a.better === 'none') {
			check(r.value === null, `${layout.id} ${a.id}: a score-less analyser gave a value`);
			for (const part of a.headline)
				check(Number.isFinite(r.parts[part]), `${layout.id} ${a.id}: ${part} is not finite`);
		} else check(Number.isFinite(r.value), `${layout.id} ${a.id}: ${r.value} is not finite`);
	}
}
const perLayout = (Date.now() - started) / sample.length;
check(
	perLayout <= BUDGET_MS_PER_LAYOUT,
	`every analyser takes ${perLayout.toFixed(0)} ms per layout, budget ${BUDGET_MS_PER_LAYOUT} ms`
);

if (errors.length > 0) {
	console.error(`test-analyser-scores: ${errors.length} error(s)`);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}
console.log(
	`test-analyser-scores: OK (${analysers.length} analysers, ${vectors.length} vectors, ${compared} values, ` +
		`${sample.length} layouts at ${perLayout.toFixed(0)} ms each)`
);
