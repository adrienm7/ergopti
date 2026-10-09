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
const { validate: nativeValidateTIS } = require('../diagnostics/tis_evidence_transport.cjs');
const { loadValidator, verifyPort } = require('./fixtures/tis_fixture_metadata_port.cjs');
const validateTIS = (root, session) =>
	process.platform === 'win32'
		? loadValidator(root).validate(root, session)
		: nativeValidateTIS(root, session);
const pipeline = require('./ci-full-default.cjs');
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
// Add the frozen independent14 start/pass receipts only to workflow replays.
// The original two-case collector corpus and every existing verdict oracle stay intact.
const ownedProgramCases = fs
	.readFileSync(path.join(__dirname, 'fixtures/owned-program-xctest/complete.xctest.txt'), 'utf8')
	.split('\n')
	.filter((line) => /^Test Case '-\[ErgoptiPlusTests\.OwnedProgramWorkerTests /.test(line));
assert.equal(
	ownedProgramCases.length,
	28,
	'the independently pinned14 corpus contains14 starts and14 passes'
);
function withOwnedProgramCases(text) {
	return text
		.replace(
			/^(Test Suite 'All tests' (?:passed|failed) at .+)$/m,
			ownedProgramCases.join('\n') + '\n$1'
		)
		.replace('Executed 2 tests', 'Executed 16 tests');
}
// Git metadata is an inert producer in these genuine workflow-literal replays,
// just like their existing script/tee producers; no native execution is claimed.
const controlledCheckout =
	'git() { [ "$#" -eq 2 ] && [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ] || return 64; printf "%s\\n" "fad2fde93dbfe8a53a943eb9fdfd3afd3160283c"; }\n';
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
// A bounded census diagnostic must survive the actual XCTest evidence owner.
// Plain helper prints are deliberately absent from its failure annotations.
const censusFile = path.join(
	repository,
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift'
);
const censusFacts =
	'Native Sparkle census refusal: code=path-unavailable helper_pid=9123 path_errno=3 bsd_bytes=136 bsd_errno=0 bsd_state=zombie';
const onlyPrintedCensus = evaluate(passed + '\n' + censusFacts, 1, 0);
assert.equal(
	onlyPrintedCensus.failures.some((failure) => failure.message.includes('bsd_state=zombie')),
	false,
	'a plain print cannot be mistaken for an available XCTest diagnostic'
);
const annotatedCensus = evaluate(
	failed +
		`\n${censusFile}:274: error: SparkleArchiveUpdateAcceptanceTests : failed - ${censusFacts}\n`,
	1,
	0
);
const censusFailure = annotatedCensus.failures.find((failure) =>
	failure.message.endsWith(censusFacts)
);
assert.notEqual(censusFailure, undefined, 'the native snapshot is visible without raw CI logs');
assert.equal(
	annotation(censusFailure),
	'::error title=Swift XCTest failure,file=static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/SparkleArchiveUpdateAcceptanceTests.swift,line=274::SparkleArchiveUpdateAcceptanceTests : failed - ' +
		censusFacts
);
assert.equal(
	annotatedCensus.exit_status,
	1,
	'diagnosis must never turn census refusal into success'
);
const censusHostSource = fs.readFileSync(censusFile, 'utf8');
const censusAnnotation = censusHostSource.slice(
	censusHostSource.indexOf('private func annotateCensusRefusal('),
	censusHostSource.indexOf('private func privateDirectory(')
);
assert.match(
	censusAnnotation,
	/XCTFail\(summary\)/,
	'the actual host publishes validated facts as XCTest failure'
);
assert.doesNotMatch(
	censusAnnotation,
	/(?:print|XCTFail)\(stdout/,
	'raw helper output stays private'
);

// A pre-path failure has its own bounded visible stage; no raw exception crosses.
const stageFacts =
	'Native Sparkle census refusal: code=stage-refused helper_pid=9123 stage=private-root';
const stageErrors = evaluate(failed + `\n${censusFile}:255: error: failed - ${stageFacts}\n`, 1, 0);
const stageFailure = stageErrors.failures.find((failure) => failure.message.endsWith(stageFacts));
assert.notEqual(
	stageFailure,
	undefined,
	'private directory rejection is visible before proc_pidpath'
);
assert.match(annotation(stageFailure), /stage=private-root$/);
assert.match(censusAnnotation, /\["private-root", "library", "inventory", "unexpected"\]/);
assert.match(
	censusHostSource,
	/XCTFail\("Native Sparkle census refusal: code=diagnostic-unavailable"\)/,
	'empty or invalid output must still have a fixed visible native diagnostic'
);

// Independently fixed directory facts survive the real annotation parser.
const directoryFacts =
	'Native Sparkle census refusal: code=directory-refused helper_pid=9123 reason=mode';
const directoryErrors = evaluate(
	failed + `\n${censusFile}:260: error: failed - ${directoryFacts}\n`,
	1,
	0
);
const directoryFailure = directoryErrors.failures.find((failure) =>
	failure.message.endsWith(directoryFacts)
);
assert.notEqual(
	directoryFailure,
	undefined,
	'the directory refusal reason is available without raw logs'
);
assert.match(annotation(directoryFailure), /code=directory-refused helper_pid=9123 reason=mode$/);
assert.equal(directoryErrors.exit_status, 1, 'a reason cannot admit a directory');
assert.equal(
	evaluate(passed + '\n' + directoryFacts, 1, 0).failures.some((failure) =>
		failure.message.includes('reason=mode')
	),
	false,
	'a plain directory-fact print is still not an XCTest diagnostic'
);
assert.match(
	censusAnnotation,
	/Set\(packet.keys\) == Set\(\["schema", "code", "helper_pid", "reason"\]\)/
);
assert.match(censusAnnotation, /reasons\.contains\(reason\)/);
assert.match(
	censusAnnotation,
	/XCTFail\("Native Sparkle census refusal: code=directory-refused helper_pid=/
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

// Independent protocol fixtures publish real private files. They model the
// native wire contract, not Carbon execution or XCTest observer delivery.
function makeControlledSession(root, nonce) {
	const fs = require('node:fs');
	const path = require('node:path');
	const crypto = require('node:crypto');
	const sha = (data) => crypto.createHash('sha256').update(data).digest('hex');
	function publish(name, data) {
		const stage = path.join(root, '.' + name + '.stage');
		const target = path.join(root, name);
		const descriptor = fs.openSync(stage, 'wx', 0o600);
		try {
			fs.writeFileSync(descriptor, data);
			fs.fsyncSync(descriptor);
		} finally {
			fs.closeSync(descriptor);
		}
		fs.linkSync(stage, target);
		fs.unlinkSync(stage);
	}
	const start = Buffer.from(
		JSON.stringify({
			version: 1,
			session: nonce,
			producerPID: 9123,
			bundleSHA256: sha(Buffer.from('controlled XCTest bundle'))
		})
	);
	publish('start.json', start);
	const records = [];
	for (let index = 1; index <= 6; index++) {
		const receipt = {
			version: 1,
			pid: 9123,
			test: { state: 'present', value: 'controlled-native-' + index },
			events: [
				{
					phase: 'restore.after',
					uptime: 123.5,
					status: -50,
					snapshotID: { state: 'present', value: 'é'.repeat(512) }
				}
			],
			omittedEvents: 0
		};
		// More than 4KiB of independent bounded Unicode source data is retained.
		if (index === 6) receipt.events = Array.from({ length: 64 }, () => receipt.events[0]);
		const bytes = Buffer.concat([
			Buffer.from('TIS_TEST_EVIDENCE '),
			Buffer.from(JSON.stringify(receipt)),
			Buffer.from('\n')
		]);
		publish('record-' + String(index).padStart(6, '0') + '.dat', bytes);
		records.push({ index, bytes: bytes.length, sha256: sha(bytes), closed: true });
	}
	publish(
		'manifest.json',
		Buffer.from(
			JSON.stringify({
				version: 1,
				session: nonce,
				producerPID: 9123,
				bundleSHA256: JSON.parse(start).bundleSHA256,
				startSHA256: sha(start),
				phase: 'closed',
				enrolledCount: 6,
				records
			})
		)
	);
}

/** Resolve one actual CPython instead of the Microsoft Store launcher alias. */
function fixturePython() {
	for (const candidate of ['python3', 'python']) {
		const result = spawnSync(
			candidate,
			[
				'-c',
				'import platform, sys; assert platform.python_implementation() == "CPython"; assert sys.version_info >= (3, 8); print(sys.executable)'
			],
			{ encoding: 'utf8' }
		);
		if (!result.error && result.status === 0) {
			const executable = result.stdout.trim();
			if (path.isAbsolute(executable) && fs.statSync(executable).isFile()) return executable;
		}
	}
	throw new Error('The actual Swift shell pipeline fixture requires CPython 3.8 or later.');
}

/** Preserve actual YAML Python bytes while declaring the closed Windows syscall port. */
function fixtureCheckpointHarness(commands, directory) {
	const publishers = [...commands.matchAll(/python3 - <<'PY'\n([\s\S]*?)\nPY/g)];
	assert.equal(publishers.length, 1, 'the actual workflow owns one literal checkpoint publisher');
	fs.writeFileSync(path.join(directory, 'workflow-publisher.py'), publishers[0][1] + '\n');
	return (
		'node() { if [ "$SWIFT_FIXTURE_PLATFORM" = "win32" ] && [ "$1" = "tools/diagnostics/tis_evidence_transport.cjs" ]; then shift; "$SWIFT_FIXTURE_NODE" "$SWIFT_FIXTURE_TIS_PORT" "$@"; else "$SWIFT_FIXTURE_NODE" "$@"; fi; }\n' +
		'python3() { if [ "$SWIFT_FIXTURE_PLATFORM" = "win32" ]; then "$SWIFT_FIXTURE_PYTHON" "$SWIFT_FIXTURE_PYTHON_PORT" "$@"; else "$SWIFT_FIXTURE_PYTHON" "$@"; fi; }\n'
	);
}

const pythonExecutable = fixturePython();
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-swift-evidence-'));
try {
	if (process.platform === 'win32') verifyPort(root);
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
	for (const [
		text,
		script,
		tee,
		expected,
		includeOwned = true,
		mutation = '',
		expectedCollector = expected
	] of [
		[passed, 0, 0, 0],
		[failed, 0, 0, 1],
		[passed, 42, 0, 42],
		[passed, 0, 17, 17],
		[passed, 0, 0, 1, false, '', 0],
		[passed, 42, 0, 42, false],
		[passed, 0, 17, 17, false],
		[passed, 0, 0, 1, true, 'duplicate-start', 0],
		[passed, 0, 0, 1, true, 'skip']
	]) {
		const fixture = path.join(
			root,
			'pipeline-' + script + '-' + tee + '-' + expected + '-' + includeOwned + '-' + mutation
		);
		fs.mkdirSync(fixture);
		let publishedText = includeOwned ? withOwnedProgramCases(text) : text;
		if (mutation === 'duplicate-start')
			publishedText = publishedText.replace(
				ownedProgramCases[0],
				ownedProgramCases[0] + '\n' + ownedProgramCases[0]
			);
		if (mutation === 'skip')
			publishedText = publishedText.replace(
				ownedProgramCases[1],
				ownedProgramCases[1].replace(' passed ', ' skipped ')
			);
		fs.writeFileSync(log, publishedText);
		const fixturePublisher = path.join(fixture, 'publish.cjs');
		fs.writeFileSync(
			fixturePublisher,
			'(' +
				makeControlledSession.toString() +
				')(process.env.ERGOPTI_TIS_EVIDENCE_DIR,process.env.ERGOPTI_TIS_EVIDENCE_SESSION);'
		);
		const harness =
			controlledCheckout +
			fixtureCheckpointHarness(run, fixture) +
			'script() { node "$SWIFT_FIXTURE_PUBLISHER" || return $?; cat "$SWIFT_FIXTURE_LOG"; return "$SWIFT_FIXTURE_SCRIPT_STATUS"; }\n' +
			'tee() { command tee "$@"; return "$SWIFT_FIXTURE_TEE_STATUS"; }\n' +
			run;
		result = spawnSync(bashExecutable(), ['-c', harness], {
			cwd: repository,
			env: {
				...process.env,
				SWIFT_FIXTURE_PLATFORM: process.platform,
				SWIFT_FIXTURE_NODE: process.execPath.replaceAll('\\', '/'),
				SWIFT_FIXTURE_TIS_PORT: path
					.join(__dirname, 'fixtures/tis_fixture_metadata_port.cjs')
					.replaceAll('\\', '/'),
				SWIFT_FIXTURE_PYTHON_PORT: path
					.join(__dirname, 'fixtures/swift_workflow_checkpoint_port.py')
					.replaceAll('\\', '/'),
				SWIFT_FIXTURE_PYTHON_BODY: path
					.join(fixture, 'workflow-publisher.py')
					.replaceAll('\\', '/'),
				SWIFT_FIXTURE_PYTHON: pythonExecutable.replaceAll('\\', '/'),
				RUNNER_TEMP: fixture.replaceAll('\\', '/'),
				GITHUB_OUTPUT: path.join(fixture, 'step-outputs').replaceAll('\\', '/'),
				SWIFT_FIXTURE_PUBLISHER: fixturePublisher.replaceAll('\\', '/'),
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
		assert.equal(fs.readFileSync(path.join(evidence, transcripts[0]), 'utf8'), publishedText);
		assert.equal(
			JSON.parse(fs.readFileSync(path.join(evidence, 'verdict.json'), 'utf8')).exit_status,
			expectedCollector
		);
	}
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}

console.log(
	'[OK] Native Swift transcript failures, exhaustive XCTest receipts, original pipeline statuses and safe annotations are preserved.'
);

// These controls exercise the actual artifact validator and real filesystem;
// successful raw XCTest and successful artifact admission remain independent.
const transportRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-tis-transport-'));
const sessionNonce = 'a'.repeat(64);
try {
	let serial = 0;
	function fixture() {
		const directory = path.join(transportRoot, String(++serial));
		fs.mkdirSync(directory, { mode: 0o700 });
		makeControlledSession(directory, sessionNonce);
		return directory;
	}
	function terminal(directory, change) {
		const source = path.join(directory, 'manifest.json');
		const value = JSON.parse(fs.readFileSync(source));
		change(value);
		fs.writeFileSync(source, JSON.stringify(value));
	}
	const good = fixture();
	const before = fs.readFileSync(path.join(good, 'record-000006.dat'));
	assert.ok(before.length > 4096);
	const admitted = validateTIS(good, sessionNonce);
	assert.equal(admitted.complete, true);
	assert.equal(admitted.record_count, 6);
	assert.equal(admitted.receipts[5].events.length, 64);
	assert.equal(admitted.receipts[5].events[0].snapshotID.value, 'é'.repeat(512));
	assert.deepEqual(fs.readFileSync(path.join(good, 'record-000006.dat')), before);
	for (const [name, mutate] of [
		['wholly lost last diagnostic', (d) => fs.unlinkSync(path.join(d, 'record-000006.dat'))],
		['missing terminal', (d) => fs.unlinkSync(path.join(d, 'manifest.json'))],
		[
			'no enrollment',
			(d) => {
				for (const file of fs.readdirSync(d).filter((x) => x.startsWith('record-')))
					fs.unlinkSync(path.join(d, file));
				terminal(d, (x) => {
					x.enrolledCount = 0;
					x.records = [];
				});
			}
		],
		[
			'pending last enrollment',
			(d) =>
				terminal(d, (x) => {
					x.enrolledCount = 7;
				})
		],
		[
			'duplicated index',
			(d) =>
				terminal(d, (x) => {
					x.records[5].index = 5;
				})
		],
		[
			'reordered records',
			(d) =>
				terminal(d, (x) => {
					x.records.reverse();
				})
		],
		[
			'unclosed record',
			(d) =>
				terminal(d, (x) => {
					x.records[0].closed = false;
				})
		],
		[
			'truthy close instead of ACK',
			(d) =>
				terminal(d, (x) => {
					x.records[0].closed = 1;
				})
		],
		[
			'foreign producer',
			(d) =>
				terminal(d, (x) => {
					x.producerPID++;
				})
		],
		[
			'foreign bundle',
			(d) =>
				terminal(d, (x) => {
					x.bundleSHA256 = 'b'.repeat(64);
				})
		],
		[
			'stale nonce',
			(d) =>
				terminal(d, (x) => {
					x.session = 'b'.repeat(64);
				})
		],
		['changed start receipt', (d) => fs.appendFileSync(path.join(d, 'start.json'), ' ')],
		['changed diagnostic', (d) => fs.appendFileSync(path.join(d, 'record-000001.dat'), 'x')],
		[
			'same-length changed content',
			(d) => {
				const file = path.join(d, 'record-000001.dat');
				fs.writeFileSync(
					file,
					fs.readFileSync(file, 'utf8').replace('"status":-50', '"status":-49')
				);
			}
		],
		[
			'missing full content hash',
			(d) =>
				terminal(d, (x) => {
					delete x.records[0].sha256;
				})
		],
		[
			'incorrect byte length',
			(d) =>
				terminal(d, (x) => {
					x.records[0].bytes++;
				})
		],
		[
			'open publication debt',
			(d) => fs.writeFileSync(path.join(d, '.record-000007.dat.stage'), 'owned debt')
		],
		['terminal reentry refusal', (d) => fs.writeFileSync(path.join(d, 'refusal.json'), '{}')],
		['foreign directory member', (d) => fs.writeFileSync(path.join(d, 'foreign.json'), '{}')],
		[
			'nonterminal phase',
			(d) =>
				terminal(d, (x) => {
					x.phase = 'publishing';
				})
		],
		[
			'encoding refusal payload',
			(d) => {
				const file = path.join(d, 'record-000001.dat');
				const bytes = Buffer.from(
					'TIS_TEST_EVIDENCE {"version":1,"diagnosticEncodingRefused":true}\n'
				);
				fs.writeFileSync(file, bytes);
				terminal(d, (x) => {
					x.records[0].bytes = bytes.length;
					x.records[0].sha256 = require('node:crypto')
						.createHash('sha256')
						.update(bytes)
						.digest('hex');
				});
			}
		]
	]) {
		const directory = fixture();
		mutate(directory);
		assert.throws(() => validateTIS(directory, sessionNonce), name);
		fs.rmSync(directory, { recursive: true });
	}
	assert.throws(() => validateTIS(good, 'b'.repeat(64)), 'caller owns exact session nonce');
	assert.throws(() => validateTIS(good, ''), 'missing env never falls back');
	if (process.platform !== 'win32') {
		const directory = fixture();
		const target = path.join(directory, 'record-000001.dat');
		fs.renameSync(target, path.join(transportRoot, 'foreign-record'));
		fs.symlinkSync(path.join(transportRoot, 'foreign-record'), target);
		assert.throws(
			() => validateTIS(directory, sessionNonce),
			'foreign symlink cannot supply evidence'
		);
	}
	const uploaded = pipeline.step(
		pipeline.job('package-macos'),
		'Retain closed TIS diagnostic session'
	);
	assert.equal(
		pipeline.stepField(uploaded, 'if'),
		"${{ always() && steps.swift-launcher-tests.outcome != 'skipped' && steps.swift-launcher-tests.outputs.tis_session_dir != '' }}"
	);
	assert.match(uploaded, /steps\.swift-launcher-tests\.outputs\.tis_session_dir/);
	assert.doesNotMatch(uploaded, /runner\.temp|\/tmp|\*\*/);
	assert.match(uploaded, /if-no-files-found: error/);
	const commands = pipeline
		.runOf(pipeline.step(pipeline.job('package-macos'), 'Run Swift launcher tests'))
		.join('\n');
	assert.match(commands, /mktemp -d .*tis-session\.XXXXXX/);
	assert.match(commands, /randomBytes\(32\)/);
	assert.match(commands, /tis_evidence_transport\.cjs/);
	assert.ok(
		commands.indexOf('swift_xctest_evidence.cjs') < commands.indexOf('tis_evidence_transport.cjs')
	);
	// Execute the actual mandatory workflow gate after a successful raw suite,
	// with a genuinely missing terminal or wholly lost final artifact file.
	for (const lost of ['manifest.json', 'record-000006.dat']) {
		const runner = path.join(transportRoot, 'workflow-' + lost);
		fs.mkdirSync(runner, { mode: 0o700 });
		const transcript = path.join(runner, 'native.log');
		fs.writeFileSync(transcript, withOwnedProgramCases(passed));
		const producer = path.join(runner, 'producer.cjs');
		fs.writeFileSync(
			producer,
			'(' +
				makeControlledSession.toString() +
				')(process.env.ERGOPTI_TIS_EVIDENCE_DIR,process.env.ERGOPTI_TIS_EVIDENCE_SESSION);' +
				'require("node:fs").unlinkSync(require("node:path").join(process.env.ERGOPTI_TIS_EVIDENCE_DIR,' +
				JSON.stringify(lost) +
				'));'
		);
		const harness =
			controlledCheckout +
			fixtureCheckpointHarness(commands, runner) +
			'script() { node "$SWIFT_FIXTURE_PUBLISHER" || return $?; cat "$SWIFT_FIXTURE_LOG"; }\n' +
			commands;
		const result = spawnSync(bashExecutable(), ['-c', harness], {
			cwd: repository,
			env: {
				...process.env,
				SWIFT_FIXTURE_PLATFORM: process.platform,
				SWIFT_FIXTURE_NODE: process.execPath.replaceAll('\\', '/'),
				SWIFT_FIXTURE_TIS_PORT: path
					.join(__dirname, 'fixtures/tis_fixture_metadata_port.cjs')
					.replaceAll('\\', '/'),
				SWIFT_FIXTURE_PYTHON_PORT: path
					.join(__dirname, 'fixtures/swift_workflow_checkpoint_port.py')
					.replaceAll('\\', '/'),
				SWIFT_FIXTURE_PYTHON_BODY: path.join(runner, 'workflow-publisher.py').replaceAll('\\', '/'),
				SWIFT_FIXTURE_PYTHON: pythonExecutable.replaceAll('\\', '/'),
				RUNNER_TEMP: runner.replaceAll('\\', '/'),
				GITHUB_OUTPUT: path.join(runner, 'outputs').replaceAll('\\', '/'),
				SWIFT_FIXTURE_PUBLISHER: producer.replaceAll('\\', '/'),
				SWIFT_FIXTURE_LOG: transcript.replaceAll('\\', '/')
			},
			encoding: 'utf8'
		});
		assert.equal(result.error, undefined);
		assert.equal(result.status, 1, 'Lost TIS transport evidence defeats a successful raw suite');
		assert.match(result.stderr, /TIS diagnostic session is incomplete or refused/);
		const verdict = JSON.parse(
			fs.readFileSync(path.join(runner, 'swift-launcher-evidence/verdict.json'))
		);
		assert.equal(verdict.exit_status, 0, 'The raw XCTest owner keeps its own unchanged verdict');
	}
	// A raw receipt glued after any diagnostic still refuses unchanged.
	const mixed = passed.replace(
		"Test Case '-[ErgoptiPlusTests.WindowTitlePolicyTests testPrivatePolicies]' passed",
		'TIS_TEST_EVIDENCE {"unclosed":' +
			"Test Case '-[ErgoptiPlusTests.WindowTitlePolicyTests testPrivatePolicies]' passed"
	);
	assert.equal(evaluate(mixed, 0, 0).exit_status, 1);
	assert.equal(
		validateTIS(good, sessionNonce).complete,
		true,
		'artifact success cannot repair a raw XCTest refusal'
	);
} finally {
	fs.rmSync(transportRoot, { recursive: true, force: true });
}
console.log(
	'[OK] Six lossless closed records, Unicode, source identity and twenty-one mandatory refusal cases are admitted independently of raw XCTest.'
);

// Fixed archive outcomes are independently judged from authentic XCTest terminals.
// These fixtures are authored here, not regenerated from the reporter projection.
{
	const {
		archiveAnnotation,
		archiveOutcomes,
		main
	} = require('../diagnostics/swift_xctest_evidence.cjs');
	const brewCase =
		'-[ErgoptiPlusTests.HomebrewArchiveAcceptanceTests testRealBrewZIPInstallXZUpgradeAndRefusalsPreserveInstalledState]';
	const sparkleCase =
		'-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests testActualSparkleTarXZUpdateRefusesWrongKeyPreservesOldAppAndRetriesThroughRelaunch]';
	const mixed = [
		"Test Suite 'All tests' started at 2026-10-05 01:00:00.000.",
		`Test Case '${brewCase}' started.`,
		'private helper exited zero; receipt.checked; cleanup.closed',
		`Test Case '${brewCase}' failed (0.100 seconds).`,
		`Test Case '${sparkleCase}' started.`,
		`Test Case '${sparkleCase}' passed (0.200 seconds).`,
		"Test Suite 'All tests' failed at 2026-10-05 01:00:01.000.",
		'\t Executed 2 tests, with 1 failure (0 unexpected) in 0.300 (0.310) seconds',
		'◇ Test run started.',
		'✔ Test run with 0 tests passed after 0.001 seconds.'
	].join('\n');
	const expectedMixed = [
		{
			schema: 1,
			case: 'brew',
			outcome: 'FAIL',
			basis: 'exact-xctest-completion',
			script_status: 1,
			capture_status: 0
		},
		{
			schema: 1,
			case: 'sparkle',
			outcome: 'PASS',
			basis: 'exact-xctest-completion',
			script_status: 1,
			capture_status: 0
		}
	];
	assert.deepEqual(
		archiveOutcomes(mixed, 1, 0),
		expectedMixed,
		'authentic Sparkle PASS is visible while Brew makes the global suite FAIL'
	);
	assert.equal(
		evaluate(mixed, 1, 0).exit_status,
		1,
		'case PASS cannot override the global verdict'
	);
	assert.equal(evaluate(mixed, 1, 0).complete, false);
	assert.equal(
		archiveOutcomes(mixed, 1, 0)[0].outcome,
		'FAIL',
		'failure after helper/cleanup progress remains the actual case FAIL'
	);
	const allPassed = mixed
		.replace(`Test Case '${brewCase}' failed`, `Test Case '${brewCase}' passed`)
		.replace("Test Suite 'All tests' failed", "Test Suite 'All tests' passed")
		.replace('with 1 failure', 'with 0 failures');
	assert.deepEqual(
		archiveOutcomes(allPassed, 0, 0).map((receipt) => receipt.outcome),
		['PASS', 'PASS']
	);
	assert.equal(evaluate(allPassed, 0, 0).exit_status, 0);
	assert.deepEqual(
		archiveOutcomes('\x1b[32m' + allPassed.replaceAll('\n', '\r\n') + '\x1b[0m', 0, 0),
		archiveOutcomes(allPassed, 0, 0),
		'styling and PTY CRLF retain the same authentic receipts'
	);
	const skipped = allPassed
		.replace(`Test Case '${brewCase}' passed`, `Test Case '${brewCase}' skipped`)
		.replace('with 0 failures', 'with 1 test skipped and 0 failures');
	assert.deepEqual(
		archiveOutcomes(skipped, 0, 0).map((receipt) => receipt.outcome),
		['SKIP', 'PASS']
	);
	assert.equal(
		evaluate(skipped, 0, 0).exit_status,
		1,
		'genuine SKIP remains distinct and globally refused'
	);
	const unavailable = [
		['missing transcript/API absence', '', 0, 0],
		['capture failure', allPassed, 0, 17],
		['capture failure during failed suite', mixed, 1, 17],
		['native nonzero contradicts successful suite', allPassed, 42, 0],
		['missing case start', mixed.replace(`Test Case '${sparkleCase}' started.\n`, ''), 1, 0],
		[
			'missing case terminal',
			mixed.replace(`Test Case '${sparkleCase}' passed (0.200 seconds).\n`, ''),
			1,
			0
		],
		[
			'duplicate case start',
			mixed.replace(
				`Test Case '${sparkleCase}' started.`,
				`Test Case '${sparkleCase}' started.\nTest Case '${sparkleCase}' started.`
			),
			1,
			0
		],
		[
			'duplicate terminal',
			mixed.replace(
				`Test Case '${sparkleCase}' passed (0.200 seconds).`,
				`Test Case '${sparkleCase}' passed (0.200 seconds).\nTest Case '${sparkleCase}' passed (0.200 seconds).`
			),
			1,
			0
		],
		[
			'conflicting terminal',
			mixed.replace(
				`Test Case '${sparkleCase}' passed (0.200 seconds).`,
				`Test Case '${sparkleCase}' passed (0.200 seconds).\nTest Case '${sparkleCase}' failed (0.200 seconds).`
			),
			1,
			0
		],
		['truncated suite', mixed.slice(0, mixed.indexOf("Test Suite 'All tests' failed")), 1, 0],
		[
			'missing root start',
			mixed.replace("Test Suite 'All tests' started at 2026-10-05 01:00:00.000.\n", ''),
			1,
			0
		],
		[
			'restarted root',
			mixed + "\nTest Suite 'All tests' started at 2026-10-05 01:00:02.000.",
			1,
			0
		],
		['terminal after root', mixed + `\nTest Case '${sparkleCase}' passed (0.200 seconds).`, 1, 0],
		['case before root', `Test Case '${sparkleCase}' started.\n` + mixed, 1, 0],
		['malformed terminal', mixed.replace('(0.200 seconds).', '(unknown seconds).'), 1, 0],
		['count mismatch', mixed.replace('Executed 2 tests', 'Executed 3 tests'), 1, 0],
		[
			'missing summary',
			mixed.replace(
				'\t Executed 2 tests, with 1 failure (0 unexpected) in 0.300 (0.310) seconds\n',
				''
			),
			1,
			0
		],
		['malformed summary', mixed.replace('(0 unexpected)', '(unknown unexpected)'), 1, 0],
		['failed root without failures', mixed.replace('with 1 failure', 'with 0 failures'), 1, 0],
		[
			'passed root with failure',
			mixed.replace("Test Suite 'All tests' failed", "Test Suite 'All tests' passed"),
			0,
			0
		],
		['unexpected exceeds failures', mixed.replace('(0 unexpected)', '(2 unexpected)'), 1, 0],
		['vacuous Swift Testing success', '✔ Test run with 0 tests passed after 0.001 seconds.', 0, 0]
	];
	for (const [reason, text, scriptStatus, captureStatus] of unavailable)
		assert.deepEqual(
			archiveOutcomes(text, scriptStatus, captureStatus).map((receipt) => receipt.outcome),
			['UNAVAILABLE', 'UNAVAILABLE'],
			reason
		);
	const unrelated =
		allPassed
			.replaceAll(brewCase, '-[ErgoptiPlusTests.OtherTests testOther]')
			.replaceAll(sparkleCase, '-[ErgoptiPlusTests.OtherTests testOtherTwo]') +
		'\n::notice::sparkle PASS';
	assert.deepEqual(
		archiveOutcomes(unrelated, 0, 0).map((receipt) => receipt.outcome),
		['UNAVAILABLE', 'UNAVAILABLE'],
		'arbitrary tests and annotation text cannot supply archive success'
	);
	assert.equal(
		archiveAnnotation({
			...expectedMixed[1],
			private: 'https://private.invalid/path?nonce=secret'
		}),
		'::notice title=Native archive XCTest outcome::{"schema":1,"case":"sparkle","outcome":"PASS","basis":"exact-xctest-completion","script_status":1,"capture_status":0}'
	);
	for (const change of [
		{ case: 'private/path' },
		{ outcome: 'unknown' },
		{ basis: 'helper-zero' },
		{ capture_status: 256 }
	])
		assert.throws(() => archiveAnnotation({ ...expectedMixed[1], ...change }));
	for (const status of [-1, 256, '01', '', '0\n::notice::PASS'])
		assert.throws(() => archiveOutcomes(mixed, status, 0));
	const archiveRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-archive-outcomes-'));
	try {
		const transcriptPath = path.join(archiveRoot, 'native.log');
		const verdictPath = path.join(archiveRoot, 'verdict.json');
		fs.writeFileSync(transcriptPath, mixed);
		const output = [];
		assert.equal(
			main([transcriptPath, '1', '0', verdictPath], (line) => output.push(line)),
			1
		);
		assert.deepEqual(
			JSON.parse(fs.readFileSync(verdictPath, 'utf8')).archive_outcomes,
			expectedMixed
		);
		assert.deepEqual(
			output.filter((line) => line.startsWith('::notice ')),
			[
				'::notice title=Native archive XCTest outcome::{"schema":1,"case":"brew","outcome":"FAIL","basis":"exact-xctest-completion","script_status":1,"capture_status":0}',
				'::notice title=Native archive XCTest outcome::{"schema":1,"case":"sparkle","outcome":"PASS","basis":"exact-xctest-completion","script_status":1,"capture_status":0}'
			]
		);
		assert.ok(
			output.some((line) => line.startsWith('::error ')),
			'old global failure annotations remain present'
		);
		const lost = [];
		assert.equal(
			main([path.join(archiveRoot, 'missing'), '42', '0', verdictPath], (line) => lost.push(line)),
			42
		);
		assert.deepEqual(
			lost
				.filter((line) => line.startsWith('::notice '))
				.map((line) => JSON.parse(line.split('::')[2]).outcome),
			['UNAVAILABLE', 'UNAVAILABLE'],
			'lost transcript cannot publish success'
		);
	} finally {
		fs.rmSync(archiveRoot, { recursive: true, force: true });
	}
	console.log(
		'[OK] Exact native Brew/Sparkle XCTest outcomes remain bounded, retrievable and independent of the global failure verdict.'
	);
}
