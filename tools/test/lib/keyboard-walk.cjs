// tools/test/lib/keyboard-walk.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Walk Analysis
 * DESCRIPTION:
 * Judges a recorded Tab walk of a page (WCAG 2.1.2 no keyboard trap, 2.4.3
 * focus order, 2.4.7 focus visible): the stops a forward walk met until the
 * focus left the page, and the stops a backward walk met from the end. Pure,
 * so tools/test/test-keyboard-walk.cjs proves without a browser that each
 * failure is caught; tools/test/browser/studio-keyboard.playwright.cjs feeds
 * it the walks of the Studio pages.
 * ==============================================================================
 */

'use strict';

/**
 * One focus stop, as the page reports it.
 * @typedef {object} Stop
 * @property {string} id - The element: tag, id, place in the document and name.
 * @property {string} key - The same without the place, which a re-render above shifts.
 * @property {number} order - Its index among the elements of the document, in document order.
 * @property {boolean} visible - It has a box on screen and is not hidden.
 * @property {number} tabindex - Its tabIndex.
 */

/**
 * The problems of a walk, in words a failing assertion can print.
 * @param {{forward: Stop[], forwardLeft: boolean, backward: Stop[], backwardLeft: boolean}} walk
 *   forwardLeft and backwardLeft: whether the walk reached the end of the page (the
 *   focus left the document) within its step budget.
 * @returns {string[]} Empty when the walk passes.
 */
function walkProblems(walk) {
	const problems = [];
	const { forward, backward } = walk;
	if (forward.length === 0) problems.push('no element takes the focus');
	if (!walk.forwardLeft) {
		const tail = forward.slice(-4).map((stop) => stop.id);
		problems.push(
			'the focus never leaves the page going forward (trap near ' + tail.join(' → ') + ')'
		);
	}
	if (!walk.backwardLeft) {
		const tail = backward.slice(-4).map((stop) => stop.id);
		problems.push(
			'the focus never leaves the page going backward (trap near ' + tail.join(' → ') + ')'
		);
	}
	// A held focus repeats its stops; once is enough to say where.
	const seen = new Set();
	const repeated = new Set();
	for (const stop of forward) {
		if (seen.has(stop.id)) {
			if (!repeated.has(stop.id)) problems.push('the forward walk meets ' + stop.id + ' twice');
			repeated.add(stop.id);
			continue;
		}
		seen.add(stop.id);
		if (!stop.visible) problems.push(stop.id + ' takes the focus while hidden');
		if (stop.tabindex > 0)
			problems.push(stop.id + ' has a positive tabindex, out of the page order');
	}
	for (let i = 1; i < forward.length; i++)
		if (forward[i].order < forward[i - 1].order)
			problems.push(
				'the focus goes back up the page from ' + forward[i - 1].id + ' to ' + forward[i].id
			);
	if (walk.forwardLeft && walk.backwardLeft) {
		const there = forward.map((stop) => stop.key);
		const back = backward.map((stop) => stop.key).reverse();
		const length = Math.max(there.length, back.length);
		for (let i = 0; i < length; i++)
			if (there[i] !== back[i]) {
				problems.push(
					`Shift+Tab does not retrace the Tab order: stop ${i + 1} is ${there[i]} going forward, ` +
						`${back[i]} coming back (${there.length} and ${back.length} stops)`
				);
				break;
			}
	}
	return problems;
}

module.exports = { walkProblems };
