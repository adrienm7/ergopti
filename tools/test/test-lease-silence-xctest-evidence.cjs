// tools/test/test-lease-silence-xctest-evidence.cjs
'use strict';

/** Independent single-case transcript controls; these are not native execution receipts. */
const assert = require('node:assert/strict');
const { evaluate, context } = require('../diagnostics/lease_silence_xctest_evidence.cjs');
const name =
	'-[ErgoptiPlusTests.KarabinerLeaseWorkerTests testRealInnerSilenceExitZeroBecomesOuterFailureAfterReady]';
const lines = [
	"Test Suite 'Selected tests' started at 2026-10-11 00:00:00.000.",
	"Test Suite 'ErgoptiPlusPackageTests.xctest' started at 2026-10-11 00:00:00.000.",
	"Test Suite 'KarabinerLeaseWorkerTests' started at 2026-10-11 00:00:00.000.",
	`Test Case '${name}' started.`,
	`Test Case '${name}' passed (17.752 seconds).`,
	"Test Suite 'KarabinerLeaseWorkerTests' passed at 2026-10-11 00:00:17.752.",
	' Executed 1 test, with 0 failures (0 unexpected) in 17.752 (17.752) seconds',
	"Test Suite 'ErgoptiPlusPackageTests.xctest' passed at 2026-10-11 00:00:17.752.",
	' Executed 1 test, with 0 failures (0 unexpected) in 17.752 (17.752) seconds',
	"Test Suite 'Selected tests' passed at 2026-10-11 00:00:17.752.",
	' Executed 1 test, with 0 failures (0 unexpected) in 17.752 (17.752) seconds'
];
const good = lines.join('\n') + '\n';
let passed = 0;
function check(label, fn) {
	fn();
	passed++;
	console.log('PASS ' + label);
}
function refused(label, text, swift = '0', capture = '0') {
	check(label, () => assert.equal(evaluate(text, swift, capture).complete, false));
}
check('one complete exact real-case transcript is admitted only within its scope', () => {
	const result = evaluate(good, '0', '0');
	assert.equal(result.complete, true);
	assert.equal(result.observed, 1);
	assert.equal(result.native_karabiner_qualified, false);
	assert.equal(result.hammerspoon_scheduling_qualified, false);
	assert.equal(result.user_exit73_resolved, false);
	assert.equal(result.full_suite_qualified, false);
});
check('PTY CRLF and ANSI styling do not replace exact frames', () => {
	assert.equal(
		evaluate('\x1b[32m' + good.replaceAll('\n', '\r\n') + '\x1b[0m', 0, 0).complete,
		true
	);
});
refused('absent selected case cannot qualify', 'Build complete!\n');
refused(
	'trailing Swift Testing zero-test success cannot qualify',
	'Test run with 0 tests passed after 0.001 seconds.\n'
);
refused(
	'skipped method cannot qualify',
	good.replace('passed (17.752 seconds).', 'skipped (17.752 seconds).')
);
refused(
	'failed method cannot qualify',
	good.replace('passed (17.752 seconds).', 'failed (17.752 seconds).')
);
refused('missing start cannot qualify', lines.filter((_, i) => i !== 3).join('\n'));
refused('missing terminal cannot qualify', lines.filter((_, i) => i !== 4).join('\n'));
refused(
	'duplicate selected case cannot qualify',
	[...lines.slice(0, 5), ...lines.slice(3, 5), ...lines.slice(5)].join('\n')
);
refused('duplicate complete runs cannot qualify', good + good);
refused(
	'foreign method cannot qualify',
	good.replaceAll('testRealInnerSilenceExitZeroBecomesOuterFailureAfterReady', 'testAnotherFixture')
);
refused('foreign suite cannot qualify', good.replaceAll('KarabinerLeaseWorkerTests', 'OtherTests'));
refused(
	'zero-test summary cannot qualify',
	good.replaceAll('Executed 1 test,', 'Executed 0 tests,')
);
refused(
	'summary with unexpected failures cannot qualify',
	good.replaceAll('(0 unexpected)', '(1 unexpected)')
);
refused(
	'extra unowned test frame cannot qualify',
	good + "Test Case 'foreign' passed (1 seconds).\n"
);
refused(
	'failed root cannot qualify',
	good.replace("'Selected tests' passed", "'Selected tests' failed")
);
refused(
	'reordered frames cannot qualify',
	[...lines.slice(0, 3), lines[4], lines[3], ...lines.slice(5)].join('\n')
);
refused('native compile error cannot qualify', good + 'error: native compilation refused\n');
refused(
	'the pre-host-stall 6.75-second silence cannot qualify the current native budget',
	good.replace('passed (17.752', 'passed (6.752')
);
refused(
	'too-short fixture duration cannot qualify the unchanged native deadline',
	good.replace('passed (17.752', 'passed (1.000')
);
refused('nonzero Swift status cannot qualify', good, '1', '0');
refused('signaled Swift status cannot qualify', good, '137', '0');
refused('capture refusal cannot qualify', good, '0', '1');
check('noncanonical process statuses are refused', () => {
	for (const value of ['00', '-1', '256', '0\n', 'unavailable'])
		assert.throws(() => evaluate(good, value, '0'));
});
check('receipt cannot disclose arbitrary warning text', () => {
	const raw = 'warning: arbitrary-private-string /Users/private-machine InternalProxy\n';
	const result = evaluate(raw + good, '0', '0');
	assert.equal(result.complete, true);
	assert.equal(JSON.stringify(result).includes('private'), false);
	assert.equal(JSON.stringify(result).includes('InternalProxy'), false);
});
check('exact source run and architecture identity is retained', () => {
	assert.deepEqual(context('a'.repeat(40), '42', '1', 'arm64'), {
		candidate: 'a'.repeat(40),
		run_id: '42',
		run_attempt: '1',
		architecture: 'arm64'
	});
	assert.equal(context('a'.repeat(40), '42', '1', 'amd64').architecture, 'amd64');
});
check('invalid source run or architecture identity is refused', () => {
	for (const args of [
		['bad', '42', '1', 'arm64'],
		['a'.repeat(40), '0', '1', 'arm64'],
		['a'.repeat(40), '42', '01', 'arm64'],
		['a'.repeat(40), '42', '1', 'x86_64']
	])
		assert.throws(() => context(...args));
});

// Preserve the independent direct-child vectors when the normal guard runs.
passed += (() => {
	'use strict';
	const assert = require('node:assert/strict');
	const judge = require('../diagnostics/lease_silence_xctest_evidence.cjs');
	let passed = 0;
	function check(name, fn) {
		fn();
		passed++;
		console.log('PASS ' + name);
	}
	check('canonical direct zero is retained', () => assert.equal(judge.parseChildStatus('0\n'), 0));
	check('canonical direct signaled status is retained', () =>
		assert.equal(judge.parseChildStatus('143\n'), 143)
	);
	for (const raw of ['', '0', '0\n0\n', ' 0\n', '00\n', '256\n', 'PRIVATE-PATH\n'])
		check('refuses malformed direct status ' + JSON.stringify(raw), () =>
			assert.throws(() => judge.parseChildStatus(raw))
		);
	// A closed canonical transcript is independent of producer status.
	const n =
		'-[ErgoptiPlusTests.KarabinerLeaseWorkerTests testRealInnerSilenceExitZeroBecomesOuterFailureAfterReady]';
	const t = [
		"Test Suite 'Selected tests' started at 2026-10-11.",
		"Test Suite 'ErgoptiPlusPackageTests.xctest' started at 2026-10-11.",
		"Test Suite 'KarabinerLeaseWorkerTests' started at 2026-10-11.",
		`Test Case '${n}' started.`,
		`Test Case '${n}' passed (17.752 seconds).`,
		"Test Suite 'KarabinerLeaseWorkerTests' passed at 2026-10-11.",
		' Executed 1 test, with 0 failures (0 unexpected) in 17.752 seconds',
		"Test Suite 'ErgoptiPlusPackageTests.xctest' passed at 2026-10-11.",
		' Executed 1 test, with 0 failures (0 unexpected) in 17.752 seconds',
		"Test Suite 'Selected tests' passed at 2026-10-11.",
		' Executed 1 test, with 0 failures (0 unexpected) in 17.752 seconds'
	].join('\n');
	check('only all three original statuses zero admits', () => {
		const r = judge.evaluateDirect(t, 0, 0, 0);
		assert.equal(r.complete, true);
		assert.equal(r.swift_status, 0);
		assert.equal(r.script_status, 0);
		assert.equal(r.capture_status, 0);
	});
	for (const [name, a, b, c] of [
		['direct failure', 1, 0, 0],
		['direct signal', 143, 0, 0],
		['BSD script failure', 0, 1, 0],
		['capture failure', 0, 0, 1]
	])
		check(name + ' refuses valid frames', () =>
			assert.equal(judge.evaluateDirect(t, a, b, c).complete, false)
		);
	return passed;
})();
check('a second LF cannot qualify a direct-child status', () => {
	const judge = require('../diagnostics/lease_silence_xctest_evidence.cjs');
	assert.throws(() => judge.parseChildStatus('0\n\n'));
});
// The native cell refuses at "begin" when the frozen method or role hash
// drifts; check it here, where any OS sees it before a Mac runner does.
check('the frozen native method and role hashes match the checked-in Swift', () => {
	const fs = require('node:fs');
	const path = require('node:path');
	const judge = require('../diagnostics/lease_silence_xctest_evidence.cjs');
	const launcher = path.join(__dirname, '../../static/ergopti_plus/macos/launcher');
	const test = fs.readFileSync(
		path.join(launcher, 'Tests/ErgoptiPlusTests/RemapLeaseWorkerTests.swift'),
		'utf8'
	);
	const worker = fs.readFileSync(
		path.join(launcher, 'Sources/ErgoptiPlus/RemapLeaseWorker.swift'),
		'utf8'
	);
	judge.validateNativeSources(test, worker);
	assert.throws(() => judge.validateNativeSources(test.replace('silenceBudget', 'budget'), worker));
});
console.log(`RESULT passed=${passed} failed=0 native_executed=0`);
