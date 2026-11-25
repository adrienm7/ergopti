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
 *    fidelity on a text and on n-gram tables alone, and direction; each score
 *    names the fidelity of the tables it read; an unknown analyser throws.
 * 3. Whole library: every library layout gets a finite value (or, for an
 *    analyser without a score, finite parts) from every analyser on a
 *    built-in corpus, at a cost of at most SCORES_WALKS_BOUND reference walks
 *    of the corpus table per layout (tools/test/lib/table-walk-speed.cjs),
 *    timed in the same process. keycraft's reference statistics shipped
 *    with the corpus are those its reference layouts give, and are read.
 * 4. Own levels: a layout with levels beyond the four (Neo 2) is scored on
 *    its first four by every analyser, never throwing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { shared } = require('../lib/paths.cjs');
const { relativeSpeed, tableWalk } = require('./lib/table-walk-speed.cjs');
const { reportMeasured } = require('./lib/bound-measurements.cjs');

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
	if (vector.keep_line_breaks) return countsWithLineBreaks(text);
	// A text corpus ships the counts only its text gives (genkey's and
	// Oxeylyzer's skipgrams of every gap); « chain » scores without them, as a
	// count table is scored.
	const tables = E.ngramsFromText(text);
	if (!vector.chain) tables.analysers = S.textTables(text);
	return tables;
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
	// (analyser-fidelity-per-corpus) One fidelity per corpus a scorer reads.
	for (const corpus of ['text', 'tables'])
		check(
			['exact', 'close', 'approximate'].includes(a.fidelity[corpus]),
			`${a.id}: fidelity on ${corpus} ${a.fidelity && a.fidelity[corpus]}`
		);
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
// The counts only a text gives (textTables), hand-counted from genkey's
// corpus reader (pairs up to 9 apart weighted 1/2^(g−1) inside a run of its
// valid characters) and Oxeylyzer's counter (pairs 1 to 3 apart in its token
// stream, Shift tokens counted in the totals only). On these texts the
// trigrams' chain is not exact, so the scores must follow the text's counts.
{
	const same = (got, expected, what) =>
		check(
			JSON.stringify(Object.entries(got).sort()) ===
				JSON.stringify(Object.entries(expected).sort()),
			`textTables ${what}: ${JSON.stringify(got)}, expected ${JSON.stringify(expected)}`
		);
	const genkeyText = 'abcde\nxbcdy\nAb?c d';
	same(
		S.textTables(genkeyText).genkey.skipgrams,
		{
			ac: 1.5,
			bd: 2,
			ce: 1,
			ad: 0.5,
			be: 0.5,
			ae: 0.25,
			xc: 1,
			cy: 1,
			xd: 0.5,
			by: 0.5,
			xy: 0.25,
			'a/': 1,
			bc: 1
		},
		'genkey skipgrams'
	);
	const oxey = S.textTables('Ab c\n\nDe').oxeylyzer;
	same(oxey.bigrams, { ab: 1, de: 1 }, 'oxeylyzer bigrams');
	same(oxey.skipgrams[0], { bc: 1 }, 'oxeylyzer skip-1');
	same(oxey.skipgrams[1], { ac: 1 }, 'oxeylyzer skip-2');
	same(oxey.skipgrams[2], { cd: 1 }, 'oxeylyzer skip-3');
	check(
		oxey.chars === 7 &&
			JSON.stringify(oxey.totals) ===
				JSON.stringify({ bigrams: 4, skipgrams: [3, 2, 2], trigrams: 2 }),
		`textTables oxeylyzer totals: ${oxey.chars} characters, ${JSON.stringify(oxey.totals)}`
	);
	// A chain that splits a continuation: the scores read the text's counts.
	const qwerty = library.get('qwerty');
	// Repeated: Oxeylyzer truncates each weighted pair count to an integer.
	const split = 'edcxd\nqdcxe\nedcwe\n'.repeat(100);
	const withText = Object.assign(E.ngramsFromText(split), { analysers: S.textTables(split) });
	for (const id of ['genkey', 'oxeylyzer'])
		check(
			S.score(id, qwerty, withText, { keyboard: 'ansi' }).value !==
				S.score(id, qwerty, E.ngramsFromText(split), { keyboard: 'ansi' }).value,
			`${id}: the text's own skipgrams are not used`
		);
	// (analyser-fidelity-per-corpus) Each score names the fidelity of the
	// tables it read: genkey is exact on a text's own counts, close on n-gram
	// tables alone (a word list, a count table), where the chain stands in.
	const fidelities = {
		genkey: { text: 'exact', tables: 'close' },
		oxeylyzer: { text: 'close', tables: 'close' },
		kla: { text: 'exact', tables: 'exact' }
	};
	for (const [id, expected] of Object.entries(fidelities)) {
		const onText = S.score(id, qwerty, withText, { keyboard: 'ansi' }).fidelity;
		const onTables = S.scoreAll(qwerty, E.ngramsFromText(split), { keyboard: 'ansi' })[id].official
			.fidelity;
		check(
			onText === expected.text && S.fidelity(id, withText) === expected.text,
			`${id}: fidelity on a text ${onText}, expected ${expected.text}`
		);
		check(
			onTables === expected.tables && S.fidelity(id, E.ngramsFromText(split)) === expected.tables,
			`${id}: fidelity on tables ${onTables}, expected ${expected.tables}`
		);
	}
	// The codegen refuses a fidelity that is one value for every corpus.
	const { checkAnalysers } = require('../codegen/codegen-layout-analysis-data-js.cjs');
	const models = JSON.parse(
		fs.readFileSync(shared('layouts', 'data', 'analysis', 'analyser_models.json'), 'utf8')
	).analysers;
	const refusedFidelity = (fidelity) => {
		try {
			checkAnalysers({ genkey: Object.assign({}, models.genkey, { fidelity }) });
		} catch {
			return true;
		}
		return false;
	};
	check(!refusedFidelity(models.genkey.fidelity), 'codegen: refuses the shipped genkey fidelity');
	check(refusedFidelity('close'), 'codegen: accepts one fidelity for every corpus');
	check(refusedFidelity({ text: 'exact' }), 'codegen: accepts a fidelity without tables');
	check(
		refusedFidelity({ text: 'exact', tables: 'faithful' }),
		'codegen: accepts an unknown fidelity'
	);
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
// keycraft's reference statistics: the built-in corpus ships them
// (references.keycraft), they are what its reference layouts give on the
// corpus, and a score reads them: a table carrying other statistics scores
// otherwise. A table without them gets the same score from the reference set.
{
	const raw = vm.runInContext('LAYOUT_ANALYSIS_CORPORA', sandbox).fr_don_quichotte;
	const shipped = raw.references && raw.references.keycraft;
	check(
		shipped && shipped.medians && shipped.iqrs,
		'fr_don_quichotte ships no keycraft statistics'
	);
	const bare = Object.assign({}, raw);
	delete bare.references;
	const computed = S.referenceTables(bare).keycraft;
	check(
		JSON.stringify(computed) === JSON.stringify(shipped),
		'the shipped keycraft statistics are not those of its reference layouts on the corpus'
	);
	const qwerty = library.get('qwerty');
	const withShipped = S.score('keycraft', qwerty, raw).value;
	check(
		withShipped === S.score('keycraft', qwerty, bare).value,
		'keycraft scores a corpus otherwise with its shipped statistics'
	);
	const medians = Object.assign({}, shipped.medians, { SFB: shipped.medians.SFB + 1 });
	const moved = Object.assign({}, raw, {
		references: { keycraft: { medians, iqrs: shipped.iqrs } }
	});
	check(
		S.score('keycraft', qwerty, moved).value !== withShipped,
		'keycraft does not read the statistics a corpus ships'
	);
}
// The import of keycraft's reference layouts reads its notation as its
// layout.go does (« ~ » empty, « _ » a space, « ~~ », « __ », « ## » the
// characters) and refuses what it refuses: a character twice, a key of more
// than one byte, a row of another length, an unknown geometry.
{
	const os = require('os');
	const { readKlf, isReference } = require('../build/import-keycraft-layouts.cjs');
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keycraft-klf-'));
	const klf = (name, lines) => {
		const file = path.join(dir, `${name}.klf`);
		fs.writeFileSync(file, `${lines.join('\n')}\n`);
		return file;
	};
	const rows = [
		'~ q w e r t  y u i o p ~~',
		'__ a s d f g  h j k l ; ##',
		'~ z x c v b  n m , . / ~',
		'      ~ ~ ~  _ ~ ~'
	];
	try {
		const read = readKlf(klf('ok', ['# A test layout', 'AngleMod', ...rows]));
		check(read.type === 'anglemod', `readKlf: geometry ${read.type}`);
		check(read.credit === 'A test layout', `readKlf: credit ${read.credit}`);
		const keys = Array.from(read.keys);
		check(
			keys.length === 42 &&
				keys[0] === ' ' &&
				keys[11] === '~' &&
				keys[12] === '_' &&
				keys[23] === '#',
			`readKlf: keys ${JSON.stringify(read.keys)}`
		);
		check(keys[39] === ' ', 'readKlf: the space key is not an empty key');
		const refused = (name, lines) => {
			try {
				readKlf(klf(name, lines));
			} catch {
				return true;
			}
			return false;
		};
		check(
			refused('twice', ['rowstag', rows[0].replace('w', 'q'), ...rows.slice(1)]),
			'readKlf: accepts a character twice'
		);
		check(
			refused('wide', ['rowstag', rows[0].replace('w', 'é'), ...rows.slice(1)]),
			'readKlf: accepts a key outside ASCII, which keycraft refuses'
		);
		check(
			refused('long', ['rowstag', rows[0].replace('w', 'ww'), ...rows.slice(1)]),
			'readKlf: accepts a key of two characters'
		);
		check(
			refused('short', ['rowstag', rows[0].slice(2), ...rows.slice(1)]),
			'readKlf: accepts a short row'
		);
		check(refused('type', ['split', ...rows]), 'readKlf: accepts an unknown geometry');
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
	check(
		isReference('qwerty') &&
			!isReference('_mine') &&
			!isReference('x-opt') &&
			!isReference('x-flipped'),
		"isReference: does not follow keycraft's scorer"
	);
}
// A corpus without a pair or a triple outside white space (the editor's
// preview of « a ») gets a finite keycraft score: its shares count as 0
// where keycraft divides by zero, which threw in the Studio (2026-11-25).
for (const text of ['a', 'ab', 'a b c'])
	check(
		Number.isFinite(S.score('keycraft', library.get('qwerty'), E.ngramsFromText(text)).value),
		`keycraft gives no finite score on ${JSON.stringify(text)}`
	);
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
reportMeasured(
	'every analyser on one layout, reference walks of the table',
	walks,
	SCORES_WALKS_BOUND
);
check(
	walks <= SCORES_WALKS_BOUND,
	`every analyser costs ${walks.toFixed(0)} reference walks of the corpus per layout ` +
		`(bound ${SCORES_WALKS_BOUND}): ${speed.subjectMs.toFixed(0)} ms against ` +
		`${speed.referenceMs.toFixed(0)} ms on ${sample.length} layouts, fastest of ${speed.rounds} rounds`
);

// A layout with levels of its own (Neo 2's Mod3 and Mod4, a tap-hold's
// layer) is read on its first four levels: every scorer gives what it gives
// for those four alone, where row cells past the fourth threw (2026-11-25).
{
	const neo = library.get('neo2_new');
	check(neo && neo.levels, 'the library has Neo 2 with levels of its own');
	if (neo && neo.levels) {
		const rows = {};
		for (const [code, row] of Object.entries(neo.rows)) {
			const four = row.slice(0, 4);
			if (four.some((cell) => cell !== null)) rows[code] = four;
		}
		const four = { id: neo.id, name: neo.name, rows, dead: neo.dead, command: neo.command };
		const ngrams = E.ngramsFromText('Über die Brücke gehen große Leute schnell.');
		for (const { id } of S.analysers()) {
			let got = null;
			try {
				got = S.score(id, neo, ngrams);
			} catch (error) {
				errors.push(`${id} throws on a layout with levels of its own: ${error.message}`);
				continue;
			}
			const expected = S.score(id, four, ngrams);
			check(
				JSON.stringify(got) === JSON.stringify(expected),
				`${id} reads a layout of its own levels on its first four`
			);
		}
	}
}

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
