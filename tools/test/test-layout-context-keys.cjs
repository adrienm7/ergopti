// tools/test/test-layout-context-keys.cjs

/**
 * ==============================================================================
 * MODULE: Layout Repeat and Magic Keys Gate
 * DESCRIPTION:
 * A layout's own repeat and magic keys (docs/design/magic-and-repeat-keys.md)
 * in the Studio's analysis engine (_shared/ui/layout_analysis/analysis_engine.js).
 *
 * WHAT IS CHECKED:
 * 1. Output: every vector of _shared/tests/corpus/layouts/magic_vectors.json,
 *    the one source the drivers replay too, gives what contextOutput types.
 * 2. Model: layoutFromRows keeps the context and the magic tables, a layout
 *    without them reads as before, and every malformed action, rule or table
 *    is refused (an unknown or unused table, a rule without context, a context
 *    of three characters, a context twice, an output of two characters, a
 *    level that also types its cell, a repeat three places back).
 * 3. Analysis, worked by hand: « ed » on QWERTY is one SFB (E then D, left
 *    middle finger); a magic key typing d after e on the ISO key left of Z
 *    (the left pinky) breaks it, so the best typing has no SFB and types half
 *    the characters by the magic key; the fixed typing never takes it. The
 *    rule with the longest context wins in the trace (« ce » then the magic
 *    key types s, not d), the « typed via » rows name the key by its label
 *    (◆), never by its code, and a repeat key on its base level types the
 *    second E of « EE » without Shift.
 * 4. Counts: the context tokens keep every character, pair and triple of the
 *    corpus (typed + unsupported equal the corpus's characters), the typing
 *    paths add up to each character's count, the best typing never costs
 *    more than the fixed one, and a plan the keys would make costlier (two on
 *    the left pinky) is the plan without them.
 * 5. Score session: after random swaps of a contextual layout's cells, a
 *    trial's total equals the whole analysis's, compiled whole.
 * 6. Kept apart from ★: the labels never use Ergopti+'s magic key glyph.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const vm = require('vm');
const { shared } = require('../lib/paths.cjs');

const LEGEND_PATH = shared('ui', '_generated', 'key_legend.js');
const DATA_PATH = shared('ui', 'layout_analysis', '_generated', 'analysis_data.js');
const ENGINE_PATH = shared('ui', 'layout_analysis', 'analysis_engine.js');
const VECTORS_PATH = shared('tests', 'corpus', 'layouts', 'magic_vectors.json');
const MODEL_PATH = shared('layouts', 'data', 'analysis', 'analysis_model.json');
// Floors: an empty vector file must not read as a pass.
const MIN_VECTORS = 20;
const TOLERANCE = 1e-9;
// Random swaps the score session is checked on.
const SESSION_TRIALS = 40;
// Ergopti+'s hotstring trigger and its replacements' glyph (maintainer-decisions.md,
// « The magic key is a configured character »): never a layout's own key label.
const ERGOPTI_GLYPHS = ['★', '✦'];

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};
const near = (a, b) => Math.abs(a - b) <= TOLERANCE * Math.max(1, Math.abs(b));

const sandbox = {};
vm.createContext(sandbox);
for (const file of [LEGEND_PATH, DATA_PATH, ENGINE_PATH])
	vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const qwerty = E.libraryLayouts().find((layout) => layout.id === 'qwerty');
const copy = (value) => JSON.parse(JSON.stringify(value));

// ==========================
// ======= 1/ Output ========
// ==========================

const vectors = JSON.parse(fs.readFileSync(VECTORS_PATH, 'utf8'));
check(vectors.vectors.length >= MIN_VECTORS, `output: only ${vectors.vectors.length} vectors`);
for (const vector of vectors.vectors) {
	const types = E.contextOutput(vector.action, vectors.magic, vector.before);
	check(
		types === vector.types,
		`output: ${JSON.stringify(vector.action)} after ${JSON.stringify(vector.before)} types ` +
			`${JSON.stringify(types)}, not ${JSON.stringify(vector.types)}`
	);
}

// ==========================
// ======= 2/ Model =========
// ==========================

/** QWERTY with a magic key on the ISO key left of Z (base level), typing the table given. */
function withMagic(id, table) {
	const layout = copy(qwerty);
	layout.id = id;
	layout.rows.IntlBackslash = [null, null, null, null];
	layout.context = { IntlBackslash: [{ magic: 'sfb' }, null, null, null] };
	layout.magic = { sfb: table };
	return layout;
}
const SFB_TABLE = {
	rules: [
		{ after: 'e', types: 'd' },
		{ after: 'd', types: 'e' },
		{ after: 'ce', types: 's' }
	],
	fallback: ''
};
const magicLayout = withMagic('qwerty_magic', SFB_TABLE);
const read = E.layoutFromRows(magicLayout);
check(
	read.context === magicLayout.context && read.magic === magicLayout.magic,
	'model: layoutFromRows drops the context or the magic tables'
);
check(
	E.layoutFromRows(qwerty).context === undefined && E.layoutFromRows(qwerty).magic === undefined,
	'model: a layout without repeat or magic keys gains context fields'
);
const refusals = {
	'an unknown table': (l) => (l.context.IntlBackslash[0] = { magic: 'none' }),
	'an unused table': (l) => (l.magic.other = { rules: [] }),
	'a rule without context': (l) => (l.magic.sfb.rules[0].after = ''),
	'a context of three characters': (l) => (l.magic.sfb.rules[0].after = 'the'),
	'a context twice': (l) => l.magic.sfb.rules.push({ after: 'e', types: 'f' }),
	'an output of two characters': (l) => (l.magic.sfb.rules[0].types = 'de'),
	'a fallback of two characters': (l) => (l.magic.sfb.fallback = 'de'),
	'a level that also types its cell': (l) => (l.rows.IntlBackslash[0] = 'z'),
	'a repeat three places back': (l) => (l.context.IntlBackslash[1] = { repeat: 3 }),
	'an action of two kinds': (l) => (l.context.IntlBackslash[0] = { magic: 'sfb', repeat: 1 }),
	'a context row of the wrong width': (l) => (l.context.IntlBackslash = [{ magic: 'sfb' }]),
	'a context without any key': (l) => {
		l.context.IntlBackslash = [null, null, null, null];
		delete l.magic;
	}
};
for (const [what, spoil] of Object.entries(refusals)) {
	const layout = copy(magicLayout);
	spoil(layout);
	let refused = false;
	try {
		E.layoutFromRows(layout);
	} catch {
		refused = true;
	}
	check(refused, `model: layoutFromRows accepts ${what}`);
}

// ==========================
// ======= 3/ Analysis ======
// ==========================

const ed = E.ngramsFromText('ed');
const plain = E.measure(qwerty, ed, { keyboard: 'iso' });
const best = E.measure(magicLayout, ed, { keyboard: 'iso' });
const fixed = E.measure(magicLayout, ed, { keyboard: 'iso', typing: 'fixed' });
check(
	near(plain.metrics.sfb, 100),
	`analysis: « ed » on QWERTY is ${plain.metrics.sfb} % SFB, not 100`
);
check(
	near(best.metrics.sfb, 0),
	`analysis: the magic key leaves ${best.metrics.sfb} % SFB on « ed »`
);
check(
	near(best.metrics.context_key_usage, 50),
	`analysis: the magic key types ${best.metrics.context_key_usage} % of « ed », not 50`
);
check(
	near(fixed.metrics.context_key_usage, 0) && near(fixed.metrics.sfb, 100),
	'analysis: the fixed typing takes the magic key'
);
check(
	near(plain.metrics.context_key_usage, 0),
	'analysis: a layout without repeat or magic keys uses them'
);
const dWays = best.typing.paths.d || [];
check(
	dWays.length === 1 &&
		dWays[0].kind === 'magic' &&
		dWays[0].steps[0][0] === 'IntlBackslash' &&
		dWays[0].count === 1,
	`analysis: d is typed ${JSON.stringify(dWays)}, not once by the magic key`
);
const rows = E.typingRows(
	E.analyse(magicLayout, E.ngramsFromText('ed ed d'), { keyboard: 'iso' }),
	read
);
const dRow = rows.find((row) => row.char === 'd');
const magicLabel = JSON.parse(fs.readFileSync(MODEL_PATH, 'utf8')).context_keys.labels.magic;
check(
	dRow && dRow.ways.some((way) => way.kind === 'magic' && way.keys === magicLabel),
	`analysis: « typed via » names the magic key ${JSON.stringify(dRow && dRow.ways)}, not ${magicLabel}`
);
const trace = E.traceText(magicLayout, 'ced', { keyboard: 'iso' });
check(
	trace.chars.map((c) => c.kind).join(' ') === 'direct direct direct',
	`analysis: after « ce » the magic key types d (${trace.chars.map((c) => c.kind).join(' ')})`
);
const traceEd = E.traceText(magicLayout, 'the ed', { keyboard: 'iso' });
check(
	traceEd.chars[5].kind === 'magic' && traceEd.counts.sfb === 0,
	`analysis: the trace of « the ed » types d by ${traceEd.chars[5].kind} with ${traceEd.counts.sfb} SFB`
);
// A repeat key types what was typed, Shift or not: on the base level of the
// right hand's Quote it types the second E of « EE » without Shift, a hand
// change instead of Shift and E again.
const repeatLayout = copy(qwerty);
repeatLayout.id = 'qwerty_repeat';
repeatLayout.rows.Quote = [null, null, null, null];
repeatLayout.context = { Quote: [{ repeat: 1 }, null, null, null] };
const capitals = E.measure(repeatLayout, E.ngramsFromText('EE'), { keyboard: 'iso' });
const eWays = capitals.typing.paths.E || [];
check(
	eWays.length === 2 &&
		eWays[1].kind === 'repeat' &&
		eWays[1].steps.join() === 'Quote,base' &&
		eWays[1].count === 1 &&
		near(capitals.metrics.modifier_usage, 50),
	`analysis: the second E of « EE » is not typed by the base repeat key (${JSON.stringify(eWays)})`
);

// ==========================
// ======= 4/ Counts ========
// ==========================

const TEXT =
	'the dedicated decorated reddened ceded deeds were decided; ced ce ce. ' +
	'Le bookkeeper a vu les pommes tomber, et cela suffit. Quelle question !';
const both = copy(magicLayout);
both.id = 'qwerty_both';
both.context.Quote = [{ repeat: 1 }, { repeat: 2 }, null, null];
both.rows.Quote = [null, null, null, null];
const table = E.ngramsFromText(TEXT);
const total = Array.from(TEXT.replace(/\n/g, '')).length;
for (const typing of ['best', 'fixed']) {
	const result = E.measure(both, table, { keyboard: 'iso', typing });
	check(
		near(result.coverage.typed + result.coverage.unsupported, total),
		`counts (${typing}): ${result.coverage.typed} typed and ${result.coverage.unsupported} unsupported of ${total}`
	);
	for (const [char, ways] of Object.entries(result.typing.paths)) {
		const count = ways.reduce((sum, way) => sum + way.count, 0);
		const occurrences = Array.from(TEXT).filter((c) => c === char).length;
		check(
			near(count, occurrences),
			`counts (${typing}): ${char} is typed ${count} times, not ${occurrences}`
		);
	}
}
const bestBoth = E.measure(both, table, { keyboard: 'iso' });
const fixedBoth = E.measure(both, table, { keyboard: 'iso', typing: 'fixed' });
check(
	bestBoth.typing.cost <= fixedBoth.typing.cost + TOLERANCE,
	`counts: the best typing costs ${bestBoth.typing.cost}, more than the fixed ${fixedBoth.typing.cost}`
);
check(
	bestBoth.metrics.context_key_usage > 0,
	'counts: neither the repeat nor the magic key is used on the sample'
);

// Two keys on the left pinky (the magic key, and a repeat key on Backquote)
// would meet on that finger where the choice weighs each way with its
// neighbours typed their own way: the whole path costs more, so the plan
// keeps neither, exactly the plan without them.
const pinky = copy(magicLayout);
pinky.id = 'qwerty_pinky';
pinky.context.Backquote = [{ repeat: 1 }, { repeat: 2 }, null, null];
pinky.rows.Backquote = [null, null, null, null];
const bare = copy(qwerty);
bare.rows.IntlBackslash = [null, null, null, null];
bare.rows.Backquote = [null, null, null, null];
const declined = E.measure(pinky, table, { keyboard: 'iso' });
const without = E.measure(bare, table, { keyboard: 'iso' });
check(
	near(declined.metrics.context_key_usage, 0) && near(declined.typing.cost, without.typing.cost),
	`counts: a costlier context plan is kept (${declined.metrics.context_key_usage} %, ` +
		`${declined.typing.cost} against ${without.typing.cost} without the keys)`
);

// ==========================
// ===== 5/ Score session ===
// ==========================

{
	const session = E.scoreSession(both, table, { keyboard: 'iso' });
	const letters = Object.keys(both.rows).filter((code) => /^Key[A-Z]$/.test(code));
	let state = copy(both);
	let seed = 7;
	const random = (n) => {
		seed = (seed * 48271) % 2147483647;
		return seed % n;
	};
	for (let i = 0; i < SESSION_TRIALS; i++) {
		const next = copy(state);
		const a = letters[random(letters.length)];
		const b = letters[random(letters.length)];
		[next.rows[a], next.rows[b]] = [next.rows[b], next.rows[a]];
		const trial = session.trial(next);
		const whole = E.analyse(next, table, { keyboard: 'iso' }).score.total;
		check(
			near(trial.total, whole) && trial.compile === 'whole',
			`session: trial ${i} totals ${trial.total} (${trial.compile}), the analysis ${whole}`
		);
		if (random(2) === 0) {
			trial.commit();
			state = next;
		}
	}
}

// ==========================
// ======= 6/ Apart from ★ ==
// ==========================

for (const label of Object.values(
	JSON.parse(fs.readFileSync(MODEL_PATH, 'utf8')).context_keys.labels
))
	check(
		!ERGOPTI_GLYPHS.includes(label),
		`apart: a layout key is labelled ${label}, Ergopti+'s glyph`
	);

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-context-keys: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-context-keys: OK (${vectors.vectors.length} vectors, ${SESSION_TRIALS} session trials)`
);
