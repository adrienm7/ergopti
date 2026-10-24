// tools/test/run-go-route-plan.cjs

/**
 * ==============================================================================
 * MODULE: Go Route Plan Twin Gate
 * DESCRIPTION:
 * Runs the standalone Go twin of the shared per-origin route plan
 * (_shared/go/route_plan) against route_plan_vectors.json, offline and with
 * the installed toolchain only. A missing toolchain or a run in which a
 * required test did not pass is a failure: "no test files" is never green.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const MODULE = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'go', 'route_plan');

// Every test the twin must answer; a renamed or skipped one fails the gate.
const REQUIRED_TESTS = [
	'TestRoutePlanAnswersEverySharedVector',
	'TestRoutePlanReevaluatesEveryRedirectTarget',
	'TestRoutePlanReasonsNeverEchoTheirInput',
	'TestRoutePlanReasonsAreTheSharedClosedSet'
];

/**
 * Lists the required tests a verbose `go test` transcript does not report as passed.
 * @param {string} transcript Combined stdout and stderr of `go test -v`.
 * @returns {string[]} Missing test names, empty when every one passed.
 */
function missingPasses(transcript) {
	return REQUIRED_TESTS.filter((name) => !transcript.includes(`--- PASS: ${name} (`));
}

/**
 * Runs the twin and returns the process exit code.
 * @param {object} [options]
 * @param {Function} [options.spawn] Injected spawnSync for the gate's own tests.
 * @returns {number}
 */
function run({ spawn = spawnSync } = {}) {
	// GOTOOLCHAIN=local never downloads a toolchain and GOPROXY=off never
	// fetches a module: the twin has no dependency and CI stays offline.
	const result = spawn('go', ['test', '-count=1', '-v', './...'], {
		cwd: MODULE,
		encoding: 'utf8',
		env: { ...process.env, GOTOOLCHAIN: 'local', GOPROXY: 'off', GOFLAGS: '-mod=readonly' }
	});
	if (result.error) {
		console.error(
			`[FAIL] Go route plan twin: the Go toolchain could not run (${result.error.code}).`
		);
		return 1;
	}
	const transcript = `${result.stdout || ''}${result.stderr || ''}`;
	if (result.status !== 0) {
		process.stderr.write(transcript);
		console.error(`[FAIL] Go route plan twin: go test exited with ${result.status}.`);
		return 1;
	}
	const missing = missingPasses(transcript);
	if (missing.length > 0) {
		process.stderr.write(transcript);
		console.error(`[FAIL] Go route plan twin: no passing run of ${missing.join(', ')}.`);
		return 1;
	}
	console.log(
		`[OK] Go route plan twin: ${REQUIRED_TESTS.length} tests answered the shared vectors.`
	);
	return 0;
}

if (require.main === module) process.exitCode = run();

module.exports = { run, missingPasses, REQUIRED_TESTS };
