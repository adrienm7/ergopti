// tools/test/run-hs274-diagnostics-tests.cjs

/**
 * ==============================================================================
 * MODULE: HS-274 Diagnostics Test Runner
 * DESCRIPTION:
 * Runs the portable tests of the HS-274 producer and native-fixture tooling in
 * tools/diagnostics: every hs274_*_test.py suite and the two C++ tests that
 * need no vendor headers. The owned runtime build (ADR 011, TODO item 31) pins
 * the producer patch set and headers these tests cover, so they guard inputs
 * of tools/build/remap_runtime_source.py, not a finished investigation.
 *
 * ROOT CAUSE ENCODED:
 * Deleting the hs274-*.yml dispatch workflows left these tests run by no
 * workflow, so a regression in the pinned producer patch set or its stream
 * protocol reader would have gone unnoticed until the native build.
 *
 * FEATURES & RATIONALE:
 * 1. Python suites are discovered by name, so a new hs274_*_test.py runs
 *    without editing this file. Each exclusion names why it runs elsewhere,
 *    and a stale exclusion (file gone) fails the run.
 * 2. The C++ tests compile with $CXX (default c++) and run once each; the
 *    tests that include the pinned Karabiner-Elements vendor headers belong to
 *    the runtime build and are not compiled here.
 * 3. A suite that cannot start (no interpreter or compiler) is a failure with
 *    its reason, never a pass.
 * ==============================================================================
 */

'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DIAGNOSTICS = path.join(ROOT, 'tools', 'diagnostics');
const PYTHON = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const CXX = process.env.CXX || 'c++';
const EXCLUDED = Object.freeze({
	// Runs inside test-macos-remap-launchagent.cjs, in the shared lane already.
	'hs274_helper_environment_test.py': 'run by tools/test/test-macos-remap-launchagent.cjs',
	// Exercises sudo and process groups of the native harness on a hosted Mac only.
	'hs274_shutdown_test.py': 'native macOS process-scope script for hs274-remap.py'
});
const PORTABLE_CPP = Object.freeze(['hs274-raw-capture-test.cpp', 'hs274-stream-session-test.cpp']);

// Each child has Node's ordinary synchronous capture ceiling. A verbose child
// remains a failed check on ENOBUFS, rather than silently dropping its status.
const CHILD_CAPTURE_BYTES = 1024 * 1024;
// Final receipts retain bounded UTF-8 edges per stream, independently of later
// healthy suite output. This is a console-receipt budget, not a suite log limit.
const FAILURE_EXCERPT_BYTES = 4096;
const failures = [];

/** Retains valid UTF-8 edges and accounts explicitly for omitted source bytes. */
function excerpt(text) {
	const bytes = Buffer.from(text || '', 'utf8');
	if (bytes.length <= FAILURE_EXCERPT_BYTES)
		return { head: bytes.toString('utf8'), tail: '', omitted_bytes: 0 };
	let headEnd = FAILURE_EXCERPT_BYTES / 2;
	let tailStart = bytes.length - headEnd;
	while ((bytes[headEnd] & 0xc0) === 0x80) headEnd--;
	while ((bytes[tailStart] & 0xc0) === 0x80) tailStart++;
	return {
		head: bytes.subarray(0, headEnd).toString('utf8'),
		tail: bytes.subarray(tailStart).toString('utf8'),
		omitted_bytes: tailStart - headEnd
	};
}

/**
 * Runs one command from the repository root and records a failure with its reason.
 * @param {string} label What the command proves.
 * @param {string} command Executable.
 * @param {string[]} args Arguments.
 * @returns {boolean} Whether the command exited zero.
 */
function run(label, command, args) {
	console.log(`\n=== ${label} ===`);
	let result;
	try {
		result = spawnSync(command, args, {
			cwd: ROOT,
			stdio: ['inherit', 'pipe', 'pipe'],
			encoding: 'utf8',
			maxBuffer: CHILD_CAPTURE_BYTES,
			env: { ...process.env, PYTHONIOENCODING: 'utf-8' }
		});
	} catch (error) {
		result = { error, status: null, signal: null };
	}
	if (result.stdout) process.stdout.write(result.stdout);
	if (result.stderr) process.stderr.write(result.stderr);
	if (result.error || result.status !== 0 || result.signal) {
		failures.push({
			kind: 'child',
			label,
			exit_code: result.status ?? null,
			signal: result.signal ?? null,
			error_code: result.error?.code ?? null,
			error: excerpt(result.error?.message),
			stdout: excerpt(result.stdout),
			stderr: excerpt(result.stderr)
		});
		return false;
	}
	return true;
}

const entries = fs.readdirSync(DIAGNOSTICS);
for (const name of Object.keys(EXCLUDED)) {
	if (!entries.includes(name))
		failures.push({
			kind: 'inventory',
			label: `stale exclusion ${name}: the file no longer exists`
		});
}
const suites = entries.filter((name) => /^hs274_.+_test\.py$/.test(name) && !EXCLUDED[name]).sort();
if (suites.length === 0)
	failures.push({
		kind: 'inventory',
		label: 'no hs274_*_test.py suite found in tools/diagnostics'
	});
for (const suite of suites) {
	run(`${PYTHON} -m unittest ${suite}`, PYTHON, [
		'-m',
		'unittest',
		'discover',
		'-s',
		'tools/diagnostics',
		'-p',
		suite
	]);
}

const build = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-hs274-cpp-'));
try {
	for (const source of PORTABLE_CPP) {
		const binary = path.join(build, path.basename(source, '.cpp'));
		const compiled = run(`${CXX} ${source}`, CXX, [
			'-std=c++17',
			'-Wall',
			'-Wextra',
			'-Werror',
			'-pthread',
			path.join('tools', 'diagnostics', source),
			'-o',
			binary
		]);
		if (compiled) run(source.replace(/\.cpp$/, ''), binary, []);
	}
} finally {
	fs.rmSync(build, { recursive: true, force: true });
}

if (failures.length > 0) {
	console.error(`\n${failures.length} HS-274 diagnostics check(s) failed:`);
	for (const failure of failures) console.error(`  - ${failure.label}`);
	// One compact line keeps every failed child's bounded diagnosis in the
	// aggregate tail when the outer JS runner clips each stream's middle.
	console.error(
		'HS274_FAILURE_RECEIPT ' +
			JSON.stringify({
				schema: 1,
				capture_limit_bytes: CHILD_CAPTURE_BYTES,
				excerpt_limit_bytes: FAILURE_EXCERPT_BYTES,
				failures
			})
	);
	// Let piped output drain: an immediate exit can cut off the final receipt.
	process.exitCode = 1;
} else {
	console.log(
		`\nAll ${suites.length} HS-274 Python suites and ${PORTABLE_CPP.length} C++ tests passed.`
	);
}
