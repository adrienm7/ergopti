// tools/test/test-wp7-timer-xctest-evidence.cjs
'use strict';
const assert = require('node:assert/strict');
const { evaluate } = require('../diagnostics/wp7_timer_xctest_evidence.cjs');
const name =
	'-[ErgoptiPlusTests.HS274NativePolicyQualificationTests testActualPinnedDispatcherCancellationUsesGenuineOfflineLibrary]';
const date = '2026-10-10 12:00:00.000';
const summary = 'Executed 1 test, with 0 failures (0 unexpected) in 0.100 (0.100) seconds';
const frames = [
	`Test Suite 'Selected tests' started at ${date}.`,
	`Test Suite 'ErgoptiPlusPackageTests.xctest' started at ${date}.`,
	`Test Suite 'HS274NativePolicyQualificationTests' started at ${date}.`,
	`Test Case '${name}' started.`,
	`Test Case '${name}' passed (0.100 seconds).`,
	`Test Suite 'HS274NativePolicyQualificationTests' passed at ${date}.`,
	summary,
	`Test Suite 'ErgoptiPlusPackageTests.xctest' passed at ${date}.`,
	summary,
	`Test Suite 'Selected tests' passed at ${date}.`,
	summary
];
const whole = frames.join('\n') + '\n';
let count = 0;
function check(label, fn) {
	fn();
	count++;
	console.log('PASS ' + label);
}
check('modeled exact one-method complete receipt', () => {
	const result = evaluate(whole, 0, 0);
	assert.equal(result.complete, true);
	assert.equal(result.expected, 1);
	assert.equal(result.passed, 1);
	assert.equal(result.full_package_qualified, false);
});
for (const [label, changed] of [
	['empty', ''],
	['unfinished', frames.slice(0, 8).join('\n')],
	['unknown method', whole.replaceAll(name, name.replace('GenuineOfflineLibrary', 'Foreign'))],
	['failed case', whole.replace('passed (0.100 seconds)', 'failed (0.100 seconds)')],
	['skipped case', whole.replace('passed (0.100 seconds)', 'skipped (0.100 seconds)')],
	['duplicate case', whole.replace(frames[4], frames[4] + '\n' + frames[3] + '\n' + frames[4])],
	['zero summary', whole.replaceAll('Executed 1 test', 'Executed 0 tests')],
	['nonzero summary', whole.replaceAll('with 0 failures', 'with 1 failure')],
	['foreign suite', whole.replaceAll('Selected tests', 'All tests')],
	['misordered case', frames.slice(0, 3).concat(frames[4], frames[3], frames.slice(5)).join('\n')],
	['malformed terminal', whole.replace('passed (0.100 seconds)', 'passed (nan seconds)')],
	['late fatal error', whole + 'fatal error: controlled_failure\n']
])
	check('modeled refusal ' + label, () => assert.equal(evaluate(changed, 0, 0).complete, false));
check('direct Swift child nonzero despite complete transcript', () =>
	assert.equal(evaluate(whole, 1, 0).complete, false)
);
check('capture nonzero despite complete transcript', () =>
	assert.equal(evaluate(whole, 0, 1).complete, false)
);
for (const invalid of ['-1', '256', '00', '1\n', 'unsafe'])
	check('invalid pipeline status ' + JSON.stringify(invalid), () =>
		assert.throws(() => evaluate(whole, invalid, 0))
	);
console.log(`WP7 receiving models: ${count} PASS; native/CLI source and ownership UNRUN.`);
