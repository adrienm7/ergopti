// tools/test/test-go-route-plan-gate.cjs

/**
 * ==============================================================================
 * MODULE: Go Route Plan Gate Controls
 * DESCRIPTION:
 * Proves the Go twin gate cannot pass vacuously: a missing toolchain, a failed
 * run, a build that reports "no test files" and a transcript missing one
 * required test are failures. Runs without Go through an injected spawn.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { run, missingPasses, REQUIRED_TESTS } = require('./run-go-route-plan.cjs');

const passing = REQUIRED_TESTS.map((name) => `--- PASS: ${name} (0.00s)`).join('\n') + '\nok\n';
const quiet = (action) => {
	const saved = { log: console.log, error: console.error, write: process.stderr.write };
	console.log = console.error = () => {};
	process.stderr.write = () => true;
	try {
		return action();
	} finally {
		console.log = saved.log;
		console.error = saved.error;
		process.stderr.write = saved.write;
	}
};
const gate = (result) => quiet(() => run({ spawn: () => result }));

assert.deepEqual(missingPasses(passing), []);
assert.equal(gate({ status: 0, stdout: passing, stderr: '' }), 0, 'every required test passed');
assert.equal(
	gate({ error: Object.assign(new Error('spawn go'), { code: 'ENOENT' }) }),
	1,
	'no toolchain'
);
assert.equal(gate({ status: 1, stdout: passing, stderr: '' }), 1, 'a failed go test');
assert.equal(
	gate({ status: 0, stdout: '?   \troute_plan\t[no test files]\n', stderr: '' }),
	1,
	'a build that excludes every test file'
);
const partial = passing.replace(
	`--- PASS: ${REQUIRED_TESTS[0]} (`,
	`--- SKIP: ${REQUIRED_TESTS[0]} (`
);
assert.equal(gate({ status: 0, stdout: partial, stderr: '' }), 1, 'a skipped required test');
assert.deepEqual(missingPasses(partial), [REQUIRED_TESTS[0]]);

console.log('[OK] Go route plan gate controls (6 checks).');
