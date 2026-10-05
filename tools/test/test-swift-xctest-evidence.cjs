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
	evaluate,
	keyboardPhases,
	loggerReceipts
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

// Hand-authored boundary witnesses are independent of the Swift producer.
const phaseLine = (phase, sequence = 1) =>
	'TIS_TEST_PHASE ' + JSON.stringify({ version: 1, sequence, phase });
const initialBoundaries = [
	'original.capture.call.entered',
	'original.capture.call.returned',
	'target.list.call.entered',
	'target.list.call.returned',
	'target.enabledProperty.call.entered',
	'target.enabledProperty.call.returned'
];
assert.deepEqual(
	keyboardPhases(initialBoundaries.map((phase, index) => phaseLine(phase, index + 1))),
	{
		accepted: 6,
		refused: 0,
		count_saturated: false,
		last: [
			'target.list.call.returned',
			'target.enabledProperty.call.entered',
			'target.enabledProperty.call.returned'
		]
	}
);
const phaseTranscript = [
	phaseLine('select.before.observe.entered', 1),
	phaseLine('select.before.observe.completed', 2),
	phaseLine('select.call.entered', 3),
	phaseLine('select.call.returned', 4)
].join('\n');
assert.deepEqual(keyboardPhases(phaseTranscript.split('\n')), {
	accepted: 4,
	refused: 0,
	count_saturated: false,
	last: ['select.before.observe.completed', 'select.call.entered', 'select.call.returned']
});
const foreign = 'PRIVATE_PATH_/Users/foreign/TOKEN%\n::error::not-a-command';
const refusedPhases = [
	'TIS_TEST_PHASE {',
	'TIS_TEST_PHASE null',
	'TIS_TEST_PHASE []',
	phaseLine(foreign),
	phaseLine('select.call.entered', 0),
	phaseLine('select.call.entered', 130),
	phaseLine('select.call.entered', 1.5),
	phaseLine('select.call.entered', '1'),
	'TIS_TEST_PHASE ' + JSON.stringify({ version: 2, sequence: 1, phase: 'select.call.entered' }),
	'TIS_TEST_PHASE ' +
		JSON.stringify({ version: 1, sequence: 1, phase: 'select.call.entered', secret: foreign }),
	'TIS_TEST_PHASE {"version":1,"sequence":1,"sequence":2,"phase":"select.call.entered"}',
	'TIS_TEST_PHASE {"version":1,"sequence":1,"phase":true}',
	'TIS_TEST_PHASE {"ver\\u0073ion":1,"sequence":1,"phase":"select.call.entered"}',
	'TIS_TEST_PHASE ' + ' '.repeat(257) + '{}'
].join('\n');
assert.deepEqual(keyboardPhases(refusedPhases.split('\n')), {
	accepted: 0,
	refused: 14,
	count_saturated: false,
	last: []
});
for (const [text, script, tee] of [
	[failed, 0, 0],
	[passed, 42, 0],
	[passed, 0, 17],
	[passed, 0, 0]
]) {
	const original = evaluate(text, script, tee);
	const observed = evaluate(text + '\n' + phaseTranscript + '\n' + refusedPhases, script, tee);
	assert.equal(observed.exit_status, original.exit_status);
	assert.equal(observed.complete, original.complete);
	assert.deepEqual(observed.failures, original.failures);
	assert.deepEqual(observed.completed_tests, original.completed_tests);
	assert.deepEqual(observed.summary, original.summary);
}

// This hand-authored frame follows the existing native stderr protocol; its
// example lock stage is not a claim about the unavailable actual CI transcript.
const loggerFrame =
	'Logger test writer=writer-3 entry=75 stage=lock-file errno=35 ' +
	'directoryStatus=0 directoryInode=13883934701001 directoryLinks=2 fileStatus=0 fileInode=13883934701002.';
const loggerStages = [
	'validate-test-directory',
	'validate-directory',
	'open-directory',
	'chmod-directory',
	'open-file',
	'stat-file',
	'validate-file',
	'chmod-file',
	'lock-file',
	'write-file',
	'rotate-file'
];
assert.deepEqual(loggerReceipts([loggerFrame]), {
	accepted: 1,
	refused: 0,
	count_saturated: false,
	last: [{ writer: 3, entry: 75, stage: 'lock-file', errno: 35 }]
});
const allLoggerStages = loggerStages.map((stage) =>
	loggerFrame.replace('stage=lock-file', 'stage=' + stage)
);
assert.deepEqual(loggerReceipts(allLoggerStages), {
	accepted: 11,
	refused: 0,
	count_saturated: false,
	last: [
		{ writer: 3, entry: 75, stage: 'lock-file', errno: 35 },
		{ writer: 3, entry: 75, stage: 'write-file', errno: 35 },
		{ writer: 3, entry: 75, stage: 'rotate-file', errno: 35 }
	]
});
const invalidLoggerFrames = [
	loggerFrame + ' secret=' + foreign,
	loggerFrame.replace('writer-3', 'private-writer'),
	loggerFrame.replace('writer-3', 'writer-10'),
	loggerFrame.replace('entry=75', 'entry=512'),
	loggerFrame.replace('entry=75', 'entry=-1'),
	loggerFrame.replace('entry=75', 'entry=075'),
	loggerFrame.replace('stage=lock-file', 'stage=/Users/foreign/TOKEN%::error::inert'),
	loggerFrame.replace('stage=lock-file', 'stage=unknown-file'),
	loggerFrame.replace('errno=35', 'errno=2147483648'),
	loggerFrame.replace('errno=35', 'errno=-2147483649'),
	loggerFrame.replace('errno=35', 'errno=NaN'),
	loggerFrame.replace('errno=35', 'errno=35 errno=22'),
	loggerFrame.replace('directoryStatus=0', 'directoryStatus=1'),
	loggerFrame.replace('fileStatus=0', 'fileStatus=-2'),
	loggerFrame.replace('directoryInode=13883934701001', 'directoryInode=18446744073709551616'),
	loggerFrame.replace('fileInode=13883934701002', 'fileInode=-1'),
	loggerFrame.replace('directoryLinks=2', 'directoryLinks=65536'),
	loggerFrame.replace('directoryLinks=2', 'directoryLinks=2.5'),
	loggerFrame.replace(' fileStatus=0', ''),
	loggerFrame.slice(0, -1),
	'Logger test ' + 'x'.repeat(321),
	loggerFrame.replace('stage=lock-file', 'stage=lock-file\r::error::inert')
];
assert.deepEqual(loggerReceipts(invalidLoggerFrames), {
	accepted: 0,
	refused: 22,
	count_saturated: false,
	last: []
});
const edgeLoggerFrame = loggerFrame
	.replace('writer-3', 'writer-9')
	.replace('entry=75', 'entry=511')
	.replace('errno=35', 'errno=-2147483648')
	.replace('directoryStatus=0', 'directoryStatus=-1')
	.replace('directoryInode=13883934701001', 'directoryInode=18446744073709551615')
	.replace('directoryLinks=2', 'directoryLinks=65535')
	.replace('fileStatus=0', 'fileStatus=-1')
	.replace('fileInode=13883934701002', 'fileInode=0');
assert.deepEqual(loggerReceipts([edgeLoggerFrame]).last, [
	{ writer: 9, entry: 511, stage: 'lock-file', errno: -2147483648 }
]);
assert.equal(loggerReceipts(Array(200).fill(loggerFrame)).accepted, 200);
assert.equal(loggerReceipts(Array(200).fill(loggerFrame)).last.length, 3);
for (const [text, script, tee] of [
	[failed, 0, 0],
	[passed, 42, 0],
	[passed, 0, 17],
	[passed, 0, 0]
]) {
	const original = evaluate(text, script, tee);
	const observed = evaluate(
		text + '\n' + allLoggerStages.join('\n') + '\n' + invalidLoggerFrames.join('\n'),
		script,
		tee
	);
	assert.equal(observed.exit_status, original.exit_status);
	assert.equal(observed.complete, original.complete);
	assert.deepEqual(observed.failures, original.failures);
	assert.deepEqual(observed.completed_tests, original.completed_tests);
	assert.deepEqual(observed.summary, original.summary);
	assert.deepEqual(observed.keyboard_phase_witnesses, original.keyboard_phase_witnesses);
}

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

	// Actual CLI: the old reader emitted no accessible witness for this causal
	// incomplete-case transcript. Witnesses cannot make that case complete.
	const incomplete = [
		"Test Suite 'All tests' started at 2026-10-02 01:00:00.000.",
		"Test Case '-[ErgoptiPlusTests.KeyboardSourceProbeTests testActualSelectedSourcesProveDirectPunctuationAndRejectDeadAccent]' started.",
		phaseTranscript,
		refusedPhases
	].join('\n');
	fs.writeFileSync(log, incomplete);
	result = spawnSync(process.execPath, [owner, log, '0', '0', json], { encoding: 'utf8' });
	assert.equal(result.status, 1);
	assert.match(result.stdout, /XCTest case did not complete: .*testActualSelectedSources/);
	assert.match(result.stdout, /complete successful suite summary and every test-case receipt/);
	const notices = result.stdout.split('\n').filter((line) => line.startsWith('::notice '));
	assert.equal(
		notices.length,
		1,
		'one accessible failure annotation survives error annotation limits'
	);
	assert.ok(notices[0].length < 512, 'visible evidence stays bounded');
	assert.match(notices[0], /cause remains unqualified/);
	assert.match(notices[0], /accepted=4; refused=14/);
	assert.match(
		notices[0],
		/last=select.before.observe.completed, select.call.entered, select.call.returned$/
	);
	assert.doesNotMatch(notices[0], /PRIVATE_PATH|TOKEN|Users|::error|%0A|%0D/);
	assert.deepEqual(
		JSON.parse(fs.readFileSync(json, 'utf8')).keyboard_phase_witnesses,
		keyboardPhases((phaseTranscript + '\n' + refusedPhases).split('\n'))
	);
	fs.writeFileSync(log, incomplete.slice(0, incomplete.indexOf('TIS_TEST_PHASE')));
	result = spawnSync(process.execPath, [owner, log, '42', '17', json], { encoding: 'utf8' });
	assert.equal(result.status, 42);
	assert.match(result.stdout, /accepted=0; refused=0; countSaturated=false; last=unobserved/);
	fs.writeFileSync(log, passed + '\n' + phaseTranscript + '\n' + refusedPhases);
	result = spawnSync(process.execPath, [owner, log, '0', '0', json], { encoding: 'utf8' });
	assert.equal(result.status, 0);
	assert.doesNotMatch(result.stdout, /::notice|::error|PRIVATE_PATH|TOKEN/);

	const loggerFile = path.join(
		repository,
		'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/LauncherLogTests.swift'
	);
	const loggerFailure = [
		"Test Suite 'All tests' started at 2026-10-05 01:00:00.000.",
		"Test Case '-[ErgoptiPlusTests.LauncherLogTests testIndependentProcessesAppendEveryWholeRecordExactlyOnce]' started.",
		loggerFrame,
		`${loggerFile}:606: error: expected child exit 0, observed 73`,
		`${loggerFile}:635: error: observed 1227 records, expected 1280`,
		`${loggerFile}:641: error: complete records: missing=53, unexpected=0`,
		"Test Case '-[ErgoptiPlusTests.LauncherLogTests testIndependentProcessesAppendEveryWholeRecordExactlyOnce]' failed (0.500 seconds).",
		"Test Suite 'All tests' failed at 2026-10-05 01:00:01.000.",
		'Executed 1 test, with 3 failures (0 unexpected) in 0.500 (0.500) seconds'
	].join('\n');
	fs.writeFileSync(log, loggerFailure + '\n' + invalidLoggerFrames.join('\n'));
	result = spawnSync(process.execPath, [owner, log, '1', '0', json], { encoding: 'utf8' });
	assert.equal(result.status, 1);
	assert.match(result.stdout, /expected child exit 0, observed 73/);
	assert.match(result.stdout, /complete records: missing=53, unexpected=0/);
	const loggerNotices = result.stdout
		.split('\n')
		.filter((line) => line.startsWith('::notice title=Native logger callback receipt::'));
	assert.equal(
		loggerNotices.length,
		1,
		'one bounded logger annotation exposes the existing native callback'
	);
	assert.ok(loggerNotices[0].length < 512);
	assert.match(loggerNotices[0], /accepted=1; refused=22/);
	assert.match(loggerNotices[0], /last=writer=3 entry=75 stage=lock-file errno=35$/);
	assert.doesNotMatch(
		loggerNotices[0],
		/PRIVATE_PATH|TOKEN|Users|directory|Inode|1388393470100|::error|%0A|%0D/
	);
	const loggerVerdict = JSON.parse(fs.readFileSync(json, 'utf8'));
	assert.equal(loggerVerdict.complete, false);
	assert.deepEqual(loggerVerdict.logger_callback_receipts.last, [
		{ writer: 3, entry: 75, stage: 'lock-file', errno: 35 }
	]);
	assert.doesNotMatch(
		JSON.stringify(loggerVerdict.logger_callback_receipts),
		/Inode|1388393470100|TOKEN/
	);
	fs.writeFileSync(log, loggerFailure.replace(loggerFrame, invalidLoggerFrames[0]));
	result = spawnSync(process.execPath, [owner, log, '73', '17', json], { encoding: 'utf8' });
	assert.equal(
		result.status,
		73,
		'callback visibility cannot override the original native pipeline status'
	);
	assert.match(
		result.stdout,
		/Native logger callback receipt::.*accepted=0; refused=1; countSaturated=false; last=unobserved/
	);
	fs.writeFileSync(log, passed + '\n' + loggerFrame + '\n' + invalidLoggerFrames.join('\n'));
	result = spawnSync(process.execPath, [owner, log, '0', '0', json], { encoding: 'utf8' });
	assert.equal(result.status, 0);
	assert.doesNotMatch(result.stdout, /::notice|::error|PRIVATE_PATH|TOKEN/);

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
