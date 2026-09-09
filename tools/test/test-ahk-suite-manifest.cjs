// tools/test/test-ahk-suite-manifest.cjs

'use strict';

const assert = require('node:assert/strict');
const { validateAhkSuiteManifest } = require('./validate-ahk-suite-manifest.cjs');

const beforeSlowTail = [
	'\uFEFF1..3',
	'RUNNING 1/3 - fast head',
	'ok 1 - fast head',
	'RUNNING 2/3 - ordinary middle',
	'ok 2 - ordinary middle',
	'# 2 passed, 0 failed.',
].join('\n');
const early = validateAhkSuiteManifest(beforeSlowTail);
assert.equal(early.complete, false, 'a green-looking footer must not complete before the slow tail');
assert.match(early.errors.join('\n'), /planned test 3\/3 never started/);

const afterSlowTail = [
	'1..3',
	'RUNNING 1/3 - fast head',
	'ok 1 - fast head',
	'RUNNING 2/3 - ordinary middle',
	'ok 2 - ordinary middle',
	'RUNNING 3/3 - deliberately slow tail',
	'ok 3 - deliberately slow tail',
	'# 3 passed, 0 failed.',
].join('\n');
const complete = validateAhkSuiteManifest(afterSlowTail);
assert.equal(complete.complete, true, complete.errors.join('\n'));
assert.deepEqual(complete.executed.map((entry) => entry.index), [1, 2, 3]);

const missingTerminal = validateAhkSuiteManifest(afterSlowTail.replace('ok 3 - deliberately slow tail\n', ''));
assert.equal(missingTerminal.complete, false, 'RUNNING without a terminal result must fail the manifest');

assert.equal(complete.timed_count, 0, 'legacy transcripts have no measured cases');
assert.deepEqual(complete.executed.map((entry) => entry.duration_ms), [null, null, null]);

const timedSource = afterSlowTail
	.replace('ok 1 - fast head', 'ok 1 - fast head\n# duration_ms 1 0')
	.replace('ok 2 - ordinary middle', 'ok 2 - ordinary middle\n# duration_ms 2 12.375')
	.replace('ok 3 - deliberately slow tail', 'ok 3 - deliberately slow tail\n# duration_ms 3 2500.00');
const timed = validateAhkSuiteManifest(timedSource);
assert.equal(timed.complete, true, timed.errors.join('\n'));
assert.equal(timed.timed_count, 3);
assert.deepEqual(timed.executed.map((entry) => entry.duration_ms), [0, 12.375, 2500]);

function rejectsTiming(source, label) {
	const result = validateAhkSuiteManifest(source);
	assert.equal(result.complete, false, label);
	assert.ok(result.errors.length > 0, `${label}: rejection must explain the failure`);
}
rejectsTiming(timedSource.replace('# duration_ms 2 12.375\n', ''), 'mixed timed and untimed cases');
rejectsTiming(`${timedSource}\n# duration_ms 1 0`, 'duplicate timing');
rejectsTiming(`${timedSource}\n# duration_ms 4 1`, 'timing outside the plan');
rejectsTiming(`${timedSource}\n# duration_ms 0 1`, 'zero timing ordinal');
rejectsTiming(timedSource.replace('ok 2 - ordinary middle\n', ''), 'timing without a terminal result');
rejectsTiming(timedSource.replace('ok 2 - ordinary middle\n# duration_ms 2 12.375',
	'# duration_ms 2 12.375\nok 2 - ordinary middle'), 'timing before its terminal result');
for (const value of ['NaN', 'Infinity', '-1', '-0.5', '1e3', '1ms', '', '1 2', '.5', '1.', '9'.repeat(400)]) {
	rejectsTiming(timedSource.replace('# duration_ms 2 12.375', `# duration_ms 2 ${value}`),
		`invalid duration ${value}`);
}
for (const comment of ['# duration_ms', '# duration_ms x 1', '# duration_ms 1.5 1', '# duration_ms 2']) {
	rejectsTiming(`${afterSlowTail}\n${comment}`, `malformed timing must not enable legacy mode: ${comment}`);
}
const failedTimed = validateAhkSuiteManifest(timedSource
	.replace('ok 2 - ordinary middle', 'not ok 2 - ordinary middle — injected failure')
	.replace('# 3 passed, 0 failed.', '# 2 passed, 1 failed.'));
assert.equal(failedTimed.complete, true, failedTimed.errors.join('\n'));
assert.equal(failedTimed.failed, 1);
assert.equal(failedTimed.executed[1].duration_ms, 12.375, 'failed cases are measured too');

require('./support/ahk-timing-runtime.cjs')();

console.log('AHK suite execution manifest: completeness and per-case timing guards passed.');
