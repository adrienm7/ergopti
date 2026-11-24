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

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-analysis-views: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log('test-layout-analysis-views: OK (pareto layers, text trace against analyse())');
