// tools/test/test-layout-analysis-engine.cjs

/**
 * ==============================================================================
 * MODULE: Layout Analysis Engine Gate
 * DESCRIPTION:
 * _shared/ui/layout_analysis/analysis_engine.js measures a layout on n-gram
 * counts for the site's /studio page and the app's Ergopti Studio. This gate
 * holds it to the definitions of docs/design/layout-analysis.md.
 *
 * WHAT IS CHECKED:
 * 1. Metrics: every reference vector of
 *    _shared/tests/corpus/layout_analysis/metric_vectors.json gives the value
 *    computed by hand from its definition, and the per-key heatmap data blames
 *    the keys of each event.
 * 2. Exact keystrokes: the key n-grams rebuilt from character n-gram tables
 *    equal those counted on the expanded key stream of the text itself.
 * 3. Score: each contribution is sign × weight × value, the total their sum,
 *    weights override the defaults without changing them, rescoring re-ranks
 *    without re-analysis, and an unknown or invalid weight throws. The ideal
 *    finger load keeps index ≥ middle ≥ ring ≥ pinky with pinkies under 8 %,
 *    an edited one is the one measured, and an invalid one throws.
 * 4. Library: about a hundred layouts with unique ids, every registry layout
 *    with its dead keys, and the reference QWERTY as its source says.
 * 5. Incremental score: scoreSession gives the full analysis's score after
 *    random swaps of any cells and dead-key rules (a property test) on
 *    layouts with one way per character and with several (Ergo-L, Ergopti,
 *    bépo: the incremental context plan and walk), compiles each trial's
 *    layout in part to exactly the ways a whole compile gives (dead-key
 *    tables shared or copied), plans it from the current plan to exactly
 *    the counts per way a plan from nothing gives, keeps a trial only once
 *    committed (an earlier trial too, after a later one replaced its plan),
 *    writes its compile into spare maps rather than copies (the committed
 *    layout's maps left as a whole compile gives them), and refuses a
 *    layout on another board.
 * 6. Ways of typing: in context the cheaper copy of a character (« a. »,
 *    « b. »), direct, AltGr or dead key by their documented costs, a
 *    two-character output only when cheaper than its two taps, one way per
 *    character exactly as the fixed path, and the best path never above the
 *    fixed one (seeded random layouts).
 * 7. Bonuses: distinct characters and the capped coverage bonus, which never
 *    outweighs worse SFBs; each simplicity rule passing and failing.
 * 8. Speed: the whole library on a 2.5 MB corpus, from prepared tables, within
 *    a budget per layout, on the fastest of a few runs.
 * 9. Golden: every metric of every library layout on both French corpora (the
 *    speed corpus and the built-in Don Quichotte table) equals the reference
 *    values of library_golden.json, recorded before the engine's speed-ups:
 *    an optimisation of the walks must not move any metric. A deliberate
 *    change of a definition, layout or corpus records them again with
 *    `node tools/test/test-layout-analysis-engine.cjs --update-golden`.
 * 10. Incomplete layouts: a layout that cannot type the space or one of the 26
 *    letters in either case (each case on its own) is flagged with what it
 *    lacks and ranked after every complete layout, whatever its score, also
 *    after a re-score; QWERTY (US) and Colemak on a French corpus stay
 *    complete, their accents only unsupported.
 * 11. Whole French layouts type French: Optimot, BvoFRak and the Spanish
 *    QWERTY with their dead keys.
 * 12. Official layouts: the keys, levels and dead-key results of the layouts
 *    re-encoded from their official files (Ergo-L's 1DK, Optimot 1.8.0, the
 *    Neo family, QWERTZ, the Spanish layouts, Engram-es), and their language's
 *    text typed in full.
 * 13. Similarity: a layout and its copy are 100 % alike; one swap of two keys
 *    moves exactly their characters, by occurrences (weighted) and by
 *    distinct characters, and keeps them alike on finger and row when both
 *    keys share them; moving « e » weighs far more than moving a rare letter;
 *    a moved dead key moves the characters behind it, a level change moves
 *    its character; the measure is symmetric and refuses a corpus of spaces.
 * 14. Collections: the library never holds fewer layouts than at its last
 *    import, each entry names its source (with a commit, version or date) and
 *    file, each layout of an author's own collection has a checked credit,
 *    key cells read in each collection's official files, and the reasons a
 *    file is left out.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { spawnSync } = require('child_process');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const DATA_PATH = shared('ui', 'layout_analysis', '_generated', 'analysis_data.js');
const ENGINE_PATH = shared('ui', 'layout_analysis', 'analysis_engine.js');
const VECTORS_PATH = shared('tests', 'corpus', 'layout_analysis', 'metric_vectors.json');
const GOLDEN_PATH = shared('tests', 'corpus', 'layout_analysis', 'library_golden.json');
const DON_QUICHOTTE_PATH = shared(
	'ui',
	'layout_analysis',
	'_generated',
	'corpus_fr_don_quichotte.js'
);
const UPDATE_GOLDEN = process.argv.includes('--update-golden');
const REGISTRY_INDEX = path.join(REPO_ROOT, 'static', 'layouts', 'registry', 'index.json');
const SPEED_CORPUS = path.join(
	REPO_ROOT,
	'static',
	'corpus',
	'original',
	'fr',
	'corpus_nemolivier.txt'
);

// Floors: an empty library or vector file must not read as a pass.
const MIN_VECTORS = 20;
const MIN_LIBRARY = 100;
// The layouts the library held at its last import: it may only grow.
const LIBRARY_COUNT = 641;
// The collections imported from their authors' own files: each of their
// layouts is credited from the author's page (layout_credits.json).
const CREDITED_SOURCES = ['handsdown', 'ergol_repo'];
// Budget per library layout on the speed corpus, from prepared tables: the
// 1.5 s the whole library had when it held 115 layouts, so a growing library
// keeps the same budget per layout. The measured time is about 3 ms.
const SPEED_BUDGET_MS_PER_LAYOUT = 13;
// The library is ranked up to this many times and the fastest run counts: one
// run's time follows the machine's load and the JIT warming up, the fastest
// the engine's own work. A run within the budget ends the check.
const SPEED_RUNS = 3;
const TOLERANCE = 1e-6;
// The golden metrics are compared to this relative gap: the values are
// bit-identical on the machines measured; the margin only covers another
// platform's last-bit rounding of Math.hypot (the key distances).
const GOLDEN_TOLERANCE = 1e-12;

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};
const near = (a, b) => Math.abs(a - b) <= TOLERANCE * Math.max(1, Math.abs(b));

const sandbox = {};
vm.createContext(sandbox);
for (const file of [DATA_PATH, ENGINE_PATH])
	vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const library = E.libraryLayouts();
const byId = new Map(library.map((layout) => [layout.id, layout]));

// ==========================
// ======= 1/ Metrics =======
// ==========================

const vectors = JSON.parse(fs.readFileSync(VECTORS_PATH, 'utf8')).vectors;
check(vectors.length >= MIN_VECTORS, `only ${vectors.length} metric vectors`);
let compared = 0;
for (const vector of vectors) {
	const layout = byId.get(vector.layout);
	check(layout, `${vector.name}: no layout ${vector.layout}`);
	if (!layout) continue;
	const result = E.analyse(layout, E.ngramsFromText(vector.text), { keyboard: vector.keyboard });
	for (const [metric, expected] of Object.entries(vector.expect)) {
		check(metric in E.METRICS, `${vector.name}: unknown metric ${metric}`);
		const got = result.metrics[metric];
		check(near(got, expected), `${vector.name}: ${metric} = ${got}, expected ${expected}`);
		compared++;
	}
}

// The heatmap's per-key data: both keys of an SFB carry it, each names the other.
const heat = E.analyse(byId.get('qwerty'), E.ngramsFromText('ed'), { keyboard: 'iso' }).keys;
check(heat.KeyE.sfb === 100 && heat.KeyD.sfb === 100, 'keys: both keys of "ed" carry the SFB');
check(heat.KeyE.worst.sfb[0][0][0] === 'KeyD', 'keys: KeyE names KeyD as its SFB partner');
check(heat.KeyF.sfb === 0 && heat.KeyE.presses === 50, 'keys: other keys carry nothing');

// Finger shares beside their ideal load, worked by hand: « asdf » on QWERTY is
// one press on each left finger, so each holds 25 % of the non-thumb presses
// and the right hand none. Against the default ideal (6.5, 11.5, 15.5, 16.5 %
// per hand), the gaps are 18.5 + 13.5 + 9.5 + 8.5 on the left and 50 on the
// right: finger_imbalance is half of 100, 50 %.
{
	const result = E.analyse(byId.get('qwerty'), E.ngramsFromText('asdf'), { keyboard: 'iso' });
	const expected = { lp: 25, lr: 25, lm: 25, li: 25, ri: 0, rm: 0, rr: 0, rp: 0 };
	check(
		JSON.stringify(Object.keys(result.fingerShares).sort()) ===
			JSON.stringify(Object.keys(expected).sort()),
		`fingerShares: fingers ${Object.keys(result.fingerShares).join(' ')}`
	);
	for (const [id, share] of Object.entries(expected))
		check(near(result.fingerShares[id], share), `fingerShares: ${id} = ${result.fingerShares[id]}`);
	check(
		JSON.stringify(result.idealLoad) === JSON.stringify(E.defaultIdealLoad()),
		'fingerShares: the result names the default ideal load it was measured against'
	);
	check(
		near(result.metrics.finger_imbalance, 50),
		`fingerShares: finger_imbalance = ${result.metrics.finger_imbalance}, expected 50`
	);
}

// diff, worked by hand: « ed » is an SFB on QWERTY (E and D, left middle) and a
// hand change on Dvorak (E on KeyD, D on KeyH): QWERTY is worse by 100 points
// of SFB, hand_change is shown but not scored, and the score delta is the
// difference of the two totals.
{
	const tables = E.ngramsFromText('ed');
	const qwerty = E.analyse(byId.get('qwerty'), tables, { keyboard: 'iso' });
	const dvorak = E.analyse(byId.get('dvorak'), tables, { keyboard: 'iso' });
	const d = E.diff(qwerty, dvorak);
	check(
		d.metrics.sfb.a === 100 &&
			d.metrics.sfb.b === 0 &&
			d.metrics.sfb.delta === 100 &&
			d.metrics.sfb.verdict === 'worse',
		`diff: sfb ${JSON.stringify(d.metrics.sfb)}`
	);
	check(
		d.metrics.hand_change.delta === -100 && d.metrics.hand_change.verdict === 'none',
		`diff: hand_change ${JSON.stringify(d.metrics.hand_change)}`
	);
	check(
		near(d.score.delta, qwerty.score.total - dvorak.score.total) &&
			d.score.verdict === (d.score.delta > 0 ? 'better' : 'worse'),
		`diff: score ${JSON.stringify(d.score)}`
	);
	check(
		E.diff(dvorak, qwerty).metrics.sfb.verdict === 'better',
		'diff: the other way round, Dvorak is better on SFB'
	);
	check(
		Object.values(E.diff(qwerty, qwerty).metrics).every(
			(m) => m.delta === 0 && (m.verdict === 'same' || m.verdict === 'none')
		),
		'diff: a layout against itself changes nothing'
	);
	let refused = false;
	try {
		E.diff(qwerty, { metrics: {} });
	} catch {
		refused = true;
	}
	check(refused, 'diff: a result without metrics is refused');
}

// The good events per key, worked by hand. « asdf » on QWERTY: as, sd and df
// each roll inward on the left hand, so roll_in is 100 %; A and F take part in
// one of the three bigrams (33.3 %), S and D in two (66.7 %), and each roll is
// shared by its two keys: 16.7, 33.3, 33.3 and 16.7, adding up to 100.
// « fjf » is one trigram alternating hands: F takes part twice, J once, so
// F holds two thirds of alternation's 100 % and J one third.
{
	const rolls = E.analyse(byId.get('qwerty'), E.ngramsFromText('asdf'), { keyboard: 'iso' });
	check(near(rolls.metrics.roll_in, 100), `gain: roll_in = ${rolls.metrics.roll_in}`);
	const expected = { KeyA: 100 / 6, KeyS: 100 / 3, KeyD: 100 / 3, KeyF: 100 / 6, KeyJ: 0 };
	for (const [code, part] of Object.entries(expected))
		check(
			near(rolls.keys[code].gain.roll_in, part),
			`gain: ${code} roll_in part ${rolls.keys[code].gain.roll_in}`
		);
	check(
		Object.values(rolls.keys).every((key) => key.gain.alternation === 0 && key.gain.roll_out === 0),
		'gain: « asdf » neither alternates nor rolls outward'
	);
	const values = E.keyValues(rolls, 'roll_in');
	check(near(values.KeyS, 100 / 3) && near(values.KeyA, 100 / 6), 'keyValues: reads a gain');
	check(near(E.keyValues(rolls, 'presses').KeyA, 25), 'keyValues: reads the presses');
	const alternate = E.analyse(byId.get('qwerty'), E.ngramsFromText('fjf'), { keyboard: 'iso' });
	check(
		near(alternate.metrics.alternation, 100),
		`gain: alternation = ${alternate.metrics.alternation}`
	);
	check(
		near(alternate.keys.KeyF.gain.alternation, 200 / 3) &&
			near(alternate.keys.KeyJ.gain.alternation, 100 / 3),
		`gain: F ${alternate.keys.KeyF.gain.alternation}, J ${alternate.keys.KeyJ.gain.alternation}`
	);
	let refused = false;
	try {
		E.keyValues(rolls, 'home_row');
	} catch {
		refused = true;
	}
	check(refused, 'keyValues: a metric that is not per key is refused');
}

// Each finger's part of the travel, worked by hand: « ed » on QWERTY presses E
// (the left middle finger's top-row key) and D (its home key, no travel) over
// two characters, so the left middle finger travels half of E's reach per
// character, which is the whole distance; every other finger travels nothing.
{
	const result = E.analyse(byId.get('qwerty'), E.ngramsFromText('ed'), { keyboard: 'iso' });
	const board = E.keyboard('iso');
	const reachE = board.reach[board.codes.indexOf('KeyE')];
	check(reachE > 0, `fingerDistance: KeyE reaches ${reachE} mm`);
	check(
		near(result.fingerDistance.lm, reachE / 2) &&
			near(result.fingerDistance.lm, result.metrics.distance),
		`fingerDistance: lm = ${result.fingerDistance.lm}, distance ${result.metrics.distance}`
	);
	check(
		Object.entries(result.fingerDistance).every(([id, mm]) => id === 'lm' || mm === 0),
		'fingerDistance: the other fingers travel nothing'
	);
}

// The heaviest groups of the whole board, worked by hand: « eded » holds the
// bigrams ed, de, ed, three SFBs of the same pair E-D (100 % of the bigrams);
// its trigrams ede and ded repeat a key, so they are no skipgram. Counted only
// for a layout analysed in detail (keyGroups).
{
	const tables = E.ngramsFromText('eded');
	const result = E.analyse(byId.get('qwerty'), tables, { keyboard: 'iso', keyGroups: true });
	const sfb = result.topGroups.sfb;
	check(
		sfb.length === 1 &&
			sfb[0].keys.slice().sort().join(' ') === 'KeyD KeyE' &&
			sfb[0].count === 3 &&
			near(sfb[0].share, 100),
		`topGroups: sfb ${JSON.stringify(sfb)}`
	);
	check(result.topGroups.sfs.length === 0, 'topGroups: no skipgram in « eded »');
	check(
		E.analyse(byId.get('qwerty'), tables, { keyboard: 'iso' }).topGroups === undefined,
		'topGroups: a ranking (no keyGroups) does not count them'
	);
}

// keyDiff, worked by hand: on « ed », QWERTY's E and D each carry half of the
// 100 % of SFB (50) and Dvorak's none; the presses move from QWERTY's E and D
// to Dvorak's KeyD (its e) and KeyH (its d): E +50, D 0, H −50.
{
	const tables = E.ngramsFromText('ed');
	const qwerty = E.analyse(byId.get('qwerty'), tables, { keyboard: 'iso' });
	const dvorak = E.analyse(byId.get('dvorak'), tables, { keyboard: 'iso' });
	const sfb = E.keyDiff(qwerty, dvorak, 'sfb');
	check(
		near(sfb.KeyE, 50) && near(sfb.KeyD, 50) && sfb.KeyH === 0,
		`keyDiff: sfb ${sfb.KeyE} ${sfb.KeyD}`
	);
	const presses = E.keyDiff(qwerty, dvorak, 'presses');
	check(
		near(presses.KeyE, 50) && near(presses.KeyD, 0) && near(presses.KeyH, -50),
		`keyDiff: presses E ${presses.KeyE}, D ${presses.KeyD}, H ${presses.KeyH}`
	);
	let refused = false;
	try {
		E.keyDiff(qwerty, E.analyse(byId.get('dvorak'), tables, { keyboard: 'ansi' }), 'sfb');
	} catch {
		refused = true;
	}
	check(refused, 'keyDiff: two keyboards are refused');
}

// standing, worked by hand: three results equal but for their SFB (1, 2 and
// 2 %, lower is better): the first beats both, the second ties the third and
// loses to the first; a metric shown but not scored is left out.
{
	const base = E.analyse(byId.get('qwerty'), E.ngramsFromText('ed'), { keyboard: 'iso' });
	const fake = (id, sfb) => ({
		layout: { id },
		metrics: Object.assign({}, base.metrics, { sfb })
	});
	const results = [fake('a', 1), fake('b', 2), fake('c', 2)];
	const a = E.standing(results, 'a');
	const b = E.standing(results, 'b');
	check(
		JSON.stringify(a.sfb) === JSON.stringify({ beats: 2, ties: 0, loses: 0, others: 2 }),
		`standing: a ${JSON.stringify(a.sfb)}`
	);
	check(
		JSON.stringify(b.sfb) === JSON.stringify({ beats: 0, ties: 1, loses: 1, others: 2 }),
		`standing: b ${JSON.stringify(b.sfb)}`
	);
	check(b.roll_in.ties === 2 && !('hand_change' in b), 'standing: ties and unscored metrics');
	let refused = false;
	try {
		E.standing(results, 'z');
	} catch {
		refused = true;
	}
	check(refused, 'standing: a layout not among the results is refused');
}

// =====================================
// ======= 2/ Exact key n-grams ========
// =====================================

/**
 * Types a text the way the engine's typing plan does, token by token: a
 * chord where its two characters follow each other, then each token's way
 * chosen from the tokens before and after it (null at an edge or beside an
 * unsupported character).
 * @returns {Array<object|null>} One way per token, null for an unsupported one.
 */
function typeSegment(plan, segment) {
	const chars = Array.from(segment);
	const tokens = [];
	for (let i = 0; i < chars.length; i++) {
		if (i + 1 < chars.length && plan.chords.includes(chars[i] + chars[i + 1])) {
			tokens.push(chars[i] + chars[i + 1]);
			i++;
		} else tokens.push(chars[i]);
	}
	const known = (token) => (token !== undefined && plan.ways.has(token) ? token : null);
	return tokens.map((token, i) => {
		const ways = plan.ways.get(token);
		if (!ways) return null;
		return { token, way: ways[plan.choose(known(tokens[i - 1]), token, known(tokens[i + 1]))] };
	});
}

/**
 * Counts SFBs and alternations on the expanded key stream of a text, the
 * definition the tables must reproduce. The tables complete as a Markov chain
 * only the n-grams whose way needs a fourth character: a pair of two
 * multi-way tokens, a triple whose first or last token (not the middle one's)
 * has several ways; those are counted apart (markovBigrams, markovTrigrams),
 * everything else must match exactly.
 */
function streamCounts(layout, text, keyboardId) {
	const plan = E.typingPlan(layout, E.ngramsFromText(text), { keyboard: keyboardId });
	const board = plan.board;
	const thumb = (k) => board.finger[k] === 4 || board.finger[k] === 5;
	const counts = {
		bigrams: 0,
		sfb: 0,
		trigrams: 0,
		alternation: 0,
		sfs: 0,
		markovBigrams: 0,
		markovTrigrams: 0
	};
	for (const segment of text.split(/[\r\n\t]+/)) {
		// Each key with the index of its token and whether that token has several ways.
		const keys = [];
		const flush = () => {
			for (let i = 0; i + 1 < keys.length; i++) {
				const [x, y] = [keys[i], keys[i + 1]];
				const [a, b] = [x.k, y.k];
				if (thumb(a) || thumb(b)) continue;
				counts.bigrams++;
				if (x.token !== y.token && x.multi && y.multi) counts.markovBigrams++;
				if (a !== b && board.finger[a] === board.finger[b]) counts.sfb++;
			}
			for (let i = 0; i + 2 < keys.length; i++) {
				const [x, y, z] = [keys[i], keys[i + 1], keys[i + 2]];
				const [a, b, c] = [x.k, y.k, z.k];
				if (thumb(a) || thumb(b) || thumb(c)) continue;
				counts.trigrams++;
				if ((x.multi && x.token !== y.token) || (z.multi && z.token !== y.token))
					counts.markovTrigrams++;
				if (board.finger[a] === board.finger[c] && a !== c) counts.sfs++;
				const sameFinger =
					board.finger[a] === board.finger[b] || board.finger[b] === board.finger[c];
				if (!sameFinger && board.hand[a] !== board.hand[b] && board.hand[b] !== board.hand[c])
					counts.alternation++;
			}
			keys.length = 0;
		};
		typeSegment(plan, segment).forEach((seq, token) => {
			// An unsupported character cuts the stream, as it cuts the tables.
			if (!seq) {
				flush();
				return;
			}
			const multi = plan.ways.get(seq.token).length > 1;
			for (const k of seq.way.keys) keys.push({ k, token, multi });
		});
		flush();
	}
	return counts;
}

const STREAM_TEXT =
	'À l’été, ça bêêle : « où êtes-vous ? » Ô déjà-vu, Noël à Ïle-de-France ; naïf cœur, ' +
	'l’âme sœur dîne. The quick brown fox jumps over the lazy dog.';
for (const id of ['azerty', 'bepo', 'ergol', 'ergopti_plus', 'qwerty']) {
	const layout = byId.get(id);
	const expected = streamCounts(layout, STREAM_TEXT, 'iso');
	const result = E.analyse(layout, E.ngramsFromText(STREAM_TEXT), { keyboard: 'iso' });
	check(
		result.coverage.bigrams === expected.bigrams,
		`${id}: ${result.coverage.bigrams} key bigrams from tables, ${expected.bigrams} on the stream`
	);
	check(
		result.coverage.trigrams === expected.trigrams,
		`${id}: ${result.coverage.trigrams} key trigrams from tables, ${expected.trigrams} on the stream`
	);
	const pct = (part, whole) => (whole > 0 ? (100 * part) / whole : 0);
	// Exact, but for the share of the n-grams the Markov completion estimates.
	const within = (got, want, markov, whole) =>
		Math.abs(got - want) <= pct(markov, whole) + TOLERANCE * Math.max(1, Math.abs(want));
	check(
		within(
			result.metrics.sfb,
			pct(expected.sfb, expected.bigrams),
			expected.markovBigrams,
			expected.bigrams
		),
		`${id}: SFB differs from the stream`
	);
	check(
		within(
			result.metrics.sfs,
			pct(expected.sfs, expected.trigrams),
			expected.markovTrigrams,
			expected.trigrams
		),
		`${id}: SFS differs from the stream`
	);
	check(
		within(
			result.metrics.alternation,
			pct(expected.alternation, expected.trigrams),
			expected.markovTrigrams,
			expected.trigrams
		),
		`${id}: alternation differs from the stream`
	);
	// The completion has something to do on this text for some layout, and on
	// one with a single way per character (QWERTY) nothing at all.
	if (id === 'qwerty')
		check(expected.markovBigrams + expected.markovTrigrams === 0, 'qwerty: no n-gram to complete');
}
// keyNgrams, the input of the analyser scorers, holds the same stream.
{
	const tables = E.prepareNgrams(E.ngramsFromText(STREAM_TEXT));
	for (const id of ['bepo', 'ergol', 'qwerty']) {
		const layout = byId.get(id);
		const expected = streamCounts(layout, STREAM_TEXT, 'iso');
		const k = E.keyNgrams(layout, tables, { keyboard: 'iso' });
		const thumb = (i) => k.board.finger[i] === 4 || k.board.finger[i] === 5;
		let bigrams = 0;
		let sfb = 0;
		for (const [code, n] of k.bigrams) {
			const [a, b] = [Math.floor(code / k.KEY_BASE), code % k.KEY_BASE];
			if (thumb(a) || thumb(b)) continue;
			bigrams += n;
			if (a !== b && k.board.finger[a] === k.board.finger[b]) sfb += n;
		}
		let trigrams = 0;
		for (const [code, n] of k.trigrams) {
			const keys = [
				Math.floor(code / k.KEY_BASE ** 2),
				Math.floor(code / k.KEY_BASE) % k.KEY_BASE,
				code % k.KEY_BASE
			];
			if (!keys.some(thumb)) trigrams += n;
		}
		check(
			bigrams === expected.bigrams,
			`${id}: keyNgrams has ${bigrams} key bigrams, ${expected.bigrams} on the stream`
		);
		check(sfb === expected.sfb, `${id}: keyNgrams has ${sfb} SFBs, ${expected.sfb} on the stream`);
		check(
			trigrams === expected.trigrams,
			`${id}: keyNgrams has ${trigrams} key trigrams, ${expected.trigrams} on the stream`
		);
		check(E.keyNgrams(layout, tables, { keyboard: 'iso' }) === k, `${id}: keyNgrams is not cached`);
	}
}
check(
	E.analyse(byId.get('ergol'), E.ngramsFromText('été'), {}).metrics.dead_key_usage > 0,
	'Ergo-L types é with its dead key: the stream test needs a dead key'
);

// ========================
// ======= 3/ Score =======
// ========================

const ngrams = E.ngramsFromText(STREAM_TEXT);
const result = E.analyse(byId.get('ergopti'), ngrams, {});
const defaults = E.defaultWeights();
let sum = 0;
for (const [metric, weight] of Object.entries(defaults)) {
	const sign = E.METRICS[metric].better === 'higher' ? 1 : -1;
	check(
		near(result.score.contributions[metric], sign * weight * result.metrics[metric]),
		`score: contribution of ${metric}`
	);
	sum += result.score.contributions[metric];
}
check(near(result.score.total, sum), 'score: the total is the sum of the contributions');
const custom = E.score(result, { sfb: 0 });
check(custom.contributions.sfb === 0, 'score: a zero weight removes the metric');
check(
	near(custom.total, sum - result.score.contributions.sfb),
	'score: only the changed weight moves'
);
check(
	E.defaultWeights().sfb === defaults.sfb,
	'score: a custom weight leaves the defaults unchanged'
);
for (const bad of [{ nonsense: 1 }, { repeat: 1 }, { sfb: -1 }, { sfb: Infinity }]) {
	let threw = false;
	try {
		E.score(result, bad);
	} catch {
		threw = true;
	}
	check(threw, `score: ${JSON.stringify(bad)} must throw`);
}
// The ideal finger load: the maintainer's order (index ≥ middle ≥ ring ≥
// pinky, pinkies under 8 %), editable per analysis, checked when edited.
const ideal = E.defaultIdealLoad();
for (const hand of ['l', 'r']) {
	const [p, r, m, i] = ['p', 'r', 'm', 'i'].map((f) => ideal[hand + f]);
	check(
		i >= m && m >= r && r >= p,
		`ideal load: ${hand} hand breaks index ≥ middle ≥ ring ≥ pinky`
	);
	check(p < 8, `ideal load: ${hand} pinky at ${p} %, not under 8 %`);
	check(near(p + r + m + i, 50), `ideal load: ${hand} hand sums to ${p + r + m + i}, not 50`);
}
const allIndex = Object.fromEntries(Object.keys(ideal).map((f) => [f, 0]));
allIndex.li = 100;
const onF = E.analyse(byId.get('qwerty'), E.ngramsFromText('f'), { idealLoad: allIndex });
check(onF.metrics.finger_imbalance === 0, 'ideal load: an edited target is the one measured');
check(E.defaultIdealLoad().li === ideal.li, 'ideal load: an edited target leaves the default');
for (const bad of [
	{ li: 100 },
	Object.assign({}, ideal, { li: -1 }),
	Object.assign({}, ideal, { li: 40 })
]) {
	let threw = false;
	try {
		E.analyse(byId.get('qwerty'), E.ngramsFromText('f'), { idealLoad: bad });
	} catch {
		threw = true;
	}
	check(threw, `ideal load: ${JSON.stringify(bad)} must throw`);
}
// An edited load keeps the order too: a pinky above its ring finger, on either
// hand, is refused with its code, even when the shares sum to 100.
for (const [hand, pinky, ring] of [
	['left', 'lp', 'lr'],
	['right', 'rp', 'rr']
]) {
	const swapped = Object.assign({}, ideal, { [pinky]: ideal[ring], [ring]: ideal[pinky] });
	let refusal = null;
	try {
		E.idealLoad(swapped);
	} catch (error) {
		refusal = error;
	}
	check(
		refusal && refusal.code === 'ideal_load_order',
		`ideal load: the ${hand} hand's swapped pinky and ring are refused`
	);
	check(
		refusal && refusal.values.finger === ring && refusal.values.below === pinky,
		`ideal load: the ${hand} refusal names ${ring} below ${pinky}`
	);
}
check(
	E.idealLoad(Object.assign({}, ideal)).li === ideal.li,
	'ideal load: the default order passes'
);

// Fingering profiles. The default board derives the lateral keys this list
// once named by hand (index inner column, pinky outer keys).
const LATERAL_KEYS = [
	'Digit5',
	'KeyT',
	'KeyG',
	'KeyB',
	'Digit6',
	'KeyY',
	'KeyH',
	'KeyN',
	'Backquote',
	'IntlBackslash',
	'Minus',
	'Equal',
	'BracketLeft',
	'BracketRight',
	'Quote',
	'Backslash'
];
for (const id of ['iso', 'ansi', 'ortho', 'iso_angle']) {
	const board = E.keyboard(id);
	const lateral = board.codes.filter((_, k) => board.lateral[k]).sort();
	const expected = LATERAL_KEYS.filter((code) => board.index.has(code)).sort();
	check(
		JSON.stringify(lateral) === JSON.stringify(expected),
		`profile: ${id} lateral keys ${lateral.join(' ')}`
	);
}
// An index resting one column in: its home key costs nothing, F costs a reach,
// G stops being lateral, and the home row still counts both.
const shifted = { home: { li: 'KeyG' }, fingers: { KeyG: 'li' } };
const onGShifted = E.analyse(byId.get('qwerty'), E.ngramsFromText('g'), { profile: shifted });
const onFShifted = E.analyse(byId.get('qwerty'), E.ngramsFromText('f'), { profile: shifted });
check(
	onGShifted.metrics.distance === 0 && onFShifted.metrics.distance > 0,
	'profile: the index home key moved to G'
);
check(
	!E.keyboard('iso', shifted).lateral[E.keyboard('iso', shifted).index.get('KeyG')],
	'profile: G is the home column'
);
check(onFShifted.metrics.home_row === 100, 'profile: F stays on the index home row');
// A key given to another finger moves its load; a home row one row up counts
// the top row as home.
const ringOnV = E.analyse(byId.get('qwerty'), E.ngramsFromText('v'), {
	profile: { fingers: { KeyV: 'lr' } }
});
check(ringOnV.fingers.lr === 100, 'profile: V pressed by the left ring finger');
const topHome = {
	home: {
		lp: 'KeyQ',
		lr: 'KeyW',
		lm: 'KeyE',
		li: 'KeyR',
		ri: 'KeyU',
		rm: 'KeyI',
		rr: 'KeyO',
		rp: 'KeyP'
	}
};
const onR = E.analyse(byId.get('qwerty'), E.ngramsFromText('r'), { profile: topHome });
check(onR.metrics.home_row === 100 && onR.metrics.distance === 0, 'profile: a home row one row up');
const onV = E.analyse(byId.get('qwerty'), E.ngramsFromText('v'), { profile: topHome });
check(
	onV.metrics.bottom_row === 0 && onV.metrics.distance > 0,
	'profile: V is two rows below that home row'
);
check(
	E.analyse(byId.get('qwerty'), ngrams, { profile: {} }).score.total ===
		E.analyse(byId.get('qwerty'), ngrams, {}).score.total,
	'profile: an empty profile is the default'
);
// Each refusal carries a stable code and the values its message names, so the
// page shows it in the reader's language (layout_analysis.error.<code>).
for (const [bad, code, values] of [
	[{ fingers: { KeyQ: 'nose' } }, 'fingering_unknown_finger', { finger: 'nose' }],
	[{ fingers: { NoKey: 'lp' } }, 'fingering_unknown_key', { key: 'NoKey' }],
	[{ home: { li: 'KeyJ' } }, 'home_key_other_finger', { key: 'KeyJ', finger: 'li' }],
	[{ base: 'diagonal' }, 'fingering_unknown_base', { base: 'diagonal' }],
	['not a profile', 'fingering_not_object', {}]
]) {
	let refusal = null;
	try {
		E.keyboard('iso', bad);
	} catch (error) {
		refusal = error;
	}
	check(
		refusal instanceof E.AnalysisError &&
			refusal.code === code &&
			JSON.stringify(refusal.values) === JSON.stringify(values),
		`profile: ${JSON.stringify(bad)} is refused as ${code} ${JSON.stringify(values)}`
	);
}

// The user's shortcut table and compact form factor weights (maintainer,
// 2026-11-14: editable in the Studio): absent, the model's; edited, the
// metrics follow; out of range, refused with a stable code.
const qwerty = byId.get('qwerty');
const defaultShortcuts = E.defaultShortcuts();
check(
	E.analyse(qwerty, ngrams, { shortcuts: defaultShortcuts }).metrics.shortcut_left ===
		E.analyse(qwerty, ngrams, {}).metrics.shortcut_left,
	'shortcuts: the default table is the model'
);
const onlyZ = {
	letters: Object.fromEntries(
		Object.keys(defaultShortcuts.letters).map((l) => [l, l === 'z' ? 10 : 0])
	),
	ease: defaultShortcuts.ease
};
check(
	near(
		E.analyse(qwerty, ngrams, { shortcuts: onlyZ }).metrics.shortcut_left,
		100 * defaultShortcuts.ease.KeyZ
	),
	'shortcuts: with Z alone, shortcut_left is the ease of its key'
);
const only40 = Object.fromEntries(
	Object.keys(E.defaultFormFactorWeights()).map((f) => [f, f === '40' ? 1 : 0])
);
check(
	E.analyse(qwerty, E.ngramsFromText('a1'), { formWeights: only40 }).metrics.compact_fit === 50,
	'form factors: on the 40 % alone, a digit is lost'
);
for (const [call, code, values] of [
	[
		() =>
			E.shortcuts({ letters: { ...defaultShortcuts.letters, z: 11 }, ease: defaultShortcuts.ease }),
		'shortcut_letter_value',
		{ letter: 'z', max: 10 }
	],
	[
		() =>
			E.shortcuts({
				letters: { ...defaultShortcuts.letters, '!': 1 },
				ease: defaultShortcuts.ease
			}),
		'shortcut_letter_unknown',
		{ letter: '!' }
	],
	[
		() =>
			E.shortcuts({
				letters: defaultShortcuts.letters,
				ease: { ...defaultShortcuts.ease, KeyA: 2 }
			}),
		'shortcut_key_value',
		{ key: 'KeyA', max: 1 }
	],
	[() => E.shortcuts({ letters: defaultShortcuts.letters }), 'shortcuts_not_object', {}],
	[() => E.formFactorWeights({ ...only40, 40: -1 }), 'form_factor_weight', { form: '40' }],
	[() => E.formFactorWeights({ ...only40, 50: 1 }), 'form_factor_unknown', { form: '50' }],
	[() => E.formFactorWeights({ ...only40, 40: 0 }), 'form_weights_zero', {}]
]) {
	let refusal = null;
	try {
		call();
	} catch (error) {
		refusal = error;
	}
	check(
		refusal instanceof E.AnalysisError &&
			refusal.code === code &&
			JSON.stringify(refusal.values) === JSON.stringify(values),
		`tables: refused as ${code} ${JSON.stringify(values)}, got ${refusal && refusal.code}`
	);
}

// Split, ortholinear and column-staggered boards: their own positions, fingers
// and homes; keys they lack are reported, not dropped silently.
for (const id of ['corne', 'planck', 'ergodox', 'moonlander', 'kinesis_advantage']) {
	const board = E.keyboard(id);
	check(
		board.homeOf.every((k) => k !== undefined),
		`board ${id}: a finger has no home key`
	);
	const onBoard = E.analyse(byId.get('qwerty'), E.ngramsFromText('fj'), { keyboard: id });
	check(onBoard.metrics.distance === 0, `board ${id}: f and j are home keys`);
}
const corne = E.analyse(byId.get('qwerty'), E.ngramsFromText('a1'), { keyboard: 'corne' });
check(
	corne.coverage.missingKeys.includes('Digit1') && corne.metrics.unsupported === 50,
	'board corne: no number row, reported and unsupported'
);
// Rows are counted along each staggered column: E stays one row above home.
const dox = E.keyboard('ergodox');
check(dox.relRow[dox.index.get('KeyE')] === -1, 'board ergodox: E one row above the home row');

const ranked = E.compare([byId.get('qwerty'), byId.get('ergopti')], ngrams, {});
check(ranked[0].layout.id === 'ergopti' && ranked[0].rank === 1, 'compare: Ergopti beats QWERTY');
// The access weights choose the ways of typing: rescore keeps them, and a
// change of one needs a new analysis.
const zeroOthers = Object.fromEntries(
	Object.keys(defaults).map((m) => [m, E.ACCESS_WEIGHTS.includes(m) ? defaults[m] : 0])
);
const flipped = E.rescore(ranked, zeroOthers);
check(
	flipped.every((r) => {
		const access = E.ACCESS_WEIGHTS.reduce((sum, m) => sum - defaults[m] * r.metrics[m], 0);
		return Math.abs(r.score.total - access) < 1e-9;
	}),
	'rescore: zero weights but the access ones leave only the access contributions'
);
for (const id of E.ACCESS_WEIGHTS) {
	let refused = false;
	try {
		E.rescore(ranked, { [id]: defaults[id] + 1 });
	} catch (error) {
		refused = /analyse again/.test(error.message);
	}
	check(refused, `rescore: a changed ${id} is refused, it chooses the ways of typing`);
}
// The score settings file: an export read back gives the same settings, the
// defaults (the « reset ») included, and every malformed file is refused whole
// with its code.
{
	const custom = {
		weights: Object.assign(E.defaultWeights(), { sfb: 7.25, altgr_usage: 0, dead_key_usage: 4 }),
		idealLoad: Object.assign({}, E.defaultIdealLoad()),
		shortcuts: E.defaultShortcuts(),
		formWeights: E.defaultFormFactorWeights()
	};
	custom.shortcuts.letters.c = 3;
	const defaultsSettings = {
		weights: E.defaultWeights(),
		idealLoad: Object.assign({}, E.defaultIdealLoad()),
		shortcuts: E.defaultShortcuts(),
		formWeights: E.defaultFormFactorWeights()
	};
	for (const [name, settings] of [
		['custom', custom],
		['defaults', defaultsSettings]
	]) {
		const file = JSON.parse(JSON.stringify(E.scoreConfig(settings)));
		check(
			file.format === 'ergopti-score-settings' &&
				file.schema_version === 1 &&
				file.analyser === 'ergopti',
			`score config: ${name} names its format, version and analyser`
		);
		const back = E.readScoreConfig(file);
		check(
			JSON.stringify(back) === JSON.stringify(settings),
			`score config: ${name} round trip gives ${JSON.stringify(back)}`
		);
	}
	const good = () => JSON.parse(JSON.stringify(E.scoreConfig(custom)));
	const refusals = [
		['config_not_object', () => []],
		['config_unknown_key', () => Object.assign(good(), { extra: 1 })],
		[
			'config_unknown_key',
			() => {
				const file = good();
				file.weights.typo_sfb = 1;
				return file;
			}
		],
		[
			'config_missing',
			() => {
				const file = good();
				delete file.ideal_load;
				return file;
			}
		],
		[
			'config_missing',
			() => {
				const file = good();
				delete file.weights.altgr_usage;
				return file;
			}
		],
		['config_format', () => Object.assign(good(), { format: 'kla' })],
		['config_version', () => Object.assign(good(), { schema_version: 2 })],
		['config_analyser', () => Object.assign(good(), { analyser: 'oxeylyzer' })],
		[
			'config_weight_type',
			() => {
				const file = good();
				file.weights.sfb = '10';
				return file;
			}
		],
		['config_weight_type', () => Object.assign(good(), { shortcuts: null })],
		[
			'config_weight_range',
			() => {
				const file = good();
				file.weights.sfb = -1;
				return file;
			}
		],
		[
			'ideal_load_sum',
			() => {
				const file = good();
				file.ideal_load.lp += 10;
				return file;
			}
		],
		[
			'shortcut_letter_value',
			() => {
				const file = good();
				file.shortcuts.letters.c = 11;
				return file;
			}
		],
		[
			'form_weights_zero',
			() => {
				const file = good();
				for (const id of Object.keys(file.form_weights)) file.form_weights[id] = 0;
				return file;
			}
		]
	];
	for (const [code, make] of refusals) {
		let caught = null;
		try {
			E.readScoreConfig(make());
		} catch (error) {
			caught = error;
		}
		check(
			caught && caught.name === 'AnalysisError' && caught.code === code,
			`score config: expected the refusal ${code}, got ${caught ? caught.code || caught.message : 'none'}`
		);
	}
	let exportRefused = false;
	try {
		E.scoreConfig(
			Object.assign({}, custom, { weights: Object.assign({}, custom.weights, { sfb: -2 }) })
		);
	} catch (error) {
		exportRefused = error.code === 'config_weight_range';
	}
	check(exportRefused, 'score config: an export of settings the import would refuse is refused');
}
const zeroAll = Object.fromEntries(Object.keys(defaults).map((m) => [m, 0]));
check(
	E.compare([byId.get('qwerty'), byId.get('ergopti')], ngrams, { weights: zeroAll }).every(
		(r) => r.score.total === 0
	),
	'analyse: all-zero weights give every layout zero'
);

// ==========================
// ======= 4/ Library =======
// ==========================

check(library.length >= MIN_LIBRARY, `library: only ${library.length} layouts`);
check(byId.size === library.length, 'library: duplicate ids');
const registry = JSON.parse(fs.readFileSync(REGISTRY_INDEX, 'utf8')).layouts;
for (const entry of registry) {
	const layout = byId.get(entry.id);
	check(layout && layout.origin === 'registry', `library: registry layout ${entry.id} is missing`);
}
check(Object.keys(byId.get('bepo').dead).length > 0, 'library: Bépo keeps its dead keys');
// A dead key pressed in a dead state chains: Ergo-L's 1dk twice is the diaeresis.
check(
	JSON.stringify(
		E.analyse(byId.get('ergol'), E.ngramsFromText('ëË'), {}).coverage.unsupportedChars
	) === '{}',
	'library: Ergo-L types ë and Ë through 1dk 1dk'
);
check(byId.get('qwerty').rows.KeyQ[0] === 'q', 'library: QWERTY types q on KeyQ');
// An alphabetic block keeps or regains what QWERTY types outside it (Colemak's
// Quote key, the / and ? Dvorak's block displaces).
const types = (id, char) =>
	Object.values(byId.get(id).rows).some((row) => row.slice(0, 2).includes(char));
for (const [id, chars] of [
	['colemak', ["'", '"', '[', '-']],
	['dvorak', ['/', '?', ';', ':']]
])
	for (const char of chars) check(types(id, char), `library: ${id} cannot type ${char}`);
// Dvorak is the standard ANSI one (dvorak-ansi-2026-11-18): [ ] on the number
// row's right, / = after L, - after S; its alphabetic block alone left them
// where QWERTY has them.
for (const [code, base, shift] of [
	['Minus', '[', '{'],
	['Equal', ']', '}'],
	['BracketLeft', '/', '?'],
	['BracketRight', '=', '+'],
	['Quote', '-', '_'],
	['KeyQ', "'", '"'],
	['KeyZ', ';', ':']
]) {
	const row = byId.get('dvorak').rows[code];
	check(
		row[0] === base && row[1] === shift,
		`library: Dvorak's ${code} is ${row[0]} ${row[1]}, the ANSI Dvorak's ${base} ${shift}`
	);
}
// Credits: a registry layout from its meta.toml, another from layout_credits.json.
check(
	byId.get('bepo').authors[0] === 'bépo community (bepo.fr)',
	'library: bépo is not credited from its meta.toml'
);
check(byId.get('dvorak').authors.includes('August Dvorak'), 'library: Dvorak is not credited');
check(
	library.every((layout) => layout.authors.length > 0 || layout.source !== ''),
	'library: a layout has neither an author nor a source'
);
// A credit read on its author's page records the page, the date and what it
// says; Hands Down's site names « R. Alan Reiser ».
{
	const credits = JSON.parse(
		fs.readFileSync(shared('layouts', 'data', 'analysis', 'layout_credits.json'), 'utf8')
	).credits;
	for (const [id, credit] of Object.entries(credits)) {
		check(
			['source', 'collection', 'knowledge'].includes(credit.basis),
			`credits: ${id} has the unknown basis ${credit.basis}`
		);
		if (credit.checked !== undefined)
			check(
				/^\d{4}-\d{2}-\d{2}$/.test(credit.checked) &&
					typeof credit.evidence === 'string' &&
					credit.evidence !== '' &&
					typeof credit.url === 'string',
				`credits: ${id} was checked but records no date, evidence or page`
			);
	}
	// One entry per arrangement: no two layouts have the same letters on the
	// same keys and the same digits (the import's duplicate rule).
	const { signature } = require('../build/import-kla-layouts.cjs');
	const codes = E.typingCodes();
	const seen = new Map();
	for (const layout of library) {
		const key = signature(layout.rows, codes);
		check(!seen.has(key), `library: ${layout.id} has the keys of ${seen.get(key)}`);
		seen.set(key, layout.id);
	}
	check(
		byId.get('hands_down').authors[0] === 'R. Alan Reiser' &&
			byId.get('hands_down').url === 'https://sites.google.com/alanreiser.com/handsdown',
		'library: Hands Down is not credited from its author’s site'
	);
}
check(byId.get('azerty').rows.KeyQ[0] === 'a', 'library: AZERTY types a on KeyQ');
for (const layout of library) {
	const r = E.analyse(layout, ngrams, {});
	check(Number.isFinite(r.score.total), `library: ${layout.id} has no finite score`);
}

// =========================================
// ======= 4b/ Per-key costs (heatmap) =====
// =========================================

// (studio-key-heatmap) Each key's part of a metric adds up to the metric, so a
// key's colour and the score it costs are the metric's own numbers, split.
{
	const swann = E.ngramsFromText(fs.readFileSync(SPEED_CORPUS, 'utf8').slice(0, 20000));
	for (const id of ['azerty', 'ergopti', 'qwerty']) {
		const r = E.analyse(byId.get(id), swann, { keyGroups: true });
		for (const metric of E.KEY_COST_METRICS) {
			const sum = Object.values(r.keys).reduce((total, key) => total + key.cost[metric], 0);
			check(
				near(sum, r.metrics[metric]),
				`key costs: ${id} ${metric} keys add up to ${sum}, the metric is ${r.metrics[metric]}`
			);
		}
		const points = Object.values(E.keyScoreCost(r)).reduce((total, cost) => total + cost, 0);
		const expected = E.KEY_COST_METRICS.reduce(
			(total, metric) => total + (E.defaultWeights()[metric] || 0) * r.metrics[metric],
			0
		);
		check(
			near(points, expected),
			`key costs: ${id} score costs add up to ${points}, not ${expected}`
		);
		const doubled = E.keyScoreCost(r, { sfb: 2 * E.defaultWeights().sfb });
		const code = Object.keys(r.keys).find((c) => r.keys[c].cost.sfb > 0);
		check(
			near(doubled[code] - E.keyScoreCost(r)[code], E.defaultWeights().sfb * r.keys[code].cost.sfb),
			'key costs: a weight changes the score cost by weight × the key part'
		);
	}
	// QWERTY: « ed » is a same-finger pair, « sad » a redirect without the index.
	const qwerty = byId.get('qwerty');
	const tiny = E.ngramsFromText('ed ed ed sad sad');
	const grouped = E.analyse(qwerty, tiny, { keyGroups: true }).keys;
	check(
		JSON.stringify(grouped.KeyE.worst.sfb.map(([others]) => others)) === JSON.stringify([['KeyD']]),
		`worst groups: KeyE's SFB partner is ${JSON.stringify(grouped.KeyE.worst.sfb)}`
	);
	const redirect = grouped.KeyA.worst.redirect_bad.map(([others]) => others.slice().sort());
	check(
		JSON.stringify(redirect) === JSON.stringify([['KeyD', 'KeyS']]),
		`worst groups: KeyA's bad redirect is ${JSON.stringify(redirect)}`
	);
	check(grouped.KeyA.worst.redirect_bad[0][1] > 0, 'worst groups: a group carries its share');
	const plainKeys = E.analyse(qwerty, tiny, {}).keys;
	check(plainKeys.KeyA.worst.redirect_bad.length === 0, 'worst groups: counted only when asked');
	check(plainKeys.KeyE.worst.sfb.length === 1, 'worst groups: the SFB partners are always counted');
	// The events shown but not scored split over their keys the same way.
	const r = E.analyse(byId.get('ergopti'), swann, {});
	for (const metric of E.KEY_INFO_METRICS) {
		const sum = Object.values(E.keyValues(r, metric)).reduce((total, v) => total + v, 0);
		check(near(sum, r.metrics[metric]), `key parts: ${metric} keys add up to ${sum}`);
	}
}

// ============================================
// ======= 4c/ Row jumps, pairs and words =====
// ============================================

// (row-jump) Worked by hand on QWERTY ISO, whose rows are 1 (digits) to 4
// (bottom). « qz ex ea 4d ej » has five key bigrams without a thumb (the
// space is the left thumb's): Q→Z (left pinky, rows 2 and 4), E→X (left
// middle then ring, 2 and 4), 4→D (left index then middle, 1 and 3) jump two
// rows; E→A is one row, E→J changes hands. Row jumps are 3 of 5 = 60 %, each
// key of a jump takes half of its 20 %, and the score does not weigh them.
{
	const qwerty = byId.get('qwerty');
	const tables = E.ngramsFromText('qz ex ea 4d ej');
	const result = E.analyse(qwerty, tables, { keyboard: 'iso', keyGroups: true });
	check(near(result.metrics.row_jump, 60), `row jumps: ${result.metrics.row_jump} %, expected 60`);
	check(E.METRICS.row_jump.better === 'none', 'row jumps: shown, not scored');
	check(!('row_jump' in result.score.contributions), 'row jumps: no part of the score');
	check(
		!E.KEY_COST_METRICS.includes('row_jump') && E.KEY_INFO_METRICS.includes('row_jump'),
		'row jumps: a per-key value outside the points a key costs'
	);
	const parts = E.keyValues(result, 'row_jump');
	for (const [code, expected] of Object.entries({
		KeyQ: 10,
		KeyZ: 10,
		KeyE: 10,
		KeyX: 10,
		Digit4: 10,
		KeyD: 10,
		KeyA: 0,
		KeyJ: 0
	}))
		check(
			near(parts[code], expected),
			`row jumps: ${code} carries ${parts[code]}, not ${expected}`
		);
	const groups = result.topGroups.row_jump.map((g) => `${g.keys.join('+')}:${g.count}:${g.share}`);
	check(
		JSON.stringify(groups.slice().sort()) ===
			JSON.stringify(['Digit4+KeyD:1:20', 'KeyE+KeyX:1:20', 'KeyQ+KeyZ:1:20']),
		`row jumps: the board's jumps are ${JSON.stringify(groups)}`
	);
	// One row apart, or the other hand, is no jump.
	const none = E.analyse(qwerty, E.ngramsFromText('ea ej rf'), { keyboard: 'iso' });
	check(none.metrics.row_jump === 0, `row jumps: « ea ej rf » has ${none.metrics.row_jump} %`);

	// (bigram-matrix) The same text, pair by pair: each pair's class from the
	// one visitor, its share of the five bigrams, and its points with the
	// default weights: Q→Z an SFB (−10 × 20 = −200), 4→D a full scissor and
	// an outward roll (−3 × 20 + 0.5 × 20 = −50), E→A and E→X outward rolls
	// (+10), E→J a hand change (0).
	const matrix = E.bigramMatrix(qwerty, tables, { keyboard: 'iso' });
	check(matrix.bigrams === 5, `bigram matrix: ${matrix.bigrams} bigrams, expected 5`);
	const byPair = new Map(matrix.pairs.map((p) => [p.keys.join('+'), p]));
	const expected = {
		'KeyQ+KeyZ': [['row_jump', 'sfb'], -200],
		'Digit4+KeyD': [['roll_out', 'row_jump', 'scissors'], -50],
		'KeyE+KeyA': [['roll_out'], 10],
		'KeyE+KeyX': [['roll_out', 'row_jump'], 10],
		'KeyE+KeyJ': [['hand_change'], 0]
	};
	check(matrix.pairs.length === 5, `bigram matrix: ${matrix.pairs.length} pairs, expected 5`);
	for (const [pair, [events, points]] of Object.entries(expected)) {
		const got = byPair.get(pair);
		check(got, `bigram matrix: no pair ${pair}`);
		if (!got) continue;
		check(
			JSON.stringify(got.events.slice().sort()) === JSON.stringify(events),
			`bigram matrix: ${pair} is ${got.events.join(', ')}`
		);
		check(got.count === 1 && near(got.share, 20), `bigram matrix: ${pair} share ${got.share}`);
		check(near(got.points, points), `bigram matrix: ${pair} = ${got.points} points, not ${points}`);
	}
	check(matrix.keys[0] === 'KeyE', `bigram matrix: the busiest key is ${matrix.keys[0]}`);
	check(!matrix.keys.includes('Space'), 'bigram matrix: no thumb key');
	const heavier = E.bigramMatrix(qwerty, tables, { keyboard: 'iso', weights: { sfb: 1 } });
	check(
		near(heavier.pairs.find((p) => p.keys.join('+') === 'KeyQ+KeyZ').points, -20),
		'bigram matrix: the points follow the weights'
	);
	// On a real text, the pairs add up to analyse()'s bigram metrics and their part of the score.
	const swann = E.ngramsFromText(fs.readFileSync(SPEED_CORPUS, 'utf8').slice(0, 20000));
	for (const id of ['azerty', 'ergopti']) {
		const r = E.analyse(byId.get(id), swann, {});
		const m = E.bigramMatrix(byId.get(id), swann, {});
		check(m.bigrams === r.coverage.bigrams, `bigram matrix: ${id} counts ${m.bigrams} bigrams`);
		const bigramMetrics = Object.keys(E.METRICS).filter((k) => E.METRICS[k].of === 'bigrams');
		for (const metric of bigramMetrics) {
			const share = m.pairs
				.filter((p) => p.events.includes(metric))
				.reduce((sum, p) => sum + p.share, 0);
			check(near(share, r.metrics[metric]), `bigram matrix: ${id} ${metric} pairs ${share}`);
		}
		const points = m.pairs.reduce((sum, p) => sum + p.points, 0);
		const scored = bigramMetrics.reduce((sum, k) => sum + (r.score.contributions[k] || 0), 0);
		check(near(points, scored), `bigram matrix: ${id} pairs give ${points} points, not ${scored}`);
	}

	// (word-effort) Words: letters and marks folded to lower case, an
	// apostrophe or a digit cuts them, one letter is no word, the most
	// frequent first and the table bounded.
	const words = E.wordsFromText("L'homme a vu l'Homme. Ça, ça 4d ÇA");
	check(
		JSON.stringify(words) === JSON.stringify({ ça: 3, homme: 2, vu: 1 }),
		`words: ${JSON.stringify(words)}`
	);
	const many = {};
	for (let i = 0; i < E.WORD_TABLE_SIZE + 50; i++)
		many[`w${String.fromCharCode(97 + (i % 26))}${i}`] = i + 1;
	const bounded = E.wordTable(many);
	check(
		Object.keys(bounded).length === E.WORD_TABLE_SIZE,
		'words: the table keeps WORD_TABLE_SIZE'
	);
	check(Object.values(bounded)[0] === E.WORD_TABLE_SIZE + 50, 'words: the most frequent first');
	check(E.countWords('ab ab', 3).ab === 6, 'words: a word list counts each word its count');
	// (word-prototype) A word named like an Object property counts from zero.
	const proto = E.wordsFromText('constructor Constructor hasOwnProperty');
	check(proto.constructor === 2 && proto.hasownproperty === 1, `words: ${JSON.stringify(proto)}`);
	// Each word measured alone, worked by hand on QWERTY with the default
	// weights: « qz » is one bigram, an SFB (100 % × 10 = 1000 points) with a
	// mean travel of (19.636 + 21.299) / 2 mm (Q and Z from the pinky's home);
	// « ea » is a roll from the top row to home (19.636 / 2 mm, no event).
	const efforts = E.wordEfforts(qwerty, { qz: 1, ea: 3, qé: 2 }, { keyboard: 'iso' });
	const board = E.keyboard('iso');
	const reach = (code) => board.reach[board.index.get(code)];
	const qz = efforts.words.find((w) => w.word === 'qz');
	const ea = efforts.words.find((w) => w.word === 'ea');
	check(near(qz.parts.sfb, 1000), `word effort: qz SFB part ${qz.parts.sfb}`);
	check(
		near(qz.parts.distance, (reach('KeyQ') + reach('KeyZ')) / 2),
		`word effort: qz travel ${qz.parts.distance}`
	);
	check(
		near(qz.effort, 1000 + (reach('KeyQ') + reach('KeyZ')) / 2),
		`word effort: qz ${qz.effort}`
	);
	check(near(ea.effort, reach('KeyE') / 2), `word effort: ea ${ea.effort}`);
	check(efforts.words[0].word === 'qz', 'word effort: the hardest first');
	check(
		efforts.unsupported.length === 1 && efforts.unsupported[0].word === 'qé',
		'word effort: a word QWERTY cannot type is listed apart'
	);
	check(near(efforts.mean, (qz.effort + 3 * ea.effort) / 4), `word effort: mean ${efforts.mean}`);
	check(
		near(
			E.wordEfforts(qwerty, { qz: 1 }, { keyboard: 'iso', weights: { sfb: 1, distance: 0 } })
				.words[0].effort,
			100
		),
		'word effort: the weights apply'
	);
	// The distribution: two ranges from 0 to the hardest word, by occurrences.
	const bins = E.effortDistribution(efforts.words, 2);
	check(bins.length === 2 && bins[1].to === qz.effort, 'word effort: ranges up to the hardest');
	check(bins[0].count === 3 && bins[1].count === 1, `word effort: ${JSON.stringify(bins)}`);
	check(near(bins[0].share, 75) && bins[0].words === 1, 'word effort: shares of the occurrences');
	let refused = 0;
	for (const bad of [
		() => E.effortDistribution([], 0),
		() => E.wordEfforts(qwerty, { '': 1 }),
		() => E.wordEfforts(qwerty, { ab: 0 })
	])
		try {
			bad();
		} catch {
			refused++;
		}
	check(refused === 3, `word effort: ${refused} of 3 bad inputs refused`);
}

// ====================================
// ======= 5/ Incremental score =======
// ====================================

// scoreSession re-scores only the n-grams a change touches; it must give the
// full analysis's score after any change. Property: random swaps of any two
// cells (any level, dead keys and holes included), some dead-key rules
// changed, on layouts with dead keys and AltGr levels, several boards,
// formats and weights, with trials kept or dropped at random. Each trial's
// layout is compiled in part (compileCoreFrom): its ways must be those a
// whole compile gives, list for list.
{
	const SWAPS = 120;
	const SESSION_TOLERANCE = 1e-9;
	const sessionTable = E.prepareNgrams(
		E.ngramsFromText(fs.readFileSync(SPEED_CORPUS, 'utf8').slice(0, 30000))
	);
	let state = 20261116;
	const next = () => {
		state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
		return state / 4294967296;
	};
	const pick = (items) => items[Math.floor(next() * items.length)];
	// shareDead keeps the dead-key tables as one object, as the optimizer does
	// for the layouts it scores.
	const clone = (layout, shareDead) => ({
		id: layout.id,
		fingering: layout.fingering,
		rows: Object.fromEntries(Object.entries(layout.rows).map(([code, row]) => [code, row.slice()])),
		dead: shareDead
			? layout.dead
			: Object.fromEntries(
					Object.entries(layout.dead).map(([dead, rules]) => [dead, Object.assign({}, rules)])
				),
		command: Object.assign({}, layout.command)
	});
	/** A copy of layout with two cells swapped, or two dead-key outputs swapped. */
	const mutate = (layout) => {
		const editRules = next() < 0.15;
		const out = clone(layout, !editRules && next() < 0.5);
		const states = Object.keys(out.dead).filter((dead) => Object.keys(out.dead[dead]).length > 1);
		if (states.length && editRules) {
			const rules = out.dead[pick(states)];
			const [x, y] = [pick(Object.keys(rules)), pick(Object.keys(rules))];
			[rules[x], rules[y]] = [rules[y], rules[x]];
			return out;
		}
		const codes = Object.keys(out.rows);
		const [a, b] = [pick(codes), pick(codes)];
		const [i, j] = [Math.floor(next() * 4), Math.floor(next() * 4)];
		[out.rows[a][i], out.rows[b][j]] = [out.rows[b][j], out.rows[a][i]];
		return out;
	};
	const cases = [
		{ layout: 'azerty', options: { format: 'tkl' } },
		{ layout: 'ergol', options: {} },
		{ layout: 'ergopti', options: { keyboard: 'ansi', weights: { sfb: 9, distance: 0.5 } } },
		{ layout: 'bepo', options: { keyboard: 'corne', format: '60' } }
	];
	let trials = 0;
	let planned = 0;
	let worst = 0;
	// How the trials were walked: the layouts with choices must take the
	// incremental context walk, not only the whole-stream fallback.
	const walks = {};
	// How the trials were compiled ('incremental', 'whole' or 'none'), per layout.
	const compiles = {};
	// A compiled layout as text: each character's, dead state's and text's ways in order.
	const waysText = (compiled) =>
		JSON.stringify([
			[...compiled.ways].sort((a, b) => (a[0] < b[0] ? -1 : 1)),
			[...compiled.texts].sort((a, b) => (a[0] < b[0] ? -1 : 1)),
			compiled.distinct
		]);
	for (const { layout: id, options } of cases) {
		if (!byId.has(id)) {
			check(false, `incremental: the library has no ${id}`);
			continue;
		}
		let current = clone(byId.get(id));
		const session = E.scoreSession(current, sessionTable, options);
		const full = (layout) => E.analyse(layout, sessionTable, options).score.total;
		check(
			Math.abs(session.total - full(current)) <= SESSION_TOLERANCE,
			`incremental: ${id} starts at the full score`
		);
		for (let s = 0; s < SWAPS; s++) {
			const candidate = mutate(current);
			const trial = session.trial(candidate);
			walks[`${id}:${trial.walk}`] = (walks[`${id}:${trial.walk}`] || 0) + 1;
			compiles[`${id}:${trial.compile}`] = (compiles[`${id}:${trial.compile}`] || 0) + 1;
			const parsed = E.layoutFromRows(candidate);
			const board = E.keyboard(
				(options.keyboard || 'iso') === 'iso' && parsed.fingering === 'angle'
					? 'iso_angle'
					: options.keyboard || 'iso'
			);
			const whole = waysText(E.compileWays(parsed, board, null));
			if (waysText(trial.compiled) !== whole) {
				check(false, `incremental: ${id} swap ${s} compiles other ways than a whole compile`);
				break;
			}
			const analysis = E.analyse(candidate, sessionTable, options);
			// The plan made from the current one is the plan made from nothing,
			// to the last bit: each character's count per way and the chords.
			const typing = trial.typing();
			const plain = (report) => JSON.stringify([report.paths, report.chords]);
			if (plain(typing) !== plain(analysis.typing)) {
				check(false, `incremental: ${id} swap ${s} plans other ways than a plan from nothing`);
				break;
			}
			planned += 1;
			const expected = analysis.score.total;
			const gap = Math.abs(trial.total - expected);
			worst = Math.max(worst, gap);
			trials += 1;
			if (gap > SESSION_TOLERANCE * Math.max(1, Math.abs(expected))) {
				check(
					false,
					`incremental: ${id} swap ${s} scores ${trial.total}, the full score is ${expected}`
				);
				break;
			}
			if (next() < 0.5) {
				trial.commit();
				current = candidate;
				check(session.total === trial.total, `incremental: ${id} keeps a committed trial`);
				// The next trials are measured from the committed layout: the same one walks nothing.
				check(session.trial(candidate).changed === 0, `incremental: ${id} stands on its commit`);
			}
		}
	}
	check(trials >= cases.length * SWAPS, `incremental: only ${trials} trials ran`);
	check(planned === trials, `incremental: ${planned} of ${trials} plans compared`);
	// A trial's plan is written over by the next trial (the session keeps two
	// plans): committing an earlier trial must still keep its own layout.
	if (byId.has('ergol')) {
		const ergol = clone(byId.get('ergol'));
		const stale = E.scoreSession(ergol, sessionTable, {});
		const first = clone(ergol);
		[first.rows.KeyA, first.rows.KeyE] = [first.rows.KeyE, first.rows.KeyA];
		const second = clone(ergol);
		[second.rows.KeyI, second.rows.KeyU] = [second.rows.KeyU, second.rows.KeyI];
		const kept = stale.trial(first);
		const later = stale.trial(second);
		let replaced = false;
		try {
			kept.typing();
		} catch (error) {
			replaced = /later trial/.test(error.message);
		}
		check(
			replaced,
			'incremental: an earlier trial refuses to report a plan a later trial replaced'
		);
		kept.commit();
		const firstTotal = E.analyse(first, sessionTable, {}).score.total;
		check(
			Math.abs(stale.total - firstTotal) <= SESSION_TOLERANCE,
			`incremental: committing an earlier trial keeps its layout (${stale.total} vs ${firstTotal})`
		);
		check(stale.trial(first).changed === 0, 'incremental: the earlier trial is the current layout');
		const again = stale.trial(second);
		check(
			Math.abs(again.total - later.total) <= SESSION_TOLERANCE,
			'incremental: a later trial scores the same from the earlier commit'
		);
	}
	// A trial writes its compile into the session's spare maps, not into
	// copies of the current ones: two trials in a row hand out the same maps,
	// and a trial after a commit writes the other ones, leaving the committed
	// layout's maps as they were.
	if (byId.has('bepo')) {
		const bepo = clone(byId.get('bepo'), true);
		const spares = E.scoreSession(bepo, sessionTable, {});
		const swapped = (a, b) => {
			const out = clone(bepo, true);
			[out.rows[a], out.rows[b]] = [out.rows[b], out.rows[a]];
			return out;
		};
		const wholeText = (layout) => {
			const parsed = E.layoutFromRows(layout);
			const board = E.keyboard(parsed.fingering === 'angle' ? 'iso_angle' : 'iso');
			return waysText(E.compileWays(parsed, board, null));
		};
		const first = spares.trial(swapped('KeyA', 'KeyS'));
		const firstMaps = [first.compiled.ways, first.compiled.best, first.compiled.texts];
		const keptLayout = swapped('KeyF', 'KeyD');
		const second = spares.trial(keptLayout);
		check(
			first.compile === 'incremental' && second.compile === 'incremental',
			`incremental: bépo's letter swaps compile in part (${first.compile}, ${second.compile})`
		);
		check(
			second.compiled.ways === firstMaps[0] &&
				second.compiled.best === firstMaps[1] &&
				second.compiled.texts === firstMaps[2],
			'incremental: a trial reuses the spare maps of the trial before, instead of copying the current ones'
		);
		second.commit();
		const kept = second.compiled;
		const third = spares.trial(swapped('KeyE', 'KeyR'));
		check(
			third.compiled.ways !== kept.ways && third.compiled.best !== kept.best,
			'incremental: a trial after a commit writes the other spare maps'
		);
		check(
			waysText(third.compiled) === wholeText(swapped('KeyE', 'KeyR')) &&
				waysText(kept) === wholeText(keptLayout),
			"incremental: a later trial leaves the committed layout's maps as a whole compile gives them"
		);
	}
	// The partial compile must carry the trials, not the whole-compile fallback.
	for (const { layout: id } of cases)
		check(
			(compiles[`${id}:incremental`] || 0) >= SWAPS / 2,
			`incremental: ${id} compiles its trials in part: ${JSON.stringify(compiles)}`
		);
	for (const id of ['ergol', 'ergopti', 'bepo'])
		check(
			(walks[`${id}:context`] || 0) >= SWAPS / 2,
			`incremental: ${id} (several ways per character) re-walks its changed contexts: ${JSON.stringify(walks)}`
		);
	// Every walk is held to the full score: each must have run.
	for (const walk of ['stream', 'context', 'whole'])
		check(
			Object.keys(walks).some((key) => key.endsWith(':' + walk)),
			`incremental: no trial took the ${walk} walk: ${JSON.stringify(walks)}`
		);
	// A trial leaves the session where it was until it is committed.
	const azerty = byId.get('azerty');
	const session = E.scoreSession(azerty, sessionTable, {});
	const before = session.total;
	const moved = clone(azerty);
	[moved.rows.KeyA, moved.rows.KeyQ] = [moved.rows.KeyQ, moved.rows.KeyA];
	const trial = session.trial(moved);
	check(trial.changed > 0, 'incremental: a swap of two letters changes their sequences');
	check(session.total === before, 'incremental: an uncommitted trial changes nothing');
	check(
		Math.abs(session.trial(azerty).total - before) <= SESSION_TOLERANCE,
		'incremental: the session still stands on the first layout'
	);
	// A layout measured on another board is refused, not scored wrongly.
	let refused = false;
	try {
		session.trial(Object.assign(clone(azerty), { fingering: 'angle' }));
	} catch (error) {
		refused = /keeps the board/.test(error.message);
	}
	check(refused, 'incremental: a trial on another board is refused');
	console.log(
		`  incremental: ${trials} trials, largest gap ${worst.toExponential(1)}, compiles ${JSON.stringify(compiles)}`
	);
}

// =================================
// ======= 6/ Ways of typing =======
// =================================

// A toy layout: code → base cell (string or {dead}), or the four cells.
const toy = (id, cells, dead) =>
	E.layoutFromRows({
		id,
		rows: Object.fromEntries(
			Object.entries(cells).map(([code, cell]) => [
				code,
				Array.isArray(cell) ? cell : [cell, null, null, null]
			])
		),
		dead: dead || {}
	});
const firstStep = (result, char) => result.typing.paths[char][0].steps[0][0];
const onlyKind = (result, char) =>
	result.typing.paths[char].length === 1 ? result.typing.paths[char][0].kind : 'several';

// « a. » and « b. »: the dot on KeyE (left middle finger, like a on KeyD) and
// on KeyU (right index, like b on KeyJ). Out of context both cost one press
// (the lower key, KeyE, is the fixed way); after a, KeyE is a same-finger
// bigram, so the dot is typed on KeyU, and after b on KeyE.
{
	const layout = toy('toy_dots', { KeyD: 'a', KeyJ: 'b', KeyE: '.', KeyU: '.' });
	const afterA = E.analyse(layout, E.ngramsFromText('a.'), { keyboard: 'iso' });
	const afterB = E.analyse(layout, E.ngramsFromText('b.'), { keyboard: 'iso' });
	check(
		firstStep(afterA, '.') === 'KeyU',
		`ways: « a. » types the dot on ${firstStep(afterA, '.')}`
	);
	check(
		firstStep(afterB, '.') === 'KeyE',
		`ways: « b. » types the dot on ${firstStep(afterB, '.')}`
	);
	check(
		afterA.metrics.sfb === 0 && afterB.metrics.sfb === 0,
		'ways: neither « a. » nor « b. » is an SFB'
	);
	const fixed = E.analyse(layout, E.ngramsFromText('a.'), { keyboard: 'iso', typing: 'fixed' });
	check(fixed.metrics.sfb === 100, 'ways: the fixed path types « a. » as an SFB');
	check(afterA.typing.cost < fixed.typing.cost, 'ways: the best path of « a. » costs less');
}

// Direct, AltGr or dead key, by the documented costs (default weights:
// distance 1/mm, home_row 0.3, pinky_load 0.3, sfb 10, and the access weights
// modifier_usage 0.5, altgr_usage 2, dead_key_usage 2; ISO reaches KeyR, KeyP,
// KeyE 19.636 mm, AltRight 69.056 mm). In « fé » there are 2 characters and 1
// bigram, so a pair counts 100 × 2 per point of weight:
// - é on KeyR (left index, like f): 19.636 + 10 × 200 (SFB) = 2019.636;
// - AltGr+KeyL (home): −30 (home) + 69.056 (AltRight) + 50 (modifier) + 200
//   (AltGr layer) = 289.056;
// - dead key KeyP then e on KeyE: 19.636 + 30 (pinky) + 19.636 + 200 (dead key)
//   = 269.272, both pairs changing hands.
// Alone, é is typed directly (19.636 is the least). The user's access weights
// choose too: with altgr_usage 0, AltGr costs 89.056 and wins.
{
	const cells = {
		KeyF: 'f',
		KeyR: 'é',
		KeyE: 'e',
		KeyL: [null, null, 'é', null],
		KeyP: { dead: 'acute' }
	};
	const dead = { acute: { e: 'é' } };
	const full = toy('toy_access', cells, dead);
	const alone = E.analyse(full, E.ngramsFromText('é'), { keyboard: 'iso' });
	check(onlyKind(alone, 'é') === 'direct', `ways: é alone is typed ${onlyKind(alone, 'é')}`);
	const afterF = E.analyse(full, E.ngramsFromText('fé'), { keyboard: 'iso' });
	check(onlyKind(afterF, 'é') === 'dead', `ways: « fé » types é by ${onlyKind(afterF, 'é')}`);
	// f on the home row (−30), é through the dead key (269.272), over 2 characters.
	check(
		Math.abs(afterF.typing.cost - (-30 + 269.272) / 2) < 1e-3,
		`ways: « fé » costs ${afterF.typing.cost}`
	);
	check(afterF.metrics.altgr_usage === 0, 'ways: « fé » through the dead key holds no AltGr');
	const cheapAltGr = E.analyse(full, E.ngramsFromText('fé'), {
		keyboard: 'iso',
		weights: { altgr_usage: 0 }
	});
	check(
		onlyKind(cheapAltGr, 'é') === 'altgr',
		`ways: with altgr_usage 0, « fé » types é by ${onlyKind(cheapAltGr, 'é')}`
	);
	check(
		Math.abs(cheapAltGr.typing.cost - (-30 + 89.056) / 2) < 1e-3,
		`ways: « fé » with altgr_usage 0 costs ${cheapAltGr.typing.cost}`
	);
	check(
		cheapAltGr.metrics.altgr_usage === 50 && cheapAltGr.metrics.modifier_usage === 50,
		'ways: AltGr types one character of two, counted in altgr_usage and modifier_usage'
	);
	check(
		cheapAltGr.typing.access.altgr_usage === 0 && afterF.typing.access.altgr_usage === 2,
		'ways: a result names the access weights its ways were chosen by'
	);
	// A dearer dead key sends é back to AltGr: 89.056 + 200 < 19.636 + 30 + 19.636 + 1000.
	const dearDead = E.analyse(full, E.ngramsFromText('fé'), {
		keyboard: 'iso',
		weights: { dead_key_usage: 10 }
	});
	check(
		onlyKind(dearDead, 'é') === 'altgr',
		`ways: with dead_key_usage 10, « fé » types é by ${onlyKind(dearDead, 'é')}`
	);
	const noAltGr = toy('toy_access_dead', Object.assign({}, cells, { KeyL: null }), dead);
	const deadKey = E.analyse(noAltGr, E.ngramsFromText('fé'), { keyboard: 'iso' });
	check(
		onlyKind(deadKey, 'é') === 'dead',
		`ways: without AltGr, « fé » types é by ${onlyKind(deadKey, 'é')}`
	);
	check(deadKey.metrics.dead_key_usage === 50, 'ways: the dead key types one character of two');
}

// Ergo-L types é as its one dead key (KeyO, right ring finger, top row) then
// s (KeyS). « ié »: i on KeyL (right ring, home row), so the stream is KeyL
// KeyO KeyS: KeyL → KeyO is an SFB (one finger, two keys), KeyO → KeyS changes
// hands: SFB 1 of 2 key bigrams, 50 %. « éi »: KeyO KeyS KeyL, no SFB, and the
// skipgram KeyO … KeyL is the one key trigram, SFS 100 %. The dead key's press
// is a keystroke of the stream on its own finger, both before and after.
{
	const ergol = byId.get('ergol');
	const ie = E.analyse(ergol, E.ngramsFromText('ié'), {});
	const steps = ie.typing.paths['é'];
	check(
		steps.length === 1 && steps[0].steps.map(([code]) => code).join(' ') === 'KeyO KeyS',
		`Ergo-L: « ié » types é by ${JSON.stringify(steps)}`
	);
	check(
		ie.metrics.sfb === 50,
		`Ergo-L: « ié » has SFB ${ie.metrics.sfb} %, i → dead key is one of 2`
	);
	const pairs = E.bigramMatrix(ergol, E.ngramsFromText('ié'), {}).pairs;
	const sfbPairs = pairs.filter((p) => p.events.includes('sfb')).map((p) => p.keys.join('>'));
	check(
		sfbPairs.join(' ') === 'KeyL>KeyO',
		`Ergo-L: the SFB of « ié » is i → dead key, found ${sfbPairs.join(' ')}`
	);
	const ei = E.analyse(ergol, E.ngramsFromText('éi'), {});
	check(
		ei.metrics.sfb === 0 && ei.metrics.sfs === 100,
		`Ergo-L: « éi » has SFB ${ei.metrics.sfb} % and SFS ${ei.metrics.sfs} %`
	);
	// The optimizer's session types by the same access weights as analyse().
	const text = E.ngramsFromText('ié ça, l’été où « il » a dû voir ê à è (là) !');
	for (const weights of [{}, { altgr_usage: 0, dead_key_usage: 10 }]) {
		const total = E.analyse(ergol, text, { weights }).score.total;
		const session = E.scoreSession(ergol, text, { weights }).total;
		check(
			Math.abs(total - session) < 1e-9,
			`Ergo-L: scoreSession ${session} differs from analyse ${total} with ${JSON.stringify(weights)}`
		);
	}
}

// A two-character output: AltGr+KeyR types « ab ». With a on KeyQ and b on
// KeyA (both the left pinky) the two taps cost 49.636 + 0 + 2000 (SFB), the
// chord 19.636 + 69.056 + 2 × 50 (two characters with AltGr) = 188.692: the
// chord wins. With a on KeyF and b on KeyJ the taps cost −30 − 30 = −60.
{
	const chord = [null, null, 'ab', null];
	const sfbLayout = toy('toy_chord', { KeyQ: 'a', KeyA: 'b', KeyR: chord });
	const viaChord = E.analyse(sfbLayout, E.ngramsFromText('ab'), { keyboard: 'iso' });
	check(viaChord.typing.chords.ab === 1, 'chords: « ab » is typed with its chord');
	check(
		viaChord.metrics.sfb === 0 && viaChord.coverage.typed === 2,
		'chords: no SFB, two characters'
	);
	check(near(viaChord.metrics.modifier_usage, 100), 'chords: both characters typed with AltGr');
	const apart = toy('toy_chord_apart', { KeyF: 'a', KeyJ: 'b', KeyR: chord });
	const viaTaps = E.analyse(apart, E.ngramsFromText('ab'), { keyboard: 'iso' });
	check(Object.keys(viaTaps.typing.chords).length === 0, 'chords: two cheap taps beat the chord');
	check(
		viaTaps.coverage.typed === 2 && viaTaps.metrics.modifier_usage === 0,
		'chords: typed by two taps'
	);
}

// One way per character: the best path is the fixed path, metric for metric.
for (const id of ['qwerty', 'azerty']) {
	const tables = E.ngramsFromText(STREAM_TEXT);
	const best = E.analyse(byId.get(id), tables, { keyboard: 'iso' });
	const fixed = E.analyse(byId.get(id), tables, { keyboard: 'iso', typing: 'fixed' });
	for (const metric of Object.keys(E.METRICS))
		check(
			best.metrics[metric] === fixed.metrics[metric],
			`ways: ${id} ${metric} moved without a choice`
		);
	check(
		best.typing.changed === 0 && best.typing.alternatives === 0,
		`ways: ${id} has no alternative`
	);
}
let refused = false;
try {
	E.analyse(byId.get('qwerty'), E.ngramsFromText('a'), { typing: 'fastest' });
} catch {
	refused = true;
}
check(refused, 'ways: an unknown typing mode is refused');

// Property: where the characters with several ways stand at least three
// places apart, the best path never costs more than the fixed one (random
// toy layouts and texts from a fixed seed).
{
	let seed = 20261116;
	const random = () => {
		seed = (seed + 0x6d2b79f5) | 0;
		let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
	const pick = (list) => list[Math.floor(random() * list.length)];
	const codes = E.typingCodes().filter((code) => /^Key/.test(code));
	const singles = 'abcdefghijkl'.split('');
	const multis = ['.', ',', 'é'];
	for (let trial = 0; trial < 40; trial++) {
		const free = codes.slice().sort(() => random() - 0.5);
		const rows = {};
		for (const char of singles) rows[free.pop()] = [char, null, null, null];
		for (const char of multis)
			for (let copy = 0; copy < 2 + Math.floor(random() * 2); copy++) {
				const code = free.pop();
				rows[code] = [null, null, null, null];
				rows[code][random() < 0.5 ? 0 : 2] = char;
			}
		const layout = E.layoutFromRows({ id: `toy_random_${trial}`, rows });
		let text = '';
		for (let i = 0; i < 300; i++) {
			text += pick(singles) + pick(singles) + pick(singles);
			if (random() < 0.7) text += pick(multis);
			if (random() < 0.1) text += '\n';
		}
		const tables = E.ngramsFromText(text);
		const best = E.analyse(layout, tables, { keyboard: 'iso' });
		const fixed = E.analyse(layout, tables, { keyboard: 'iso', typing: 'fixed' });
		check(
			best.typing.cost <= fixed.typing.cost + 1e-9,
			`ways: trial ${trial} best path ${best.typing.cost} above the fixed ${fixed.typing.cost}`
		);
	}
}

// ==================================================
// ======= 7/ Coverage and simplicity bonuses =======
// ==================================================

// Distinct characters: a A s S ß, à À through the dead key, c h from the
// output « ch », and " (typed for « by substitution, which does not count): 10.
{
	const layout = toy(
		'toy_coverage',
		{
			KeyA: ['a', 'A', null, null],
			KeyS: ['s', 'S', 'ß', null],
			KeyQ: { dead: 'grave' },
			KeyW: 'ch',
			KeyZ: '"'
		},
		{ grave: { a: 'à', A: 'À' } }
	);
	const result = E.analyse(layout, E.ngramsFromText('a«'), { keyboard: 'iso' });
	check(
		result.metrics.distinct_chars === 10,
		`coverage: ${result.metrics.distinct_chars} characters, not 10`
	);
	check(
		near(result.metrics.coverage_bonus, 1),
		`coverage: bonus ${result.metrics.coverage_bonus}, not 1 %`
	);
}
// Past the cap (1,000): 39 keys × 4 levels and 6 dead keys over those 156
// characters, with e and d, type 1,094 characters, a bonus of 100 %.
const bigLayout = (() => {
	const iso = E.keyboard('iso');
	const codes = E.typingCodes().filter(
		(code) => iso.index.has(code) && !['KeyE', 'KeyD', 'KeyJ', 'Space'].includes(code)
	);
	const rows = {};
	const typed = [];
	for (let i = 0; i < 39; i++) {
		rows[codes[i]] = [0, 1, 2, 3].map((level) => String.fromCodePoint(0x400 + i * 4 + level));
		typed.push(...rows[codes[i]]);
	}
	const dead = {};
	for (let j = 0; j < 6; j++) {
		rows[codes[39 + j]] = [{ dead: `s${j}` }, null, null, null];
		dead[`s${j}`] = Object.fromEntries(
			typed.map((char, i) => [char, String.fromCodePoint(0x1000 + j * 156 + i)])
		);
	}
	rows.KeyE = ['e', null, null, null];
	rows.KeyD = ['d', null, null, null];
	return E.layoutFromRows({ id: 'toy_big', rows, dead });
})();
{
	const result = E.analyse(bigLayout, E.ngramsFromText('ed'), { keyboard: 'iso' });
	check(
		result.metrics.distinct_chars === 1094,
		`coverage: big layout has ${result.metrics.distinct_chars}`
	);
	check(result.metrics.coverage_bonus === 100, 'coverage: the bonus stops at the cap');
	// e on KeyE and d on KeyD (one finger) against e and d on two hands: many
	// more characters never outweigh the SFBs.
	const small = toy('toy_small', { KeyE: 'e', KeyJ: 'd' });
	const ranked = E.compare([bigLayout, small], E.ngramsFromText('ed ed ed'), { keyboard: 'iso' });
	check(ranked[0].layout.id === 'toy_small', 'coverage: more characters do not outrank worse SFBs');
	const w = E.defaultWeights();
	check(
		w.coverage_bonus * 100 < w.sfb,
		'coverage: the whole bonus is worth less than one point of SFB'
	);
	check(
		w.simplicity * 100 < w.sfb,
		'simplicity: the whole bonus is worth less than one point of SFB'
	);
}

// Simplicity rules, each with a case that passes and one that fails.
{
	const rule = (cells, dead, id) =>
		E.analyse(toy(`toy_simple_${id}`, cells, dead), E.ngramsFromText('e'), { keyboard: 'iso' })
			.simplicity;
	const circ = { circ: { e: 'ê' } };
	check(
		rule({ KeyE: 'e', KeyQ: { dead: 'circ' } }, circ, 'dead').accents.value === 100,
		'simplicity: dead key then e for ê'
	);
	check(
		rule({ KeyE: 'e', KeyK: [null, null, 'ê', null] }, {}, 'far').accents.value === 0,
		'simplicity: ê on AltGr of another key'
	);
	check(
		rule({ KeyE: 'e', KeyK: 'ê' }, {}, 'own').accents === null,
		'simplicity: a key of its own is not measured'
	);
	check(
		rule({ KeyU: '(', KeyI: ')' }, {}, 'pair').pairs.value === 100,
		'simplicity: ( then ) on the next key'
	);
	check(
		rule({ KeyU: ')', KeyI: '(' }, {}, 'reversed').pairs.value === 50,
		'simplicity: ) before ( is half'
	);
	check(
		rule({ KeyU: ['(', ')', null, null] }, {}, 'shift').pairs.value === 50,
		'simplicity: ( and ) on one key is half'
	);
	check(rule({ KeyU: '(', KeyP: ')' }, {}, 'apart').pairs.value === 0, 'simplicity: ( and ) apart');
	const digits = (order) =>
		Object.fromEntries(order.split('').map((d, i) => [`Digit${(i + 1) % 10}`, d]));
	check(
		rule(digits('1234567890'), {}, 'digits').digits.value === 100,
		'simplicity: digits in order'
	);
	check(
		rule(digits('0987654321'), {}, 'reversed_digits').digits.value === 0,
		'simplicity: digits reversed'
	);
	const mixed = E.analyse(
		toy('toy_simple_mixed', { KeyU: '(', KeyI: ')', ...digits('0987654321') }),
		E.ngramsFromText('e'),
		{
			keyboard: 'iso'
		}
	);
	check(
		mixed.metrics.simplicity === 50,
		`simplicity: the mean of the measured rules, ${mixed.metrics.simplicity}`
	);
}

// ========================
// ======= 8/ Speed =======
// ========================

const prepared = E.prepareNgrams(E.ngramsFromText(fs.readFileSync(SPEED_CORPUS, 'utf8')));
const speedBudgetMs = SPEED_BUDGET_MS_PER_LAYOUT * library.length;
const runsMs = [];
while (runsMs.length < SPEED_RUNS && !(Math.min(...runsMs) < speedBudgetMs)) {
	const start = process.hrtime.bigint();
	E.compare(library, prepared, {});
	runsMs.push(Number(process.hrtime.bigint() - start) / 1e6);
}
const elapsedMs = Math.min(...runsMs);
check(
	elapsedMs < speedBudgetMs,
	`speed: ${library.length} layouts took ${runsMs.map((ms) => ms.toFixed(0)).join(', ')} ms ` +
		`(fastest ${(elapsedMs / library.length).toFixed(1)} ms per layout, ` +
		`budget ${SPEED_BUDGET_MS_PER_LAYOUT} ms)`
);

// =========================
// ======= 9/ Golden =======
// =========================

vm.runInContext(fs.readFileSync(DON_QUICHOTTE_PATH, 'utf8'), sandbox, {
	filename: DON_QUICHOTTE_PATH
});
const goldenCorpora = {
	corpus_nemolivier: prepared,
	fr_don_quichotte: E.prepareNgrams(
		vm.runInContext('LAYOUT_ANALYSIS_CORPORA', sandbox).fr_don_quichotte
	)
};
const metricIds = Object.keys(E.METRICS);
const measured = {};
for (const [corpus, table] of Object.entries(goldenCorpora)) {
	measured[corpus] = {};
	for (const layout of library) {
		const metrics = E.analyse(layout, table, {}).metrics;
		measured[corpus][layout.id] = metricIds.map((id) => metrics[id]);
	}
}
let goldenValues = 0;
let goldenGap = 0;
if (UPDATE_GOLDEN) {
	const golden = {
		_description:
			'Every metric of every library layout on both French corpora, on the default keyboard, as analyse() gives them (tools/test/test-layout-analysis-engine.cjs, section 9): a speed-up of the engine must leave them unchanged. Values follow the order of metrics. Recorded again with node tools/test/test-layout-analysis-engine.cjs --update-golden only when a definition, a layout or a corpus changes on purpose.',
		metrics: metricIds,
		corpora: measured
	};
	fs.writeFileSync(GOLDEN_PATH, `${JSON.stringify(golden, null, '\t')}\n`);
	// The repository's formatter packs the number arrays: the file keeps its style.
	const formatted = spawnSync(
		process.execPath,
		[require.resolve('prettier/bin/prettier.cjs'), '--write', GOLDEN_PATH],
		{ stdio: 'inherit' }
	);
	check(formatted.status === 0, `golden: prettier could not format ${GOLDEN_PATH}`);
	console.log(`test-layout-analysis-engine: golden recorded in ${GOLDEN_PATH}`);
} else {
	const golden = JSON.parse(fs.readFileSync(GOLDEN_PATH, 'utf8'));
	const update = 'record them with --update-golden if the change is deliberate';
	check(
		JSON.stringify(golden.metrics) === JSON.stringify(metricIds),
		`golden: metrics ${golden.metrics.join(' ')} differ from the engine's; ${update}`
	);
	for (const [corpus, layouts] of Object.entries(measured)) {
		const expected = golden.corpora[corpus] || {};
		check(
			Object.keys(expected).length === Object.keys(layouts).length,
			`golden: ${corpus} has ${Object.keys(expected).length} layouts, the library ` +
				`${Object.keys(layouts).length}; ${update}`
		);
		for (const [id, values] of Object.entries(layouts)) {
			const want = expected[id];
			if (!want) {
				check(false, `golden: ${corpus} lacks ${id}; ${update}`);
				continue;
			}
			values.forEach((value, i) => {
				const gap = Math.abs(value - want[i]) / Math.max(1, Math.abs(want[i]));
				goldenGap = Math.max(goldenGap, gap);
				goldenValues++;
				check(
					gap <= GOLDEN_TOLERANCE,
					`golden: ${corpus} ${id} ${golden.metrics[i]} = ${value}, recorded ${want[i]}`
				);
			});
		}
	}
}

// ======================================
// ======= 10/ Incomplete layouts =======
// ======================================

{
	const french = goldenCorpora.fr_don_quichotte;
	/** A copy of a library layout with some characters taken off every level. */
	const without = (id, chars, newId) => {
		const layout = byId.get(id);
		const rows = Object.fromEntries(
			Object.entries(layout.rows).map(([code, row]) => [
				code,
				row.map((cell) => (typeof cell === 'string' && chars.includes(cell) ? null : cell))
			])
		);
		return Object.assign({}, layout, { id: newId, name: newId, rows });
	};
	const required = Array.from(
		vm.runInContext('LAYOUT_ANALYSIS_DATA', sandbox).model.required_characters
	);
	check(required.length === 53, `incomplete: ${required.length} required characters, expected 53`);
	// English layouts lack the French accents: unsupported, never incomplete.
	for (const id of ['qwerty', 'colemak']) {
		const result = E.analyse(byId.get(id), french, {});
		check(
			result.incomplete === false && result.coverage.missingRequired.length === 0,
			`incomplete: ${id} on Don Quichotte is flagged incomplete (${result.coverage.missingRequired.join('')})`
		);
		check(result.metrics.unsupported > 0, `incomplete: ${id} types every French character`);
	}
	const noK = without('ergopti', ['k', 'K'], 'ergopti_no_k');
	const noKResult = E.analyse(noK, french, {});
	check(
		noKResult.incomplete === true && noKResult.coverage.missingRequired.join('') === 'kK',
		`incomplete: Ergopti without k lacks ${JSON.stringify(noKResult.coverage.missingRequired)}`
	);
	const noSpace = without('qwerty', [' '], 'qwerty_no_space');
	const noSpaceResult = E.analyse(noSpace, french, {});
	check(
		noSpaceResult.incomplete === true && noSpaceResult.coverage.missingRequired.join('') === ' ',
		`incomplete: QWERTY without Space lacks ${JSON.stringify(noSpaceResult.coverage.missingRequired)}`
	);
	// « a » on its key but no « A » on the Shift level: each case is checked.
	const noCapital = without('qwerty', ['A'], 'qwerty_no_capital_a');
	const noCapitalResult = E.analyse(noCapital, french, {});
	check(
		noCapitalResult.incomplete === true &&
			noCapitalResult.coverage.missingRequired.join('') === 'A',
		`incomplete: QWERTY without « A » lacks ${JSON.stringify(noCapitalResult.coverage.missingRequired)}`
	);
	// The unusable Ergopti outscores QWERTY, and still ranks after it.
	const qwerty = E.analyse(byId.get('qwerty'), french, {});
	check(
		noKResult.score.total > qwerty.score.total,
		'incomplete: the test needs an incomplete layout that outscores a complete one'
	);
	const ranked = E.compare([noK, byId.get('qwerty'), noSpace, byId.get('ergopti')], french, {});
	check(
		ranked.map((r) => r.layout.id).join(' ') === 'ergopti qwerty ergopti_no_k qwerty_no_space' &&
			ranked.map((r) => r.rank).join(' ') === '1 2 3 4',
		`incomplete: ranking ${ranked.map((r) => `${r.rank}:${r.layout.id}`).join(' ')}`
	);
	const rescored = E.rescore(ranked, { sfb: 0 });
	check(
		rescored.slice(0, 2).every((r) => !r.incomplete) &&
			rescored.slice(2).every((r) => r.incomplete),
		'incomplete: a re-score keeps the complete layouts first'
	);
	check(
		E.rankOrder(qwerty, noKResult) < 0 && E.rankOrder(noKResult, qwerty) > 0,
		'incomplete: rankOrder puts the complete layout first'
	);
	let refused = false;
	try {
		E.rankOrder({ score: { total: 1 } }, qwerty);
	} catch {
		refused = true;
	}
	check(refused, 'incomplete: rankOrder refuses a result that does not say whether it is complete');
}

// =============================================
// ======= 11/ Whole French layouts type French =======
// =============================================

{
	// (optimot-unsupported) The library held Optimot as Oxeylyzer's letter block,
	// completed with the US number row: no à, è, ç, ê, ?, and 1.28 % of Don
	// Quichotte « unsupported ». It is now the whole layout with its dead ^ and
	// ¨, as are the other whole layouts whose accents only a dead key types.
	const french = goldenCorpora.fr_don_quichotte;
	for (const id of ['optimot', 'bvofrak1', 'qwerty_spanish']) {
		const layout = byId.get(id);
		const result = E.analyse(layout, french, {});
		check(
			result.metrics.unsupported < 0.05,
			`dead keys: ${id} leaves ${result.metrics.unsupported.toFixed(3)} % of Don Quichotte unsupported (${Object.keys(result.coverage.unsupportedChars).join('')})`
		);
	}
	const optimot = byId.get('optimot');
	const deadCells = Object.values(optimot.rows)
		.flat()
		.filter((cell) => cell && typeof cell === 'object')
		.map((cell) => cell.dead)
		.sort();
	// (official-layouts-2026-11-18) Optimot 1.8.0's thirteen dead keys.
	check(
		deadCells.join(' ') ===
			'abovedot abovering acute breve caron cedilla circumflex currency diaeresis grave horn macron tilde',
		`dead keys: Optimot's dead keys are ${deadCells.join(' ')}`
	);
	check(
		(optimot.dead.circumflex || {}).e === 'ê' && (optimot.dead.diaeresis || {}).i === 'ï',
		'dead keys: Optimot composes ê and ï'
	);
	check(
		E.analyse(optimot, E.ngramsFromText('être où ça ? Noël'), {}).metrics.unsupported === 0,
		'dead keys: Optimot types « être où ça ? Noël »'
	);
}

// ==================================================
// ======= 12/ Layouts as their official files ======
// ==================================================

{
	// (official-layouts-2026-11-18) Each fact below is read in the layout's
	// official file: Ergo-L's Kalamine TOML (ergol-v1.0.2), Optimot 1.8.0's
	// Linux XKB and XCompose (optimot.fr), xkeyboard-config's symbols/de and
	// symbols/es, dl.neo-layout.org/mine_2.39 and Engram-es's README. The
	// library held letter blocks completed with the US rows, KLA files without
	// their dead keys or AltGr level, and Mine as it was before April 2022.
	const cell = (id, code, level) => {
		const layout = byId.get(id);
		const row = layout && layout.rows[code];
		const value = row ? row[level] : undefined;
		return value && typeof value === 'object' ? `dead:${value.dead}` : value;
	};
	const rule = (id, state, typed) => ((byId.get(id) || { dead: {} }).dead[state] || {})[typed];
	const official = [
		// Ergo-L: the 1DK is the base of the key right of D, and 1DK + s is é.
		['ergol', 'KeyO', 0, 'dead:1dk'],
		['ergol', 'KeyO', 1, '!'],
		// Optimot 1.8.0: ^ ! ¨ ¡ on the key right of N, the AltGr arrows of 1.8.
		['optimot', 'Quote', 0, 'dead:circumflex'],
		['optimot', 'Quote', 2, 'dead:diaeresis'],
		['optimot', 'KeyR', 2, 'dead:acute'],
		['optimot', 'KeyS', 2, '↓'],
		['optimot', 'KeyD', 2, '↑'],
		['optimot', 'KeyX', 2, 'dead:grave'],
		['optimot', 'Backquote', 2, 'dead:currency'],
		// Neo 2: ; ? ! on level 3, the dead ^ ` ´ on level 1.
		['neo2_new', 'Slash', 2, ';'],
		['neo2_new', 'KeyH', 2, '?'],
		['neo2_new', 'KeyY', 2, '!'],
		['neo2_new', 'Backquote', 0, 'dead:circumflex'],
		['neo2_new', 'Equal', 0, 'dead:grave'],
		['neo2_new', 'BracketRight', 0, 'dead:acute'],
		// Bone, KOY, AdNW, Noted, Mine: their own 31st and 32nd keys.
		['bone', 'Quote', 0, 'q'],
		['bone', 'BracketLeft', 0, 'ß'],
		['koy', 'Quote', 0, 'f'],
		['koy', 'Slash', 0, 'j'],
		['koy', 'BracketLeft', 0, 'z'],
		['adnw', 'KeyP', 0, 'j'],
		['adnw', 'BracketLeft', 0, 'f'],
		['adnw', 'Quote', 0, 'ß'],
		['noted', 'Backslash', 0, 'dead:acute'],
		['mine', 'KeyQ', 0, 'j'],
		['mine', 'KeyT', 0, 'q'],
		['mine', 'BracketLeft', 0, 'z'],
		['mine', 'KeyL', 0, 's'],
		['mine', 'Semicolon', 0, 'h'],
		['mine', 'Backslash', 0, 'dead:acute'],
		// German QWERTZ: ü ö ä ß, the dead ^ and ´, Shift+7 is /.
		['qwertz', 'BracketLeft', 0, 'ü'],
		['qwertz', 'Semicolon', 0, 'ö'],
		['qwertz', 'Quote', 0, 'ä'],
		['qwertz', 'Minus', 0, 'ß'],
		['qwertz', 'Digit7', 1, '/'],
		['qwertz', 'Backquote', 0, 'dead:circumflex'],
		['qwertz', 'Equal', 0, 'dead:acute'],
		// Spanish QWERTY: Shift+7 is /, Shift+8 is (, the dead ´ right of ñ.
		['qwerty_spanish', 'Digit7', 1, '/'],
		['qwerty_spanish', 'Digit8', 1, '('],
		['qwerty_spanish', 'Semicolon', 0, 'ñ'],
		['qwerty_spanish', 'Quote', 0, 'dead:acute'],
		// Spanish Dvorak (xkeyboard-config): the dead ´ and ` and its R-H exchange.
		['spanish_dvorak', 'Quote', 0, 'dead:acute'],
		['spanish_dvorak', 'BracketLeft', 0, 'dead:grave'],
		['spanish_dvorak', 'KeyO', 0, 'h'],
		['spanish_dvorak', 'KeyJ', 0, 'r'],
		// Engram-es: ☆ in the middle of the home row, ¿¡ and ?! below it.
		['engram_es', 'KeyH', 0, 'dead:engram_star'],
		['engram_es', 'KeyB', 0, '¿'],
		['engram_es', 'KeyN', 1, '!'],
		['engram_es', 'BracketLeft', 0, 'w']
	];
	for (const [id, code, level, expected] of official)
		check(
			cell(id, code, level) === expected,
			`official layouts: ${id} ${code} level ${level} is ${cell(id, code, level)}, its official file has ${expected}`
		);
	for (const [id, state, typed, expected] of [
		['ergol', '1dk', 's', 'é'],
		['ergol', '1dk', 'e', 'è'],
		['ergol', '1dk', 'a', 'à'],
		['ergol', '1dk', 'n', 'ê'],
		['ergol', '1dk', 'c', 'ç'],
		// Optimot's own ^ and ¨ tables (its XCompose), not the plain accents.
		['optimot', 'circumflex', 'p', '|'],
		['optimot', 'circumflex', 'k', '='],
		['optimot', 'circumflex', 'n', 'ñ'],
		['optimot', 'circumflex', 'm', 'ç'],
		['optimot', 'circumflex', "'", '['],
		['optimot', 'diaeresis', 't', 'þ'],
		['optimot', 'currency', '$', '£'],
		['neo2_new', 'circumflex', 'e', 'ê'],
		['neo2_new', 'caron', 's', 'š'],
		['qwerty_spanish', 'acute', 'e', 'é'],
		['spanish_dvorak', 'acute', 'o', 'ó'],
		['engram_es', 'engram_star', 'a', 'á'],
		['engram_es', 'engram_star', 'n', 'ñ']
	])
		check(
			rule(id, state, typed) === expected,
			`official layouts: ${id} ${state} + ${typed} is ${rule(id, state, typed)}, its official file gives ${expected}`
		);
	// AdNW is one layout: KLA's copy of it is left out as a duplicate.
	check(!byId.has('adnw_kla'), 'official layouts: AdNW is in the library twice');
	// Each types its language's text in full.
	for (const [ids, text] of [
		[
			['neo2_new', 'bone', 'koy', 'adnw', 'noted', 'mine', 'qwertz'],
			'Größe, Übung; ändern? Ja! Öl: „Straße“ – (Fuß) @ 3 € mögen.'
		],
		[
			['qwerty_spanish', 'spanish_dvorak', 'engram_es'],
			'¿Qué pasó, niño? ¡Ánimo, pingüino! Él lo dijo: «sí».'
		],
		[['optimot'], 'Ça ! Où ? « Noël » : être, naïf, cœur — [x] {y} | 1 = 2, ñ.']
	])
		for (const id of ids) {
			const result = E.analyse(byId.get(id), E.ngramsFromText(text), {});
			check(
				result.metrics.unsupported === 0,
				`official layouts: ${id} cannot type ${Object.keys(result.coverage.unsupportedChars).join('')}`
			);
		}
}

// =========================================
// ======= 13/ Similarity of layouts =======
// =========================================

// How alike two layouts type a corpus (layoutSimilarity): the optimizer's
// « an existing layout would do the job ».
check(typeof E.layoutSimilarity === 'function', 'similarity: the engine has no layoutSimilarity');
check(typeof E.similarScoreGap === 'function', 'similarity: the engine has no similarScoreGap');
if (typeof E.layoutSimilarity === 'function' && typeof E.similarScoreGap === 'function') {
	const azerty = byId.get('azerty');
	const counts = E.ngramsFromText(
		'Tarte et ratatouille, le rat trotte sur la terre. Elle a vu un kiwi, Waouh, et un xylophone ! '.repeat(
			3
		)
	);
	const uni = new Map(E.prepareNgrams(counts).uni);
	// Every character of the text but the space, each counted by its occurrences.
	const typed = [...uni.keys()].filter((char) => char !== ' ');
	const occurrences = typed.reduce((sum, char) => sum + uni.get(char), 0);
	const shares = (moved) => ({
		weighted: 100 * (1 - moved.reduce((sum, char) => sum + (uni.get(char) || 0), 0) / occurrences),
		unweighted: 100 * (1 - moved.filter((char) => uni.has(char)).length / typed.length)
	});
	const swapped = (layout, a, b) => {
		const rows = Object.assign({}, layout.rows, { [a]: layout.rows[b], [b]: layout.rows[a] });
		return Object.assign({}, layout, { id: `${layout.id}_${a}_${b}`, rows });
	};
	const same = E.layoutSimilarity(azerty, JSON.parse(JSON.stringify(azerty)), counts, {});
	for (const [kind, value] of [
		['weighted.sameKey', same.weighted.sameKey],
		['weighted.sameFingerRow', same.weighted.sameFingerRow],
		['unweighted.sameKey', same.unweighted.sameKey],
		['unweighted.sameFingerRow', same.unweighted.sameFingerRow]
	])
		check(value === 100, `similarity: a layout and its copy are ${value} % alike (${kind})`);
	check(
		same.chars === typed.length && same.occurrences === occurrences,
		`similarity: ${same.chars} characters and ${same.occurrences} occurrences compared, the text has ${typed.length} and ${occurrences} without its spaces`
	);
	// R and T: the left index on the top row, both of them. A swap moves r, R,
	// t and T to another key, never to another finger or row.
	const rt = E.layoutSimilarity(azerty, swapped(azerty, 'KeyR', 'KeyT'), counts, {});
	const rtExpected = shares(['r', 'R', 't', 'T']);
	check(
		near(rt.weighted.sameKey, rtExpected.weighted) &&
			near(rt.unweighted.sameKey, rtExpected.unweighted),
		`similarity: one swap of R and T gives ${rt.weighted.sameKey} / ${rt.unweighted.sameKey} %, expected ${rtExpected.weighted} / ${rtExpected.unweighted}`
	);
	check(
		rt.weighted.sameFingerRow === 100 && rt.unweighted.sameFingerRow === 100,
		`similarity: R and T keep their finger and row, yet ${rt.weighted.sameFingerRow} %`
	);
	// E (middle finger) and R (index): another finger, so both measures fall alike.
	const er = E.layoutSimilarity(azerty, swapped(azerty, 'KeyE', 'KeyR'), counts, {});
	const erExpected = shares(['e', 'E', 'r', 'R']);
	check(
		near(er.weighted.sameFingerRow, erExpected.weighted) &&
			near(er.weighted.sameKey, erExpected.weighted),
		`similarity: E and R on two fingers give ${er.weighted.sameFingerRow} %, expected ${erExpected.weighted}`
	);
	const back = E.layoutSimilarity(swapped(azerty, 'KeyE', 'KeyR'), azerty, counts, {});
	check(JSON.stringify(back) === JSON.stringify(er), 'similarity: the measure is not symmetric');
	// The weighting: moving the frequent « e » with « k » and moving the rare
	// « w » with « x » move as many characters, far from as many occurrences.
	const frequent = E.layoutSimilarity(azerty, swapped(azerty, 'KeyE', 'KeyK'), counts, {});
	const rare = E.layoutSimilarity(azerty, swapped(azerty, 'KeyZ', 'KeyX'), counts, {});
	const frequentExpected = shares(['e', 'E', 'k', 'K']);
	const rareExpected = shares(['w', 'W', 'x', 'X']);
	check(
		near(frequent.weighted.sameKey, frequentExpected.weighted) &&
			near(rare.weighted.sameKey, rareExpected.weighted),
		`similarity: the weighted shares are ${frequent.weighted.sameKey} and ${rare.weighted.sameKey}, expected ${frequentExpected.weighted} and ${rareExpected.weighted}`
	);
	check(
		frequent.unweighted.sameKey === rare.unweighted.sameKey &&
			frequent.weighted.sameKey < rare.weighted.sameKey - 10,
		`similarity: moving « e » weighs ${frequent.weighted.sameKey} %, moving « w » ${rare.weighted.sameKey} %, unweighted ${frequent.unweighted.sameKey} and ${rare.unweighted.sameKey}`
	);
	// Levels and dead keys, as the engine types them: « a » moved from the
	// base to AltGr of its own key moves; « ê » moves with its dead key.
	const toy = (deadCode, aRow) => ({
		id: `toy_${deadCode}`,
		rows: Object.assign(
			{ KeyE: ['e', 'E', null, null], KeyA: aRow, Space: [' ', ' ', null, null] },
			{ [deadCode]: [{ dead: 'circ' }, null, null, null] }
		),
		dead: { circ: { e: 'ê', ' ': '^' } }
	});
	const toyCounts = E.ngramsFromText('ê e a ee aa');
	const toyUni = new Map(E.prepareNgrams(toyCounts).uni);
	const toyTotal = toyUni.get('ê') + toyUni.get('e') + toyUni.get('a');
	const dead = E.layoutSimilarity(
		toy('KeyQ', ['a', 'A', null, null]),
		toy('KeyW', ['a', 'A', null, null]),
		toyCounts,
		{}
	);
	check(
		near(dead.weighted.sameKey, (100 * (toyTotal - toyUni.get('ê'))) / toyTotal) &&
			near(dead.unweighted.sameKey, (100 * 2) / 3),
		`similarity: a moved dead key moves « ê » only: ${dead.weighted.sameKey} / ${dead.unweighted.sameKey} %`
	);
	const level = E.layoutSimilarity(
		toy('KeyQ', ['a', 'A', null, null]),
		toy('KeyQ', [null, 'A', 'a', null]),
		toyCounts,
		{}
	);
	check(
		near(level.weighted.sameFingerRow, (100 * (toyTotal - toyUni.get('a'))) / toyTotal),
		`similarity: « a » moved to AltGr of its own key stays alike: ${level.weighted.sameFingerRow} %`
	);
	let empty = null;
	try {
		E.layoutSimilarity(azerty, azerty, E.ngramsFromText('    '), {});
	} catch (error) {
		empty = error.code;
	}
	check(empty === 'similarity_empty', `similarity: a corpus of spaces gives ${empty}`);
	const gap = E.similarScoreGap();
	check(
		Number.isFinite(gap) &&
			gap >= 0 &&
			gap === sandbox.LAYOUT_ANALYSIS_DATA.model.similar_score_gap,
		`similarity: the small score gap is ${gap}`
	);
}

// ===============================================
// ======= 14/ Collections of the library ========
// ===============================================

{
	// (layout-collections-2026-11-19) The library only grows: a regenerated
	// collection that lost layouts must fail here, not read as a pass.
	check(
		library.length >= LIBRARY_COUNT,
		`collections: the library holds ${library.length} layouts, fewer than its ${LIBRARY_COUNT}`
	);
	const libraryFile = JSON.parse(
		fs.readFileSync(shared('layouts', 'data', 'analysis', 'layout_library.json'), 'utf8')
	);
	const credits = JSON.parse(
		fs.readFileSync(shared('layouts', 'data', 'analysis', 'layout_credits.json'), 'utf8')
	).credits;
	// Every entry names its collection and file; an entry of a collection
	// imported from its author's own files is credited to its author, with the
	// page, the date it was read and what it says.
	for (const entry of libraryFile.layouts) {
		const source = libraryFile.sources[entry.source];
		check(
			source !== undefined && typeof entry.source_path === 'string' && entry.source_path !== '',
			`collections: ${entry.id} names no known source and file`
		);
		check(
			source === undefined || Boolean(source.commit || source.version || source.date),
			`collections: the source ${entry.source} of ${entry.id} has no commit, version or date`
		);
		if (!CREDITED_SOURCES.includes(entry.source)) continue;
		const credit = credits[entry.id];
		check(
			credit !== undefined &&
				credit.authors.length > 0 &&
				typeof credit.url === 'string' &&
				(credit.basis === 'knowledge' || typeof credit.checked === 'string'),
			`collections: ${entry.id} (${entry.source}) has no credit with an author and a page, checked unless « knowledge »`
		);
	}
	// Key cells as each collection's official file states them.
	const cell = (id, code, level) => {
		const layout = byId.get(id);
		const row = layout && layout.rows[code];
		const value = row ? row[level] : undefined;
		return value && typeof value === 'object' ? `dead:${value.dead}` : value;
	};
	const official = [
		// moutis/HandsDown JSON/: Alt « wchfv/yujq rsntgkieoa xmldbzp',. ».
		['hands_down_alt', 'KeyQ', 0, 'w'],
		['hands_down_alt', 'KeyY', 0, '/'],
		['hands_down_alt', 'KeyH', 0, 'k'],
		['hands_down_alt', 'Semicolon', 0, 'a'],
		['hands_down_alt', 'KeyN', 0, 'z'],
		// Extreme « xchgzkyoj/ rsntpwueia 'mldbvfq,. ».
		['hands_down_extreme', 'KeyQ', 0, 'x'],
		['hands_down_extreme', 'KeyZ', 0, "'"],
		['hands_down_extreme', 'KeyM', 0, 'f'],
		// XKCD « qmhgzyfob' srntpwueia » on its ErgoDox number row 7 5 3 1 9.
		['hands_down_xkcd', 'KeyA', 0, 's'],
		['hands_down_xkcd', 'KeyS', 0, 'r'],
		['hands_down_xkcd', 'Digit1', 0, '7'],
		// The sym (angle) files: Polyglot « wgmfq'uokx rsntbyieah cldvzjp,./ ».
		['hands_down_polyglot_sym', 'KeyP', 0, 'x'],
		['hands_down_polyglot_sym', 'KeyZ', 0, 'c'],
		['hands_down_ref_sym', 'KeyQ', 0, 'q'],
		['hands_down_alt_sym', 'KeyH', 0, 'y'],
		// Reiser's other layouts: Notarise « qwfdpyulk' asetghnoir », Heads Up
		// « qwdgmyukl' rsetfhnioa », Hands On « wgldjykuq' rsntpfieoa ».
		['notarise', 'KeyD', 0, 'e'],
		['notarise', 'Semicolon', 0, 'r'],
		['heads_up', 'KeyL', 0, 'o'],
		['hands_on', 'KeyT', 0, 'j'],
		['hands_on_sym', 'KeyB', 0, 'j'],
		// KLAnext's layouts/ files (2026-11-19): Fargas (ISO), Navarre's 1907
		// French layout, SteveP's ISO Colemak-DH on the angle mod, Alphametric.
		['fargas', 'KeyQ', 0, '$'],
		['fargas', 'KeyW', 0, 'l'],
		['fargas', 'IntlBackslash', 0, 'q'],
		['fargas', 'KeyB', 0, '['],
		['zhjayscpg_1907_fr', 'KeyQ', 0, 'à'],
		['zhjayscpg_1907_fr', 'KeyA', 0, '-'],
		['zhjayscpg_1907_fr', 'IntlBackslash', 0, '<'],
		['zhjayscpg_1907_fr', 'KeyB', 0, 'o'],
		['colemak_mod_dh', 'IntlBackslash', 0, 'z'],
		['colemak_mod_dh', 'KeyB', 0, '\\'],
		['alphametric', 'KeyQ', 0, '/'],
		['alphametric', 'KeyA', 0, 'a'],
		['alphametric', 'KeyZ', 0, "'"],
		// xkeyboard-config symbols/fr (f4d3ed8b): the AFNOR AZERTY (NF Z71-300)
		// « @ # ◌̆ ◌̑ », « à 1 § À », « - – − ‑ », « / \ ÷ √ »; Dvorak-fr's
		// « : ? æ Æ » and « à ç » left of Z; the ISO Ergo-L with z left of x.
		['azerty_afnor', 'Backquote', 0, '@'],
		['azerty_afnor', 'Backquote', 2, 'dead:breve'],
		['azerty_afnor', 'Digit1', 0, 'à'],
		['azerty_afnor', 'BracketLeft', 0, '-'],
		['azerty_afnor', 'Quote', 3, '√'],
		['azerty_afnor', 'Equal', 0, 'dead:circumflex'],
		['dvorak_fr', 'KeyQ', 0, ':'],
		['dvorak_fr', 'KeyA', 0, 'o'],
		['dvorak_fr', 'IntlBackslash', 1, 'ç'],
		['dvorak_fr', 'BracketLeft', 0, 'z'],
		['ergol_iso', 'IntlBackslash', 0, 'z'],
		['ergol_iso', 'KeyZ', 0, 'x'],
		['ergol_iso', 'KeyO', 0, 'dead:1dk'],
		['azerty_latin9', 'Backquote', 0, 'œ'],
		['azerty_mac', 'Backquote', 0, '@'],
		// Nuclear-Squid/ergol keymaps/ (03c6c7c8b3), Kalamine JSON: Bépolar's
		// 1DK right of B, Erglace's left of O, Ergaie's right of I, Kazerty's
		// on the key right of M, and Béopy's « b é p o ».
		['bepolar', 'KeyQ', 0, 'b'],
		['bepolar', 'KeyN', 0, 'dead:odk'],
		['erglace', 'KeyQ', 0, 'y'],
		['erglace', 'KeyW', 0, 'dead:odk'],
		['ergaie', 'KeyO', 0, 'dead:odk'],
		['ergaie', 'KeyN', 0, 'z'],
		['kazerty', 'Quote', 0, 'dead:odk'],
		['beopy', 'KeyW', 0, 'é'],
		// cyanophage.github.io (b02780b39d), its 3 × 11 strings: Gallium
		// « bldcvzyou,- nrtsgphaei/ », Neu « wfmpv/.q;'z rsntb,aeihj », Pine v4.
		['gallium', 'KeyQ', 0, 'b'],
		['gallium', 'Quote', 0, '/'],
		['handsdown_neu', 'BracketLeft', 0, 'z'],
		['handsdown_neu', 'Quote', 0, 'j'],
		['pine_v4', 'KeyP', 0, 'y'],
		['beakl19bis', 'KeyA', 0, 'h']
	];
	for (const [id, code, level, expected] of official)
		check(
			cell(id, code, level) === expected,
			`collections: ${id} ${code} level ${level} is ${cell(id, code, level)}, its official file has ${expected}`
		);
	for (const id of [
		'hands_down_polyglot_sym',
		'hands_down_ref_sym',
		'hands_on_sym',
		'colemak_mod_dh',
		'ergol_iso'
	])
		check(byId.get(id).fingering === 'angle', `collections: ${id} is not on the angle fingering`);
	// What a collection leaves out says why: a Hands Down letter on a thumb key
	// has no key on the library's keyboards, and its Reference is held once.
	const left = new Map(libraryFile.not_imported.map((entry) => [entry.source_path, entry]));
	const gold = left.get('JSON/HandsDownNeu/hands-down-gold-ts.eu.ergodox.json');
	check(
		gold && /T on a thumb key/.test(gold.reason),
		'collections: Hands Down Gold is not left out for its thumb T'
	);
	check(
		(left.get('JSON/HandsDownArchive/Hands_Down_ref_ansi.json') || {}).same_as === 'hands_down',
		'collections: Hands Down Reference is not the library’s hands_down'
	);
	// bépo's xkeyboard-config variants (1.0rc2, its Latin-9 subset, AFNOR) share the
	// registry bépo's letters and digits: held once.
	for (const variant of ['bepo', 'bepo_latin9', 'bepo_afnor'])
		check(
			(left.get(`symbols/fr, ${variant}`) || {}).same_as === 'bepo',
			`collections: fr(${variant}) is not held as the registry bépo`
		);
	// Their 1DK tables, as the files' « deadkeys » state them.
	for (const [id, typed, expected] of [
		['bepolar', '1', '&'],
		['erglace', '2', '°'],
		['kazerty', 'z', 'é'],
		['kazerty', 'a', 'à']
	])
		check(
			((byId.get(id) || { dead: {} }).dead.odk || {})[typed] === expected,
			`collections: ${id} 1DK + ${typed} is not ${expected}, as its keymap states`
		);
	// The French layouts type French with their dead keys. The ë and ï of the
	// ISO Ergo-L, Bépolar and Erglace are their 1DK typed twice, a chain the
	// library's dead_rules cannot state.
	for (const [id, text] of [
		['azerty_afnor', 'Ça ? Où « Noël » : être, naïf, cœur.'],
		['azerty_latin9', 'Ça ? Où « Noël » : être, naïf, cœur.'],
		['dvorak_fr', 'Ça ? Où « Noël » : être, naïf, cœur.'],
		['ergol_iso', 'Ça ? Où « Noel » : être, cœur.'],
		['bepolar', 'Ça ? Où « Noel » : être, cœur.'],
		['erglace', 'Ça ? Où « Noel » : être, cœur.'],
		['ergaie', 'Ça ? Où « Noël » : être, naïf, cœur.'],
		['colemak_french_touch', 'Ça ? Où « Noël » : être, naïf, cœur.']
	]) {
		const result = E.analyse(byId.get(id), E.ngramsFromText(text), {});
		check(
			Object.keys(result.coverage.unsupportedChars).join('') === '',
			`collections: ${id} cannot type ${Object.keys(result.coverage.unsupportedChars).join('')}`
		);
	}
	// cyanophage's Hands Down Vibranium puts its R on a thumb key.
	check(
		/r on a thumb key/.test((left.get('index.html#hd-vibranium') || {}).reason),
		'collections: cyanophage’s Hands Down Vibranium is not left out for its thumb R'
	);
	// KLAnext's copy of a library layout is left out, naming the one held.
	check(
		(left.get('layouts/colemak.en.ansi.json') || {}).same_as === 'colemak',
		'collections: KLAnext’s Colemak is not the library’s colemak'
	);
	// A collection's credit names the author its file states (KLAnext's « author »).
	check(
		(credits.fargas || {}).authors[0] === 'Peter Fargas, captured by Ian Douglas',
		'collections: Fargas is not credited as its KLAnext file states'
	);
}

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-analysis-engine: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-analysis-engine: OK (${vectors.length} vectors, ${compared} values, ` +
		`${library.length} layouts in ${elapsedMs.toFixed(0)} ms, ${goldenValues} golden values, ` +
		`largest gap ${goldenGap.toExponential(1)})`
);
