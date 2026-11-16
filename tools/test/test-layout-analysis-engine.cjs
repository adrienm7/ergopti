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
 * 5. Speed: the whole library on a 2.5 MB corpus, from prepared tables, well
 *    under a second.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const DATA_PATH = shared('ui', 'layout_analysis', '_generated', 'analysis_data.js');
const ENGINE_PATH = shared('ui', 'layout_analysis', 'analysis_engine.js');
const VECTORS_PATH = shared('tests', 'corpus', 'layout_analysis', 'metric_vectors.json');
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
// Budget for the whole library on the speed corpus, from prepared tables. The
// measured time is about 0.3 s; the budget leaves room for a slow CI runner.
const SPEED_BUDGET_MS = 1500;
const TOLERANCE = 1e-6;

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

// =====================================
// ======= 2/ Exact key n-grams ========
// =====================================

/**
 * Counts SFBs and alternations on the expanded key stream of a text, the
 * definition the tables must reproduce.
 */
function streamCounts(layout, text, keyboardId) {
	const board = E.keyboard(keyboardId);
	const best = E.compileLayout(layout, board, null);
	const thumb = (k) => board.finger[k] === 4 || board.finger[k] === 5;
	const counts = { bigrams: 0, sfb: 0, trigrams: 0, alternation: 0, sfs: 0 };
	for (const segment of text.split(/[\r\n\t]+/)) {
		const keys = [];
		const flush = () => {
			for (let i = 0; i + 1 < keys.length; i++) {
				const [a, b] = [keys[i], keys[i + 1]];
				if (thumb(a) || thumb(b)) continue;
				counts.bigrams++;
				if (a !== b && board.finger[a] === board.finger[b]) counts.sfb++;
			}
			for (let i = 0; i + 2 < keys.length; i++) {
				const [a, b, c] = [keys[i], keys[i + 1], keys[i + 2]];
				if (thumb(a) || thumb(b) || thumb(c)) continue;
				counts.trigrams++;
				if (board.finger[a] === board.finger[c] && a !== c) counts.sfs++;
				const sameFinger =
					board.finger[a] === board.finger[b] || board.finger[b] === board.finger[c];
				if (!sameFinger && board.hand[a] !== board.hand[b] && board.hand[b] !== board.hand[c])
					counts.alternation++;
			}
			keys.length = 0;
		};
		for (const char of Array.from(segment)) {
			const seq = best.get(char);
			// An unsupported character cuts the stream, as it cuts the tables.
			if (!seq) flush();
			else keys.push(...seq.keys);
		}
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
	check(
		near(result.metrics.sfb, pct(expected.sfb, expected.bigrams)),
		`${id}: SFB differs from the stream`
	);
	check(
		near(result.metrics.sfs, pct(expected.sfs, expected.trigrams)),
		`${id}: SFS differs from the stream`
	);
	check(
		near(result.metrics.alternation, pct(expected.alternation, expected.trigrams)),
		`${id}: alternation differs from the stream`
	);
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

// ========================
// ======= 5/ Speed =======
// ========================

const prepared = E.prepareNgrams(E.ngramsFromText(fs.readFileSync(SPEED_CORPUS, 'utf8')));
const start = process.hrtime.bigint();
E.compare(library, prepared, {});
const elapsedMs = Number(process.hrtime.bigint() - start) / 1e6;
check(
	elapsedMs < SPEED_BUDGET_MS,
	`speed: ${library.length} layouts took ${elapsedMs.toFixed(0)} ms`
);

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-analysis-engine: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-analysis-engine: OK (${vectors.length} vectors, ${compared} values, ` +
		`${library.length} layouts in ${elapsedMs.toFixed(0)} ms)`
);
