// Independent fixed transcript/JSON corpus and causal receipt mutations; no native launch.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { judge, main } = require(
	process.env.ERGOPTI_XCTEST_NOTICE_HELPER || '../diagnostics/owned_program_xctest_notice.cjs'
);
const collector = require('../diagnostics/swift_xctest_evidence.cjs');
const fixture = path.join(__dirname, 'fixtures/owned-program-xctest');
const transcript = fs.readFileSync(path.join(fixture, 'complete.xctest.txt'), 'utf8');
const golden = JSON.parse(fs.readFileSync(path.join(fixture, 'complete.json'), 'utf8'));
const sha = '0123456789abcdef0123456789abcdef01234567';
let count = 0;
function check(name, body) {
	body();
	count++;
	console.log('PASS ' + name);
}
function observed(text, script = 0, tee = 0) {
	return collector.evaluate(text, script, tee);
}
const first =
	'-[ErgoptiPlusTests.OwnedProgramWorkerTests testLiteralRawUnicodeArgumentsRemainHeldUntilActivation]';
const start = "Test Case '" + first + "' started.\n";
const end = "Test Case '" + first + "' passed (0.100 seconds).\n";
check('independently authored golden agrees with unchanged owning collector', () => {
	assert.deepEqual(observed(transcript), golden);
	const result = judge(golden, transcript);
	assert.equal(result.own_qualified, true);
	assert.equal(result.root_qualified, true);
	assert.equal(result.started, 14);
	assert.equal(result.completed, 14);
	assert.equal(result.passed, 14);
	assert.equal(result.unexecuted, 0);
});
check('dropping the entire known method cannot borrow a successful thirteen-method suite', () => {
	const text = transcript
		.replace(start, '')
		.replace(end, '')
		.replace('Executed 15 tests', 'Executed 14 tests');
	assert.equal(observed(text).complete, true);
	const result = judge(observed(text), text);
	assert.equal(result.root_qualified, true);
	assert.equal(result.own_qualified, false);
	assert.equal(result.unexecuted, 1);
	assert.equal(result.passed, 13);
});
check('duplicated start is rejected even though collector deduplicates its start set', () => {
	const text = transcript.replace(start, start + start);
	assert.equal(observed(text).complete, true);
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, false);
	assert.equal(result.duplicate, 1);
});
check('duplicated completion cannot qualify', () => {
	const text = transcript.replace(end, end + end);
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, false);
	assert.equal(result.duplicate, 1);
});
check('missing start cannot borrow a passed completion', () => {
	const text = transcript.replace(start, '');
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, false);
	assert.equal(result.unexecuted, 1);
});
check('terminal-before-start cannot borrow a globally complete but unordered receipt', () => {
	const text = transcript.replace(start + end, end + start);
	assert.equal(observed(text).complete, true);
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, false);
	assert.equal(result.ordering, 1);
});
check('missing completion remains unfinished', () => {
	const text = transcript.replace(end, '');
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, false);
	assert.equal(result.started, 14);
	assert.equal(result.completed, 13);
});
check('skip is visible and cannot qualify', () => {
	const text = transcript.replace(end, end.replace(' passed ', ' skipped '));
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, false);
	assert.equal(result.skipped, 1);
	assert.equal(result.passed, 13);
});
check('actual failed own receipt cannot qualify', () => {
	const text = transcript.replace(end, end.replace(' passed ', ' failed '));
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, false);
	assert.equal(result.failed, 1);
});
check('unknown fifteenth owner method does not expand the reviewed inventory', () => {
	const text = transcript.replaceAll(
		"Test Case '-[ErgoptiPlusTests.OtherNativeTests testOtherOwner]",
		"Test Case '-[ErgoptiPlusTests.OwnedProgramWorkerTests testUnexpectedMethod]"
	);
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, false);
	assert.equal(result.unexpected, 2);
});
check('wrong module or malformed owner name is not a native admission', () => {
	const text = transcript.replaceAll(
		'ErgoptiPlusTests.OwnedProgramWorkerTests',
		'ForeignTests.OwnedProgramWorkerTests'
	);
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, false);
	assert.equal(result.started, 0);
	assert.equal(result.unexecuted, 14);
});
check('fully qualified SwiftPM case spelling preserves exact method identity', () => {
	const text = transcript.replaceAll(
		/-\[ErgoptiPlusTests\.OwnedProgramWorkerTests (test[A-Za-z0-9_]+)\]/g,
		'ErgoptiPlusTests.OwnedProgramWorkerTests.$1'
	);
	assert.equal(judge(observed(text), text).own_qualified, true);
});
check('styles and CRLF use the owning collector normalization', () => {
	const text = transcript
		.replaceAll('\n', '\r\n')
		.replace(start.trim(), '\x1b[32m' + start.trim() + '\x1b[0m');
	assert.equal(judge(observed(text), text).own_qualified, true);
});
check('separate other-owner failure does not become full-suite success', () => {
	const text = transcript
		.replace('testOtherOwner]' + "' passed", 'testOtherOwner]' + "' failed")
		.replace("Test Suite 'All tests' passed", "Test Suite 'All tests' failed")
		.replace('with 0 failures', 'with 1 failure');
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, true);
	assert.equal(result.root_qualified, false);
	assert.equal(result.collector, 1);
});
check('nonzero native or transcript capture stays authoritative and separate', () => {
	for (const [script, tee] of [
		[9, 0],
		[0, 7]
	]) {
		const result = judge(observed(transcript, script, tee), transcript);
		assert.equal(result.own_qualified, true);
		assert.equal(result.root_qualified, false);
		assert.equal(result.script, script);
		assert.equal(result.capture, tee);
		assert.equal(result.collector, script || tee);
	}
});
check('missing root summary never becomes complete global qualification', () => {
	const text = transcript.replace(/^Test Suite 'All tests' passed.*\n.*Executed.*\n/m, '');
	const result = judge(observed(text), text);
	assert.equal(result.own_qualified, true);
	assert.equal(result.root_qualified, false);
});
check('empty actual captured run has fourteen missing start receipts', () => {
	const result = judge(observed(''), '');
	assert.equal(result.own_qualified, false);
	assert.equal(result.started, 0);
	assert.equal(result.unexecuted, 14);
});
check('malformed schema/status/records/count/error receipts refuse without inferred starts', () => {
	for (const mutate of [
		(v) => (v.schema_version = 2),
		(v) => (v.script_status = '0'),
		(v) => (v.tee_status = false),
		(v) => (v.exit_status = 999),
		(v) => (v.complete = 'true'),
		(v) => (v.completed_tests[0].result = 'success'),
		(v) => v.completed_tests.pop(),
		(v) => (v.summary.tests = 14),
		(v) => v.failures.push({ message: 'PRIVATE_SENTINEL' })
	]) {
		const value = structuredClone(golden);
		mutate(value);
		const result = judge(value, transcript);
		assert.equal(result.own_qualified, false);
		assert.equal(result.started, 'unknown');
	}
});
check('a foreign or changed transcript cannot reuse the JSON receipt', () => {
	assert.equal(judge(golden, transcript.replace(start, '')).own_qualified, false);
	assert.equal(
		judge(golden, transcript.replaceAll(first, first.replace('testLiteral', 'testChanged')))
			.own_qualified,
		false
	);
});
check('CLI notice contains only closed labels and validated SHA, never input text', () => {
	const lines = [];
	assert.equal(
		main(
			[path.join(fixture, 'complete.json'), path.join(fixture, 'complete.xctest.txt'), sha],
			(line) => lines.push(line)
		),
		0
	);
	assert.equal(lines.length, 1);
	assert.match(lines[0], /own_qualified=true; root_xctest_qualified=true/);
	assert.match(lines[0], /started=14; completed=14; passed=14; unexecuted=0/);
	assert.equal(lines[0].includes(first), false);
	const missing = [];
	assert.equal(
		main(['/PRIVATE_SENTINEL', '/PRIVATE_SENTINEL', sha], (line) => missing.push(line)),
		1
	);
	assert.equal(missing[0].includes('PRIVATE_SENTINEL'), false);
	assert.match(missing[0], /unexecuted=unknown/);
	const invalid = [];
	assert.equal(
		main(
			[
				path.join(fixture, 'complete.json'),
				path.join(fixture, 'complete.xctest.txt'),
				'PRIVATE_SENTINEL'
			],
			(line) => invalid.push(line)
		),
		1
	);
	assert.equal(invalid[0].includes('PRIVATE_SENTINEL'), false);
});
check(
	'same-count null/type/message/file/line mutations cannot borrow actual other-owner failure receipts',
	() => {
		const text = transcript
			.replace('testOtherOwner]' + "' passed", 'testOtherOwner]' + "' failed")
			.replace("Test Suite 'All tests' passed", "Test Suite 'All tests' failed")
			.replace('with 0 failures', 'with 1 failure');
		const original = observed(text);
		assert.equal(
			judge(original, text).own_qualified,
			true,
			'valid other-owner failure remains a scoped positive control'
		);
		for (const mutate of [
			(v) => (v.failures[0] = null),
			(v) => (v.failures[0] = 'PRIVATE_SENTINEL'),
			(v) => (v.failures[0] = []),
			(v) => (v.failures[0].message = 0),
			(v) => (v.failures[0].message = 'PRIVATE_SENTINEL'),
			(v) => (v.failures[0].file = 'PRIVATE_SENTINEL.swift'),
			(v) => (v.failures[0].file = null),
			(v) => (v.failures[0].line = 9),
			(v) => (v.failures[0].line = '9'),
			(v) => (v.failures[0].line = null),
			(v) => (v.failures[0].extra = 'PRIVATE_SENTINEL')
		]) {
			const value = structuredClone(original);
			mutate(value);
			assert.equal(
				value.failures.length,
				original.failures.length,
				'causal mutation must preserve failure count'
			);
			const result = judge(value, text);
			assert.equal(result.own_qualified, false);
			assert.equal(result.reason, 'invalid-evidence');
			assert.equal(result.started, 'unknown');
		}
	}
);
check(
	'exact native diagnostic optional fields survive JSON omission; wrong optional types do not',
	() => {
		const file = path.join(__dirname, 'fixtures', 'owned-program-xctest', 'Fixture.swift');
		const text =
			transcript + file + ':19: error: OtherOwner : controlled independent native diagnostic\n';
		const original = observed(text);
		assert.equal(judge(JSON.parse(JSON.stringify(original)), text).own_qualified, true);
		const outside =
			transcript + '/external/Fixture.swift:19: error: OtherOwner : controlled diagnostic\n';
		const outsideReceipt = observed(outside);
		assert.equal(outsideReceipt.failures[0].file, undefined);
		assert.equal(
			judge(JSON.parse(JSON.stringify(outsideReceipt)), outside).own_qualified,
			true,
			'only legitimately omitted optional undefined file is normalized'
		);
		for (const mutate of [
			(v) => delete v.failures[0].file,
			(v) => delete v.failures[0].line,
			(v) => (v.failures[0].file = 'different.swift'),
			(v) => (v.failures[0].file = 19),
			(v) => (v.failures[0].line = 20),
			(v) => (v.failures[0].line = '19')
		]) {
			const value = structuredClone(original);
			mutate(value);
			assert.equal(value.failures.length, original.failures.length);
			assert.equal(judge(value, text).own_qualified, false);
		}
	}
);

console.log(
	'Owned program XCTest notice: ' + count + ' passed, 0 failed (constructed policy fixtures only).'
);
