// tools/test/test-layout-analysis-views.cjs

/**
 * ==============================================================================
 * MODULE: Layout Analysis Views Gate
 * DESCRIPTION:
 * The Comparer's Pareto and Trace tabs (ideas seen in the Layouts Wiki
 * playground, docs/audits/layout-analysers/layouts-wiki-playground.md) read
 * two engine functions of _shared/ui/layout_analysis/analysis_engine.js:
 * pareto() and traceText(). This gate holds them to their definitions.
 *
 * WHAT IS CHECKED:
 * 1. pareto: hand-worked layers on small point sets (ties share a layer and
 *    do not dominate each other, « higher is better » flips a value), the
 *    frontier of random points matches a brute-force dominance check, and
 *    invalid input throws.
 * 2. traceText: each character's way of typing (Shift held by name, a dead
 *    key then its letter), a break or an untyped character cuts the stream,
 *    and on real sentences every event count of the trace, as a share of
 *    its pairs or triples, equals analyse()'s metric on the same text, for
 *    several library layouts with dead keys and AltGr levels.
 * 4. windowMetrics: a user metric's share equals the movement table's on the
 *    same event (bigrams, skipgrams, trigrams), a value and its negation make
 *    100 %, the fields mean what they say (finger 4 the pinky, row −1 above
 *    the home row), and a query naming a key the window lacks is refused.
 * 3. densityCurve: the smoothed distribution integrates to 1, peaks on the
 *    densest cluster, draws the normal bell for one value, and refuses
 *    invalid input.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const vm = require('vm');
const { shared } = require('../lib/paths.cjs');

const LEGEND_PATH = shared('ui', '_generated', 'key_legend.js');
const DATA_PATH = shared('ui', 'layout_analysis', '_generated', 'analysis_data.js');
const ENGINE_PATH = shared('ui', 'layout_analysis', 'analysis_engine.js');
// Shares are sums of integer counts: they agree to the last bits.
const TOLERANCE = 1e-9;

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};
const throws = (fn, message) => {
	try {
		fn();
	} catch {
		return;
	}
	errors.push(message);
};

const sandbox = {};
vm.createContext(sandbox);
for (const file of [LEGEND_PATH, DATA_PATH, ENGINE_PATH])
	vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const byId = new Map(E.libraryLayouts().map((layout) => [layout.id, layout]));

// ===================================
// ======= 1/ Pareto layers ==========
// ===================================

{
	const points = [
		{ id: 'a', values: [1, 1] },
		{ id: 'b', values: [2, 2] },
		{ id: 'c', values: [0, 3] },
		{ id: 'd', values: [1, 1] },
		{ id: 'e', values: [3, 3] }
	];
	const out = E.pareto(points, ['lower', 'lower']);
	const layers = Object.fromEntries(out.map((p) => [p.id, p.layer]));
	check(
		JSON.stringify(layers) === JSON.stringify({ a: 1, b: 2, c: 1, d: 1, e: 3 }),
		`pareto: layers ${JSON.stringify(layers)}`
	);
	check(
		JSON.stringify(out.find((p) => p.id === 'b').dominatedBy) === JSON.stringify(['a', 'd']),
		'pareto: b is dominated by a and d, in the points order'
	);
	check(
		out.find((p) => p.id === 'a').dominatedBy.length === 0,
		'pareto: equal points do not dominate each other'
	);
	check(
		out.every((p) => p.front === (p.layer === 1)),
		'pareto: front is layer 1'
	);
	// « higher is better » on the second value: c (0, 3) now beats everything
	// lower on the first value and higher on the second.
	const flipped = E.pareto(points, ['lower', 'higher']);
	const front = flipped.filter((p) => p.front).map((p) => p.id);
	check(
		JSON.stringify(front) === JSON.stringify(['c']),
		`pareto: higher is better flips the value (front ${front})`
	);
	// Random points against a brute-force frontier.
	let seed = 7;
	const random = () => {
		seed = (seed * 1103515245 + 12345) % 2147483648;
		return seed / 2147483648;
	};
	for (let round = 0; round < 20; round++) {
		const set = Array.from({ length: 40 }, (_, i) => ({
			id: `p${i}`,
			values: [Math.round(random() * 10), Math.round(random() * 10), Math.round(random() * 10)]
		}));
		const directions = ['lower', 'higher', 'lower'];
		const sign = directions.map((d) => (d === 'lower' ? 1 : -1));
		const beats = (a, b) =>
			a.values.every((v, i) => sign[i] * v <= sign[i] * b.values[i]) &&
			a.values.some((v, i) => sign[i] * v < sign[i] * b.values[i]);
		const result = E.pareto(set, directions);
		set.forEach((point, i) => {
			const expected = set.filter((other) => beats(other, point)).map((o) => o.id);
			check(
				JSON.stringify(result[i].dominatedBy) === JSON.stringify(expected),
				`pareto: random round ${round}, ${point.id} dominators`
			);
			// A layer is one more than the deepest layer among its dominators.
			const deepest = Math.max(0, ...expected.map((id) => result.find((r) => r.id === id).layer));
			check(result[i].layer === deepest + 1, `pareto: random round ${round}, ${point.id} layer`);
		});
	}
	throws(() => E.pareto(points, []), 'pareto: no direction throws');
	throws(() => E.pareto(points, ['lower', 'best']), 'pareto: an unknown direction throws');
	throws(
		() =>
			E.pareto(
				[
					{ id: 'a', values: [1] },
					{ id: 'a', values: [2] }
				],
				['lower']
			),
		'pareto: a duplicate id throws'
	);
	throws(
		() => E.pareto([{ id: 'a', values: [NaN] }], ['lower']),
		'pareto: a value that is not finite throws'
	);
	throws(
		() => E.pareto([{ id: 'a', values: [1, 2] }], ['lower']),
		'pareto: a value count unlike the directions throws'
	);
}

// =================================
// ======= 2/ Text trace ===========
// =================================

{
	const azerty = byId.get('azerty');
	const trace = E.traceText(azerty, 'Oê\nça', { keyboard: 'iso' });
	const [o, e, br, c, a] = trace.chars;
	check(
		o.kind === 'shift' && JSON.stringify(o.held) === JSON.stringify(['Shift']),
		`trace: AZERTY types « O » with Shift held (${JSON.stringify(o)})`
	);
	check(
		e.kind === 'dead' &&
			JSON.stringify(e.steps.map((s) => s[0])) === JSON.stringify(['BracketLeft', 'KeyE']),
		`trace: AZERTY types « ê » as its circumflex dead key then e (${JSON.stringify(e)})`
	);
	check(br.kind === null && br.keys.length === 0, 'trace: a line break types no key');
	check(c.kind === 'direct' && a.kind === 'direct', 'trace: « ç » and « a » are direct');
	// The pairs: O-^, ^-e inside « ê » (the break cuts ê from ç), ç-a.
	const pairCodes = trace.pairs.map((p) => p.keys.map((k) => trace.keys[k].code).join('-'));
	check(
		JSON.stringify(pairCodes) ===
			JSON.stringify(['KeyO-BracketLeft', 'BracketLeft-KeyE', 'Digit9-KeyQ']),
		`trace: the break cuts the stream (${pairCodes})`
	);
	check(trace.triples.length === 1, 'trace: one triple before the break, none after');
	check(
		trace.keys.every((key) => typeof key.finger === 'string' && key.finger !== ''),
		'trace: every key has its finger'
	);
	const untyped = E.traceText(byId.get('qwerty'), 'aça', { keyboard: 'iso' });
	check(
		untyped.unsupported === 1 && untyped.pairs.length === 0,
		'trace: a character the layout cannot type cuts the stream and is counted'
	);
	throws(() => E.traceText(azerty, 42), 'trace: a text that is not a string throws');
	throws(
		() => E.traceText(azerty, 'a'.repeat(E.TRACE_MAX_CHARS + 1)),
		'trace: a text over TRACE_MAX_CHARS throws'
	);

	// The trace's counts are analyse()'s metrics on the same text.
	const texts = [
		'Le cœur a ses raisons que la raison ne connaît point. Où êtes-vous allés, Zoé ?',
		'The quick brown fox jumps over the lazy dog; WHY? Because 42 > 7.'
	];
	for (const id of ['azerty', 'qwerty', 'bepo', 'ergopti', 'ergol']) {
		const layout = byId.get(id);
		check(layout, `trace: the library has ${id}`);
		if (!layout) continue;
		for (const text of texts) {
			const r = E.analyse(layout, E.ngramsFromText(text), { keyboard: 'iso' });
			const tr = E.traceText(layout, text, { keyboard: 'iso' });
			for (const event of E.TRACE_PAIR_EVENTS.concat(E.TRACE_TRIPLE_EVENTS)) {
				const whole = E.TRACE_TRIPLE_EVENTS.includes(event) ? tr.trigrams : tr.bigrams;
				const share = whole > 0 ? (100 * tr.counts[event]) / whole : 0;
				check(
					Math.abs(share - r.metrics[event]) <= TOLERANCE,
					`trace: ${id} ${event} ${share} against analyse() ${r.metrics[event]} on « ${text.slice(0, 20)}… »`
				);
			}
		}
	}
}

// ====================================
// ======= 3/ Movement table ==========
// ====================================

{
	const text = 'Le cœur a ses raisons que la raison ne connaît point. Où êtes-vous allés, Zoé ?';
	for (const id of ['azerty', 'ergopti', 'qwerty']) {
		const layout = byId.get(id);
		const ngrams = E.ngramsFromText(text);
		const table = E.movementTable(layout, ngrams, { keyboard: 'iso' });
		const r = E.analyse(layout, ngrams, { keyboard: 'iso' });
		for (const name of E.MOVEMENT_CLASSES)
			check(
				Math.abs(table.bigram[name] - r.metrics[name]) <= TOLERANCE,
				`movement: ${id} ${name} pairs ${table.bigram[name]} against analyse() ${r.metrics[name]}`
			);
	}
	// The trigram rhythm over all trigrams is analyse()'s metric of each class.
	for (const id of ['azerty', 'ergopti', 'bepo']) {
		const layout = byId.get(id);
		const ngrams = E.ngramsFromText(text);
		const table = E.movementTable(layout, ngrams, { keyboard: 'iso' });
		const r = E.analyse(layout, ngrams, { keyboard: 'iso' });
		for (const name of ['alternation', 'roll3_in', 'roll3_out', 'redirect', 'redirect_bad'])
			check(
				Math.abs(table.rhythm.all[name] - r.metrics[name]) <= TOLERANCE,
				`rhythm: ${id} ${name} ${table.rhythm.all[name]} against analyse() ${r.metrics[name]}`
			);
		check(table.trigramsNoThumbs <= table.trigrams, `rhythm: ${id} no-thumb trigrams are a subset`);
	}
	// « dke » on QWERTY: left middle, right middle, left middle again, an
	// alternation whose ends share a finger.
	const dkeRhythm = E.movementTable(byId.get('qwerty'), E.ngramsFromText('dke'), {
		keyboard: 'iso'
	}).rhythm.all;
	check(
		dkeRhythm.alternation === 100 && dkeRhythm.alternation_sfs === 100,
		`rhythm: « dke » is an alternation with same-finger ends (${JSON.stringify(dkeRhythm)})`
	);
	// Skipgrams worked by hand on QWERTY: « ded » ends on the same key (a
	// repeat), « dke » on the left middle finger twice (an SFB), « dkf » on two
	// fingers of the left hand (no same-finger class).
	const qwerty = byId.get('qwerty');
	const skip = (text) => E.movementTable(qwerty, E.ngramsFromText(text), { keyboard: 'iso' });
	const ded = skip('ded');
	check(
		ded.skipgrams === 1 && ded.skipgram.repeat === 100,
		`movement: « ded » is a repeat skipgram`
	);
	const dke = skip('dke');
	check(dke.skipgrams === 1 && dke.skipgram.sfb === 100, 'movement: « dke » is an SFB skipgram');
	// Row changes on QWERTY: « se » ring home then middle top (the longer
	// finger above: concordant), « dw » middle home then ring top (discordant),
	// « sd » one row, « dk » two hands, « de » one finger: none of them.
	const pair = (text) =>
		E.movementTable(qwerty, E.ngramsFromText(text), { keyboard: 'iso' }).bigram;
	const se = pair('se');
	check(
		se.row_change === 100 && se.row_change_concordant === 100 && se.row_change_discordant === 0,
		`movement: « se » is a concordant row change (${JSON.stringify(se)})`
	);
	const dw = pair('dw');
	check(
		dw.row_change === 100 && dw.row_change_discordant === 100,
		'movement: « dw » is a discordant row change'
	);
	for (const text of ['sd', 'dk', 'de'])
		check(pair(text).row_change === 0, `movement: « ${text} » is no row change`);
	const dkf = skip('dkf');
	check(
		dkf.skipgrams === 1 && dkf.skipgram.sfb === 0 && dkf.skipgram.repeat === 0,
		'movement: « dkf » is no same-finger skipgram'
	);
}

// =====================================
// ======= 4/ Words with keys ==========
// =====================================

{
	const qwerty = byId.get('qwerty');
	const words = { the: 5, ded: 2, cede: 3, dog: 1, édé: 9 };
	const found = E.wordsWithKeys(qwerty, words, ['KeyD', 'KeyE'], { keyboard: 'iso' });
	check(
		JSON.stringify(found.words.map((w) => w.word)) === JSON.stringify(['cede', 'ded']) &&
			found.occurrences === 5,
		`words: « de » in a row, the most frequent first, untyped words left out (${JSON.stringify(found)})`
	);
	const triple = E.wordsWithKeys(qwerty, words, ['KeyE', 'KeyD', 'KeyE'], { keyboard: 'iso' });
	check(
		JSON.stringify(triple.words.map((w) => w.word)) === JSON.stringify(['cede']),
		'words: three keys in a row'
	);
	check(
		E.wordsWithKeys(qwerty, words, ['KeyD', 'KeyE'], { keyboard: 'iso', limit: 1 }).words.length ===
			1,
		'words: the limit'
	);
	throws(() => E.wordsWithKeys(qwerty, words, ['KeyD']), 'words: one code throws');
	throws(() => E.wordsWithKeys(qwerty, words, ['KeyD', 'Nope']), 'words: an unknown code throws');
}

// ===================================
// ======= 5/ Corpus blends ===========
// ===================================

{
	const a = E.ngramsFromText('le chat dort');
	const b = E.ngramsFromText('the cat sleeps');
	a.words = { chat: 4, dort: 1 };
	b.words = { cat: 1 };
	const total = (table) => Object.values(table).reduce((sum, n) => sum + n, 0);
	const blend = E.blendNgrams([
		{ ngrams: a, weight: 3 },
		{ ngrams: b, weight: 1 },
		{ ngrams: E.ngramsFromText('zzz'), weight: 0 }
	]);
	check(Math.abs(total(blend.chars) - E.BLEND_CHARS) < 1e-6, 'blend: BLEND_CHARS characters');
	// « o » is French only: 3/4 of the characters, one of the 12 French ones.
	check(
		Math.abs(blend.chars.o - (E.BLEND_CHARS * 0.75) / 12) < 1e-6,
		`blend: a part weighs its share of the characters (${blend.chars.o})`
	);
	check(!('z' in blend.chars), 'blend: a part of weight 0 is skipped');
	check(
		Object.keys(blend.words)[0] === 'chat' && 'cat' in blend.words,
		'blend: the word tables are mixed'
	);
	// A blend of one corpus measures as that corpus.
	const alone = E.blendNgrams([{ ngrams: a, weight: 1 }]);
	const layout = byId.get('azerty');
	const r1 = E.analyse(layout, a, { keyboard: 'iso' });
	const r2 = E.analyse(layout, alone, { keyboard: 'iso' });
	check(
		Object.keys(r1.metrics).every((id) => Math.abs(r1.metrics[id] - r2.metrics[id]) <= 1e-9),
		'blend: one corpus alone measures the same'
	);
	throws(() => E.blendNgrams([]), 'blend: no part throws');
	throws(() => E.blendNgrams([{ ngrams: a, weight: -1 }]), 'blend: a negative weight throws');
	throws(() => E.blendNgrams([{ ngrams: a, weight: 0 }]), 'blend: all weights 0 throw');
}

// ===========================================
// ======= Movement percentiles ==============
// ===========================================

// The movement cells' percentiles against the library (an idea seen in the
// Layouts Wiki playground): rankAmong in the class's direction, E.percentiles
// for a scored metric, the share below for a class with no better way.
{
	const values = Array.from({ length: 40 }, (_, n) => n);
	const lower = E.rankAmong('lower', values);
	const higher = E.rankAmong('higher', values);
	const none = E.rankAmong('none', values);
	check(lower(-1).percent === 100 && lower(40).percent === 0, 'rankAmong: lower is better');
	check(higher(40).percent === 100 && higher(-1).percent === 0, 'rankAmong: higher is better');
	check(none(30).percent === higher(30).percent, 'rankAmong: none ranks the value as higher');
	check(lower(10).count === 40, 'rankAmong: the count of references');
	check(E.rankAmong('lower', values.slice(0, 19))(3) === null, 'rankAmong: too few references');
	check(lower(Number.NaN) === null, 'rankAmong: no percentile for a value that is not a number');
	throws(() => E.rankAmong('sideways', values), 'rankAmong: an unknown direction throws');
	throws(
		() => E.rankAmong('lower', [1, 'x']),
		'rankAmong: a reference that is not a number throws'
	);
	// The same answer as E.percentiles for a scored metric.
	const sfb = E.percentiles('sfb', values);
	check(
		values.every((v) => sfb(v + 0.5).percent === lower(v + 0.5).percent),
		'rankAmong: the metric percentiles in their direction'
	);
	for (const id of E.MOVEMENT_CLASSES.concat(E.MOVEMENT_EXTRA, E.RHYTHM_CLASSES))
		check(
			['higher', 'lower', 'none'].includes(E.movementBetter(id)),
			`movementBetter: ${id} has a direction`
		);
	check(E.movementBetter('sfb') === 'lower', 'movementBetter: a metric keeps its direction');
	check(
		E.movementBetter('redirect_sfs') === 'lower',
		'movementBetter: a same-finger end is a cost'
	);
	check(E.movementBetter('row_change') === 'none', 'movementBetter: a row change is neither');
	throws(() => E.movementBetter('sfb_typo'), 'movementBetter: another id throws');
}

// ===========================================
// ======= Values query ======================
// ===========================================

// The library filter's query (an idea seen in the Layouts Wiki playground):
// comparisons and yes-or-no values joined by & and |, negated by !.
{
	const names = { numbers: ['sfb', 'mark', 'roll_in'], flags: ['complete', 'mine'] };
	const values = { sfb: 1.1, mark: 120, roll_in: 30, complete: true, mine: false };
	const holds = (text) => E.compileQuery(text, names)(values);
	check(holds(''), 'query: an empty query keeps every layout');
	check(holds('sfb < 1.2'), 'query: a comparison');
	check(holds('sfb<1,2 & roll_in >= 30'), 'query: a decimal comma and &');
	check(!holds('sfb >= 1.2'), 'query: a comparison that fails');
	check(holds('not complete | mark > 100'), 'query: | and the word not');
	check(!holds('!(sfb > 1 and complete)'), 'query: ! over parentheses');
	check(holds('sfb > 2 | roll_in = 30 & complete'), 'query: & binds before |');
	check(!holds('(sfb > 2 | roll_in = 30) & mine'), 'query: parentheses group first');
	check(!E.compileQuery('sfb < 5', names)({ sfb: Number.NaN }), 'query: a missing value fails');
	check(
		E.compileQuery('mark > -1 & mark >= −2,5', names)({ mark: -0.5 }),
		'query: a negative number, with a minus sign or a hyphen'
	);
	const refusal = (text, code, at) => {
		try {
			E.compileQuery(text, names);
		} catch (error) {
			check(
				error instanceof E.QueryError && error.code === code && error.at === at,
				`query: « ${text} » is ${code} at ${at}, not ${error.code} at ${error.at}`
			);
			return;
		}
		errors.push(`query: « ${text} » should not read`);
	};
	refusal('sfb', 'query_comparison', 3);
	refusal('foo < 1', 'query_unknown_name', 0);
	refusal('sfb < ', 'query_number', 6);
	refusal('complete > 1', 'query_flag', 9);
	refusal('(sfb < 1', 'query_parenthesis', 8);
	refusal('sfb < 1 1', 'query_unexpected', 8);
	refusal('sfb ~ 2', 'query_unexpected', 4);
	refusal('sfb < 1 &', 'query_end', 9);
}

// ===========================================
// ======= Density curve =====================
// ===========================================

// The smoothed distribution of the Pareto tab's spread (an idea seen in the
// Layouts Wiki playground's Ranking view): a Gaussian kernel density.
{
	const values = [1, 1.2, 1.3, 2, 2.1, 2.2, 2.25, 4];
	const { bandwidth, points } = E.densityCurve(values, { points: 400 });
	check(bandwidth > 0, 'density: a bandwidth above 0');
	const step = points[1].x - points[0].x;
	const area = points.reduce((sum, p) => sum + p.density, 0) * step;
	check(Math.abs(area - 1) < 0.01, `density: integrates to 1 (${area})`);
	check(
		points[0].x < Math.min(...values) && points[points.length - 1].x > Math.max(...values),
		'density: the curve runs past both extremes'
	);
	check(
		points.every((p, i) => i === 0 || p.x > points[i - 1].x),
		'density: samples in increasing x'
	);
	// The densest cluster (2 to 2.25) carries the peak, not the lone 4.
	const peak = points.reduce((best, p) => (p.density > best.density ? p : best));
	check(peak.x > 1.8 && peak.x < 2.5, `density: the peak is on the densest cluster (${peak.x})`);
	// A fixed bandwidth: one value is the normal bell, its peak 1 / (h √(2π)).
	const bell = E.densityCurve([5], { bandwidth: 0.5, points: 7 });
	check(
		Math.abs(bell.points[3].density - 1 / (0.5 * Math.sqrt(2 * Math.PI))) < TOLERANCE &&
			bell.points[3].x === 5,
		'density: one value draws the normal bell'
	);
	check(E.densityCurve([3, 3, 3]).bandwidth > 0, 'density: equal values still have a width');
	check(E.densityCurve([0, 0]).bandwidth > 0, 'density: zeros still have a width');
	throws(() => E.densityCurve([]), 'density: no value throws');
	throws(() => E.densityCurve([1, Number.NaN]), 'density: a value that is not finite throws');
	throws(() => E.densityCurve([1, 2], { points: 1 }), 'density: one point throws');
	throws(() => E.densityCurve([1, 2], { bandwidth: 0 }), 'density: a bandwidth of 0 throws');
}

// ===========================================
// ======= User metrics over key windows =====
// ===========================================

// A user metric (an idea seen in the Layouts Wiki playground's metric
// queries): the share of its windows a values query holds for.
{
	const text = 'Le cœur a ses raisons que la raison ne connaît point. Où êtes-vous allés, Zoé ?';
	const ngrams = E.ngramsFromText(text);
	for (const id of ['azerty', 'ergopti', 'bepo']) {
		const layout = byId.get(id);
		const table = E.movementTable(layout, ngrams, { keyboard: 'iso' });
		const { values, windows } = E.windowMetrics(
			layout,
			ngrams,
			[
				{ id: 'sfb', window: 'bigram', query: 'sfb' },
				{ id: 'sfs', window: 'skipgram', query: 'sfb' },
				{ id: 'alt', window: 'trigram', query: 'alternation' },
				{ id: 'left', window: 'bigram', query: 'hand1 = 0' },
				{ id: 'right', window: 'bigram', query: 'hand1 = 1' },
				{ id: 'one_hand', window: 'trigram', query: 'same_hand' },
				{ id: 'two_hands', window: 'trigram', query: '!same_hand' },
				{ id: 'pinky_sfb', window: 'bigram', query: 'sfb & finger1 = 4' },
				{ id: 'everything', window: 'skipgram', query: '' }
			],
			{ keyboard: 'iso' }
		);
		check(
			Math.abs(values.sfb - table.bigram.sfb) <= TOLERANCE,
			`window metrics: ${id} bigram sfb ${values.sfb} is the movement table's ${table.bigram.sfb}`
		);
		check(
			Math.abs(values.sfs - table.skipgram.sfb) <= TOLERANCE,
			`window metrics: ${id} skipgram sfb ${values.sfs} is the movement table's ${table.skipgram.sfb}`
		);
		check(
			Math.abs(values.alt - table.rhythm.all.alternation) <= TOLERANCE,
			`window metrics: ${id} alternation ${values.alt} is the rhythm's ${table.rhythm.all.alternation}`
		);
		check(
			windows.bigram === table.bigrams && windows.skipgram === table.skipgrams,
			`window metrics: ${id} counts the movement table's windows`
		);
		check(
			Math.abs(values.left + values.right - 100) <= TOLERANCE &&
				Math.abs(values.one_hand + values.two_hands - 100) <= TOLERANCE,
			`window metrics: ${id} a value and its negation make 100 %`
		);
		check(
			values.pinky_sfb >= 0 && values.pinky_sfb <= values.sfb,
			`window metrics: ${id} the pinkies' SFB is part of the SFB`
		);
		check(values.everything === 100, `window metrics: ${id} an empty query keeps every window`);
	}
	// The pinkies' SFB on QWERTY: « aq » and « qa » are its left pinky's only pairs here.
	const qwerty = byId.get('qwerty');
	const pinky = E.windowMetrics(
		qwerty,
		E.ngramsFromText('aqa ok'),
		[
			{ id: 'pinky', window: 'bigram', query: 'same_finger & finger1 = 4 & !same_key' },
			{ id: 'top', window: 'bigram', query: 'row2 = -1 & home1' }
		],
		{ keyboard: 'iso' }
	);
	check(pinky.values.pinky > 0, 'window metrics: finger 4 is the pinky');
	check(pinky.values.top > 0, 'window metrics: row −1 is the row above the home row');
	const names = E.windowNames('bigram');
	check(
		names.numbers.includes('finger2') &&
			names.flags.includes('same_finger') &&
			names.flags.includes('lsb'),
		'window metrics: a pair names its keys, its own values and its events'
	);
	check(
		E.windowNames('trigram').flags.includes('redirect'),
		'window metrics: a trigram its events'
	);
	throws(() => E.windowNames('word'), 'window metrics: an unknown window throws');
	let refused = null;
	try {
		E.windowMetrics(qwerty, E.ngramsFromText('ab'), [
			{ id: 'x', window: 'bigram', query: 'finger3 < 2' }
		]);
	} catch (error) {
		refused = error;
	}
	check(
		refused && refused.code === 'query_unknown_name' && refused.token === 'finger3',
		'window metrics: a pair has no third key'
	);
	throws(
		() =>
			E.windowMetrics(qwerty, E.ngramsFromText('ab'), [
				{ id: 'x', window: 'bigram', query: '' },
				{ id: 'x', window: 'bigram', query: '' }
			]),
		'window metrics: a duplicate id throws'
	);
	throws(
		() =>
			E.windowMetrics(
				qwerty,
				E.ngramsFromText('ab'),
				Array.from({ length: E.WINDOW_MAX_METRICS + 1 }, (_, i) => ({
					id: `m${i}`,
					window: 'bigram',
					query: ''
				}))
			),
		'window metrics: too many metrics throw'
	);
}

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-analysis-views: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log('test-layout-analysis-views: OK (pareto layers, text trace against analyse())');
