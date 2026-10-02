// tools/test/test-swift-xctest-evidence.cjs

/**
 * Exercises exact XCTest receipts, workflow annotations and the real CI shell
 * pipeline with inert command producers. No Swift/AppKit substitute is claimed.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const {
	annotation,
	cleanTranscript,
	evaluate
} = require('../diagnostics/swift_xctest_evidence.cjs');
const pipeline = require('./ci-pipeline.cjs');
const { bashExecutable } = require('../lib/git-bash.cjs');

const repository = path.resolve(__dirname, '../..');
const file = path.join(
	repository,
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/WindowTitlePolicyTests.swift'
);
const owner = path.join(repository, 'tools/diagnostics/swift_xctest_evidence.cjs');
const passed = [
	"Test Suite 'All tests' started at 2026-10-02 01:00:00.000.",
	"Test Case '-[ErgoptiPlusTests.CatalogUpdateUserDriverTests testNativeCaption]' started.",
	"Test Case '-[ErgoptiPlusTests.CatalogUpdateUserDriverTests testNativeCaption]' passed (0.050 seconds).",
	"Test Case '-[ErgoptiPlusTests.WindowTitlePolicyTests testPrivatePolicies]' started.",
	"Test Case '-[ErgoptiPlusTests.WindowTitlePolicyTests testPrivatePolicies]' passed (0.050 seconds).",
	"Test Suite 'All tests' passed at 2026-10-02 01:00:01.000.",
	'\t Executed 2 tests, with 0 failures (0 unexpected) in 0.100 (0.110) seconds',
	'◇ Test run started.',
	'✔ Test run with 0 tests passed after 0.001 seconds.'
].join('\n');
const verdict = evaluate(passed, 0, 0);
assert.equal(verdict.exit_status, 0);
assert.equal(verdict.complete, true);
assert.deepEqual(verdict.summary, { tests: 2, failures: 0, unexpected: 0 });
assert.equal(verdict.completed_tests.length, 2);
assert.equal(
	evaluate('\x1b[32m' + passed.replaceAll('\n', '\r\n') + '\x1b[0m', 0, 0).exit_status,
	0
);
assert.equal(
	cleanTranscript('\x1b]8;;https://example.invalid\x07Échec\x1b]8;;\x07\r\n'),
	'Échec\n'
);

for (const [text, message] of [
	[passed.slice(passed.indexOf('◇')), 'trailing empty Swift Testing cannot replace XCTest'],
	[
		passed.replace("Test Suite 'All tests' passed", "Test Suite 'Subset' passed"),
		'a partial suite does not pass'
	],
	[passed.replace(/.*testPrivatePolicies.*\n/g, ''), 'a missing native test receipt does not pass'],
	[passed.replace('Executed 2 tests', 'Executed 0 tests'), 'a vacuous XCTest does not pass'],
	[passed.replace('with 0 failures', 'with 1 failure'), 'nonzero assertion failures do not pass'],
	[passed.replace('(0 unexpected)', '(1 unexpected)'), 'unexpected failures do not pass'],
	[
		passed.replace("testPrivatePolicies]' passed", "testPrivatePolicies]' failed"),
		'a failed case defeats misleading success text'
	],
	[
		passed.replace("testPrivatePolicies]' passed", "testPrivatePolicies]' skipped"),
		'a skipped native case does not pass'
	],
	[
		passed
			.replace(/.*testPrivatePolicies.*\n/g, '')
			.replace(
				"testNativeCaption]' passed (0.050 seconds).",
				"testNativeCaption]' passed (0.050 seconds).\nTest Case '-[ErgoptiPlusTests.CatalogUpdateUserDriverTests testNativeCaption]' passed (0.050 seconds)."
			),
		'a duplicated completion cannot replace the missing case'
	],
	[
		passed + "\nTest Suite 'All tests' started at 2026-10-02 02:00:00.000.",
		'a later crashed XCTest cannot reuse an earlier successful summary'
	],
	[
		passed.replace("Test Suite 'All tests' started at 2026-10-02 01:00:00.000.\n", ''),
		'a transcript missing its suite start does not pass'
	]
])
	assert.equal(evaluate(text, 0, 0).exit_status, 1, message);

const failed =
	passed
		.replace("testPrivatePolicies]' passed", "testPrivatePolicies]' failed")
		.replace("Test Suite 'All tests' passed", "Test Suite 'All tests' failed")
		.replace('with 0 failures', 'with 1 failure') +
	`\n${file}:99: error: WindowTitlePolicyTests.testPrivatePolicies : XCTAssertEqual failed — Échec % native\n`;
const errors = evaluate(failed, 0, 0);
assert.equal(errors.exit_status, 1);
assert.equal(errors.complete, false);
assert.ok(
	errors.failures.some(
		(failure) =>
			failure.file ===
				'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/WindowTitlePolicyTests.swift' &&
			failure.line === 99 &&
			failure.message.includes('Échec % native')
	)
);
const compile = evaluate(`${file}:12:9: error: cannot find 'WindowTitles' in scope\n`, 42, 0);
assert.equal(compile.exit_status, 42, 'the actual native process failure is retained');
assert.ok(
	compile.failures.some(
		(failure) => failure.line === 12 && /cannot find 'WindowTitles'/.test(failure.message)
	)
);
assert.equal(
	evaluate(passed, 49, 0).exit_status,
	49,
	'a complete transcript cannot hide a nonzero process exit'
);
assert.equal(
	evaluate(passed, 0, 17).exit_status,
	17,
	'capture failure remains decisive after native success'
);
assert.equal(evaluate(passed, 42, 17).exit_status, 42, 'first failing pipeline status is retained');
const crashed = evaluate(
	passed.slice(
		0,
		passed.indexOf(
			"Test Case '-[ErgoptiPlusTests.WindowTitlePolicyTests testPrivatePolicies]' passed"
		)
	) + 'error: Exited with unexpected signal code 6\n',
	1,
	0
);
assert.ok(
	crashed.failures.some((failure) =>
		/did not complete: .*testPrivatePolicies/.test(failure.message)
	)
);
assert.ok(
	crashed.failures.some((failure) => failure.message === 'Exited with unexpected signal code 6')
);
for (const value of [-1, 256, '', '1oops', '01']) assert.throws(() => evaluate(passed, value, 0));
assert.equal(
	annotation({ file: 'a,b.swift', line: 7, message: 'Échec %\n::warning::inert\rnext' }),
	'::error title=Swift XCTest failure,file=a%2Cb.swift,line=7::Échec %25%0A::warning::inert%0Dnext'
);

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-swift-evidence-'));
try {
	const log = path.join(root, 'native.log');
	const json = path.join(root, 'verdict.json');
	fs.writeFileSync(log, failed);
	let result = spawnSync(process.execPath, [owner, log, '0', '0', json], { encoding: 'utf8' });
	assert.equal(result.status, 1);
	assert.match(
		result.stdout,
		/file=static\/ergopti_plus\/macos\/launcher\/Tests\/ErgoptiPlusTests\/WindowTitlePolicyTests\.swift,line=99/
	);
	assert.match(result.stdout, /Échec %25 native/);
	assert.equal(JSON.parse(fs.readFileSync(json, 'utf8')).complete, false);
	result = spawnSync(process.execPath, [owner, path.join(root, 'missing.log'), '42', '0', json], {
		encoding: 'utf8'
	});
	assert.equal(result.status, 42, 'lost evidence does not override the native failure status');
	assert.match(result.stdout, /Swift XCTest evidence could not be judged/);

	// stepField folds scalars for structural checks; execute the actual literal.
	const step = pipeline.step(pipeline.job('package-macos'), 'Run Swift launcher tests');
	const header = /^([ ]+)run: \|[ \t]*$/m.exec(step);
	assert.notEqual(header, null, 'the native command owner is a YAML literal block');
	const indentation = header[1].length + 2;
	const commands = [];
	for (const line of step
		.slice(header.index + header[0].length)
		.split('\n')
		.slice(1)) {
		if (line.trim() && /^ */.exec(line)[0].length < indentation) break;
		commands.push(line.slice(indentation));
	}
	const run = commands.join('\n');
	for (const [text, script, tee, expected] of [
		[passed, 0, 0, 0],
		[failed, 0, 0, 1],
		[passed, 42, 0, 42],
		[passed, 0, 17, 17]
	]) {
		const fixture = path.join(root, 'pipeline-' + script + '-' + tee + '-' + expected);
		fs.mkdirSync(fixture);
		fs.writeFileSync(log, text);
		const harness =
			'script() { cat "$SWIFT_FIXTURE_LOG"; return "$SWIFT_FIXTURE_SCRIPT_STATUS"; }\n' +
			'tee() { command tee "$@"; return "$SWIFT_FIXTURE_TEE_STATUS"; }\n' +
			run;
		result = spawnSync(bashExecutable(), ['-c', harness], {
			cwd: repository,
			env: {
				...process.env,
				RUNNER_TEMP: fixture.replaceAll('\\', '/'),
				SWIFT_FIXTURE_LOG: log.replaceAll('\\', '/'),
				SWIFT_FIXTURE_SCRIPT_STATUS: String(script),
				SWIFT_FIXTURE_TEE_STATUS: String(tee)
			},
			encoding: 'utf8'
		});
		assert.equal(result.error, undefined);
		assert.equal(result.status, expected, result.stdout + result.stderr);
		const evidence = path.join(fixture, 'swift-launcher-evidence');
		const transcripts = fs.readdirSync(evidence).filter((name) => name.startsWith('xctest.log.'));
		assert.equal(
			transcripts.length,
			1,
			'every failure retains one exact PTY transcript for upload'
		);
		assert.equal(fs.readFileSync(path.join(evidence, transcripts[0]), 'utf8'), text);
		assert.equal(
			JSON.parse(fs.readFileSync(path.join(evidence, 'verdict.json'), 'utf8')).exit_status,
			expected
		);
	}
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}

console.log(
	'[OK] Native Swift transcript failures, exhaustive XCTest receipts, original pipeline statuses and safe annotations are preserved.'
);
