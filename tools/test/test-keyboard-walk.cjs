// tools/test/test-keyboard-walk.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Walk Analysis Tests
 * DESCRIPTION:
 * Proves, without a browser, that the analysis the Studio keyboard walk relies
 * on (tools/test/lib/keyboard-walk.cjs) refuses each failure it exists for: a
 * trap in either direction, a stop met twice, a hidden or positive-tabindex
 * stop, a jump back up the page, and a Shift+Tab order that differs.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { walkProblems } = require('./lib/keyboard-walk.cjs');

const stop = (id, order, extra = {}) => ({
	id,
	key: id,
	order,
	visible: true,
	tabindex: 0,
	...extra
});
const good = () => {
	const forward = [stop('a', 0), stop('b', 1), stop('c', 2)];
	return { forward, forwardLeft: true, backward: [...forward].reverse(), backwardLeft: true };
};

assert.deepEqual(walkProblems(good()), [], 'a clean walk passes');

const cases = [
	[
		'a forward trap',
		(w) => Object.assign(w, { forwardLeft: false }),
		/never leaves the page going forward/
	],
	[
		'a backward trap',
		(w) => Object.assign(w, { backwardLeft: false }),
		/never leaves the page going backward/
	],
	['a repeated stop', (w) => w.forward.push(stop('b', 3)), /meets b twice/],
	['a hidden stop', (w) => (w.forward[1].visible = false), /b takes the focus while hidden/],
	['a positive tabindex', (w) => (w.forward[2].tabindex = 2), /positive tabindex/],
	['a jump back up', (w) => (w.forward[2].order = 0), /goes back up the page from b to c/],
	['a different way back', (w) => w.backward.reverse(), /Shift\+Tab does not retrace/],
	[
		'no stop at all',
		(w) => Object.assign(w, { forward: [], backward: [] }),
		/no element takes the focus/
	]
];
for (const [name, spoil, expected] of cases) {
	const walk = good();
	spoil(walk);
	const problems = walkProblems(walk);
	assert.ok(
		problems.some((problem) => expected.test(problem)),
		name + ' must be refused, got: ' + JSON.stringify(problems)
	);
}

console.log('PASS test-keyboard-walk');
