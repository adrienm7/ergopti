// CI-only diagnostic for the independently reviewed native program test inventory.
// The shared collector and its native/tee status remain the owning suite verdict.
'use strict';

const fs = require('node:fs');
const { cleanTranscript, evaluate, readPacQualification } = require('./swift_xctest_evidence.cjs');

// Fixed reviewed inventory, deliberately independent of source discovery/generation.
const EXPECTED = Object.freeze([
	'testLiteralRawUnicodeArgumentsRemainHeldUntilActivation',
	'testSourceChangeBeforeActivationCannotProduceSideEffect',
	'testIndependentPOSIXScriptWithUnicodePathPreservesLiteralArgumentsAndPrivateStreams',
	'testCancelledHeldPayloadNeverActivates',
	'testSymlinkTargetChangedToFIFOCannotBlockCancellationOrExecutePayload',
	'testLeaderExitCannotSettleTermResistantOutputtingDescendant',
	'testLargePrivateStreamsNeverReachControlPipesAndNonzeroStatusIsExact',
	'testEOFWhileExitedLeaderHasLiveDescendantStillProvesGroupRetirement',
	'testEOFBeforeActivationCancelsPhysicalHeldChild',
	'testEOFBeforeAnyRequestReturnsProvenConstructorRefusal',
	'testIncompleteRequestThenEOFReturnsProvenConstructorRefusal',
	'testMissingExecutableReturnsClosedConstructorRefusal',
	'testExistingSymlinkedCanonicalSourceStillAdmitsRawPreimage',
	'testMalformedRequestsAndReceiptsFailClosedWithoutQuotingSecrets'
]);

function status(value) {
	return Number.isInteger(value) && value >= 0 && value <= 255;
}

// Darwin XCTest and the fully qualified SwiftPM spelling are the supported forms.
function ownedMethod(name) {
	const match =
		/^-\[ErgoptiPlusTests\.OwnedProgramWorkerTests (test[A-Za-z0-9_]+)\]$/.exec(name) ||
		/^ErgoptiPlusTests\.OwnedProgramWorkerTests\.(test[A-Za-z0-9_]+)$/.exec(name);
	return match ? match[1] : String(name).includes('OwnedProgramWorkerTests') ? '' : null;
}

// JSON omits undefined optional fields; no other shape/type coercion is allowed.
function sameFailure(receipt, actual) {
	if (
		!receipt ||
		typeof receipt !== 'object' ||
		Array.isArray(receipt) ||
		Object.keys(receipt).some((key) => !['message', 'file', 'line'].includes(key)) ||
		typeof receipt.message !== 'string' ||
		receipt.message.length === 0 ||
		(receipt.file !== undefined &&
			(typeof receipt.file !== 'string' || receipt.file.length === 0)) ||
		(receipt.line !== undefined && (!Number.isSafeInteger(receipt.line) || receipt.line < 0))
	)
		return false;
	return (
		receipt.message === actual.message &&
		receipt.file === actual.file &&
		receipt.line === actual.line
	);
}

function empty(reason) {
	return {
		own_qualified: false,
		root_qualified: false,
		expected: 14,
		started: 'unknown',
		completed: 'unknown',
		passed: 'unknown',
		unexecuted: 'unknown',
		skipped: 0,
		failed: 0,
		duplicate: 0,
		unexpected: 0,
		ordering: 0,
		reason,
		script: 'unknown',
		capture: 'unknown',
		collector: 'unknown'
	};
}

function judge(verdict, transcript, admission = null) {
	const result = empty('invalid-evidence');
	if (
		!verdict ||
		verdict.schema_version !== 1 ||
		typeof verdict.complete !== 'boolean' ||
		!status(verdict.script_status) ||
		!status(verdict.tee_status) ||
		!status(verdict.exit_status) ||
		!Array.isArray(verdict.failures) ||
		!Array.isArray(verdict.completed_tests) ||
		typeof transcript !== 'string'
	)
		return result;
	if (
		!verdict.completed_tests.every(
			(test) =>
				test &&
				typeof test.name === 'string' &&
				['passed', 'failed', 'skipped'].includes(test.result)
		)
	)
		return result;
	result.script = verdict.script_status;
	result.capture = verdict.tee_status;
	result.collector = verdict.exit_status;
	const parsed = evaluate(
		transcript,
		verdict.script_status,
		verdict.tee_status,
		undefined,
		admission
	);
	const sameSummary =
		(verdict.summary === null && parsed.summary === null) ||
		(verdict.summary &&
			parsed.summary &&
			['tests', 'failures', 'unexpected'].every(
				(key) => verdict.summary[key] === parsed.summary[key]
			));
	if (
		!sameSummary ||
		JSON.stringify(verdict.qualification) !== JSON.stringify(parsed.qualification) ||
		verdict.complete !== parsed.complete ||
		verdict.exit_status !== parsed.exit_status ||
		verdict.failures.length !== parsed.failures.length ||
		!verdict.failures.every((receipt, index) => sameFailure(receipt, parsed.failures[index])) ||
		verdict.completed_tests.length !== parsed.completed_tests.length ||
		!verdict.completed_tests.every(
			(test, i) =>
				test.name === parsed.completed_tests[i].name &&
				test.result === parsed.completed_tests[i].result
		)
	)
		return result;
	const receipts = new Map(EXPECTED.map((name) => [name, { starts: 0, ends: 0, passed: 0 }]));
	for (const line of cleanTranscript(transcript).split('\n')) {
		const start = /^Test Case '(.+)' started\.$/.exec(line);
		const end = /^Test Case '(.+)' (passed|failed|skipped) \(/.exec(line);
		if (!start && !end) continue;
		const method = ownedMethod((start || end)[1]);
		if (method === null) continue;
		if (!receipts.has(method)) {
			result.unexpected++;
			continue;
		}
		const receipt = receipts.get(method);
		if (start) {
			receipt.starts++;
			continue;
		}
		if (receipt.starts !== 1 || receipt.ends !== 0) result.ordering++;
		receipt.ends++;
		if (end[2] === 'passed') receipt.passed++;
		if (end[2] === 'skipped') result.skipped++;
		if (end[2] === 'failed') result.failed++;
	}

	result.started = [...receipts.values()].filter((receipt) => receipt.starts > 0).length;
	result.completed = [...receipts.values()].filter((receipt) => receipt.ends > 0).length;
	result.passed = [...receipts.values()].filter(
		(receipt) => receipt.passed === 1 && receipt.ends === 1
	).length;
	result.unexecuted = 14 - result.started;
	result.duplicate = [...receipts.values()].filter(
		(receipt) => receipt.starts > 1 || receipt.ends > 1
	).length;
	result.own_qualified =
		result.unexpected === 0 &&
		result.ordering === 0 &&
		[...receipts.values()].every(
			(receipt) => receipt.starts === 1 && receipt.ends === 1 && receipt.passed === 1
		);
	result.root_qualified =
		parsed.qualification === undefined &&
		parsed.complete &&
		parsed.script_status === 0 &&
		parsed.tee_status === 0 &&
		parsed.exit_status === 0 &&
		parsed.failures.length === 0;
	result.reason = result.own_qualified ? 'own-receipts-complete' : 'own-receipts-incomplete';
	return result;
}

function main(args = process.argv.slice(2), log = console.log) {
	let result = empty('input-unavailable');
	const validArgs =
		args.length === 3 || (args.length === 5 && args[3] === '--pac-qualification-receipt');
	const sha = validArgs && /^[0-9a-f]{40}$/.test(args[2]) ? args[2] : 'unknown';
	if (sha !== 'unknown') {
		try {
			result = judge(
				JSON.parse(fs.readFileSync(args[0], 'utf8')),
				fs.readFileSync(args[1], 'utf8'),
				args.length === 5 ? readPacQualification(args[4]) : null
			);
		} catch {
			result = empty('invalid-evidence');
		}
	}
	const level = result.own_qualified ? 'notice' : 'warning';
	// Fixed labels, counts and a validated commit only; never echo input names/text.
	log(
		`::${level} title=Owned program native XCTest::sha=${sha}; own_qualified=${result.own_qualified}; root_xctest_qualified=${result.root_qualified}; expected=14; started=${result.started}; completed=${result.completed}; passed=${result.passed}; unexecuted=${result.unexecuted}; skipped=${result.skipped}; failed=${result.failed}; duplicate=${result.duplicate}; unexpected=${result.unexpected}; ordering=${result.ordering}; script=${result.script}; capture=${result.capture}; collector=${result.collector}; reason=${result.reason}.`
	);
	return result.own_qualified ? 0 : 1;
}

module.exports = { judge, main };
if (require.main === module) process.exitCode = main();
