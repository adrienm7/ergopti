// tools/test/test-linux-updater-archive-receipt.cjs
'use strict';
const assert = require('node:assert/strict');
const runner = require('./run-linux-updater-archive-native.cjs');
const labels = [
	'actual source resolves genuine standalone installation',
	'selected checksum dispatch has actual owned admission',
	'one actual archive receipt waits retained physical owners',
	'actual loop and exact namespace descriptor owners physically drain'
];
const lines = [];
for (const mode of ['happy', 'wrong_digest', 'smoke_rollback']) {
	for (let ordinal = 0; ordinal < 2; ordinal++) {
		lines.push('Native subreaper: 0 adopted descendants physically reaped');
		lines.push('Native subreaper closure: {"adopted":0,"pending":0,"rescue":0}');
	}
	for (const name of [
		...labels.slice(0, 3),
		mode === 'happy' || mode === 'smoke_rollback'
			? 'actual verified brand enters native tar installation'
			: 'wrong digest exposes zero verified installation authority',
		labels[3]
	])
		lines.push('PIPELINE_PASS ' + mode + ' ' + name);
	lines.push('PIPELINE_RESULT ' + mode + ' passed=5 failed=0 skipped=0');
}
lines.push('PIPELINE_NATIVE_RESULT cases=3 checks=15 failed=0 skipped=0 closure=complete');
const good = { status: 0, signal: null, error: null, stdout: lines.join('\n') + '\n', stderr: '' };
let count = 0;
function control(name, fn) {
	fn();
	count++;
}
control('literal complete corpus admits', () => assert.equal(runner.pipelineReceipt(good), true));
control('nonzero exit refuses', () =>
	assert.equal(runner.pipelineReceipt({ ...good, status: 1 }), false)
);
control('unknown closure refuses', () =>
	assert.equal(runner.pipelineReceipt({ ...good, error: 'owned_cleanup_pending' }), false)
);
control('signal refuses', () =>
	assert.equal(runner.pipelineReceipt({ ...good, signal: 'SIGTERM' }), false)
);
control('stderr refuses', () =>
	assert.equal(runner.pipelineReceipt({ ...good, stderr: 'private failure' }), false)
);
control('partial happy check refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: good.stdout.replace(
				'PIPELINE_PASS happy selected checksum dispatch has actual owned admission\n',
				''
			)
		}),
		false
	)
);
control('duplicate check refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout:
				'PIPELINE_PASS happy actual source resolves genuine standalone installation\n' + good.stdout
		}),
		false
	)
);
control('wrong case name refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: good.stdout.replace('PIPELINE_PASS wrong_digest', 'PIPELINE_PASS foreign')
		}),
		false
	)
);
control('missing case terminal refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: good.stdout.replace('PIPELINE_RESULT wrong_digest passed=5 failed=0 skipped=0\n', '')
		}),
		false
	)
);
control('duplicate terminal refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: 'PIPELINE_RESULT happy passed=5 failed=0 skipped=0\n' + good.stdout
		}),
		false
	)
);
control('skipped case refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: good.stdout.replace('passed=5 failed=0 skipped=0', 'passed=5 failed=0 skipped=1')
		}),
		false
	)
);
control('missing final summary refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: good.stdout.replace(
				'PIPELINE_NATIVE_RESULT cases=3 checks=15 failed=0 skipped=0 closure=complete\n',
				''
			)
		}),
		false
	)
);
control('extra final summary refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout:
				good.stdout +
				'PIPELINE_NATIVE_RESULT cases=3 checks=15 failed=0 skipped=0 closure=complete\n'
		}),
		false
	)
);
control('pending guardian refuses', () =>
	assert.equal(
		runner.pipelineReceipt({ ...good, stdout: good.stdout.replace('"pending":0', '"pending":1') }),
		false
	)
);
control('rescue guardian refuses', () =>
	assert.equal(
		runner.pipelineReceipt({ ...good, stdout: good.stdout.replace('"rescue":0', '"rescue":1') }),
		false
	)
);
control('missing guardian closure refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: good.stdout.replace(
				'Native subreaper closure: {"adopted":0,"pending":0,"rescue":0}\n',
				''
			)
		}),
		false
	)
);
control('mismatched adopted summary refuses', () =>
	assert.equal(
		runner.pipelineReceipt({ ...good, stdout: good.stdout.replace('"adopted":0', '"adopted":1') }),
		false
	)
);
control('fixed failure marker refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: 'PIPELINE_DEBT unresolved native owners\n' + good.stdout
		}),
		false
	)
);
control('missing final LF refuses truncation', () =>
	assert.equal(runner.pipelineReceipt({ ...good, stdout: good.stdout.slice(0, -1) }), false)
);
assert.equal(count, 19);
console.log('Archive receipt model: 19 controls passed; 0 skipped.');

// Third-case proof remains mandatory; the old first-two-only corpus cannot qualify it.
control('missing rollback invocation case refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: good.stdout
				.split('\n')
				.filter((line) => !line.includes('smoke_rollback'))
				.join('\n')
		}),
		false
	)
);
control('duplicate rollback terminal refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: 'PIPELINE_RESULT smoke_rollback passed=5 failed=0 skipped=0\n' + good.stdout
		}),
		false
	)
);
control('partial rollback guardian refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: good.stdout.replace(
				'Native subreaper closure: {"adopted":0,"pending":0,"rescue":0}\n',
				''
			)
		}),
		false
	)
);
control('old whole two-case summary refuses', () =>
	assert.equal(
		runner.pipelineReceipt({
			...good,
			stdout: good.stdout.replace('cases=3 checks=15', 'cases=2 checks=10')
		}),
		false
	)
);
assert.equal(count, 23, 'Old19 plus four independent rollback receipt refusals');
console.log('Archive rollback receipt model: 4 additional controls passed; 0 skipped.');
