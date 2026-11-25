// tools/test/lib/bound-measurements.cjs

/**
 * ==============================================================================
 * MODULE: Bound Measurements
 * DESCRIPTION:
 * Prints the value a passing check measured against a bound, in a line the JS
 * suite runner keeps, so a bound can be set from what the hosted runners
 * measure instead of from a guess.
 *
 * FEATURES & RATIONALE:
 * 1. The runner shows a passing check's name and duration only, so a ratio
 *    that a check printed beside its pass never reached a CI log: the two
 *    Studio speed bounds could not be read on CI. Each line starting with
 *    MEASURED_PREFIX is echoed under the check's PASS line.
 * 2. One line per bound names the measured value and the bound, so the margin
 *    between them reads in the log without the test's source.
 * ==============================================================================
 */

'use strict';

const MEASURED_PREFIX = 'MEASURED (bound input):';

/**
 * Print one measured value beside its bound.
 * @param {string} label - What the value measures, with its unit.
 * @param {number} value - The measured value.
 * @param {number} bound - The bound the check holds the value under.
 * @throws {Error} When the value or the bound is not a finite number.
 */
function reportMeasured(label, value, bound) {
	if (!Number.isFinite(value) || !Number.isFinite(bound))
		throw new Error(`bound-measurements: ${label} measured ${value} against bound ${bound}`);
	console.log(`${MEASURED_PREFIX} ${label}: ${value.toFixed(1)} (bound ${bound})`);
}

module.exports = { MEASURED_PREFIX, reportMeasured };
