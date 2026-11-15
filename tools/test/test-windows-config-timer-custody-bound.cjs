// tools/test/test-windows-config-timer-custody-bound.cjs

/**
 * The Windows acquired-read timer custody tests retry a padded native read
 * until a real 1 ms AHK timer lands inside it, at most
 * _CTWP_TEMPORAL_READ_ATTEMPTS times per mode. A hit is a geometric draw, so
 * the bound must leave a negligible chance that any of a run's nine modes runs
 * out. The sample below is the attempt count each mode printed in hosted runs;
 * with the former bound of 512 the miss chance was about 0.7% per run, and run
 * 43611195865 missed. The check reads the bound from the AHK source.
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SOURCE = path.join(
	__dirname,
	'../../static/ergopti_plus/windows/tests/unit/settings/engine/transition/test_temporal_custody.ahk'
);
// « acquired-read timer observed on attempt N », runs 43595483595 to 43611736406 (2026-11-14).
const OBSERVED_ATTEMPTS = Object.freeze([
	67, 99, 79, 136, 96, 163, 122, 91, 70, 20, 70, 23, 22, 99, 76, 77, 37, 179, 183, 34, 104, 37, 15,
	59, 14, 38, 1, 80, 34, 33, 38, 14, 54, 15, 198, 25, 16, 89, 135, 14, 3, 116, 111, 133, 20, 68, 23,
	26, 41, 60, 74, 29, 15, 432, 47, 96, 25
]);
// Three recovery modes and six guarded-adapter modes per run.
const MODES_PER_RUN = 9;
const MAX_RUN_MISS = 1e-9;

/**
 * Chance that at least one mode of a run exhausts the bound.
 * @param {number} attempts Bound per mode.
 * @returns {number}
 */
function runMiss(attempts) {
	const hit = OBSERVED_ATTEMPTS.length / OBSERVED_ATTEMPTS.reduce((sum, n) => sum + n, 0);
	return 1 - (1 - (1 - hit) ** attempts) ** MODES_PER_RUN;
}

const match = /^global _CTWP_TEMPORAL_READ_ATTEMPTS := (\d+)$/m.exec(
	fs.readFileSync(SOURCE, 'utf8')
);
assert.ok(match, 'the AHK test declares its attempt bound');
const bound = Number(match[1]);
assert.ok(
	runMiss(bound) < MAX_RUN_MISS,
	`a bound of ${bound} misses about ${runMiss(bound).toExponential(1)} of runs`
);
assert.ok(runMiss(512) > 1e-3, 'the former bound of 512 is the measured failure');
assert.ok(Math.max(...OBSERVED_ATTEMPTS) < bound, 'every recorded hit lies inside the bound');

console.log(
	`[OK] Windows timer custody bound: ${bound} attempts miss about ${runMiss(bound).toExponential(1)} of runs.`
);
