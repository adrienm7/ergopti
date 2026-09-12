// tools/test/test-js-suite-failure-diagnostics.cjs

/** Verify failure receipts through the real runner without launching its suites. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'run-js-suite.cjs'), 'utf8');

function run(failure) {
	const output = [];
	let calls = 0;
	let exitCode;
	vm.runInNewContext(source, {
		__dirname,
		require(name) {
			if (name === 'child_process') return {
				spawnSync() { return calls++ === 0 ? failure : { status: 0 }; },
			};
			assert.equal(name, 'path');
			return path;
		},
		console: { log: (...args) => output.push(args.join(' ')) },
		process: {
			argv: [], stdout: { write: value => output.push(value) },
			exit: code => { exitCode = code; },
		},
	}, { filename: 'run-js-suite.cjs' });
	assert.ok(calls > 1, 'the real runner must execute its registered checks');
	assert.equal(exitCode, 1, 'a child failure must keep the aggregate red');
	return output.join('\n');
}

const stack = Array.from({ length: 40 }, (_, i) => `    at syntheticFrame${i}`);
const long = run({ status: 1, stdout: stack.join('\n'),
	stderr: ['Error: synthetic native failure ETIMEDOUT',
	...stack, 'synthetic-terminal-detail'].join('\r\n') });
assert.ok(long.includes('Error: synthetic native failure ETIMEDOUT'),
	'the error headline must survive a long stack');
assert.ok(long.includes('synthetic-terminal-detail'), 'retain the terminal detail');
assert.ok(long.includes('lines omitted'), 'report truncation explicitly');
assert.ok(!long.includes('syntheticFrame20'), 'bound the displayed stack');

const short = run({ status: 7, stdout: 'synthetic-single-line\n' });
assert.equal(short.split('synthetic-single-line').length - 1, 1,
	'short diagnostics must not be duplicated by head and tail');
assert.ok(short.includes('status=7'), 'retain the native exit status');

const spawn = run({ status: null, signal: null, error: { code: 'ENOENT' } });
assert.ok(spawn.includes('ENOENT'), 'an empty-output spawn failure needs its error code');
const signal = run({ status: null, signal: 'SIGTERM' });
assert.ok(signal.includes('SIGTERM'), 'retain termination by signal');

console.log('JS suite failure diagnostics: OK');
