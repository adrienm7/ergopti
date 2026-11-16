// tools/test/test-layout-optimizer.cjs

/**
 * ==============================================================================
 * MODULE: Layout Optimizer Gate
 * DESCRIPTION:
 * _shared/ui/layout_optimizer/optimizer_core.js searches the arrangement the
 * layout analysis engine scores best. This gate holds it to
 * docs/design/layout-optimizer.md.
 *
 * WHAT IS CHECKED:
 * 1. Optimum: on a 4-key toy problem the search finds the best of the 24
 *    arrangements counted by brute force, and that best keeps the corpus's
 *    only bigram off a single finger.
 * 2. Honesty: the score the search reports is the engine's score of the
 *    layout it returns; the search table keeps the most frequent n-grams.
 * 3. Determinism: the same seed gives the same layout, and splitting the
 *    restarts between workers (bestOf) gives the same winner as one run.
 * 4. Constraints, each a real switch (every layout the search scores is
 *    inspected): pinned keys, QWERTY pins from a base or a random start,
 *    case pairs, digits (fixed, number row, anywhere), letters off the number
 *    row, punctuation, symbols, the AltGr levels, the dead key's layer,
 *    zones; unknown options and impossible pins are refused with their code.
 * 5. Budget: a time budget stops the search on the clock it is given.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const UI = shared('ui');
const CORPUS = path.join(REPO_ROOT, 'static', 'corpus', 'original', 'fr', 'corpus_nemolivier.txt');
// A slice keeps every search of this gate fast; the engine is the same.
const CORPUS_CHARS = 6000;
const TOLERANCE = 1e-9;

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};

const sandbox = {};
vm.createContext(sandbox);
for (const file of [
	'layout_analysis/_generated/analysis_data.js',
	'layout_analysis/analysis_engine.js',
	'layout_optimizer/optimizer_core.js'
])
	vm.runInContext(fs.readFileSync(path.join(UI, file), 'utf8'), sandbox, { filename: file });
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const O = vm.runInContext('LAYOUT_OPTIMIZER', sandbox);
const library = new Map(E.libraryLayouts().map((layout) => [layout.id, layout]));
const text = fs.readFileSync(CORPUS, 'utf8').slice(0, CORPUS_CHARS);
const tables = E.prepareNgrams(E.ngramsFromText(text));
const ANALYSIS = { format: 'tkl' };

/** Runs a search and returns its result with every layout it scored. */
function search(start, options, settings) {
	const p = O.problem(E, start, options);
	const seen = [];
	const objective = O.engineObjective(E, tables, ANALYSIS);
	const result = O.run(
		p,
		Object.assign(
			{
				objective: (layout) => {
					seen.push(layout);
					return objective(layout);
				},
				seed: 11,
				iterations: 60
			},
			settings
		)
	);
	return { p, result, seen };
}

/** The refusal code of a call, or null. */
function refusal(fn) {
	try {
		fn();
	} catch (error) {
		return error.code || error.message;
	}
	return null;
}

const azerty = library.get('azerty');
const ergol = library.get('ergol');
check(azerty && ergol, 'the library has azerty and ergol');

// ==========================
// ======= 1/ Optimum =======
// ==========================

// Four letters on four keys: F and R are the left index, J and U the right
// index. The corpus repeats « ab » and « cd », so the best arrangements put
// a and b, and c and d, on different fingers.
const toy = {
	id: 'toy',
	rows: {
		KeyF: ['a', 'A', null, null],
		KeyR: ['b', 'B', null, null],
		KeyJ: ['c', 'C', null, null],
		KeyU: ['d', 'D', null, null]
	}
};
const toyTables = E.ngramsFromText('ab ab ab cd cd ab cd ab');
const toyProblem = O.problem(E, toy);
const toyObjective = O.engineObjective(E, toyTables, ANALYSIS);
const permutations = (items) =>
	items.length <= 1
		? [items]
		: items.flatMap((item, i) =>
				permutations(items.slice(0, i).concat(items.slice(i + 1))).map((rest) =>
					[item].concat(rest)
				)
			);
let bruteBest = -Infinity;
for (const order of permutations([0, 1, 2, 3]))
	bruteBest = Math.max(bruteBest, toyObjective(O.layoutOf(toyProblem, order)));
const toyResult = O.run(toyProblem, {
	objective: toyObjective,
	seed: 3,
	restarts: 3,
	iterations: 60
});
check(
	Math.abs(toyResult.score - bruteBest) <= TOLERANCE,
	`toy: found ${toyResult.score}, brute force ${bruteBest}`
);
check(toyResult.score > toyResult.startScore, 'toy: the start (a and b on one finger) is improved');
const board = E.keyboard('iso');
const fingerOf = (layout, char) =>
	board.finger[
		board.index.get(Object.keys(layout.rows).find((code) => layout.rows[code][0] === char))
	];
check(
	fingerOf(toyResult.layout, 'a') !== fingerOf(toyResult.layout, 'b') &&
		fingerOf(toyResult.layout, 'c') !== fingerOf(toyResult.layout, 'd'),
	'toy: the best keeps « ab » and « cd » off a single finger'
);

// ==========================
// ======= 2/ Honesty =======
// ==========================

const base = search(azerty, {}, { restarts: 2 });
const engineScore = E.analyse(base.result.layout, tables, ANALYSIS).score.total;
check(
	Math.abs(base.result.score - engineScore) <= TOLERANCE,
	`reported ${base.result.score}, engine ${engineScore}`
);
check(base.result.score > base.result.startScore, 'azerty is improved');
check(
	Math.abs(base.result.startScore - E.analyse(azerty, tables, ANALYSIS).score.total) <= TOLERANCE,
	'the start score is the engine score of the start layout'
);
const reduced = O.searchTables(E, tables, 0.9);
const kept = (all, part) =>
	part.reduce((sum, e) => sum + e[e.length - 1], 0) /
	all.reduce((sum, e) => sum + e[e.length - 1], 0);
check(
	reduced.bi.length < tables.bi.length && kept(tables.bi, reduced.bi) >= 0.9,
	'the search table keeps 90 % of the bigrams with fewer entries'
);
check(O.searchTables(E, tables, 1) === tables, 'a share of 1 keeps the whole table');
check(refusal(() => O.searchTables(E, tables, 0)) === 'option_value', 'a share of 0 is refused');

// ===============================
// ======= 3/ Determinism ========
// ===============================

const again = search(azerty, {}, { restarts: 2 });
check(
	JSON.stringify(again.result.layout) === JSON.stringify(base.result.layout),
	'the same seed gives the same layout'
);
const other = search(azerty, {}, { restarts: 2, seed: 12 });
check(
	JSON.stringify(other.result.layout) !== JSON.stringify(base.result.layout),
	'another seed explores another way'
);
const p3 = O.problem(E, azerty);
const objective = O.engineObjective(E, tables, ANALYSIS);
const whole = O.run(p3, { objective, seed: 5, restarts: 3, iterations: 40 });
const split = O.bestOf([
	O.run(p3, { objective, seed: 5, restarts: 1, firstRestart: 0, iterations: 40 }),
	O.run(p3, { objective, seed: 5, restarts: 2, firstRestart: 1, iterations: 40 })
]);
check(
	JSON.stringify(split.layout) === JSON.stringify(whole.layout) && split.score === whole.score,
	'restarts split between workers give the same winner'
);

// ===============================
// ======= 4/ Constraints ========
// ===============================

const NUMBER_ROW = O.NUMBER_ROW;
const cellsOf = (layout, code, levels) =>
	JSON.stringify(levels.map((i) => (layout.rows[code] || [])[i]));
const everyLayout = (run, predicate) => run.seen.length > 10 && run.seen.every(predicate);

// Pinned keys never move.
const pinned = search(azerty, { pinnedCodes: ['KeyE', 'KeyJ'] }, { start: 'random' });
check(
	everyLayout(
		pinned,
		(layout) =>
			cellsOf(layout, 'KeyE', [0, 1, 2, 3]) === cellsOf(azerty, 'KeyE', [0, 1, 2, 3]) &&
			cellsOf(layout, 'KeyJ', [0, 1]) === cellsOf(azerty, 'KeyJ', [0, 1])
	),
	'pinned keys never move'
);

// QWERTY pins hold Z X C V A S at their QWERTY keys, from a base or a random start.
const QWERTY_AT = { z: 'KeyZ', x: 'KeyX', c: 'KeyC', v: 'KeyV', a: 'KeyA', s: 'KeyS' };
for (const start of ['layout', 'random']) {
	const run = search(azerty, { qwertyPins: ['z', 'x', 'c', 'v', 'a', 's'] }, { start });
	check(
		everyLayout(run, (layout) =>
			Object.entries(QWERTY_AT).every(([letter, code]) => layout.rows[code][0] === letter)
		),
		`QWERTY pins hold from a ${start} start`
	);
}
check(
	JSON.stringify(O.QWERTY_PIN_PRESETS.undo_cut_copy_paste) === '["z","x","c","v"]',
	'the shortcut preset is Z X C V'
);
check(
	refusal(() => O.problem(E, azerty, { qwertyPins: ['ß'] })) === 'pin_missing',
	'a letter the layout lacks cannot be pinned'
);
check(
	refusal(() => O.problem(E, azerty, { qwertyPins: ['z'], pinnedCodes: ['KeyW', 'KeyZ'] })) ===
		'pin_conflict',
	'a QWERTY pin onto a pinned key is refused'
);

// Case pairs: a letter keeps its capital on Shift wherever it goes.
check(
	everyLayout(base, (layout) =>
		Object.values(layout.rows).every(
			(row) =>
				!(typeof row[0] === 'string' && /^[a-z]$/.test(row[0])) || row[1] === row[0].toUpperCase()
		)
	),
	'letters keep their capital on Shift'
);

// Digits: fixed by default, then the number row, then anywhere.
const digitCodes = (layout) =>
	Object.entries(layout.rows)
		.filter(([, row]) =>
			row.slice(0, 2).some((cell) => typeof cell === 'string' && /^[0-9]$/.test(cell))
		)
		.map(([code]) => code);
check(
	everyLayout(
		base,
		(layout) =>
			JSON.stringify(digitCodes(layout)) === JSON.stringify(digitCodes(azerty)) &&
			digitCodes(azerty).every(
				(code) => cellsOf(layout, code, [0, 1]) === cellsOf(azerty, code, [0, 1])
			)
	),
	'digits stay put by default'
);
// Letters may enter the row here, so only the digit rule keeps digits on it.
const digitsRow = search(
	azerty,
	{ moveDigits: true, lettersOnNumberRow: true },
	{ start: 'random' }
);
check(
	everyLayout(digitsRow, (layout) => digitCodes(layout).every((code) => NUMBER_ROW.has(code))) &&
		digitsRow.seen.some(
			(layout) => cellsOf(layout, 'Digit1', [0, 1]) !== cellsOf(azerty, 'Digit1', [0, 1])
		),
	'moved digits stay on the number row'
);
// A digit leaves the row by trading places with a letter, which may then enter it.
const digitsAnywhere = search(
	azerty,
	{ moveDigits: true, digitsOutsideNumberRow: true, lettersOnNumberRow: true },
	{ start: 'random' }
);
check(
	digitsAnywhere.seen.some((layout) => digitCodes(layout).some((code) => !NUMBER_ROW.has(code))),
	'digits may leave the number row when allowed'
);
check(
	everyLayout(base, (layout) =>
		[...NUMBER_ROW].every((code) => !/^[a-z]$/.test((layout.rows[code] || [])[0] || ''))
	),
	'letters stay off the number row by default'
);
const lettersRow = O.problem(E, azerty, { lettersOnNumberRow: true });
const eUnit = lettersRow.units.findIndex((unit) => unit.cells[0] === 'e');
const digit1Slot = lettersRow.slots.findIndex((slot) => slot.code === 'Digit1');
check(
	O.allowed(lettersRow, eUnit, digit1Slot) && !O.allowed(O.problem(E, azerty), eUnit, digit1Slot),
	'lettersOnNumberRow opens the number row to letters'
);

// Punctuation and symbols.
const kinds = (p) => new Set(p.movable.map((u) => p.units[u].kind));
check(!kinds(O.problem(E, azerty)).has('punctuation'), 'punctuation is fixed by default');
check(
	kinds(O.problem(E, azerty, { movePunctuation: true })).has('punctuation'),
	'movePunctuation moves it'
);
check(!kinds(O.problem(E, azerty)).has('symbol'), 'symbols are fixed by default');
check(kinds(O.problem(E, azerty, { moveSymbols: true })).has('symbol'), 'moveSymbols moves them');
check(
	everyLayout(
		base,
		(layout) => cellsOf(layout, 'Comma', [0, 1]) === cellsOf(azerty, 'Comma', [0, 1])
	),
	'fixed punctuation never moves'
);
check(
	everyLayout(
		base,
		(layout) => cellsOf(layout, 'Space', [0, 1]) === cellsOf(azerty, 'Space', [0, 1])
	),
	'space never moves'
);

// The AltGr levels: untouched by default, places when allowed.
check(
	everyLayout(base, (layout) =>
		Object.keys(azerty.rows).every(
			(code) => cellsOf(layout, code, [2, 3]) === cellsOf(azerty, code, [2, 3])
		)
	),
	'the AltGr levels are untouched by default'
);
const withAltgr = search(azerty, { altgr: true, moveSymbols: true }, { start: 'random' });
check(
	withAltgr.p.slots.some((slot) => slot.kind === 'altgr') &&
		withAltgr.seen.some((layout) =>
			Object.keys(azerty.rows).some(
				(code) => cellsOf(layout, code, [2, 3]) !== cellsOf(azerty, code, [2, 3])
			)
		),
	'altgr makes the AltGr levels places'
);

// The dead key's layer: characters may go behind the dead key, and the score is the engine's.
check(
	refusal(() => O.problem(E, library.get('qwerty'), { deadKeyLayer: true })) === 'no_dead_key',
	'no dead key, no layer'
);
check(
	refusal(() => O.problem(E, ergol, { deadKeyLayer: true, deadState: 'nope' })) ===
		'dead_state_unknown',
	'an unknown dead state is refused'
);
const withDead = search(ergol, { deadKeyLayer: true }, { start: 'random', iterations: 200 });
const deadState = withDead.p.deadState;
const deadOutputs = (layout) => JSON.stringify(layout.dead[deadState]);
check(
	withDead.p.slots.some((slot) => slot.kind === 'dead') &&
		withDead.seen.some((layout) => deadOutputs(layout) !== deadOutputs(ergol)),
	`deadKeyLayer places characters behind ${deadState}`
);
check(
	Math.abs(
		withDead.result.score - E.analyse(withDead.result.layout, tables, ANALYSIS).score.total
	) <= TOLERANCE,
	'with the dead key layer, the reported score is the engine score'
);
check(
	everyLayout(search(ergol, {}), (layout) => deadOutputs(layout) === deadOutputs(ergol)),
	'the dead key layer is untouched by default'
);

// Zones: a character stays inside the keys it is given.
const zoned = search(azerty, { zones: { e: ['KeyD', 'KeyK', 'KeyE'] } }, { start: 'random' });
check(
	everyLayout(zoned, (layout) =>
		['KeyD', 'KeyK', 'KeyE'].some((code) => layout.rows[code][0] === 'e')
	),
	'a zoned letter stays in its zone'
);

// Refusals.
check(
	refusal(() => O.problem(E, azerty, { nope: true })) === 'option_unknown',
	'unknown option refused'
);
check(
	refusal(() => O.problem(E, azerty, { altgr: 'yes' })) === 'option_value',
	'non-boolean switch refused'
);

// ===========================
// ======= 5/ Budget =========
// ===========================

let clock = 0;
const timed = O.createSearch(O.problem(E, azerty), {
	objective,
	seed: 1,
	iterations: 1e9,
	timeBudgetMs: 50,
	now: () => clock
});
timed.step(5);
clock = 60;
const after = timed.step(1000);
check(after.done && timed.done(), 'the time budget stops the search');

if (errors.length) {
	console.error(`FAIL test-layout-optimizer: ${errors.length} problem(s)`);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}
console.log('PASS test-layout-optimizer');
