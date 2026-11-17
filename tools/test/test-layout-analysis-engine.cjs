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
 *    bépo: the incremental context plan and walk), keeps a
 *    trial only once committed, and refuses a layout on another board.
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
const flipped = E.rescore(ranked, Object.fromEntries(Object.keys(defaults).map((m) => [m, 0])));
check(
	flipped.every((r) => r.score.total === 0),
	'rescore: all-zero weights give every layout zero'
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
}

// ====================================
// ======= 5/ Incremental score =======
// ====================================

// scoreSession re-scores only the n-grams a change touches; it must give the
// full analysis's score after any change. Property: random swaps of any two
// cells (any level, dead keys and holes included), some dead-key rules
// changed, on layouts with dead keys and AltGr levels, several boards,
// formats and weights, with trials kept or dropped at random.
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
	const clone = (layout) => ({
		id: layout.id,
		fingering: layout.fingering,
		rows: Object.fromEntries(Object.entries(layout.rows).map(([code, row]) => [code, row.slice()])),
		dead: Object.fromEntries(
			Object.entries(layout.dead).map(([dead, rules]) => [dead, Object.assign({}, rules)])
		),
		command: Object.assign({}, layout.command)
	});
	/** A copy of layout with two cells swapped, or two dead-key outputs swapped. */
	const mutate = (layout) => {
		const out = clone(layout);
		const states = Object.keys(out.dead).filter((dead) => Object.keys(out.dead[dead]).length > 1);
		if (states.length && next() < 0.15) {
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
	let worst = 0;
	// How the trials were walked: the layouts with choices must take the
	// incremental context walk, not only the whole-stream fallback.
	const walks = {};
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
			const expected = full(candidate);
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
	console.log(`  incremental: ${trials} trials, largest gap ${worst.toExponential(1)}`);
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
// distance 1/mm, home_row 0.3, pinky_load 0.3, modifier and dead-key use 0.5,
// sfb 10; ISO reaches KeyR, KeyP, KeyE 19.636 mm, AltRight 69.056 mm). In
// « fé » there are 2 characters and 1 bigram, so a pair counts 100 × 2 per
// point of weight:
// - é on KeyR (left index, like f): 19.636 + 10 × 200 (SFB) = 2019.636;
// - AltGr+KeyL (home): −30 (home) + 69.056 (AltRight) + 50 (modifier) = 89.056;
// - dead key KeyP then e on KeyE: 19.636 + 30 (pinky) + 19.636 + 50 (dead key)
//   = 119.272, both pairs changing hands.
// Alone, é is typed directly (19.636 is the least).
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
	check(onlyKind(afterF, 'é') === 'altgr', `ways: « fé » types é by ${onlyKind(afterF, 'é')}`);
	// f on the home row (−30), é through AltGr (89.056), over 2 characters.
	check(
		Math.abs(afterF.typing.cost - (-30 + 89.056) / 2) < 1e-3,
		`ways: « fé » costs ${afterF.typing.cost}`
	);
	const noAltGr = toy('toy_access_dead', Object.assign({}, cells, { KeyL: null }), dead);
	const deadKey = E.analyse(noAltGr, E.ngramsFromText('fé'), { keyboard: 'iso' });
	check(
		onlyKind(deadKey, 'é') === 'dead',
		`ways: without AltGr, « fé » types é by ${onlyKind(deadKey, 'é')}`
	);
	check(deadKey.metrics.dead_key_usage === 50, 'ways: the dead key types one character of two');
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
